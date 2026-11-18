//! Replays the shared vectors against the SDK: `contracts/test/vectors/propamm-v2-ladder.json`, which the
//! Solidity and TypeScript suites replay too, or the file `PROPAMM_VECTORS` names (a path relative to the repository
//! root, or absolute), a seeded random set from `contracts/test/vectors/fuzz.mjs` in the same format.
//!
//! Every section is checked here in full: the ladder vectors and splits through `Curve::fill`
//! (`LadderMath.fill`), the `quotes` cases through `QuoteState::quote` (`Venue.quote`), and the
//! hot words, prices, shapes, post batches and post outcomes the SDK encodes and reads.

use std::{path::PathBuf, sync::OnceLock};

use propamm_sdk::{
    Actions, Balances, CancelRequest, Consumed, Curve, Error, HotWord, LadderError, LadderFill,
    Level, Market, NO_PRIORITY_FEE_CAP, OrderRequest, OrderState, PostOutcome, PreparedCall, Price,
    QuoteError, QuoteRequest, QuoteState, Shape, Sides,
    alloy::{
        primitives::{self, Address, B256, U256, address, hex},
        rpc::types::Log,
        sol_types::{SolCall, SolEvent},
    },
    bindings::IVenue,
};
use serde_json::Value;

fn path() -> PathBuf {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    match std::env::var_os("PROPAMM_VECTORS") {
        Some(file) => root.join(file),
        None => root.join("contracts/test/vectors/propamm-v2-ladder.json"),
    }
}

/// The committed file, whose coverage of every outcome is asserted too; a random set is only held to the reference.
fn committed() -> bool {
    std::env::var_os("PROPAMM_VECTORS").is_none()
}

fn data() -> &'static Value {
    static DATA: OnceLock<Value> = OnceLock::new();
    DATA.get_or_init(|| {
        let file = path();
        let text =
            std::fs::read_to_string(&file).unwrap_or_else(|e| panic!("{}: {e}", file.display()));
        serde_json::from_str(&text).unwrap()
    })
}

fn section(name: &str) -> &'static [Value] {
    data()[name]
        .as_array()
        .unwrap_or_else(|| panic!("no {name} section"))
}

fn name(v: &Value) -> &str {
    v["name"].as_str().unwrap_or_default()
}

/// A decimal string or a JSON number.
fn int<T: TryFrom<u128>>(v: &Value) -> T {
    let n: u128 = match v {
        Value::String(s) => s.parse().unwrap(),
        other => other.as_u64().map(u128::from).unwrap(),
    };
    T::try_from(n).unwrap_or_else(|_| panic!("{v} is out of range"))
}

/// The sides that take fills, from the off flags (bit 0 bids off, bit 1 asks off).
fn sides_on(flags: u16) -> Sides {
    match flags & 3 {
        0 => Sides::Both,
        1 => Sides::Asks,
        2 => Sides::Bids,
        _ => Sides::Neither,
    }
}

/// The sides a post refills, from the refill flags (bit 2 bids, bit 3 asks).
fn refilled(flags: u16) -> Sides {
    match (flags >> 2) & 3 {
        0 => Sides::Neither,
        1 => Sides::Bids,
        2 => Sides::Asks,
        _ => Sides::Both,
    }
}

fn sides_named(v: &Value) -> Sides {
    match v.as_str().unwrap() {
        "both" => Sides::Both,
        "bids" => Sides::Bids,
        "asks" => Sides::Asks,
        "neither" => Sides::Neither,
        other => panic!("unknown sides {other}"),
    }
}

fn words(v: &Value) -> [U256; 4] {
    let words: Vec<U256> = v
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w.as_str().unwrap().parse().unwrap())
        .collect();
    words.try_into().unwrap()
}

fn ladder(sizes: &Value, spreads: &Value) -> Vec<Level> {
    let sizes = sizes.as_array().unwrap();
    let spreads = spreads.as_array().unwrap();
    assert_eq!(sizes.len(), spreads.len());
    sizes
        .iter()
        .zip(spreads)
        .map(|(size, spread)| Level::new(int(size), int(spread)))
        .collect()
}

