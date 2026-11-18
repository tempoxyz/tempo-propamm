//! Run after `forge build`: `cargo test --test onchain -- --ignored`.
//! Deploys only to a fresh local Anvil process, never to an environment RPC.
use propamm_sdk::{
    AccessMode, CancelRequest, Consumed, Error, Exchange, Info, Level, OrderRequest, PostOutcome,
    Price, QuoteError, QuoteRequest, Sequencer, Shape, Sides, SkipReason, SkippedPair,
    alloy::{
        network::TransactionBuilder,
        primitives::{Address, B256, Bytes, U256},
        providers::{Provider, ProviderBuilder},
        rpc::types::{BlockId, TransactionRequest},
        sol,
        sol_types::{SolCall, SolValue},
    },
    bindings::{IVenue, IVenueFactory},
};
use std::{
    net::TcpListener,
    path::Path,
    process::{Child, Command, Stdio},
    time::Duration,
};

sol! { interface Token { function mint(address to, uint256 amount) external; } }

struct Node(Child);
impl Drop for Node {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

async fn deploy<P: Provider>(
    provider: &P,
    from: Address,
    artifact: &str,
    args: Vec<u8>,
) -> Address {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let json: serde_json::Value = serde_json::from_slice(
        &std::fs::read(root.join("out").join(artifact))
            .expect("run forge build from the repository root first"),
    )
    .unwrap();
    let mut code = json["bytecode"]["object"]
        .as_str()
        .unwrap()
        .parse::<Bytes>()
        .unwrap()
        .to_vec();
    code.extend(args);
    let receipt = provider
        .send_transaction(
            TransactionRequest::default()
                .with_from(from)
                .with_deploy_code(code),
        )
        .await
        .unwrap_or_else(|error| panic!("deploy {artifact}: {error}"))
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status());
    receipt.contract_address.unwrap()
}

async fn send<P: Provider>(provider: &P, from: Address, to: Address, data: Vec<u8>) {
    let receipt = provider
        .send_transaction(
            TransactionRequest::default()
                .with_from(from)
                .with_to(to)
                .with_input(data),
        )
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status());
}

/// Mirrors Solidity's `TIP20FactoryMock`: Anvil has no Tempo precompile, so install the test-only factory runtime at
/// the canonical address before a real venue admits its mock tokens.
async fn install_test_tip20_factory<P: Provider>(provider: &P) {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let json: serde_json::Value = serde_json::from_slice(
        &std::fs::read(root.join("out/TIP20FactoryMock.sol/TestTIP20Factory.json"))
            .expect("run forge build from the repository root first"),
    )
    .unwrap();
    let code = json["deployedBytecode"]["object"]
        .as_str()
        .unwrap()
        .parse::<Bytes>()
        .unwrap();
    let factory: Address = "0x20Fc000000000000000000000000000000000000"
        .parse()
        .unwrap();
    provider
        .raw_request::<_, serde_json::Value>("anvil_setCode".into(), (factory, code))
        .await
        .unwrap();
}

struct Fixture<P> {
    _node: Node,
    provider: P,
    accounts: Vec<Address>,
    venue: Address,
    factory: Address,
    base: Address,
    quote: Address,
}

