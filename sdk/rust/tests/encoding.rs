use propamm_sdk::{
    Actions, CancelRequest, Error, HotWord, Level, OrderRequest, Price, Shape, Sides,
    alloy::{
        primitives::{B256, U256, address},
        sol_types::SolCall,
    },
    bindings::IVenue,
};
use proptest::prelude::*;

fn actions() -> Actions {
    Actions::new(address!("1111111111111111111111111111111111111111"), 42431).unwrap()
}

#[test]
fn reset_hot_word_targets_the_pair_without_quote_or_refill_metadata() {
    let call = actions().reset_hot_word(42);
    assert_eq!(
        IVenue::resetHotWordCall::abi_decode(call.data())
            .unwrap()
            .pairIndex,
        42
    );
    assert_eq!(call.venue(), actions().venue());
    assert_eq!(call.chain_id(), 42431);
    assert!(call.posts().is_empty());
}

#[test]
fn prices_are_exact_and_never_silently_round() {
    for value in [
        "1",
        "1.085",
        "0.000000000000000001",
        "79228162514.264337593543950335",
    ] {
        let price: Price = value.parse().unwrap();
        assert_eq!(price.to_string(), value);
    }
    for bad in [
        "",
        "0",
        "-1",
        "+1",
        " 1",
        "1e18",
        ".1",
        "1.",
        "1.2.3",
        "NaN",
        "1.0000000000000000001",
        "79228162514.264337593543950336",
        "9999999999999999999999999999999999999999999",
    ] {
        assert!(bad.parse::<Price>().is_err(), "{bad}");
    }
    assert_eq!(
        "1.085".parse::<Price>().unwrap().scaled(),
        1_085_000_000_000_000_000
    );
}

#[test]
fn matches_independent_solidity_shared_vectors() {
    let data: serde_json::Value = serde_json::from_str(include_str!(
        "../../../contracts/test/vectors/propamm-v2-ladder.json"
    ))
    .unwrap();
    let vectors = data["vectors"].as_array().unwrap();
    assert!(vectors.len() >= 300);
    for v in vectors {
        let raw: B256 = v["hot"].as_str().unwrap().parse().unwrap();
        let hot = HotWord::decode(raw).unwrap();
        assert_eq!(hot.mid.to_string(), v["mid"].as_str().unwrap());
        assert_eq!(
            hot.width_scale.to_string(),
            v["widthScale"].as_str().unwrap()
        );
        assert_eq!(
            hot.depth_scale.to_string(),
            v["depthScale"].as_str().unwrap()
        );
        let widen = if v["baseIn"].as_bool().unwrap() {
            hot.bid_widen
        } else {
            hot.ask_widen
        };
        assert_eq!(widen.to_string(), v["widen"].as_str().unwrap());
        let quote = OrderRequest {
            pair_index: 0,
            mid: Price::from_scaled(hot.mid).unwrap(),
            bid_widen: hot.bid_widen,
            ask_widen: hot.ask_widen,
            width_scale: hot.width_scale,
            depth_scale: hot.depth_scale,
            shape_id: hot.shape_id,
            valid_until: hot.valid_until,
            sequence: hot.sequence,
            sides: hot.sides,
            refill: Sides::Neither,
        };
        assert_eq!(quote.encode().unwrap(), raw);
    }
    for v in data["shapeChecks"].as_array().unwrap() {
        let words: Vec<U256> = v["words"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| w.as_str().unwrap().parse().unwrap())
            .collect();
        let valid = v["reason"].as_u64().unwrap() == 0;
        assert_eq!(
            Shape::from_words(words.try_into().unwrap()).is_ok(),
            valid,
            "{}",
            v["name"]
        );
    }
}

#[test]
fn post_batch_has_big_endian_pair_indices_and_34_byte_entries() {
    let a = OrderRequest::new(0x1234, "1.085".parse().unwrap(), 7, 2, 1_800_000_060);
    let b = OrderRequest::new(
        0xabcd,
        "2".parse().unwrap(),
        255,
        u32::MAX,
        (1u64 << 40) - 1,
    );
    let call = actions().bulk_orders(&[a, b]).unwrap();
    let decoded = IVenue::postCall::abi_decode(call.data()).unwrap();
    assert_eq!(decoded.packed.len(), 68);
    assert_eq!(&decoded.packed[..2], &[0x12, 0x34]);
    assert_eq!(&decoded.packed[2..34], a.encode().unwrap().as_slice());
    assert_eq!(&decoded.packed[34..36], &[0xab, 0xcd]);
    assert_eq!(&decoded.packed[36..], b.encode().unwrap().as_slice());
    assert!(matches!(
        actions().bulk_orders(&[a, a]),
        Err(Error::DuplicatePair(0x1234))
    ));
    assert!(actions().bulk_orders(&[]).is_err());
}

