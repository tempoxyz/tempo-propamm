//! `QuoteState::quote`'s checks that the shared vectors don't reach: the halt, unknown pairs,
//! token binding, the taker priority-fee cap and hook liquidity, each in `Venue.quote`'s order.
use propamm_sdk::{
    Balances, Consumed, Curve, HotWord, LadderError, Level, Market, NO_PRIORITY_FEE_CAP,
    OrderState, QuoteError, QuoteRequest, QuoteState, Shape, Sides,
    alloy::primitives::{Address, U256, address},
    bindings::IVenue::{self, IVenueErrors as E},
};

const BASE: Address = address!("000000000000000000000000000000000000ba5e");
const QUOTE: Address = address!("0000000000000000000000000000000000000c0e");

/// One level of 2 tokens (2e6 base units) a side at 1 bp, mid 1.0, 6-decimal tokens, 10 tokens of each held.
fn state() -> QuoteState {
    QuoteState {
        order: OrderState {
            market: Market {
                pair_index: 3,
                base: BASE,
                quote: QUOTE,
                size_unit: 1_000_000,
                access: IVenue::AccessMode::Open,
                hook: Address::ZERO,
                hook_flags: 0,
            },
            hot: HotWord {
                mid: 1_000_000_000_000_000_000,
                bid_widen: 0,
                ask_widen: 0,
                width_scale: 1000,
                depth_scale: 1000,
                shape_id: 0,
                valid_until: 2_000,
                sequence: 2,
                sides: Sides::Both,
            },
            shape: Shape::new(&[Level::new(2, 10)], &[Level::new(2, 10)]).unwrap(),
            halted: false,
            consumed: Consumed::default(),
        },
        timestamp: 1_000,
        max_taker_priority_fee: NO_PRIORITY_FEE_CAP,
        inventory: Balances {
            base: U256::from(10_000_000),
            quote: U256::from(10_000_000),
        },
        hook_liquidity: Balances::default(),
    }
}

/// The venue's revert for `request`, which must be one.
fn revert(state: &QuoteState, request: &QuoteRequest) -> E {
    match state.quote(request) {
        Err(QuoteError::Revert(error)) => error,
        other => panic!("expected a venue revert, got {other:?}"),
    }
}

/// Buys `amount` base, exact out.
fn buy(amount: u128) -> QuoteRequest {
    QuoteRequest {
        token_in: QUOTE,
        token_out: BASE,
        amount,
        exact_in: false,
        priority_fee: U256::ZERO,
    }
}

#[test]
fn prices_a_fill_and_its_consumption() {
    let mut s = state();
    s.order.consumed = Consumed { bids: 5, asks: 7 };
    let q = s.quote(&buy(1_000_000)).unwrap();
    // 1 token at 1.0001, rounded up toward the maker.
    assert_eq!(
        (q.amount_in, q.amount_out, q.base_filled),
        (1_000_100, 1_000_000, 1_000_000)
    );
    assert!(!q.base_in);
    assert_eq!(
        q.consumed_after,
        Consumed {
            bids: 5,
            asks: 1_000_007
        }
    );
    let sell = QuoteRequest {
        token_in: BASE,
        token_out: QUOTE,
        exact_in: true,
        ..buy(1_000_000)
    };
    let q = s.quote(&sell).unwrap();
    assert_eq!((q.amount_in, q.amount_out), (1_000_000, 999_900));
    assert_eq!(
        q.consumed_after,
        Consumed {
            bids: 1_000_005,
            asks: 7
        }
    );
}

#[test]
fn follows_venue_quote_check_order() {
    // Each fault in turn, every later one present too, so only the first may show.
    let mut s = state();
    s.order.halted = true;
    s.order.market.base = Address::ZERO;
    s.timestamp = 3_000;
    s.order.hot.depth_scale = 0;
    s.max_taker_priority_fee = 0;
    s.inventory = Balances::default();
    let wrong = QuoteRequest {
        token_out: QUOTE,
        ..buy(0)
    };
    let expected = [
        E::VenueHalted(IVenue::VenueHalted {}),
        E::UnknownPair(IVenue::UnknownPair { pairIndex: 3 }),
        E::TokenMismatch(IVenue::TokenMismatch {
            tokenIn: QUOTE,
            tokenOut: QUOTE,
        }),
        E::ZeroAmount(IVenue::ZeroAmount {}),
        E::QuoteExpired(IVenue::QuoteExpired {
            validUntil: 2_000u64.try_into().unwrap(),
        }),
        E::SideDisabled(IVenue::SideDisabled { baseIn: false }),
    ];
    for (k, error) in expected.into_iter().enumerate() {
        let request = if k <= 2 {
            wrong
        } else {
            buy(if k == 3 { 0 } else { 1_000_000 })
        };
        assert_eq!(revert(&s, &request), error, "step {k}");
        match k {
            0 => s.order.halted = false,
            1 => s.order.market.base = BASE,
            2 => {}
            3 => {}
            4 => s.timestamp = 2_000,
            _ => s.order.hot.depth_scale = 1000,
        }
    }
    // The ladder, then the fee cap, then inventory.
    assert_eq!(
        revert(&s, &buy(2_000_001)),
        E::InsufficientDepth(IVenue::InsufficientDepth {})
    );
    let fee = U256::from(1);
    assert_eq!(
        revert(
            &s,
            &QuoteRequest {
                priority_fee: fee,
                ..buy(1)
            }
        ),
        E::TakerPriorityFeeTooHigh(IVenue::TakerPriorityFeeTooHigh {
            priorityFee: fee,
            cap: 0
        })
    );
    assert_eq!(
        revert(&s, &buy(1)),
        E::InsufficientInventory(IVenue::InsufficientInventory {
            token: BASE,
            available: U256::ZERO,
            required: U256::from(1),
        })
    );
}