async fn fixture() -> Fixture<impl Provider + Clone> {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let _node = Node(
        Command::new(std::env::var("ANVIL_BIN").unwrap_or_else(|_| "anvil".into()))
            .args([
                "--port",
                &port.to_string(),
                "--chain-id",
                "31337",
                "--silent",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("start local Anvil"),
    );
    let provider =
        ProviderBuilder::new().connect_http(format!("http://127.0.0.1:{port}").parse().unwrap());
    let mut accounts = None;
    for _ in 0..100 {
        if let Ok(found) = provider.get_accounts().await {
            accounts = Some(found);
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let accounts = accounts.expect("Anvil ready within five seconds");
    let owner = accounts[0];
    install_test_tip20_factory(&provider).await;
    // Match the Solidity factoryWith fixture: the owner stands in as settler.
    let implementation = deploy(
        &provider,
        owner,
        "Venue.sol/Venue.json",
        (owner.create(1),).abi_encode(),
    )
    .await;
    let factory = deploy(
        &provider,
        owner,
        "VenueFactory.sol/VenueFactory.json",
        (implementation, owner).abi_encode(),
    )
    .await;
    assert_eq!(factory, owner.create(1));
    let factory_contract = IVenueFactory::new(factory, &provider);
    let venue = factory_contract
        .predictVenue(owner, B256::ZERO)
        .call()
        .await
        .unwrap();
    send(
        &provider,
        owner,
        factory,
        IVenueFactory::createVenueCall {
            owner,
            salt: B256::ZERO,
        }
        .abi_encode(),
    )
    .await;
    let base = deploy(
        &provider,
        owner,
        "MockTIP20V2.sol/MockTIP20V2.json",
        ("EURC".to_string(), U256::from(6)).abi_encode_params(),
    )
    .await;
    let quote = deploy(
        &provider,
        owner,
        "MockTIP20V2.sol/MockTIP20V2.json",
        ("USDC".to_string(), U256::from(6)).abi_encode_params(),
    )
    .await;
    Fixture {
        _node,
        provider,
        accounts,
        venue,
        factory,
        base,
        quote,
    }
}

macro_rules! mined {
    ($action:expr) => {
        assert!($action.await.unwrap().get_receipt().await.unwrap().status())
    };
}

/// `QuoteState::quote` must give `Venue.quote`'s answer at the same block: the same amounts or
/// the same revert, in every direction, from one unit through the side's depth and past it.
async fn local_quotes_match<P: Provider>(
    info: &Info<P>,
    base: Address,
    quote: Address,
    block: BlockId,
) {
    let state = info.quote_state(0, block).await.unwrap();
    let venue = IVenue::new(info.venue(), info.provider());
    let mut matched = 0;
    for (base_in, exact_in) in [(true, true), (true, false), (false, true), (false, false)] {
        let (token_in, token_out) = if base_in {
            (base, quote)
        } else {
            (quote, base)
        };
        for amount in [
            0,
            1,
            999,
            1_000_000,
            10_000_000,
            49_999_999_999,
            50_000_000_000,
            50_000_000_001,
            54_000_000_000,
            10u128.pow(30),
        ] {
            let request = QuoteRequest {
                token_in,
                token_out,
                amount,
                exact_in,
                priority_fee: U256::ZERO,
            };
            let local = state.quote(&request);
            let label = format!("{request:?} at {block:?}: local {local:?}");
            match venue
                .quote(0, token_in, token_out, amount, exact_in)
                .block(block)
                .call()
                .await
            {
                Ok(q) => {
                    let local = local.unwrap_or_else(|e| {
                        panic!("{label}: the venue quoted, local reverted {e:?}")
                    });
                    assert_eq!(
                        (local.amount_in, local.amount_out),
                        (q.amountIn, q.amountOut),
                        "{label}"
                    );
                }
                Err(e) => {
                    let onchain = e.as_decoded_interface_error::<IVenue::IVenueErrors>();
                    assert!(onchain.is_some(), "{label}: undecoded revert {e}");
                    assert_eq!(local.err(), onchain.map(QuoteError::Revert), "{label}");
                }
            }
            matched += 1;
        }
    }
    assert_eq!(matched, 40);
}

/// A pair that doesn't exist: `quote_state` still gives a state, and `QuoteState::quote` the
/// venue's own revert for it at that block (`UnknownPair`, or `VenueHalted` first).
async fn missing_pair_matches<P: Provider>(
    info: &Info<P>,
    base: Address,
    quote: Address,
    block: BlockId,
) -> QuoteError {
    let local = info
        .quote_state(9, block)
        .await
        .unwrap()
        .quote(&QuoteRequest {
            token_in: quote,
            token_out: base,
            amount: 1,
            exact_in: true,
            priority_fee: U256::ZERO,
        });
    let onchain = IVenue::new(info.venue(), info.provider())
        .quote(9, quote, base, 1, true)
        .block(block)
        .call()
        .await
        .unwrap_err()
        .as_decoded_interface_error::<IVenue::IVenueErrors>()
        .map(QuoteError::Revert);
    assert_eq!(local.clone().err(), onchain);
    local.unwrap_err()
}

#[tokio::test]
#[ignore = "requires forge build and anvil on PATH (or ANVIL_BIN)"]
async fn exchange_lifecycle_against_real_v2_contracts() {
    let fixture = fixture().await;
    let Fixture {
        provider,
        accounts,
        venue,
        factory,
        base,
        quote,
        ..
    } = &fixture;
    let (venue, factory, base, quote) = (*venue, *factory, *base, *quote);
    let owner = accounts[0];
    let info = Info::connect(provider, venue, 31337, factory)
        .await
        .unwrap();
    let exchange = Exchange::new(info.clone(), owner);
    let stranger = Exchange::new(info.clone(), accounts[1]);
    let actions = exchange.actions();
    mined!(exchange.send(&actions.prepare(IVenue::addPairCall {
        base,
        quote,
        sizeUnit: 1_000_000
    })));
    mined!(exchange.set_halted(true));
    mined!(exchange.set_pair_access(0, AccessMode::Open));
    mined!(exchange.set_halted(false));

    let shape = Shape::new(&[Level::new(50_000, 20)], &[Level::new(50_000, 20)]).unwrap();
    mined!(exchange.set_shape(0, 7, &shape));
    let now = provider
        .get_block_by_number(Default::default())
        .await
        .unwrap()
        .unwrap()
        .header
        .timestamp;
    let latest = BlockId::number(provider.get_block_number().await.unwrap());
    let sequencer = Sequencer::seed(&info, &[0], 0, latest).await.unwrap();
    let order = OrderRequest::new(
        0,
        "1.085".parse().unwrap(),
        7,
        sequencer.next(0).unwrap(),
        now + 3600,
    );
    assert_eq!(order.sequence, 2, "a fresh pair starts at sequence 1");
    let call = actions.bulk_orders(&[order]).unwrap();
    exchange.simulate(&call).await.unwrap();
    assert!(stranger.simulate(&call).await.is_err());
    let receipt = exchange
        .send(&call)
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status());
    let outcome = PostOutcome::from_logs(&call, receipt.inner.logs()).unwrap();
    assert_eq!(outcome.accepted, vec![(0, 2)]);
    assert!(outcome.all_accepted());
    let stale = exchange
        .send(&call)
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(stale.status());
    assert_eq!(
        PostOutcome::from_logs(&call, stale.inner.logs())
            .unwrap()
            .skipped,
        vec![(0, 2)],
        "stale post succeeds without an acknowledgement"
    );
    let block = BlockId::number(provider.get_block_number().await.unwrap());
    let state = info.orders(&[0], block).await.unwrap().remove(0);
    assert_eq!(state.shape, shape);
    assert_eq!(state.hot.sequence, 2);
    assert_eq!(info.meta(block).await.unwrap().len(), 1);

    // One transaction posting the pair three times at one sequence, as a Tempo batch of
    // these calls would: the venue stores the first entry and skips the cancel and the
    // identical repeat. Anvil sends no batch, so one post carries the calls' entries.
    let mut requote = order;
    requote.sequence = sequencer.next(0).unwrap();
    let requote = actions.order(requote).unwrap();
    let cancel = actions
        .cancel(CancelRequest {
            pair_index: 0,
            sequence: requote.posts()[0].1,
            mid: order.mid,
        })
        .unwrap();
    let batch = [&requote, &cancel, &requote];
    let packed: Vec<u8> = batch
        .iter()
        .flat_map(|call| IVenue::postCall::abi_decode(call.data()).unwrap().packed)
        .collect();
    let receipt = exchange
        .send(&actions.prepare(IVenue::postCall {
            packed: packed.into(),
        }))
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status());
    let entry = requote.posts().to_vec();
    let outcomes = PostOutcome::from_batch(&batch, receipt.inner.logs()).unwrap();
    assert_eq!(outcomes[0].accepted, entry);
    assert_eq!(
        outcomes[1].skipped, entry,
        "the cancel at that sequence was stale"
    );
    assert_eq!(outcomes[2].skipped, entry, "so was the identical repeat");
    assert_eq!(
        PostOutcome::from_logs(&cancel, receipt.inner.logs())
            .unwrap()
            .skipped,
        entry
    );
    send(
        provider,
        owner,
        quote,
        Token::mintCall {
            to: venue,
            amount: U256::from(10_000_000),
        }
        .abi_encode(),
    )
    .await;
    let block = BlockId::number(provider.get_block_number().await.unwrap());
    assert_eq!(
        info.inventory(quote, block).await.unwrap(),
        U256::from(10_000_000)
    );
    let (amount_in, amount_out) = info
        .quote(0, base, quote, 1_000_000, true, block)
        .await
        .unwrap();
    assert_eq!((amount_in, amount_out), (1_000_000, 1_084_783));
    local_quotes_match(&info, base, quote, block).await;
    // A tag is resolved once and every read made at that block, so `latest` gives the same
    // state as its number while no block lands; `pending` has no fixed state and is refused.
    let tagged = info.quote_state(0, BlockId::latest()).await.unwrap();
    let pinned = info.quote_state(0, block).await.unwrap();
    assert_eq!(tagged.timestamp, pinned.timestamp);
    let probe = QuoteRequest {
        token_in: base,
        token_out: quote,
        amount: 1_000_000,
        exact_in: true,
        priority_fee: U256::ZERO,
    };
    assert_eq!(tagged.quote(&probe), pinned.quote(&probe));
    assert!(info.quote_state(0, BlockId::pending()).await.is_err());
    assert_eq!(
        missing_pair_matches(&info, base, quote, block).await,
        QuoteError::Revert(IVenue::IVenueErrors::UnknownPair(IVenue::UnknownPair {
            pairIndex: 9
        }))
    );
    // The fixture's settler precredits input before filling, like the real Settler.
    send(
        provider,
        owner,
        base,
        Token::mintCall {
            to: venue,
            amount: U256::from(amount_in),
        }
        .abi_encode(),
    )
    .await;
    mined!(exchange.send(&actions.prepare(IVenue::fillCall {
        pairIndex: 0,
        tokenIn: base,
        tokenOut: quote,
        amount: amount_in,
        exactIn: true,
        taker: accounts[1],
        sponsorId: 0,
        r#ref: B256::ZERO,
    })));
    let latest = provider.get_block_number().await.unwrap();
    let fills = info.fills(Some(0), 0, latest).await.unwrap();
    assert_eq!(fills.len(), 1);
    assert_eq!(fills[0].fill.amountOut, amount_out);
    // The taker sold base, so the fill took that much depth off the bids.
    let block = BlockId::number(latest);
    let consumed = Consumed {
        bids: amount_in,
        asks: 0,
    };
    assert_eq!(info.consumed(0, block).await.unwrap(), consumed);
    assert_eq!(
        info.orders(&[0], block).await.unwrap()[0].consumed,
        consumed
    );
    local_quotes_match(&info, base, quote, block).await;
    let mut refill = order;
    refill.sequence = sequencer.next(0).unwrap();
    refill.refill = Sides::Bids;
    let call = actions.order(refill).unwrap();
    let receipt = exchange
        .send(&call)
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status());
    assert!(
        PostOutcome::from_logs(&call, receipt.inner.logs())
            .unwrap()
            .all_accepted()
    );
    let block = BlockId::number(provider.get_block_number().await.unwrap());
    let state = info.orders(&[0], block).await.unwrap().remove(0);
    assert_eq!(state.consumed, Consumed::default());
    assert_eq!(
        state.hot.sequence, refill.sequence,
        "stored without refill bits"
    );
    local_quotes_match(&info, base, quote, block).await;
    mined!(exchange.cancel(CancelRequest {
        pair_index: 0,
        sequence: sequencer.next(0).unwrap(),
        mid: order.mid
    }));
    let block = BlockId::number(provider.get_block_number().await.unwrap());
    assert_eq!(
        info.orders(&[0], block).await.unwrap()[0].hot.sides,
        Sides::Neither
    );
    local_quotes_match(&info, base, quote, block).await;
    assert!(info.quote(0, base, quote, 1, true, block).await.is_err());

    // cancel_all cancels every live pair with a newer word and leaves the venue running.
    let mut requote = order;
    requote.sequence = sequencer.next(0).unwrap();
    mined!(exchange.order(requote));
    let block = BlockId::number(provider.get_block_number().await.unwrap());
    let untracked = info.cancel_all_requests(None, block).await.unwrap().cancels;
    assert_eq!(untracked.len(), 1);
    assert_eq!(
        (untracked[0].pair_index, untracked[0].sequence),
        (0, requote.sequence + 1),
        "an untracked pair cancels at its stored sequence plus one"
    );
    assert_eq!(untracked[0].mid, requote.mid, "at the stored mid");
    let last = sequencer.last(0).unwrap();
    let requests = info
        .cancel_all_requests(Some(&sequencer), block)
        .await
        .unwrap();
    assert!(requests.skipped.is_empty());
    assert_eq!(requests.cancels[0].sequence, last + 1);
    assert_eq!(
        sequencer.last(0),
        Some(last),
        "requests leaves the sequencer alone"
    );
    // Sending the cancels yourself, record them, so the sequencer's next post outranks them.
    sequencer.observe(0, requests.cancels[0].sequence).unwrap();
    let call = actions.cancel_all(&requests.cancels).unwrap();
    let receipt = exchange
        .send(&call)
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status());
    assert!(
        PostOutcome::from_logs(&call, receipt.inner.logs())
            .unwrap()
            .all_accepted()
    );
    let block = BlockId::number(provider.get_block_number().await.unwrap());
    let state = info.orders(&[0], block).await.unwrap().remove(0);
    assert_eq!(state.hot.sides, Sides::Neither);
    assert!(!state.halted, "cancel_all never halts");
    assert!(!info.venue_state(block).await.unwrap().halted);

    // Exchange::cancel_all reads and sends in one step, and records its cancel in the sequencer.
    requote.sequence = sequencer.next(0).unwrap();
    mined!(exchange.order(requote));
    let sent = exchange.cancel_all(Some(&sequencer)).await.unwrap();
    assert!(sent.skipped.is_empty());
    assert_eq!(sequencer.last(0), Some(requote.sequence + 1));
    let receipt = sent.pending.get_receipt().await.unwrap();
    assert!(receipt.status());
    assert!(
        PostOutcome::from_logs(&sent.call, receipt.inner.logs())
            .unwrap()
            .all_accepted()
    );
    let block = BlockId::number(provider.get_block_number().await.unwrap());
    let state = info.orders(&[0], block).await.unwrap().remove(0);
    assert_eq!(state.hot.sides, Sides::Neither);
    assert!(!state.halted);

    // A pair at the last sequence has no cancel: cancel_all skips it instead of failing, so one
    // such pair never keeps the others' cancels from going out.
    requote.sequence = u32::MAX;
    mined!(exchange.order(requote));
    let block = BlockId::number(provider.get_block_number().await.unwrap());
    let exhausted = [SkippedPair {
        pair_index: 0,
        reason: SkipReason::SequenceExhausted,
    }];
    for sequencer in [None, Some(&sequencer)] {
        let requests = info.cancel_all_requests(sequencer, block).await.unwrap();
        assert!(requests.cancels.is_empty());
        assert_eq!(requests.skipped, exhausted);
    }

    // An explicit halt: the venue and every local quote refuse with VenueHalted.
    mined!(exchange.set_halted(true));
    let block = BlockId::number(provider.get_block_number().await.unwrap());
    assert!(info.orders(&[0], block).await.unwrap()[0].halted);
    local_quotes_match(&info, base, quote, block).await;
    assert_eq!(
        missing_pair_matches(&info, base, quote, block).await,
        QuoteError::Revert(IVenue::IVenueErrors::VenueHalted(IVenue::VenueHalted {}))
    );
}

