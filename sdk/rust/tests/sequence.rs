use std::{collections::HashSet, sync::Arc, thread};

use propamm_sdk::{
    Actions, CancelRequest, Error, Info, OrderRequest, PostOutcome, Sequencer, Sides,
    alloy::{
        primitives::{Address, B256, Bytes, U256, address},
        providers::ProviderBuilder,
        rpc::types::{BlockId, Log},
        sol_types::{SolEvent, SolValue},
        transports::mock::Asserter,
    },
    bindings::IVenue,
};

const VENUE: Address = address!("1111111111111111111111111111111111111111");
const FACTORY: Address = address!("2222222222222222222222222222222222222222");

fn actions() -> Actions {
    Actions::new(VENUE, 42431).unwrap()
}

fn order(pair_index: u16, sequence: u32) -> OrderRequest {
    OrderRequest::new(
        pair_index,
        "1.085".parse().unwrap(),
        7,
        sequence,
        1_800_000_060,
    )
}

fn posted(venue: Address, order: OrderRequest) -> Log {
    let event = IVenue::Posted {
        pairIndex: order.pair_index,
        hotWord: order.encode().unwrap(),
    };
    Log {
        inner: propamm_sdk::alloy::primitives::Log {
            address: venue,
            data: event.encode_log_data(),
        },
        ..Default::default()
    }
}

fn reset(venue: Address, pair_index: u16) -> Log {
    let event = IVenue::HotWordReset {
        pairIndex: pair_index,
        previousSeq: 6,
    };
    Log {
        inner: propamm_sdk::alloy::primitives::Log {
            address: venue,
            data: event.encode_log_data(),
        },
        ..Default::default()
    }
}

#[test]
fn sequencer_allocates_unique_increasing_sequences() {
    let sequencer = Sequencer::new([(0, 5), (3, 1)]);
    assert_eq!(sequencer.next(0).unwrap(), 6);
    assert_eq!(sequencer.next(0).unwrap(), 7);
    assert_eq!(sequencer.next(3).unwrap(), 2);
    assert_eq!(sequencer.last(0), Some(7));
    assert!(matches!(sequencer.next(9), Err(Error::UnseededPair(9))));
    assert_eq!(sequencer.last(9), None);

    let shared = Arc::new(Sequencer::new([(0, 1)]));
    let workers: Vec<_> = (0..8)
        .map(|_| {
            let shared = shared.clone();
            thread::spawn(move || {
                (0..1000)
                    .map(|_| shared.next(0).unwrap())
                    .collect::<Vec<_>>()
            })
        })
        .collect();
    let all: Vec<u32> = workers
        .into_iter()
        .flat_map(|w| w.join().unwrap())
        .collect();
    assert_eq!(all.iter().collect::<HashSet<_>>().len(), 8000);
    assert_eq!(shared.last(0), Some(8001));
}

#[test]
fn sequencer_only_raises_its_floor_and_reports_exhaustion() {
    let sequencer = Sequencer::new([(0, 10)]);
    sequencer.observe(0, 50).unwrap();
    assert_eq!(sequencer.next(0).unwrap(), 51);
    sequencer.observe(0, 20).unwrap();
    assert_eq!(sequencer.next(0).unwrap(), 52);

    let full = Sequencer::new([(4, u32::MAX)]);
    assert!(matches!(full.next(4), Err(Error::SequenceExhausted(4))));
    assert_eq!(full.last(4), Some(u32::MAX));
}

#[test]
fn a_pair_it_was_not_made_with_joins_through_observe_at_its_stored_sequence() {
    // One allocator for the process's life: the venue adds pair 2 after it was made.
    let sequencer = Sequencer::new([(0, 4)]);
    assert!(matches!(sequencer.next(2), Err(Error::UnseededPair(2))));
    assert_eq!(sequencer.last(2), None, "a refused next records nothing");
    sequencer.observe(2, 1).unwrap();
    assert_eq!(sequencer.last(2), Some(1));
    assert_eq!(
        sequencer.next(2).unwrap(),
        2,
        "above the 1 a new pair stores"
    );
    sequencer.observe(2, 1).unwrap();
    assert_eq!(
        sequencer.next(2).unwrap(),
        3,
        "observing it again never lowers it"
    );
    assert_eq!((sequencer.last(0), sequencer.last(2)), (Some(4), Some(3)));
    // The checkpoint holds the added pair too, so a restart from it resumes above both.
    assert_eq!(sequencer.checkpoint(), [(0, 4), (2, 3)]);
    let restarted = Sequencer::new(sequencer.checkpoint());
    assert_eq!(
        (restarted.next(0).unwrap(), restarted.next(2).unwrap()),
        (5, 4)
    );
    assert!(Sequencer::default().checkpoint().is_empty());

    // Threads that first observe one new pair at different stored sequences while others
    // allocate a known pair: the new pair starts at the highest of them, the known pair's
    // allocations stay unique.
    let shared = Arc::new(Sequencer::new([(0, 1)]));
    let observers: Vec<_> = (0..8u32)
        .map(|i| {
            let shared = shared.clone();
            thread::spawn(move || shared.observe(7, 100 + i).unwrap())
        })
        .collect();
    let allocators: Vec<_> = (0..4)
        .map(|_| {
            let shared = shared.clone();
            thread::spawn(move || {
                (0..500)
                    .map(|_| shared.next(0).unwrap())
                    .collect::<Vec<_>>()
            })
        })
        .collect();
    observers.into_iter().for_each(|w| w.join().unwrap());
    let all: Vec<u32> = allocators
        .into_iter()
        .flat_map(|w| w.join().unwrap())
        .collect();
    assert_eq!(all.iter().collect::<HashSet<_>>().len(), 2000);
    assert_eq!(shared.last(7), Some(107), "the highest observed");
    assert_eq!(shared.next(7).unwrap(), 108);
}

