//! Local pricing: `LadderMath.fill` and `Venue.quote`, ported from the Solidity so a maker can
//! price its own ladder without a call. The shared vectors hold both to the BigInt reference
//! model (`tests/vectors.rs`), and the onchain suite holds them to a deployed venue.

use alloy::primitives::{Address, U256};

use crate::{Consumed, HotWord, OrderState, Sides, bindings::IVenue};

/// A level's price factor is held over this: 100% of spread (1e5 tenths of a basis
/// point) times the width denominator.
const FACTOR_ONE: u64 = 100_000_000;
/// Quote targets are held scaled by this: `mid`'s 1e18 times `FACTOR_ONE`.
const DENOMINATOR: U256 = U256::from_limbs([0xdcc8_0cd2_e400_0000, 0x0052_b7d2, 0, 0]);
/// `widthScale` and `depthScale` are per mille.
const SCALE_ONE: u64 = 1_000;
const MAX_LEVELS: usize = 10;
/// The largest `mid` a hot word holds (`uint96`). Below it, no step of `fill` can overflow 256 bits.
const MAX_MID: u128 = (1 << 96) - 1;
/// The largest `validUntil` a hot word holds (`uint40`).
const MAX_VALID_UNTIL: u64 = (1 << 40) - 1;
const LEVELS_PER_WORD: usize = 5;
/// `VenueHookFlags.BEFORE_FILL`: the hook can add inventory before a payout.
const BEFORE_FILL: u8 = 1;
/// `Venue.NO_PRIORITY_FEE_CAP`: a cap of `type(uint64).max` is none.
pub const NO_PRIORITY_FEE_CAP: u64 = u64::MAX;

/// `LadderMath.Curve`: the walked side's pricing inputs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Curve {
    pub mid: u128,
    /// `bid_widen` on the bid side, `ask_widen` on the ask side.
    pub widen: u16,
    pub width_scale: u16,
    pub depth_scale: u16,
    pub size_unit: u64,
    /// True when the taker sells base and walks the bids.
    pub bid: bool,
}

/// One fill's amounts. They are unbounded here; `Venue.quote` refuses either above
/// `uint128` (`AmountOverflow`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LadderFill {
    pub amount_in: U256,
    pub amount_out: U256,
    /// Base the fill moves on the walked side, which the venue adds to its consumption.
    pub base_filled: U256,
}

/// The errors `LadderMath.fill` reverts with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LadderError {
    /// The side's ladder left after its consumption can't cover the fill.
    InsufficientDepth,
    /// Either side of the fill rounds to zero.
    ZeroFill,
    /// `mid` is above `uint96`, which no hot word holds. `LadderMath` never sees one; with one, its
    /// checked arithmetic could overflow, so this refuses it rather than wrap.
    MidOutOfRange,
}

impl Curve {
    /// `LadderMath.curve`: the side `base_in` walks (bids when the taker sells base).
    pub const fn new(hot: &HotWord, size_unit: u64, base_in: bool) -> Self {
        Self {
            mid: hot.mid,
            widen: if base_in {
                hot.bid_widen
            } else {
                hot.ask_widen
            },
            width_scale: hot.width_scale,
            depth_scale: hot.depth_scale,
            size_unit,
            bid: base_in,
        }
    }

    /// `LadderMath.factor`: a level's price factor over `1e8`, or 0 at or past the bid floor.
    pub fn factor(&self, spread: u16) -> u64 {
        let offset =
            u64::from(spread) * u64::from(self.width_scale) + u64::from(self.widen) * SCALE_ONE;
        if !self.bid {
            return FACTOR_ONE + offset;
        }
        FACTOR_ONE.saturating_sub(offset)
    }

    /// `LadderMath.effectiveSize`: `floor(raw_size * size_unit * depth_scale / 1000)` base units.
    pub fn effective_size(&self, raw_size: u32) -> U256 {
        U256::from(raw_size) * U256::from(self.size_unit) * U256::from(self.depth_scale)
            / U256::from(SCALE_ONE)
    }