#[tokio::test]
#[ignore = "requires forge build and anvil on PATH (or ANVIL_BIN)"]
async fn access_roles_and_effective_permissions_against_real_v2_contracts() {
    let fixture = fixture().await;
    let Fixture {
        provider,
        accounts,
        venue,
        factory,
        base,
        quote,
        ..
    } = &fixture;
    let info = Info::connect(provider, *venue, 31337, *factory)
        .await
        .unwrap();
    let owner = Exchange::new(info.clone(), accounts[0]);
    let agent = Exchange::new(info.clone(), accounts[1]);
    let admin = Exchange::new(info.clone(), accounts[2]);
    let successor = Exchange::new(info.clone(), accounts[3]);
    let taker = accounts[4];
    let new_owner = Exchange::new(info.clone(), accounts[5]);
    let actions = owner.actions();
    let latest = BlockId::latest();
    let sponsor_id = 42;
    mined!(owner.send(&actions.prepare(IVenue::addPairCall {
        base: *base,
        quote: *quote,
        sizeUnit: 1_000_000
    })));
    assert_eq!(
        info.market(0, latest).await.unwrap().access,
        IVenue::AccessMode::Closed
    );
    mined!(owner.approve_agent(agent.sender()));
    assert!(info.is_agent(agent.sender(), latest).await.unwrap());
    assert!(!info.is_agent(owner.sender(), latest).await.unwrap());
    assert!(
        agent
            .simulate(&actions.approve_agent(taker).unwrap())
            .await
            .is_err()
    );
    assert!(
        agent
            .simulate(&actions.set_pair_access(0, AccessMode::Listed))
            .await
            .is_err()
    );

    // Only the owner edits the home list; a listed caller can be denied venue-wide.
    mined!(owner.set_pair_access(0, AccessMode::Listed));
    mined!(owner.set_members(0, 0, &[taker], true));
    assert!(info.pair_sponsor(0, 0, latest).await.unwrap());
    assert!(info.taker_allowed(0, taker, 0, latest).await.unwrap());
    assert!(
        agent
            .simulate(&actions.set_members(0, 0, &[taker], false).unwrap())
            .await
            .is_err()
    );
    mined!(agent.set_denied(&[taker], true));
    assert!(info.is_denied(taker, latest).await.unwrap());
    assert_eq!(info.venue_state(latest).await.unwrap().denied_count, 1);
    assert!(!info.taker_allowed(0, taker, 0, latest).await.unwrap());
    assert!(
        agent
            .simulate(&actions.set_denied(&[taker], false).unwrap())
            .await
            .is_err()
    );
    mined!(owner.set_denied(&[taker], false));
    assert_eq!(info.venue_state(latest).await.unwrap().denied_count, 0);

    // Only a sponsor's admin can edit its list, including when the caller is owner.
    assert!(
        agent
            .simulate(&actions.add_sponsor(sponsor_id, admin.sender()))
            .await
            .is_err()
    );
    mined!(owner.add_sponsor(sponsor_id, admin.sender()));
    let sponsor = info.sponsor_state(sponsor_id, latest).await.unwrap();
    assert_eq!(sponsor.admin, admin.sender());
    assert!(sponsor.enabled);
    assert!(!info.pair_sponsor(0, sponsor_id, latest).await.unwrap());
    assert!(
        admin
            .simulate(&actions.set_members(0, sponsor_id, &[taker], true).unwrap())
            .await
            .is_err()
    );
    mined!(owner.set_pair_sponsor(0, sponsor_id, true));
    assert!(
        owner
            .simulate(&actions.set_members(0, sponsor_id, &[taker], true).unwrap())
            .await
            .is_err()
    );
    assert!(
        agent
            .simulate(&actions.set_members(0, sponsor_id, &[taker], true).unwrap())
            .await
            .is_err()
    );
    mined!(admin.set_members(0, sponsor_id, &[taker], true));
    assert!(info.is_member(0, sponsor_id, taker, latest).await.unwrap());
    assert!(
        info.taker_allowed(0, taker, sponsor_id, latest)
            .await
            .unwrap()
    );

    // Disabling/removing preserves lists; only the owner can restore access.
    mined!(agent.set_sponsor_enabled(sponsor_id, false));
    assert!(
        !info
            .sponsor_state(sponsor_id, latest)
            .await
            .unwrap()
            .enabled
    );
    assert!(
        !info
            .taker_allowed(0, taker, sponsor_id, latest)
            .await
            .unwrap()
    );
    assert!(info.is_member(0, sponsor_id, taker, latest).await.unwrap());
    assert!(
        agent
            .simulate(&actions.set_sponsor_enabled(sponsor_id, true))
            .await
            .is_err()
    );
    assert!(
        admin
            .simulate(&actions.set_members(0, sponsor_id, &[taker], true).unwrap())
            .await
            .is_err()
    );
    mined!(admin.set_members(0, sponsor_id, &[taker], false));
    assert!(!info.is_member(0, sponsor_id, taker, latest).await.unwrap());
    mined!(owner.set_sponsor_enabled(sponsor_id, true));
    mined!(admin.set_members(0, sponsor_id, &[taker], true));
    mined!(agent.set_pair_sponsor(0, sponsor_id, false));
    assert!(!info.pair_sponsor(0, sponsor_id, latest).await.unwrap());
    assert!(
        !info
            .taker_allowed(0, taker, sponsor_id, latest)
            .await
            .unwrap()
    );
    assert!(
        agent
            .simulate(&actions.set_pair_sponsor(0, sponsor_id, true))
            .await
            .is_err()
    );
    mined!(owner.set_pair_sponsor(0, sponsor_id, true));
    assert!(
        info.taker_allowed(0, taker, sponsor_id, latest)
            .await
            .unwrap()
    );

    // Handover preserves lists and requires the successor; only its admin can cancel a proposal.
    assert!(
        owner
            .simulate(&actions.transfer_sponsor_admin(sponsor_id, successor.sender()))
            .await
            .is_err()
    );
    mined!(admin.transfer_sponsor_admin(sponsor_id, successor.sender()));
    assert_eq!(
        info.sponsor_state(sponsor_id, latest)
            .await
            .unwrap()
            .pending_admin,
        successor.sender()
    );
    assert!(
        owner
            .simulate(&actions.cancel_sponsor_admin_transfer(sponsor_id))
            .await
            .is_err()
    );
    mined!(admin.cancel_sponsor_admin_transfer(sponsor_id));
    assert_eq!(
        info.sponsor_state(sponsor_id, latest)
            .await
            .unwrap()
            .pending_admin,
        Address::ZERO
    );
    assert!(
        successor
            .simulate(&actions.accept_sponsor_admin(sponsor_id))
            .await
            .is_err()
    );
    mined!(admin.transfer_sponsor_admin(sponsor_id, successor.sender()));
    assert!(
        owner
            .simulate(&actions.accept_sponsor_admin(sponsor_id))
            .await
            .is_err()
    );
    mined!(successor.accept_sponsor_admin(sponsor_id));
    let transferred = info.sponsor_state(sponsor_id, latest).await.unwrap();
    assert_eq!(transferred.admin, successor.sender());
    assert_eq!(transferred.pending_admin, Address::ZERO);
    assert_eq!(transferred.generation, sponsor.generation);
    assert!(
        info.taker_allowed(0, taker, sponsor_id, latest)
            .await
            .unwrap()
    );
    assert!(
        admin
            .simulate(&actions.set_members(0, sponsor_id, &[taker], false).unwrap())
            .await
            .is_err()
    );

    // Reset destroys old membership rather than giving the new admin its old list.
    assert!(
        agent
            .simulate(&actions.reset_sponsor(sponsor_id, admin.sender()))
            .await
            .is_err()
    );
    let before_reset = BlockId::number(provider.get_block_number().await.unwrap());
    mined!(owner.reset_sponsor(sponsor_id, admin.sender()));
    let reset = info.sponsor_state(sponsor_id, latest).await.unwrap();
    assert_eq!(reset.admin, admin.sender());
    assert_eq!(reset.generation, sponsor.generation + 1);
    assert!(reset.enabled);
    assert!(info.pair_sponsor(0, sponsor_id, latest).await.unwrap());
    assert!(!info.is_member(0, sponsor_id, taker, latest).await.unwrap());
    assert!(
        !info
            .taker_allowed(0, taker, sponsor_id, latest)
            .await
            .unwrap()
    );
    assert!(
        info.is_member(0, sponsor_id, taker, before_reset)
            .await
            .unwrap()
    );
    assert!(
        info.taker_allowed(0, taker, sponsor_id, before_reset)
            .await
            .unwrap()
    );

    // Batch limits and invalid accounts revert atomically, not partially applied.
    assert!(
        owner
            .simulate(&actions.prepare(IVenue::setMembersCall {
                pairIndex: 0,
                sponsorId: 0,
                accounts: vec![taker; 101],
                allowed: true
            }))
            .await
            .is_err()
    );
    assert!(
        owner
            .simulate(&actions.prepare(IVenue::setDeniedCall {
                accounts: vec![taker, Address::ZERO],
                deny: true
            }))
            .await
            .is_err()
    );
    assert!(!info.is_denied(taker, latest).await.unwrap());
    assert_eq!(info.venue_state(latest).await.unwrap().denied_count, 0);

    // Open requires halt and still respects denial. Updaters can halt/close only.
    assert!(
        owner
            .simulate(&actions.set_pair_access(0, AccessMode::Open))
            .await
            .is_err()
    );
    mined!(agent.set_halted(true));
    assert!(info.venue_state(latest).await.unwrap().halted);
    assert!(agent.simulate(&actions.set_halted(false)).await.is_err());
    mined!(owner.set_pair_access(0, AccessMode::Open));
    assert!(
        info.taker_allowed(0, taker, u64::MAX, latest)
            .await
            .unwrap()
    );
    mined!(agent.set_denied(&[taker], true));
    assert!(
        !info
            .taker_allowed(0, taker, u64::MAX, latest)
            .await
            .unwrap()
    );
    mined!(owner.set_denied(&[taker], false));
    mined!(owner.set_halted(false));
    mined!(agent.close_pair(0));
    assert!(!info.taker_allowed(0, taker, 0, latest).await.unwrap());
    assert!(
        agent
            .simulate(&actions.set_pair_access(0, AccessMode::Listed))
            .await
            .is_err()
    );
    mined!(owner.set_pair_access(0, AccessMode::Listed));
    mined!(owner.revoke_agent(agent.sender()));
    assert!(!info.is_agent(agent.sender(), latest).await.unwrap());
    assert!(agent.simulate(&actions.set_halted(true)).await.is_err());

    // Owner transfer takes effect only upon acceptance, including home-list rights.
    assert!(
        admin
            .simulate(&actions.transfer_ownership(new_owner.sender()).unwrap())
            .await
            .is_err()
    );
    mined!(owner.transfer_ownership(new_owner.sender()));
    let pending = info.venue_state(latest).await.unwrap();
    assert_eq!(pending.owner, owner.sender());
    assert_eq!(pending.pending_owner, new_owner.sender());
    assert!(admin.simulate(&actions.accept_ownership()).await.is_err());
    assert!(
        admin
            .simulate(&actions.cancel_ownership_transfer())
            .await
            .is_err()
    );
    mined!(owner.cancel_ownership_transfer());
    assert_eq!(
        info.venue_state(latest).await.unwrap().pending_owner,
        Address::ZERO
    );
    assert!(
        new_owner
            .simulate(&actions.accept_ownership())
            .await
            .is_err()
    );
    mined!(owner.transfer_ownership(new_owner.sender()));
    mined!(new_owner.accept_ownership());
    let transferred = info.venue_state(latest).await.unwrap();
    assert_eq!(transferred.owner, new_owner.sender());
    assert_eq!(transferred.pending_owner, Address::ZERO);
    assert!(
        owner
            .simulate(&actions.set_members(0, 0, &[taker], false).unwrap())
            .await
            .is_err()
    );
    mined!(new_owner.set_members(0, 0, &[taker], false));
    assert!(!info.taker_allowed(0, taker, 0, latest).await.unwrap());
}