#[tokio::test]
async fn sequencer_seeds_from_stored_hot_words_plus_gap() {
    let mock = Asserter::new();
    let provider = ProviderBuilder::new()
        .disable_recommended_fillers()
        .connect_mocked_client(mock.clone());
    mock.push_success(&U256::from(42431));
    mock.push_success(&Bytes::from(true.abi_encode()));
    let info = Info::connect(provider, VENUE, 42431, FACTORY)
        .await
        .unwrap();
    let block = BlockId::number(7);

    mock.push_success(&Bytes::from(order(0, 41).encode().unwrap().abi_encode()));
    mock.push_success(&Bytes::from(order(2, 9).encode().unwrap().abi_encode()));
    let sequencer = Sequencer::seed(&info, &[0, 2], 100, block).await.unwrap();
    assert_eq!(sequencer.next(0).unwrap(), 142);
    assert_eq!(sequencer.next(2).unwrap(), 110);

    mock.push_success(&Bytes::from(B256::ZERO.abi_encode()));
    assert!(matches!(
        Sequencer::seed(&info, &[5], 0, block).await,
        Err(Error::UnknownPair(5))
    ));
    mock.push_success(&Bytes::from(
        order(0, u32::MAX - 1).encode().unwrap().abi_encode(),
    ));
    assert!(matches!(
        Sequencer::seed(&info, &[0], 2, block).await,
        Err(Error::SequenceExhausted(0))
    ));
}

#[test]
fn outcome_separates_acknowledged_from_skipped_entries() {
    let (a, b, c) = (order(0, 6), order(1, 9), order(2, 4));
    let call = actions().bulk_orders(&[a, b, c]).unwrap();
    assert_eq!(call.posts(), &[(0, 6), (1, 9), (2, 4)]);

    let other_venue = posted(FACTORY, c);
    let stale_word = posted(VENUE, order(1, 8));
    let logs = [posted(VENUE, a), other_venue, stale_word];
    let outcome = PostOutcome::from_logs(&call, &logs).unwrap();
    assert_eq!(outcome.accepted, vec![(0, 6)]);
    assert_eq!(outcome.skipped, vec![(1, 9), (2, 4)]);
    assert!(!outcome.all_accepted());

    let all = PostOutcome::from_logs(
        &call,
        &[posted(VENUE, c), posted(VENUE, a), posted(VENUE, b)],
    )
    .unwrap();
    assert!(all.all_accepted());
    assert_eq!(all.accepted, vec![(0, 6), (1, 9), (2, 4)]);
}

#[test]
fn outcome_matches_the_stored_word_and_claims_each_event_once() {
    // A Tempo batch posting the pair twice at one sequence: the venue stores the
    // first entry and skips the second, so only the first word is acknowledged.
    let quote = order(0, 6);
    let first = actions().order(quote).unwrap();
    let cancel = actions()
        .cancel(CancelRequest {
            pair_index: 0,
            sequence: 6,
            mid: quote.mid,
        })
        .unwrap();
    let logs = [posted(VENUE, quote)];
    assert!(
        PostOutcome::from_logs(&first, &logs)
            .unwrap()
            .all_accepted()
    );
    assert_eq!(
        PostOutcome::from_logs(&cancel, &logs).unwrap().skipped,
        vec![(0, 6)],
        "the order's event does not acknowledge a cancel at its sequence"
    );
    let outcomes = PostOutcome::from_batch(&[&first, &cancel], &logs).unwrap();
    assert_eq!(outcomes[0].accepted, vec![(0, 6)]);
    assert_eq!(outcomes[1].skipped, vec![(0, 6)]);

    // An identical repeat is stale too: one event, so one entry reads accepted.
    let outcomes = PostOutcome::from_batch(&[&first, &first], &logs).unwrap();
    assert_eq!(outcomes[0].accepted, vec![(0, 6)]);
    assert_eq!(outcomes[1].skipped, vec![(0, 6)]);

    // The venue emits a refill's word without its refill bits.
    let mut refill = order(1, 7);
    refill.refill = Sides::Both;
    let call = actions().order(refill).unwrap();
    let mut stored = refill;
    stored.refill = Sides::Neither;
    assert!(
        PostOutcome::from_logs(&call, &[posted(VENUE, stored)])
            .unwrap()
            .all_accepted()
    );
    assert!(matches!(
        PostOutcome::from_batch(&[&call, &actions().set_halted(true)], &[]),
        Err(Error::Invalid(_))
    ));
}