#[test]
fn the_fee_cap_admits_a_fee_at_it_and_none_means_no_cap() {
    let mut s = state();
    let request = |fee: u64| QuoteRequest {
        priority_fee: U256::from(fee),
        ..buy(1_000)
    };
    assert!(s.quote(&request(u64::MAX)).is_ok());
    s.max_taker_priority_fee = 10;
    assert!(s.quote(&request(10)).is_ok());
    assert!(s.quote(&request(11)).is_err());
}

#[test]
fn a_side_switched_off_disables_only_that_side() {
    let mut s = state();
    s.order.hot.sides = Sides::Bids;
    assert_eq!(
        revert(&s, &buy(1)),
        E::SideDisabled(IVenue::SideDisabled { baseIn: false })
    );
    let sell = QuoteRequest {
        token_in: BASE,
        token_out: QUOTE,
        exact_in: true,
        ..buy(1_000)
    };
    assert!(s.quote(&sell).is_ok());
}

#[test]
fn counts_hook_liquidity_only_with_before_fill() {
    let mut s = state();
    s.inventory.base = U256::from(400_000);
    s.hook_liquidity.base = U256::from(600_000);
    let short = E::InsufficientInventory(IVenue::InsufficientInventory {
        token: BASE,
        available: U256::from(400_000),
        required: U256::from(1_000_000),
    });
    assert_eq!(revert(&s, &buy(1_000_000)), short);
    s.order.market.hook_flags = 2;
    assert_eq!(
        revert(&s, &buy(1_000_000)),
        short,
        "only BEFORE_FILL adds liquidity"
    );
    s.order.market.hook_flags = 1;
    assert!(s.quote(&buy(1_000_000)).is_ok());
    assert_eq!(
        revert(&s, &buy(2_000_001)),
        E::InsufficientDepth(IVenue::InsufficientDepth {}),
        "depth before inventory"
    );
    // Balance plus hook liquidity saturates rather than wrapping.
    s.inventory.base = U256::ZERO;
    s.hook_liquidity.base = U256::MAX;
    assert!(s.quote(&buy(1_000_000)).is_ok());
}

#[test]
fn reports_amount_overflow_above_uint128() {
    let mut s = state();
    // The deepest, widest level at the largest mid: 2^101 base of it costs about 2^143 quote.
    s.order.market.size_unit = u64::MAX;
    s.order.hot.mid = (1 << 96) - 1;
    s.order.hot.depth_scale = u16::MAX;
    s.order.hot.width_scale = u16::MAX;
    s.order.shape = Shape::new(&[], &[Level::new(u32::MAX, u16::MAX)]).unwrap();
    s.inventory.base = U256::MAX;
    assert_eq!(
        revert(&s, &buy(1 << 101)),
        E::AmountOverflow(IVenue::AmountOverflow {})
    );
}

#[test]
fn refuses_hot_words_no_venue_stores_instead_of_wrapping() {
    // A mid above uint96 could overflow LadderMath's 256-bit arithmetic, where Solidity would
    // revert; the Rust port refuses it rather than wrap.
    let mut s = state();
    s.order.hot.mid = 1 << 127;
    assert_eq!(
        s.quote(&buy(1_000)).unwrap_err(),
        QuoteError::OutOfRange("hot word: mid above uint96")
    );
    assert_eq!(
        Curve::new(&s.order.hot, 1, false).fill(U256::from(1), U256::ZERO, false, 1, 0),
        Err(LadderError::MidOutOfRange)
    );
    // An expired quote with a valid_until no uint40 holds is refused, not a panic building
    // QuoteExpired's argument.
    let mut s = state();
    s.order.hot.valid_until = 1 << 40;
    s.timestamp = u64::MAX;
    assert_eq!(
        s.quote(&buy(1_000)).unwrap_err(),
        QuoteError::OutOfRange("hot word: valid_until above uint40")
    );
    // The bounds themselves are in range.
    let mut s = state();
    s.order.hot.mid = (1 << 96) - 1;
    s.order.hot.valid_until = (1 << 40) - 1;
    s.timestamp = (1 << 40) - 1;
    s.inventory.base = U256::MAX;
    assert!(s.quote(&buy(1_000)).is_ok());
}