    /// `LadderMath.fill`, line for line: prices one fill from `consumed` base units down the
    /// side's ladder (`w0`, `w1`, as `Shape::words` holds them), rounding once toward the
    /// maker. `amount` is the input when `exact_in`, else the output. `InsufficientDepth`
    /// takes precedence over `ZeroFill`, as onchain.
    pub fn fill(
        &self,
        w0: U256,
        w1: U256,
        exact_in: bool,
        amount: u128,
        consumed: u128,
    ) -> Result<LadderFill, LadderError> {
        // Every other input's type bounds it; with `mid` in `uint96` too, the largest product
        // below (a level's value) stays under 2^236 and the sum of ten under 2^240.
        if self.mid > MAX_MID {
            return Err(LadderError::MidOutOfRange);
        }
        let amount = U256::from(amount);
        // Selling base exact-in and buying base exact-out both walk toward a base target;
        // the other two walk toward a quote target, held scaled by the denominator.
        let base_target = self.bid == exact_in;
        let mut remaining = if base_target {
            amount
        } else {
            amount * DENOMINATOR
        };
        let mut numerator = U256::ZERO;
        let mut base_filled = U256::ZERO;
        let mut done = false;
        let mut offset = U256::from(consumed);
        let mid = U256::from(self.mid);

        for i in 0..MAX_LEVELS {
            let (raw_size, spread) = level(w0, w1, i);
            if raw_size == 0 {
                break;
            }
            let f = self.factor(spread);
            if f == 0 {
                break;
            }

            // The levels earlier fills took, and any empty level, hold nothing for this one.
            let mut available = self.effective_size(raw_size);
            if offset >= available {
                offset -= available;
                continue;
            }
            available -= offset;
            offset = U256::ZERO;

            let unit_price = mid * U256::from(f);
            if base_target {
                let take = available.min(remaining);
                numerator += take * unit_price;
                base_filled += take;
                remaining -= take;
                if remaining.is_zero() {
                    done = true;
                    break;
                }
            } else {
                let value = available * unit_price;
                if self.bid {
                    // Wants quote exact-out: the smallest base whose value covers the remaining quote.
                    if value >= remaining {
                        base_filled += remaining.div_ceil(unit_price);
                        done = true;
                        break;
                    }
                    base_filled += available;
                    remaining -= value;
                } else {
                    // Pays quote exact-in: the most base the remaining quote buys. Deeper asks
                    // are never cheaper, so once the remainder can't buy one unit here it can't
                    // buy one anywhere.
                    if value > remaining {
                        base_filled += remaining / unit_price;
                        done = true;
                        break;
                    }
                    base_filled += available;
                    remaining -= value;
                    if remaining < unit_price {
                        done = true;
                        break;
                    }
                }
            }
        }

        if !done {
            return Err(LadderError::InsufficientDepth);
        }
        let (amount_in, amount_out) = match (base_target, self.bid) {
            (true, true) => (amount, numerator / DENOMINATOR),
            (true, false) => (numerator.div_ceil(DENOMINATOR), amount),
            (false, true) => (base_filled, amount),
            (false, false) => (amount, base_filled),
        };
        if amount_in.is_zero() || amount_out.is_zero() {
            return Err(LadderError::ZeroFill);
        }
        Ok(LadderFill {
            amount_in,
            amount_out,
            base_filled,
        })
    }
}

/// `ShapeWord.level`: level `i` of a side's two words, `(size, spread)`.
fn level(w0: U256, w1: U256, i: usize) -> (u32, u16) {
    let word = if i < LEVELS_PER_WORD { w0 } else { w1 };
    let slot = word >> (48 * (i % LEVELS_PER_WORD));
    let limb = slot.as_limbs()[0];
    (limb as u32, (limb >> 32) as u16)
}