/// Each pair's stored word, as `(sequence, mid, sides)`.
async fn words<P: Provider>(info: &Info<P>, pairs: &[u16]) -> Vec<(u32, u128, Sides)> {
    let block = BlockId::number(info.provider().get_block_number().await.unwrap());
    info.orders(pairs, block)
        .await
        .unwrap()
        .into_iter()
        .map(|o| (o.hot.sequence, o.hot.mid, o.hot.sides))
        .collect()
}

async fn automine<P: Provider>(provider: &P, on: bool) {
    provider
        .raw_request::<_, serde_json::Value>("evm_setAutomine".into(), (on,))
        .await
        .unwrap();
}

#[tokio::test]
#[ignore = "requires forge build and anvil on PATH (or ANVIL_BIN)"]
async fn cancel_all_skips_reports_and_cancels_unmined_first_orders() {
    let fixture = fixture().await;
    let Fixture {
        provider,
        accounts,
        venue,
        factory,
        base,
        quote,
        ..
    } = &fixture;
    let info = Info::connect(provider, *venue, 31337, *factory)
        .await
        .unwrap();
    let owner = Exchange::new(info.clone(), accounts[0]);
    let agent = Exchange::new(info.clone(), accounts[1]);
    let actions = owner.actions();
    mined!(owner.approve_agent(agent.sender()));
    let shape = Shape::new(&[Level::new(50_000, 20)], &[Level::new(50_000, 20)]).unwrap();
    for pair_index in 0..3 {
        mined!(owner.send(&actions.prepare(IVenue::addPairCall {
            base: *base,
            quote: *quote,
            sizeUnit: 1_000_000
        })));
        mined!(owner.set_shape(pair_index, 7, &shape));
    }
    let now = provider
        .get_block_by_number(Default::default())
        .await
        .unwrap()
        .unwrap()
        .header
        .timestamp;
    let latest = BlockId::latest();
    let never = |pair_index| SkippedPair {
        pair_index,
        reason: SkipReason::NeverPosted,
    };

    // Nothing posted: nothing to cancel. Exchange::cancel_all sends nothing and refuses.
    let requests = info.cancel_all_requests(None, latest).await.unwrap();
    assert!(requests.cancels.is_empty());
    assert_eq!(requests.skipped, [never(0), never(1), never(2)]);
    let nonce = provider
        .get_transaction_count(agent.sender())
        .await
        .unwrap();
    match agent.cancel_all(None).await {
        Err(Error::NothingToCancel { skipped }) => assert_eq!(
            skipped,
            [never(0), never(1), never(2)],
            "the skipped pairs, with their reasons, from the same read"
        ),
        other => panic!("expected NothingToCancel, got {other:?}"),
    }
    assert_eq!(
        provider
            .get_transaction_count(agent.sender())
            .await
            .unwrap(),
        nonce,
        "nothing was sent"
    );

    // Pair 1 is posted, then gets a band its stored mid is below; pair 2's word is at the last
    // sequence; pair 0 stays on its initial word.
    let sequencer = Sequencer::seed(&info, &[0, 1, 2], 0, latest).await.unwrap();
    let order = |pair_index, sequence, mid: &str| {
        OrderRequest::new(pair_index, mid.parse().unwrap(), 7, sequence, now + 3600)
    };
    mined!(agent.bulk_orders(&[
        order(1, sequencer.next(1).unwrap(), "1.085"),
        order(2, u32::MAX, "1.085"),
    ]));
    mined!(owner.send(&actions.prepare(IVenue::setMidBandCall {
        pairIndex: 1,
        minMid: alloy_uint96("1.1"),
        maxMid: alloy_uint96("1.2"),
    })));
    let exhausted = SkippedPair {
        pair_index: 2,
        reason: SkipReason::SequenceExhausted,
    };
    for tracking in [None, Some(&sequencer)] {
        let requests = info.cancel_all_requests(tracking, latest).await.unwrap();
        assert_eq!(requests.skipped, [never(0), exhausted]);
        let cancels: Vec<_> = requests
            .cancels
            .iter()
            .map(|c| (c.pair_index, c.sequence, c.mid))
            .collect();
        // Moved up into the band, at the stored sequence plus one.
        assert_eq!(cancels, [(1, 3, "1.1".parse::<Price>().unwrap())]);
    }
    assert_eq!(
        sequencer.last(1),
        Some(2),
        "requests leaves the sequencer alone"
    );
    // Only the sequencer's counter at the maximum: the stored sequence plus one, not a skip.
    let at_max = Sequencer::new([(1, u32::MAX)]);
    let requests = info
        .cancel_all_requests(Some(&at_max), latest)
        .await
        .unwrap();
    assert_eq!(requests.cancels[0].sequence, 3);
    assert_eq!(requests.skipped, [never(0), exhausted]);

    // Pair 0's first order goes out unmined: the sequencer has handed out 2 for it, so cancel_all
    // cancels it at 3, at a price of 1 (it has no band), and the order never quotes.
    automine(provider, false).await;
    let first = agent
        .order(order(0, sequencer.next(0).unwrap(), "1.085"))
        .await
        .unwrap();
    let sent = agent.cancel_all(Some(&sequencer)).await.unwrap();
    assert_eq!(sent.skipped, [exhausted]);
    assert_eq!(
        (sequencer.last(0), sequencer.last(1)),
        (Some(3), Some(3)),
        "the send records its cancels"
    );
    provider
        .raw_request::<_, serde_json::Value>("evm_mine".into(), ())
        .await
        .unwrap();
    automine(provider, true).await;
    assert!(first.get_receipt().await.unwrap().status());
    let receipt = sent.pending.get_receipt().await.unwrap();
    assert!(receipt.status());
    // Every cancel sent was stored; pair 2 still quotes, which only `skipped` says.
    assert!(
        PostOutcome::from_logs(&sent.call, receipt.inner.logs())
            .unwrap()
            .all_accepted()
    );
    let one = 1_000_000_000_000_000_000;
    assert_eq!(
        words(&info, &[0, 1, 2]).await,
        [
            (3, one, Sides::Neither),
            (3, 1_100_000_000_000_000_000, Sides::Neither),
            (u32::MAX, 1_085_000_000_000_000_000, Sides::Both),
        ]
    );

    // A sequencer that tracks no pair (made before any of them quoted): the send records every
    // cancel it sends, so each pair's next post from it outranks its cancel.
    let late = Sequencer::default();
    let sent = agent.cancel_all(Some(&late)).await.unwrap();
    assert!(sent.pending.get_receipt().await.unwrap().status());
    assert_eq!(
        (late.last(0), late.last(1), late.last(2)),
        (Some(4), Some(4), None),
        "both cancels recorded; the exhausted pair got none"
    );
    mined!(agent.order(order(1, late.next(1).unwrap(), "1.15")));
    assert_eq!(
        words(&info, &[1]).await[0].0,
        5,
        "the requote outranks the cancel"
    );
}