#[test]
fn cancellation_disables_both_sides_and_cancel_all_posts_cancels_without_halting() {
    let requests = [CancelRequest {
        pair_index: 42,
        sequence: 99,
        mid: "1".parse().unwrap(),
    }];
    let call = actions().bulk_cancel(&requests).unwrap();
    let data = IVenue::postCall::abi_decode(call.data()).unwrap();
    let hot = HotWord::decode(B256::from_slice(&data.packed[2..])).unwrap();
    assert_eq!(hot.sides, Sides::Neither);
    assert_eq!(hot.sequence, 99);
    assert_eq!(hot.depth_scale, 0);
    assert_eq!(hot.valid_until, 0);
    let all = actions().cancel_all(&requests).unwrap();
    assert_eq!(all, call, "cancel_all posts the cancels, never setHalted");
    assert!(matches!(
        actions().cancel_all(&[]),
        Err(Error::NothingToCancel { skipped }) if skipped.is_empty()
    ));
    let halt = actions().set_halted(true);
    assert!(
        IVenue::setHaltedCall::abi_decode(halt.data())
            .unwrap()
            .halted
    );
}

#[test]
fn ownership_handover_cancellations_have_the_canonical_calldata() {
    let sponsor = actions().cancel_sponsor_admin_transfer(42);
    assert_eq!(
        IVenue::cancelSponsorAdminTransferCall::abi_decode(sponsor.data())
            .unwrap()
            .sponsorId,
        42
    );
    let owner = actions().cancel_ownership_transfer();
    IVenue::cancelOwnershipTransferCall::abi_decode(owner.data()).unwrap();
}

#[test]
fn bounds_initial_word_and_sequence_exhaustion() {
    let hot = HotWord::decode(B256::from((U256::from(1) << 208usize).to_be_bytes::<32>())).unwrap();
    assert_eq!(hot.mid, 0);
    assert_eq!(hot.next_sequence(0).unwrap(), 2);
    let mut quote = OrderRequest::new(0, "1".parse().unwrap(), 0, 1, 1);
    assert!(quote.encode().is_err());
    quote.sequence = 2;
    quote.valid_until = 1u64 << 40;
    assert!(quote.encode().is_err());
    quote.valid_until = 1;
    quote.sequence = u32::MAX;
    assert!(matches!(
        HotWord::decode(quote.encode().unwrap())
            .unwrap()
            .next_sequence(0),
        Err(Error::SequenceExhausted(0))
    ));
}

#[test]
fn shape_rejects_ambiguous_or_nonmonotone_levels() {
    assert!(Shape::new(&[Level::new(0, 0)], &[]).is_err());
    assert!(Shape::new(&[Level::new(1, 20), Level::new(2, 19)], &[]).is_err());
    assert!(Shape::new(&[Level::new(1, 10); 11], &[]).is_err());
    let shape = Shape::new(
        &[Level::new(50_000, 20); 10],
        &[Level::new(u32::MAX, u16::MAX)],
    )
    .unwrap();
    assert_eq!(Shape::from_words(shape.words()).unwrap(), shape);
    assert_eq!(Shape::new(&[], &[]).unwrap(), Shape::empty());
}

#[test]
fn refills_set_action_bits_that_stored_words_never_carry() {
    let base = OrderRequest::new(0, "1.085".parse().unwrap(), 7, 2, 1_800_000_060);
    let plain = U256::from_be_bytes(base.encode().unwrap().0);
    for (refill, bits) in [
        (Sides::Neither, 0u16),
        (Sides::Bids, 4),
        (Sides::Asks, 8),
        (Sides::Both, 12),
    ] {
        let mut quote = base;
        quote.refill = refill;
        let word = quote.encode().unwrap();
        assert_eq!(
            U256::from_be_bytes(word.0),
            plain | (U256::from(bits) << 240)
        );
        // The venue stores and emits the word with the refill bits cleared.
        assert_eq!(HotWord::decode(word).is_ok(), bits == 0);
    }
    let mut cancelled_refill = base;
    cancelled_refill.sides = Sides::Neither;
    cancelled_refill.refill = Sides::Both;
    assert_eq!(
        U256::from_be_bytes(cancelled_refill.encode().unwrap().0) >> 240,
        U256::from(15)
    );
}

proptest! {
    #[test]
    fn hot_word_round_trip(mid in 1u128..(1u128<<96), bid in any::<u16>(), ask in any::<u16>(),
        width in any::<u16>(), depth in any::<u16>(), shape in any::<u8>(),
        expiry in 0u64..(1u64<<40), sequence in 2u32..=u32::MAX, side in 0u8..4) {
        let sides = [Sides::Both, Sides::Bids, Sides::Asks, Sides::Neither][side as usize];
        let quote = OrderRequest { pair_index: 0, mid: Price::from_scaled(mid).unwrap(), bid_widen: bid,
            ask_widen: ask, width_scale: width, depth_scale: depth, shape_id: shape,
            valid_until: expiry, sequence, sides, refill: Sides::Neither };
        let hot = HotWord::decode(quote.encode().unwrap()).unwrap();
        prop_assert_eq!(hot, HotWord { mid, bid_widen: bid, ask_widen: ask, width_scale: width,
            depth_scale: depth, shape_id: shape, valid_until: expiry, sequence, sides });
    }
}