/// The two words of one side of a shape's four (bids first).
fn side(words: [U256; 4], base_in: bool) -> (U256, U256) {
    let (w0, w1) = if base_in {
        (words[0], words[1])
    } else {
        (words[2], words[3])
    };
    // `ShapeWord.continues`: the second word is read only when level 5 has size.
    let continues = level(w0, U256::ZERO, LEVELS_PER_WORD - 1).0 != 0;
    (w0, if continues { w1 } else { U256::ZERO })
}

/// A pair's base and quote amounts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Balances {
    pub base: U256,
    pub quote: U256,
}

/// Why `QuoteState::quote` refuses a request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QuoteError {
    /// What `Venue.quote` reverts with from this state, with its arguments.
    Revert(IVenue::IVenueErrors),
    /// A hot word no venue can store (a `mid` above `uint96` or a `valid_until` above
    /// `uint40`), so there is no venue answer to reproduce. State that `Info::quote_state`
    /// reads never has one.
    OutOfRange(&'static str),
}

impl From<IVenue::IVenueErrors> for QuoteError {
    fn from(error: IVenue::IVenueErrors) -> Self {
        Self::Revert(error)
    }
}

/// Everything `Venue.quote` reads for one pair, at one block (`Info::quote_state`).
#[derive(Clone, Debug)]
pub struct QuoteState {
    /// The pair, its hot word, active shape, consumption and the venue's halt.
    pub order: OrderState,
    /// The block's timestamp, which `valid_until` is checked against.
    pub timestamp: u64,
    /// `maxTakerPriorityFee`; `NO_PRIORITY_FEE_CAP` is none.
    pub max_taker_priority_fee: u64,
    /// The venue's balance of each token.
    pub inventory: Balances,
    /// `hookLiquidity` for each token, counted only when the hook has `BEFORE_FILL`.
    pub hook_liquidity: Balances,
}

/// One taker request, as `Venue.quote` takes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct QuoteRequest {
    pub token_in: Address,
    pub token_out: Address,
    /// The input when `exact_in`, else the output.
    pub amount: u128,
    pub exact_in: bool,
    /// The priority fee per gas of the transaction the quote runs in: 0 for an
    /// `eth_call` without fee fields.
    pub priority_fee: U256,
}

/// `Venue.quote`'s amounts, and what a fill at them does to the pair's consumption.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LocalQuote {
    pub amount_in: u128,
    pub amount_out: u128,
    /// The taker sells base (walks the bids).
    pub base_in: bool,
    /// Base moved on the walked side.
    pub base_filled: u128,
    /// Both sides' consumption after a fill at this quote.
    pub consumed_after: Consumed,
}

impl QuoteState {
    /// `Venue.quote`, locally: the same checks in the same order, from the same state, so it
    /// returns the venue's amounts or its revert. In order: `VenueHalted`, `UnknownPair`,
    /// `TokenMismatch`, `ZeroAmount`, `QuoteExpired`, `SideDisabled`, the ladder
    /// (`InsufficientDepth`, `ZeroFill`), `AmountOverflow`, `TakerPriorityFeeTooHigh`, then
    /// `InsufficientInventory` (balance plus hook liquidity with `BEFORE_FILL`), each as
    /// `QuoteError::Revert`. Like `Venue.quote`, it doesn't check taker access. A hand-built hot
    /// word outside what a venue stores is `QuoteError::OutOfRange`, before any check.
    pub fn quote(&self, request: &QuoteRequest) -> Result<LocalQuote, QuoteError> {
        let hot = &self.order.hot;
        if hot.mid > MAX_MID {
            return Err(QuoteError::OutOfRange("hot word: mid above uint96"));
        }
        if hot.valid_until > MAX_VALID_UNTIL {
            return Err(QuoteError::OutOfRange("hot word: valid_until above uint40"));
        }
        self.venue_quote(request).map_err(QuoteError::Revert)
    }