#[test]
fn hot_words_encode_and_decode_like_the_reference() {
    let vectors = section("hotWords");
    let mut encoded = 0;
    for v in vectors {
        let word: B256 = v["word"].as_str().unwrap().parse().unwrap();
        let flags: u16 = int(&v["flags"]);
        let expected = HotWord {
            mid: int(&v["mid"]),
            bid_widen: int(&v["bidWiden"]),
            ask_widen: int(&v["askWiden"]),
            width_scale: int(&v["widthScale"]),
            depth_scale: int(&v["depthScale"]),
            shape_id: int(&v["shapeId"]),
            valid_until: int(&v["validUntil"]),
            sequence: int(&v["seq"]),
            sides: sides_on(flags),
        };
        // A stored word carries only the off flags: refill and reserved bits are refused.
        match HotWord::decode(word) {
            Ok(hot) => {
                assert!(flags <= 3, "{}: decoded flags {flags}", name(v));
                assert_eq!(hot, expected, "{}", name(v));
            }
            Err(_) => assert!(flags > 3, "{}: refused flags {flags}", name(v)),
        }
        // Every word an order can express: a nonzero mid, a sequence above 1, no reserved flag bits.
        if expected.mid != 0 && expected.sequence > 1 && flags <= 15 {
            let order = OrderRequest {
                pair_index: 0,
                mid: Price::from_scaled(expected.mid).unwrap(),
                bid_widen: expected.bid_widen,
                ask_widen: expected.ask_widen,
                width_scale: expected.width_scale,
                depth_scale: expected.depth_scale,
                shape_id: expected.shape_id,
                valid_until: expected.valid_until,
                sequence: expected.sequence,
                sides: sides_on(flags),
                refill: refilled(flags),
            };
            assert_eq!(order.encode().unwrap(), word, "{}", name(v));
            encoded += 1;
        }
    }
    if committed() {
        assert!(
            vectors.len() >= 50 && encoded >= 30,
            "{encoded} of {}",
            vectors.len()
        );
    }
}