/// A decimal mid as the ABI's `uint96`.
fn alloy_uint96(mid: &str) -> propamm_sdk::alloy::primitives::Uint<96, 2> {
    propamm_sdk::alloy::primitives::Uint::from(mid.parse::<Price>().unwrap().scaled())
}

#[tokio::test]
#[ignore = "requires forge build and anvil on PATH (or ANVIL_BIN)"]
async fn cancel_all_rejects_wrong_chain_without_mutating_sequencer() {
    let fixture = fixture().await;
    let provider = &fixture.provider;
    let info = Info::connect(provider, fixture.venue, 31337, fixture.factory)
        .await
        .unwrap();
    let owner = Exchange::new(info.clone(), fixture.accounts[0]);
    for pair_index in 0..2 {
        mined!(owner.send(&owner.actions().prepare(IVenue::addPairCall {
            base: fixture.base,
            quote: fixture.quote,
            sizeUnit: 1_000_000,
        })));
        mined!(owner.cancel(CancelRequest {
            pair_index,
            sequence: 100,
            mid: "1".parse().unwrap()
        }));
    }
    let sequencer = Sequencer::new([(0, 5)]);
    let checkpoint = sequencer.checkpoint();
    let nonce = provider
        .get_transaction_count(owner.sender())
        .await
        .unwrap();

    // Simulate a provider switching networks after Info::connect. The same venue
    // still answers every view, with a higher stored floor and an untracked pair.
    provider
        .raw_request::<_, serde_json::Value>("anvil_setChainId".into(), (1u64,))
        .await
        .unwrap();
    assert_eq!(
        info.orders(&[0], BlockId::latest()).await.unwrap()[0]
            .hot
            .sequence,
        100
    );
    assert!(matches!(
        owner.cancel_all(Some(&sequencer)).await,
        Err(Error::ChainMismatch {
            expected: 31337,
            actual: 1
        })
    ));
    assert_eq!(sequencer.checkpoint(), checkpoint);
    assert_eq!(
        provider
            .get_transaction_count(owner.sender())
            .await
            .unwrap(),
        nonce
    );
}