    /// `Venue.quote`'s checks, on a hot word within its fields' onchain bounds.
    fn venue_quote(&self, request: &QuoteRequest) -> Result<LocalQuote, IVenue::IVenueErrors> {
        use IVenue::IVenueErrors as E;
        let OrderState {
            market,
            hot,
            shape,
            halted,
            consumed,
        } = &self.order;
        if *halted {
            return Err(E::VenueHalted(IVenue::VenueHalted {}));
        }
        // `Venue._price`.
        if market.base.is_zero() {
            return Err(E::UnknownPair(IVenue::UnknownPair {
                pairIndex: market.pair_index,
            }));
        }
        let base_in = request.token_in == market.base;
        let bound = if base_in {
            request.token_out == market.quote
        } else {
            request.token_in == market.quote && request.token_out == market.base
        };
        if !bound {
            return Err(E::TokenMismatch(IVenue::TokenMismatch {
                tokenIn: request.token_in,
                tokenOut: request.token_out,
            }));
        }
        if request.amount == 0 {
            return Err(E::ZeroAmount(IVenue::ZeroAmount {}));
        }
        if self.timestamp > hot.valid_until {
            return Err(E::QuoteExpired(IVenue::QuoteExpired {
                validUntil: alloy::primitives::aliases::U40::from_limbs([hot.valid_until]),
            }));
        }
        let side_off = matches!(
            (hot.sides, base_in),
            (Sides::Neither, _) | (Sides::Asks, true) | (Sides::Bids, false)
        );
        if hot.depth_scale == 0 || side_off {
            return Err(E::SideDisabled(IVenue::SideDisabled { baseIn: base_in }));
        }
        let (w0, w1) = side(shape.words(), base_in);
        let offset = if base_in {
            consumed.bids
        } else {
            consumed.asks
        };
        let fill = Curve::new(hot, market.size_unit, base_in)
            .fill(w0, w1, request.exact_in, request.amount, offset)
            .map_err(|error| match error {
                LadderError::InsufficientDepth => {
                    E::InsufficientDepth(IVenue::InsufficientDepth {})
                }
                LadderError::ZeroFill => E::ZeroFill(IVenue::ZeroFill {}),
                // `quote` refused an out-of-range mid before this.
                LadderError::MidOutOfRange => unreachable!("mid checked in quote"),
            })?;
        let (Ok(amount_in), Ok(amount_out)) = (
            u128::try_from(fill.amount_in),
            u128::try_from(fill.amount_out),
        ) else {
            return Err(E::AmountOverflow(IVenue::AmountOverflow {}));
        };
        // Both are within uint128, and `base_filled` is one of them.
        let base_filled = u128::try_from(fill.base_filled).expect("base filled is an amount");

        let cap = self.max_taker_priority_fee;
        if cap != NO_PRIORITY_FEE_CAP && request.priority_fee > U256::from(cap) {
            return Err(E::TakerPriorityFeeTooHigh(
                IVenue::TakerPriorityFeeTooHigh {
                    priorityFee: request.priority_fee,
                    cap,
                },
            ));
        }

        let (balance, extra) = if base_in {
            (self.inventory.quote, self.hook_liquidity.quote)
        } else {
            (self.inventory.base, self.hook_liquidity.base)
        };
        let required = U256::from(amount_out);
        if balance < required {
            let extra = if market.hook_flags & BEFORE_FILL != 0 {
                extra
            } else {
                U256::ZERO
            };
            let available = balance.saturating_add(extra);
            if available < required {
                return Err(E::InsufficientInventory(IVenue::InsufficientInventory {
                    token: request.token_out,
                    available,
                    required,
                }));
            }
        }
        let mut consumed_after = *consumed;
        if base_in {
            consumed_after.bids += base_filled;
        } else {
            consumed_after.asks += base_filled;
        }
        Ok(LocalQuote {
            amount_in,
            amount_out,
            base_in,
            base_filled,
            consumed_after,
        })
    }
}