#[test]
fn ladder_vector_hot_words_round_trip() {
    for v in section("vectors") {
        let word: B256 = v["hot"].as_str().unwrap().parse().unwrap();
        let hot = HotWord::decode(word).unwrap();
        assert_eq!(hot.mid, int::<u128>(&v["mid"]), "{}", name(v));
        let widen = if v["baseIn"].as_bool().unwrap() {
            hot.bid_widen
        } else {
            hot.ask_widen
        };
        assert_eq!(widen, int::<u16>(&v["widen"]), "{}", name(v));
        assert_eq!(hot.width_scale, int::<u16>(&v["widthScale"]), "{}", name(v));
        assert_eq!(hot.depth_scale, int::<u16>(&v["depthScale"]), "{}", name(v));
        let order = OrderRequest {
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
        assert_eq!(order.encode().unwrap(), word, "{}", name(v));
    }
}

#[test]
fn prices_parse_and_print_like_the_reference() {
    let vectors = section("prices");
    for v in vectors {
        let text = v["text"].as_str().unwrap();
        match (text.parse::<Price>(), v["ok"].as_bool().unwrap()) {
            (Ok(price), true) => {
                assert_eq!(price.scaled(), int::<u128>(&v["mid"]), "{text:?}");
                assert_eq!(
                    price.to_string(),
                    v["canonical"].as_str().unwrap(),
                    "{text:?}"
                );
            }
            (Err(_), false) => {}
            (got, ok) => panic!("{text:?}: parsed {got:?}, the reference says ok = {ok}"),
        }
    }
    if committed() {
        assert!(vectors.len() >= 40);
    }
}

#[test]
fn shapes_encode_like_the_reference() {
    for v in section("shapes") {
        let shape = Shape::new(
            &ladder(&v["bidSizes"], &v["bidSpreads"]),
            &ladder(&v["askSizes"], &v["askSpreads"]),
        )
        .unwrap_or_else(|e| panic!("{}: {e}", name(v)));
        assert_eq!(shape.words(), words(&v["words"]), "{}", name(v));
        assert_eq!(
            Shape::from_words(shape.words()).unwrap(),
            shape,
            "{}",
            name(v)
        );
    }
    for v in section("shapeRejects") {
        let built = Shape::new(
            &ladder(&v["bidSizes"], &v["bidSpreads"]),
            &ladder(&v["askSizes"], &v["askSpreads"]),
        );
        assert!(
            built.is_err(),
            "{}: built a shape the reference refuses ({})",
            name(v),
            v["error"]
        );
    }
    // `from_words` accepts exactly the words `ShapeWord.check` accepts; it returns no reason.
    for v in section("shapeChecks") {
        let valid = v["reason"].as_u64().unwrap() == 0;
        assert_eq!(
            Shape::from_words(words(&v["words"])).is_ok(),
            valid,
            "{}",
            name(v)
        );
    }
}

fn order(q: &Value) -> OrderRequest {
    let mut order = OrderRequest::new(
        int(&q["pairIndex"]),
        Price::from_scaled(int(&q["mid"])).unwrap(),
        int(&q["shapeId"]),
        int(&q["sequence"]),
        int(&q["validUntil"]),
    );
    if let Some(x) = q.get("bidWiden") {
        order.bid_widen = int(x);
    }
    if let Some(x) = q.get("askWiden") {
        order.ask_widen = int(x);
    }
    if let Some(x) = q.get("widthScale") {
        order.width_scale = int(x);
    }
    if let Some(x) = q.get("depthScale") {
        order.depth_scale = int(x);
    }
    if let Some(x) = q.get("sides") {
        order.sides = sides_named(x);
    }
    if let Some(x) = q.get("refill") {
        order.refill = sides_named(x);
    }
    order
}

fn cancel(q: &Value) -> CancelRequest {
    CancelRequest {
        pair_index: int(&q["pairIndex"]),
        sequence: int(&q["sequence"]),
        mid: Price::from_scaled(int(&q["mid"])).unwrap(),
    }
}

const VENUE: Address = address!("1111111111111111111111111111111111111111");

/// An order or cancel batch in the `posts` section's request form.
fn batch(v: &Value) -> Result<PreparedCall, Error> {
    let actions = Actions::new(VENUE, 42431).unwrap();
    let requests = v["requests"].as_array().unwrap();
    if v["kind"] == "cancels" {
        actions.bulk_cancel(&requests.iter().map(cancel).collect::<Vec<_>>())
    } else {
        actions.bulk_orders(&requests.iter().map(order).collect::<Vec<_>>())
    }
}

/// The reference's name for the SDK's refusal.
fn refusal(error: &Error) -> &'static str {
    match error {
        Error::DuplicatePair(_) => "DuplicatePair",
        Error::Invalid(m) if m.starts_with("empty") => "EmptyBatch",
        Error::Invalid(m) if m.starts_with("sequence") => "InvalidSequence",
        Error::Invalid(m) if m.starts_with("expiry") => "InvalidExpiry",
        other => panic!("no reference name for {other}"),
    }
}

#[test]
fn post_batches_pack_like_the_reference() {
    let selector: [u8; 4] = hex::decode(data()["postSelector"].as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap();
    assert_eq!(selector, IVenue::postCall::SELECTOR);
    let vectors = section("posts");
    let mut built = 0;
    for v in vectors {
        match (batch(v), v["expect"].as_str().unwrap()) {
            (Ok(call), "ok") => {
                let calldata = hex::decode(v["calldata"].as_str().unwrap()).unwrap();
                assert_eq!(call.data().as_ref(), calldata.as_slice(), "{}", name(v));
                let packed = hex::decode(v["packed"].as_str().unwrap()).unwrap();
                let decoded = IVenue::postCall::abi_decode(call.data()).unwrap();
                assert_eq!(decoded.packed.as_ref(), packed.as_slice(), "{}", name(v));
                assert_eq!(call.posts(), entries(&v["posts"]), "{}", name(v));
                built += 1;
            }
            (Err(e), expect) => assert_eq!(refusal(&e), expect, "{}: {e}", name(v)),
            (Ok(_), expect) => panic!(
                "{}: built a batch the reference refuses ({expect})",
                name(v)
            ),
        }
    }
    if committed() {
        assert!(
            built >= 10 && vectors.len() > built,
            "{built} of {}",
            vectors.len()
        );
    }
}

fn entries(v: &Value) -> Vec<(u16, u32)> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|p| (int(&p[0]), int(&p[1])))
        .collect()
}