#[test]
fn outcome_refuses_a_reset_of_an_attributed_pair() {
    let quote = order(0, 6);
    let call = actions().order(quote).unwrap();
    let logs = [reset(VENUE, 0), posted(VENUE, quote)];
    assert!(matches!(
        PostOutcome::from_batch(&[&call, &call], &logs),
        Err(Error::Invalid(
            "post outcome: HotWordReset makes attribution ambiguous"
        ))
    ));

    let unrelated = [reset(VENUE, 1), posted(VENUE, quote)];
    let outcomes = PostOutcome::from_batch(&[&call, &call], &unrelated).unwrap();
    assert!(outcomes[0].all_accepted());
    assert_eq!(outcomes[1].skipped, vec![(0, 6)]);

    let other_venue = [reset(FACTORY, 0), posted(VENUE, quote)];
    let outcomes = PostOutcome::from_batch(&[&call, &call], &other_venue).unwrap();
    assert!(outcomes[0].all_accepted());
    assert_eq!(outcomes[1].skipped, vec![(0, 6)]);
}

#[test]
fn outcome_covers_cancels_and_rejects_non_post_calls() {
    let cancel = actions()
        .cancel(CancelRequest {
            pair_index: 3,
            sequence: 12,
            mid: "1".parse().unwrap(),
        })
        .unwrap();
    assert_eq!(cancel.posts(), &[(3, 12)]);
    assert_eq!(
        PostOutcome::from_logs(&cancel, &[]).unwrap().skipped,
        vec![(3, 12)]
    );
    assert!(actions().set_halted(true).posts().is_empty());
    assert!(matches!(
        PostOutcome::from_logs(&actions().set_halted(true), &[]),
        Err(Error::Invalid(_))
    ));
}

#[test]
fn outcome_accepts_canonical_max_pair_topics() {
    let quote = order(u16::MAX, 6);
    let call = actions().order(quote).unwrap();
    let outcome = PostOutcome::from_logs(&call, &[posted(VENUE, quote)]).unwrap();
    assert_eq!(outcome.accepted, vec![(u16::MAX, 6)]);
    assert!(matches!(
        PostOutcome::from_logs(&call, &[reset(VENUE, u16::MAX)]),
        Err(Error::Invalid(
            "post outcome: HotWordReset makes attribution ambiguous"
        ))
    ));
}

#[test]
fn outcome_rejects_noncanonical_posted_pair_topics() {
    let quote = order(0, 6);
    let call = actions().order(quote).unwrap();
    // Byte 29 encodes 65536; byte 0 exercises the highest topic bits.
    for high_byte in [29, 0] {
        let mut malformed = posted(VENUE, quote);
        malformed.topics_mut()[1][high_byte] = 1;
        for logs in [
            vec![malformed.clone()],
            vec![malformed.clone(), posted(VENUE, quote)],
            vec![posted(VENUE, quote), malformed.clone()],
        ] {
            assert!(matches!(
                PostOutcome::from_logs(&call, &logs),
                Err(Error::Invalid("Posted event"))
            ));
        }
        // An unrelated emitter cannot invalidate this venue's valid logs.
        malformed.inner.address = FACTORY;
        assert!(
            PostOutcome::from_logs(&call, &[malformed, posted(VENUE, quote)])
                .unwrap()
                .all_accepted()
        );
    }
}

#[test]
fn outcome_rejects_noncanonical_reset_pair_topics() {
    let quote = order(0, 6);
    let call = actions().order(quote).unwrap();
    for high_byte in [29, 0] {
        let mut malformed = reset(VENUE, 0);
        malformed.topics_mut()[1][high_byte] = 1;
        for logs in [
            vec![malformed.clone()],
            vec![malformed.clone(), posted(VENUE, quote)],
            vec![posted(VENUE, quote), malformed.clone()],
        ] {
            assert!(matches!(
                PostOutcome::from_logs(&call, &logs),
                Err(Error::Invalid("HotWordReset event"))
            ));
        }
        malformed.inner.address = FACTORY;
        assert!(
            PostOutcome::from_logs(&call, &[malformed, posted(VENUE, quote)])
                .unwrap()
                .all_accepted()
        );
    }
}
