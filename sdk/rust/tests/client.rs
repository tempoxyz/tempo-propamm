use propamm_sdk::{
    Actions, Error, Exchange, Info,
    alloy::{
        primitives::{B256, Bytes, U256, address},
        providers::ProviderBuilder,
        rpc::types::Log,
        sol_types::{SolEvent, SolValue},
        transports::mock::Asserter,
    },
    bindings::IVenue,
};

const VENUE: propamm_sdk::alloy::primitives::Address =
    address!("1111111111111111111111111111111111111111");
const FACTORY: propamm_sdk::alloy::primitives::Address =
    address!("2222222222222222222222222222222222222222");

#[tokio::test]
async fn wrong_chain_and_unrecognized_venue_are_rejected() {
    let mock = Asserter::new();
    let provider = ProviderBuilder::new()
        .disable_recommended_fillers()
        .connect_mocked_client(mock.clone());
    mock.push_success(&U256::from(1));
    assert!(matches!(
        Info::connect(provider.clone(), VENUE, 42431, FACTORY).await,
        Err(Error::ChainMismatch {
            expected: 42431,
            actual: 1
        })
    ));
    mock.push_success(&U256::from(42431));
    mock.push_success(&Bytes::from(false.abi_encode()));
    assert!(matches!(
        Info::connect(provider, VENUE, 42431, FACTORY).await,
        Err(Error::UnknownVenue)
    ));
}

#[tokio::test]
async fn rejects_cross_venue_calls_and_rechecks_chain_before_sending() {
    let mock = Asserter::new();
    let provider = ProviderBuilder::new()
        .disable_recommended_fillers()
        .connect_mocked_client(mock.clone());
    mock.push_success(&U256::from(42431));
    mock.push_success(&Bytes::from(true.abi_encode()));
    let client = Info::connect(provider, VENUE, 42431, FACTORY)
        .await
        .unwrap();
    let client = Exchange::new(client, VENUE);
    let other = Actions::new(FACTORY, 42431).unwrap();
    assert!(matches!(
        client.send(&other.set_halted(true)).await,
        Err(Error::CallMismatch)
    ));
    mock.push_success(&U256::from(4217));
    assert!(matches!(
        client.send(&client.actions().set_halted(true)).await,
        Err(Error::ChainMismatch { .. })
    ));
    mock.push_success(&U256::from(42431));
    mock.push_failure_msg("execution reverted: NotOwnerOrUpdater");
    assert!(matches!(
        client.simulate(&client.actions().set_halted(true)).await,
        Err(Error::Transport(_))
    ));
}

/// A wire-level RPC mock: unlike Asserter, records the serialized EIP-1898 selectors.
fn quote_rpc(
    orphan: bool,
    missing_pair: bool,
) -> (String, std::thread::JoinHandle<Vec<serde_json::Value>>) {
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::time::Duration;

    use propamm_sdk::alloy::{
        primitives::{Address, B256},
        rpc::types::{Block, Transaction},
    };
    use serde_json::json;

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let task = std::thread::spawn(move || {
        let hash = B256::repeat_byte(0x42);
        let mut block = Block::<Transaction>::default();
        block.header.hash = hash;
        let mut requests = Vec::new();
        // The caller sends one final sentinel after quote_state returns.
        loop {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(10)))
                .unwrap();
            let mut reader = BufReader::new(&mut stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut length = 0;
            loop {
                line.clear();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" {
                    break;
                }
                if let Some((key, value)) = line.split_once(':')
                    && key.eq_ignore_ascii_case("content-length")
                {
                    length = value.trim().parse::<usize>().unwrap();
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let request: serde_json::Value = serde_json::from_slice(&body).unwrap();
            let method = request["method"].as_str().unwrap();
            let mut rejected = false;
            let result = match method {
                "eth_chainId" => json!("0xa5bf"),
                "eth_getBlockByHash" | "eth_getBlockByNumber" => json!(block),
                "eth_call" => {
                    if requests.len() == 1 {
                        json!(Bytes::from(true.abi_encode())) // factory provenance
                    } else {
                        rejected = orphan && request["params"][1]["requireCanonical"] == true;
                        let call = requests
                            .iter()
                            .filter(|r: &&serde_json::Value| r["method"] == "eth_call")
                            .count();
                        let data = match call {
                            1 => U256::MAX.abi_encode(),
                            2 | 4 => (
                                if missing_pair { Address::ZERO } else { VENUE },
                                FACTORY,
                                1u64,
                                U256::from(1),
                                FACTORY,
                                U256::from(1),
                            )
                                .abi_encode(),
                            3 => false.abi_encode(),
                            5 => B256::ZERO.abi_encode(),
                            6 => [U256::ZERO; 4].abi_encode(),
                            7 => (0u128, 0u128).abi_encode(),
                            _ => U256::ZERO.abi_encode(),
                        };
                        json!(Bytes::from(data))
                    }
                }
                "test_done" => json!(true),
                _ => panic!("unexpected RPC method {method}"),
            };
            let response = if rejected {
                json!({"jsonrpc":"2.0", "id":request["id"], "error":{"code":-32000,"message":"block is not canonical"}})
            } else {
                json!({"jsonrpc":"2.0", "id":request["id"], "result":result})
            }.to_string();
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", response.len(), response).unwrap();
            if method == "test_done" {
                break;
            }
            requests.push(request);
        }
        requests
    });
    (url, task)
}