#[test]
fn post_outcomes_match_the_reference() {
    let vectors = section("outcomes");
    let other = address!("2222222222222222222222222222222222222222");
    for v in vectors {
        let calls: Vec<_> = v["calls"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| batch(c).unwrap())
            .collect();
        let posted = |venue, p: &Value| Log {
            inner: primitives::Log {
                address: venue,
                data: IVenue::Posted {
                    pairIndex: int(&p[0]),
                    hotWord: p[1].as_str().unwrap().parse().unwrap(),
                }
                .encode_log_data(),
            },
            ..Default::default()
        };
        // The venue's events, and each once more from another contract, which must not count.
        let events = v["posted"].as_array().unwrap();
        let logs: Vec<_> = events
            .iter()
            .flat_map(|p| [posted(other, p), posted(VENUE, p)])
            .collect();
        let expected: Vec<_> = v["outcomes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|o| PostOutcome {
                accepted: entries(&o["accepted"]),
                skipped: entries(&o["skipped"]),
            })
            .collect();
        let outcomes = PostOutcome::from_batch(&calls.iter().collect::<Vec<_>>(), &logs).unwrap();
        assert_eq!(outcomes, expected, "{}", name(v));
        if let [call] = calls.as_slice() {
            assert_eq!(
                PostOutcome::from_logs(call, &logs).unwrap(),
                expected[0],
                "{}",
                name(v)
            );
        }
    }
    if committed() {
        assert!(vectors.len() >= 10, "{} outcome cases", vectors.len());
    }
}

/// A decimal string, a JSON number or a 0x hex string.
fn u256(v: &Value) -> U256 {
    match v {
        Value::String(s) if s.starts_with("0x") => s.parse().unwrap(),
        Value::String(s) => U256::from_str_radix(s, 10).unwrap(),
        other => U256::from(other.as_u64().unwrap()),
    }
}

/// One `vectors` entry through `Curve::fill`.
fn price(v: &Value) -> Result<LadderFill, LadderError> {
    let word: B256 = v["hot"].as_str().unwrap().parse().unwrap();
    let hot = HotWord::decode(word).unwrap();
    let curve = Curve::new(&hot, int(&v["sizeUnit"]), v["baseIn"].as_bool().unwrap());
    curve.fill(
        u256(&v["w0"]),
        u256(&v["w1"]),
        v["exactIn"].as_bool().unwrap(),
        int(&v["amount"]),
        int(&v["consumed"]),
    )
}

#[test]
fn ladder_vectors_price_like_the_reference() {
    let vectors = section("vectors");
    let mut seen = std::collections::BTreeMap::new();
    for v in vectors {
        let expect = v["expect"].as_str().unwrap();
        match (price(v), expect) {
            (Ok(fill), "ok") => {
                assert_eq!(
                    fill.amount_in,
                    u256(&v["amountIn"]),
                    "{}: amountIn",
                    name(v)
                );
                assert_eq!(
                    fill.amount_out,
                    u256(&v["amountOut"]),
                    "{}: amountOut",
                    name(v)
                );
                assert_eq!(
                    fill.base_filled,
                    u256(&v["baseFilled"]),
                    "{}: baseFilled",
                    name(v)
                );
            }
            (Err(LadderError::InsufficientDepth), "InsufficientDepth")
            | (Err(LadderError::ZeroFill), "ZeroFill") => {}
            (got, expect) => panic!("{}: got {got:?}, the reference says {expect}", name(v)),
        }
        *seen
            .entry((v["direction"].as_str().unwrap(), expect))
            .or_insert(0) += 1;
    }
    if committed() {
        // Every direction fills and runs out of depth; rounding to zero is rarer.
        assert!(vectors.len() >= 2000, "{} vectors", vectors.len());
        for direction in [
            "sellBaseExactIn",
            "buyBaseExactOut",
            "payQuoteExactIn",
            "wantQuoteExactOut",
        ] {
            for expect in ["ok", "InsufficientDepth"] {
                assert!(
                    seen.contains_key(&(direction, expect)),
                    "no {direction} {expect}"
                );
            }
        }
        assert!(seen.keys().any(|(_, expect)| *expect == "ZeroFill"));
    }
}