#[tokio::test]
async fn quote_state_preserves_wire_selectors_and_canonical_rejection() {
    use propamm_sdk::alloy::{primitives::B256, providers::Provider, rpc::types::BlockId};
    use serde_json::json;

    let hash = B256::repeat_byte(0x42);
    for selector in [
        BlockId::hash_canonical(hash),
        BlockId::hash(hash),
        serde_json::from_value(json!({"blockHash": hash, "requireCanonical": false})).unwrap(),
        BlockId::latest(),
        BlockId::safe(),
        BlockId::finalized(),
        BlockId::earliest(),
        BlockId::number(0),
    ] {
        for missing_pair in [false, true] {
            for orphan in [false, true] {
                let (url, task) = quote_rpc(orphan, missing_pair);
                let provider = ProviderBuilder::new()
                    .disable_recommended_fillers()
                    .connect_http(url.parse().unwrap());
                let info = Info::connect(provider.clone(), VENUE, 42431, FACTORY)
                    .await
                    .unwrap();
                let result = info.quote_state(0, selector).await;
                let canonical = selector == BlockId::hash_canonical(hash);
                assert_eq!(result.is_err(), orphan && canonical);
                if orphan && canonical {
                    assert!(
                        result
                            .unwrap_err()
                            .to_string()
                            .contains("block is not canonical")
                    );
                }
                let _: bool = provider.raw_request("test_done".into(), ()).await.unwrap();
                let requests = task.join().unwrap();
                let reads: Vec<_> = requests
                    .iter()
                    .skip(2)
                    .filter(|r| r["method"] == "eth_call")
                    .collect();
                assert_eq!(
                    reads.len(),
                    if orphan && canonical {
                        1
                    } else if missing_pair {
                        3
                    } else {
                        11
                    }
                );
                let expected = if matches!(selector, BlockId::Hash(_)) {
                    selector
                } else {
                    BlockId::hash(hash)
                };
                for read in reads {
                    assert_eq!(read["params"][1], json!(expected));
                }
                assert_eq!(
                    requests[2]["method"],
                    if matches!(selector, BlockId::Hash(_)) {
                        "eth_getBlockByHash"
                    } else {
                        "eth_getBlockByNumber"
                    }
                );
            }
        }
    }
}

fn fill_log(pair: u16, base_in: bool) -> Log {
    Log {
        inner: propamm_sdk::alloy::primitives::Log {
            address: VENUE,
            data: IVenue::Fill {
                pairIndex: pair,
                taker: FACTORY,
                r#ref: B256::repeat_byte(0xff),
                sponsorId: u64::MAX,
                baseIn: base_in,
                amountIn: u128::MAX,
                amountOut: u128::MAX,
                makerMid: propamm_sdk::alloy::primitives::aliases::U96::MAX,
                seq: u32::MAX,
            }
            .encode_log_data(),
        },
        block_number: Some(10),
        log_index: Some(3),
        removed: true,
        ..Default::default()
    }
}

async fn query_fills(
    logs: Vec<Log>,
    pair: Option<u16>,
) -> propamm_sdk::Result<Vec<propamm_sdk::Fill>> {
    let mock = Asserter::new();
    let provider = ProviderBuilder::new()
        .disable_recommended_fillers()
        .connect_mocked_client(mock.clone());
    mock.push_success(&U256::from(42431));
    mock.push_success(&Bytes::from(true.abi_encode()));
    let info = Info::connect(provider, VENUE, 42431, FACTORY)
        .await
        .unwrap();
    mock.push_success(&logs);
    info.fills(pair, 0, 10).await
}

#[tokio::test]
async fn fills_accept_canonical_boundaries_and_preserve_logs() {
    for pair in [0, u16::MAX] {
        for base_in in [false, true] {
            let log = fill_log(pair, base_in);
            for filter in [None, Some(pair)] {
                let fills = query_fills(vec![log.clone()], filter).await.unwrap();
                assert_eq!(fills.len(), 1);
                assert_eq!(fills[0].fill.pairIndex, pair);
                assert_eq!(fills[0].fill.baseIn, base_in);
                assert_eq!(fills[0].log, log);
            }
        }
    }
    assert!(query_fills(vec![], None).await.unwrap().is_empty());
}