#[test]
fn splits_chain_through_consumed_and_never_beat_the_whole() {
    let vectors = section("vectors");
    let splits = section("splits");
    let mut dust = 0;
    for sp in splits {
        let whole = &vectors[int::<usize>(&sp["whole"])];
        let w = price(whole).unwrap_or_else(|e| panic!("{}: the whole must fill: {e:?}", name(sp)));
        let mut consumed: u128 = int(&whole["consumed"]);
        let (mut traded, mut paid, mut received) = (U256::ZERO, U256::ZERO, U256::ZERO);
        for part in sp["parts"].as_array().unwrap() {
            let part = &vectors[int::<usize>(part)];
            assert_eq!(
                int::<u128>(&part["consumed"]),
                consumed,
                "{}: a part starts where the last stopped",
                name(sp)
            );
            assert_eq!(part["hot"], whole["hot"], "{}", name(sp));
            assert_eq!(part["direction"], whole["direction"], "{}", name(sp));
            let Ok(fill) = price(part) else {
                dust += 1;
                continue;
            };
            consumed += u128::try_from(fill.base_filled).unwrap();
            traded += u256(&part["amount"]);
            paid += fill.amount_in;
            received += fill.amount_out;
        }
        assert_eq!(traded, u256(&whole["amount"]), "{}", name(sp));
        if whole["exactIn"].as_bool().unwrap() {
            assert!(
                received <= w.amount_out,
                "{}: the split paid out more",
                name(sp)
            );
        } else {
            assert!(paid >= w.amount_in, "{}: the split cost less", name(sp));
        }
    }
    if committed() {
        assert!(
            splits.len() >= 40 && dust > 0,
            "{} splits, {dust} dust parts",
            splits.len()
        );
    }
}

const BASE: Address = address!("000000000000000000000000000000000000ba5e");
const QUOTE: Address = address!("0000000000000000000000000000000000000c0e");

/// The reference's revert, as the venue's error.
fn revert(step: &Value) -> IVenue::IVenueErrors {
    use IVenue::IVenueErrors as E;
    let args = step["args"].as_array().unwrap();
    let arg = |i: usize| args[i].as_str().unwrap();
    match step["expect"].as_str().unwrap() {
        "ZeroAmount" => E::ZeroAmount(IVenue::ZeroAmount {}),
        "QuoteExpired" => E::QuoteExpired(IVenue::QuoteExpired {
            validUntil: arg(0).parse().unwrap(),
        }),
        "SideDisabled" => E::SideDisabled(IVenue::SideDisabled {
            baseIn: arg(0) == "true",
        }),
        "InsufficientDepth" => E::InsufficientDepth(IVenue::InsufficientDepth {}),
        "ZeroFill" => E::ZeroFill(IVenue::ZeroFill {}),
        "AmountOverflow" => E::AmountOverflow(IVenue::AmountOverflow {}),
        "InsufficientInventory" => E::InsufficientInventory(IVenue::InsufficientInventory {
            token: if arg(0) == "base" { BASE } else { QUOTE },
            available: U256::from_str_radix(arg(1), 10).unwrap(),
            required: U256::from_str_radix(arg(2), 10).unwrap(),
        }),
        other => panic!("no venue error for {other}"),
    }
}

/// One case through the SDK's own model of a pair: the stored word and refills for posts,
/// `QuoteState::quote` for quotes, and its `consumed_after` and amounts for fills.
fn replay(c: &Value) -> usize {
    // `HotWord.INITIAL`, the word `addPair` stores: sequence 1, everything else 0.
    let mut stored = B256::from(U256::from(1) << 208);
    let mut shapes = std::collections::HashMap::new();
    let mut consumed = Consumed::default();
    let mut inventory = Balances {
        base: u256(&c["inventory"][0]),
        quote: u256(&c["inventory"][1]),
    };
    let mut fills = 0;
    for (j, s) in c["steps"].as_array().unwrap().iter().enumerate() {
        let label = format!("{}: step {j} {}", name(c), s["op"].as_str().unwrap());
        match s["op"].as_str().unwrap() {
            "setShape" => {
                let shape = Shape::from_words(words(&s["words"])).unwrap();
                shapes.insert(int::<u8>(&s["shapeId"]), shape);
            }
            "post" => {
                let mut word: B256 = s["word"].as_str().unwrap().parse().unwrap();
                // Refill bits are flag bits 2 and 3; the venue applies them and stores the word without.
                let refill = word[1] & 0x0c;
                word[1] &= !0x0c;
                let entry = HotWord::decode(word).unwrap();
                let accepted = entry.sequence > HotWord::decode(stored).unwrap().sequence;
                assert_eq!(
                    accepted,
                    s["accepted"].as_bool().unwrap(),
                    "{label}: accepted"
                );
                if accepted {
                    stored = word;
                    if refill & 0x04 != 0 {
                        consumed.bids = 0;
                    }
                    if refill & 0x08 != 0 {
                        consumed.asks = 0;
                    }
                }
            }
            op => {
                let hot = HotWord::decode(stored).unwrap();
                let state = QuoteState {
                    order: OrderState {
                        market: Market {
                            pair_index: 0,
                            base: BASE,
                            quote: QUOTE,
                            size_unit: int(&c["sizeUnit"]),
                            access: IVenue::AccessMode::Open,
                            hook: Address::ZERO,
                            hook_flags: 0,
                        },
                        hot,
                        shape: shapes
                            .get(&hot.shape_id)
                            .cloned()
                            .unwrap_or_else(Shape::empty),
                        halted: false,
                        consumed,
                    },
                    timestamp: int(&c["timestamp"]),
                    max_taker_priority_fee: NO_PRIORITY_FEE_CAP,
                    inventory,
                    hook_liquidity: Balances::default(),
                };
                let base_in = s["baseIn"].as_bool().unwrap();
                let (token_in, token_out) = if base_in {
                    (BASE, QUOTE)
                } else {
                    (QUOTE, BASE)
                };
                let request = QuoteRequest {
                    token_in,
                    token_out,
                    amount: int(&s["amount"]),
                    exact_in: s["exactIn"].as_bool().unwrap(),
                    priority_fee: U256::ZERO,
                };
                match (state.quote(&request), s["expect"].as_str().unwrap()) {
                    (Ok(q), "ok") => {
                        assert_eq!(
                            q.amount_in,
                            int::<u128>(&s["amountIn"]),
                            "{label}: amountIn"
                        );
                        assert_eq!(
                            q.amount_out,
                            int::<u128>(&s["amountOut"]),
                            "{label}: amountOut"
                        );
                        assert_eq!(
                            q.base_filled,
                            int::<u128>(&s["baseFilled"]),
                            "{label}: baseFilled"
                        );
                        if op == "fill" {
                            consumed = q.consumed_after;
                            let (amount_in, amount_out) =
                                (U256::from(q.amount_in), U256::from(q.amount_out));
                            if base_in {
                                inventory.base += amount_in;
                                inventory.quote -= amount_out;
                            } else {
                                inventory.quote += amount_in;
                                inventory.base -= amount_out;
                            }
                            fills += 1;
                        }
                    }
                    (Err(got), "ok") => panic!("{label}: expected ok, got {got:?}"),
                    (got, _) => {
                        assert_eq!(got.err(), Some(QuoteError::Revert(revert(s))), "{label}")
                    }
                }
            }
        }
        let after = [consumed.bids.to_string(), consumed.asks.to_string()];
        assert_eq!(
            after.as_slice(),
            s["consumed"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap())
                .collect::<Vec<_>>(),
            "{label}: consumed"
        );
        assert_eq!(
            [inventory.base, inventory.quote],
            [u256(&s["inventory"][0]), u256(&s["inventory"][1])],
            "{label}: inventory"
        );
    }
    fills
}

#[test]
fn quotes_follow_the_reference() {
    let cases = section("quotes");
    let fills: usize = cases.iter().map(replay).sum();
    if committed() {
        assert!(
            cases.len() >= 10 && fills >= 40,
            "{} cases, {fills} fills",
            cases.len()
        );
    }
}