#[tokio::test]
async fn fills_reject_noncanonical_topics() {
    for (topic, padding) in [(1, 30), (2, 12)] {
        for byte in 0..padding {
            let mut log = fill_log(0, true);
            log.topics_mut()[topic][byte] = 1;
            for pair in [None, Some(0)] {
                assert!(
                    matches!(
                        query_fills(vec![log.clone()], pair).await,
                        Err(Error::Invalid("Fill event"))
                    ),
                    "topic {topic}, byte {byte}"
                );
            }
        }
    }
}

#[tokio::test]
async fn fills_reject_noncanonical_body_words() {
    // Every padding byte of each narrow integer and bool must be zero.
    for (word, padding) in [(0, 24), (1, 31), (2, 16), (3, 16), (4, 20), (5, 28)] {
        for byte in 0..padding {
            let mut log = fill_log(0, true);
            let mut data = log.inner.data.data.to_vec();
            data[word * 32 + byte] = 1;
            log.inner.data.data = data.into();
            assert!(
                matches!(
                    query_fills(vec![log], None).await,
                    Err(Error::Invalid("Fill event"))
                ),
                "word {word}, byte {byte}"
            );
        }
    }
    let mut log = fill_log(0, true);
    let mut data = log.inner.data.data.to_vec();
    data[63] = 2;
    log.inner.data.data = data.into();
    assert!(matches!(
        query_fills(vec![log], None).await,
        Err(Error::Invalid("Fill event"))
    ));
}

#[tokio::test]
async fn fills_reject_malformed_or_out_of_scope_logs_without_partial_results() {
    let valid = fill_log(0, true);
    let mut wrong_emitter = valid.clone();
    wrong_emitter.inner.address = FACTORY;
    let mut wrong_signature = valid.clone();
    wrong_signature.topics_mut()[0] = B256::ZERO;
    let mut short_body = valid.clone();
    short_body.inner.data.data = Bytes::from(vec![0; 191]);
    let mut missing_topic = valid.clone();
    missing_topic.inner.data = propamm_sdk::alloy::primitives::LogData::new_unchecked(
        valid.topics()[..3].to_vec(),
        valid.inner.data.data.clone(),
    );
    for bad in [
        wrong_emitter,
        wrong_signature,
        short_body,
        missing_topic,
        fill_log(1, true),
    ] {
        for logs in [
            vec![bad.clone()],
            vec![valid.clone(), bad.clone()],
            vec![bad, valid.clone()],
        ] {
            assert!(matches!(
                query_fills(logs, Some(0)).await,
                Err(Error::Invalid("Fill event"))
            ));
        }
    }
}

#[tokio::test]
async fn cancel_all_rejects_late_malformed_state_without_reserving_or_sending() {
    use propamm_sdk::{
        Sequencer,
        alloy::rpc::types::{Block, BlockId, Transaction},
    };

    let initial = B256::from(U256::from(1) << 208);
    let posted = B256::from((U256::from(2) << 208) | U256::from(10));
    let bad_flags = B256::from(U256::from(4) << 240);
    for (word, min, max) in [
        (initial, 0u128, 1u128),
        (initial, 1, 0),
        (initial, 2, 1),
        (bad_flags, 0, 0),
        (B256::from(U256::from(10)), 0, 0),
    ] {
        for preview in [false, true] {
            let mock = Asserter::new();
            let provider = ProviderBuilder::new()
                .disable_recommended_fillers()
                .connect_mocked_client(mock.clone());
            mock.push_success(&U256::from(42431));
            mock.push_success(&Bytes::from(true.abi_encode()));
            let info = Info::connect(provider, VENUE, 42431, FACTORY)
                .await
                .unwrap();
            let sequencer = Sequencer::new([(0, 9), (1, 9), (7, 42)]);
            let before = sequencer.checkpoint();
            if !preview {
                mock.push_success(&U256::from(42431));
            }
            let mut block = Block::<Transaction>::default();
            block.header.hash = B256::repeat_byte(0x42);
            mock.push_success(&block);
            mock.push_success(&Bytes::from(2u16.abi_encode()));
            for (hot, lo, hi) in [(posted, 0, 0), (word, min, max)] {
                mock.push_success(&Bytes::from(hot.abi_encode()));
                mock.push_success(&Bytes::from((lo, hi).abi_encode()));
            }
            // Any attempt to send would reach this response instead of a planning error.
            mock.push_failure_msg("unexpected RPC after cancellation reads");
            let error = if preview {
                info.cancel_all_requests(Some(&sequencer), BlockId::latest())
                    .await
                    .unwrap_err()
            } else {
                match Exchange::new(info, VENUE)
                    .cancel_all(Some(&sequencer))
                    .await
                {
                    Err(error) => error,
                    Ok(_) => panic!("malformed cancellation sent"),
                }
            };
            assert_eq!(
                sequencer.checkpoint(),
                before,
                "word={word} band=({min},{max}) preview={preview}"
            );
            assert!(matches!(error, Error::Invalid(_)), "{error:?}");
        }
    }
}
