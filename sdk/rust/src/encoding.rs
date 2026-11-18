use std::{fmt, str::FromStr};

use alloy::primitives::{B256, U256};

use crate::{Error, Result};

const MAX_MID: u128 = (1u128 << 96) - 1;
const MAX_EXPIRY: u64 = (1u64 << 40) - 1;
const PRICE_SCALE: u128 = 1_000_000_000_000_000_000;

/// Quote tokens per base token, in 18 decimal places. Never uses floating point.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Price(u128);

impl Price {
    pub fn from_scaled(value: u128) -> Result<Self> {
        if value == 0 || value > MAX_MID {
            return Err(Error::Invalid("price: must be a nonzero uint96"));
        }
        Ok(Self(value))
    }

    pub const fn scaled(self) -> u128 {
        self.0
    }
}

impl FromStr for Price {
    type Err = Error;

    fn from_str(value: &str) -> Result<Self> {
        let (whole, fraction) = value.split_once('.').unwrap_or((value, ""));
        if whole.is_empty()
            || !whole.bytes().all(|b| b.is_ascii_digit())
            || !fraction.bytes().all(|b| b.is_ascii_digit())
            || fraction.len() > 18
            || (value.contains('.') && fraction.is_empty())
        {
            return Err(Error::Invalid(
                "price: use an unsigned decimal with at most 18 places",
            ));
        }
        let whole = whole.parse::<u128>().map_err(|_| Error::Invalid("price"))?;
        let fraction_value = if fraction.is_empty() {
            0
        } else {
            fraction
                .parse::<u128>()
                .map_err(|_| Error::Invalid("price"))?
                * 10u128.pow(18 - fraction.len() as u32)
        };
        let scaled = whole
            .checked_mul(PRICE_SCALE)
            .and_then(|w| w.checked_add(fraction_value))
            .ok_or(Error::Invalid("price overflow"))?;
        Self::from_scaled(scaled)
    }
}

impl fmt::Display for Price {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let fraction = format!("{:018}", self.0 % PRICE_SCALE);
        let fraction = fraction.trim_end_matches('0');
        write!(f, "{}", self.0 / PRICE_SCALE)?;
        if !fraction.is_empty() {
            write!(f, ".{fraction}")?;
        }
        Ok(())
    }
}

/// Enabled maker sides. A taker selling base walks bids; buying base walks asks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sides {
    Both,
    Bids,
    Asks,
    Neither,
}

impl Sides {
    fn flags(self) -> u16 {
        match self {
            Self::Both => 0,
            Self::Bids => 2,
            Self::Asks => 1,
            Self::Neither => 3,
        }
    }

    fn refill_flags(self) -> u16 {
        match self {
            Self::Both => 12,
            Self::Bids => 4,
            Self::Asks => 8,
            Self::Neither => 0,
        }
    }
}

/// The complete replacement for one pair's hot word. Scales are per mille
/// (1000 = 1x); widenings are tenths of a basis point (10 = 1 bp).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OrderRequest {
    pub pair_index: u16,
    pub mid: Price,
    pub bid_widen: u16,
    pub ask_widen: u16,
    pub width_scale: u16,
    pub depth_scale: u16,
    pub shape_id: u8,
    /// Inclusive Unix seconds; no implicit clock or default expiry.
    pub valid_until: u64,
    /// Must exceed the onchain sequence. A newly added pair starts at 1.
    pub sequence: u32,
    pub sides: Sides,
    /// Sides whose consumed depth this post resets, offering their whole ladder again.
    /// Fills take depth off the ladder until the maker refills it; a post without a
    /// refill keeps the consumption, which then comes off the top of the new ladder.
    /// The venue applies a refill once and stores the word without it.
    pub refill: Sides,
}

impl OrderRequest {
    pub fn new(pair_index: u16, mid: Price, shape_id: u8, sequence: u32, valid_until: u64) -> Self {
        Self {
            pair_index,
            mid,
            shape_id,
            sequence,
            valid_until,
            bid_widen: 0,
            ask_widen: 0,
            width_scale: 1000,
            depth_scale: 1000,
            sides: Sides::Both,
            refill: Sides::Neither,
        }
    }

    pub fn encode(&self) -> Result<B256> {
        if self.valid_until > MAX_EXPIRY {
            return Err(Error::Invalid("expiry: exceeds uint40"));
        }
        if self.sequence <= 1 {
            return Err(Error::Invalid(
                "sequence: must exceed the initial sequence of 1",
            ));
        }
        let word: U256 = U256::from(self.mid.scaled())
            | (U256::from(self.bid_widen) << 96)
            | (U256::from(self.ask_widen) << 112)
            | (U256::from(self.width_scale) << 128)
            | (U256::from(self.depth_scale) << 144)
            | (U256::from(self.shape_id) << 160)
            | (U256::from(self.valid_until) << 168)
            | (U256::from(self.sequence) << 208)
            | (U256::from(self.sides.flags() | self.refill.refill_flags()) << 240);
        Ok(B256::from(word.to_be_bytes::<32>()))
    }
}

/// Decoded storage, including the initial unposted word (`mid = 0`, `sequence = 1`).
/// Stored and `Posted` words never carry refill bits; decoding rejects them as reserved.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HotWord {
    pub mid: u128,
    pub bid_widen: u16,
    pub ask_widen: u16,
    pub width_scale: u16,
    pub depth_scale: u16,
    pub shape_id: u8,
    pub valid_until: u64,
    pub sequence: u32,
    pub sides: Sides,
}

impl HotWord {
    pub fn decode(word: B256) -> Result<Self> {
        let bytes = word.as_slice();
        let flags = u16::from_be_bytes(bytes[0..2].try_into().unwrap());
        let sides = match flags {
            0 => Sides::Both,
            1 => Sides::Asks,
            2 => Sides::Bids,
            3 => Sides::Neither,
            _ => return Err(Error::Invalid("hot word: reserved flag bits")),
        };
        let mut mid = [0u8; 16];
        mid[4..].copy_from_slice(&bytes[20..]);
        let mut expiry = [0u8; 8];
        expiry[3..].copy_from_slice(&bytes[6..11]);
        Ok(Self {
            mid: u128::from_be_bytes(mid),
            bid_widen: u16::from_be_bytes(bytes[18..20].try_into().unwrap()),
            ask_widen: u16::from_be_bytes(bytes[16..18].try_into().unwrap()),
            width_scale: u16::from_be_bytes(bytes[14..16].try_into().unwrap()),
            depth_scale: u16::from_be_bytes(bytes[12..14].try_into().unwrap()),
            shape_id: bytes[11],
            valid_until: u64::from_be_bytes(expiry),
            sequence: u32::from_be_bytes(bytes[2..6].try_into().unwrap()),
            sides,
        })
    }

    pub fn next_sequence(&self, pair_index: u16) -> Result<u32> {
        self.sequence
            .checked_add(1)
            .ok_or(Error::SequenceExhausted(pair_index))
    }
}

/// One level: size in the pair's `sizeUnit`, spread in tenths of a basis point.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Level {
    pub size: u32,
    pub spread: u16,
}

impl Level {
    pub const fn new(size: u32, spread: u16) -> Self {
        Self { size, spread }
    }
}

/// Canonical bid and ask ladders, at most ten nonempty levels per side.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Shape {
    words: [U256; 4],
}

impl Shape {
    pub fn new(bids: &[Level], asks: &[Level]) -> Result<Self> {
        let mut words = [U256::ZERO; 4];
        for (side, levels) in [bids, asks].into_iter().enumerate() {
            if levels.len() > 10 {
                return Err(Error::Invalid("shape: at most ten levels per side"));
            }
            let mut last = 0;
            for (i, level) in levels.iter().enumerate() {
                if level.size == 0 || level.spread < last {
                    return Err(Error::Invalid(
                        "shape: nonzero sizes and nondecreasing spreads required",
                    ));
                }
                last = level.spread;
                let packed = U256::from(level.size) | (U256::from(level.spread) << 32);
                words[side * 2 + i / 5] |= packed << (48 * (i % 5));
            }
        }
        Ok(Self { words })
    }

    /// Empty ladders delete the shape. Deleting an active shape disables its depth.
    pub const fn empty() -> Self {
        Self {
            words: [U256::ZERO; 4],
        }
    }
    pub const fn words(&self) -> [U256; 4] {
        self.words
    }

    pub fn from_words(words: [U256; 4]) -> Result<Self> {
        for side in 0..2 {
            let mut ended = false;
            let mut last = 0;
            for word in &words[side * 2..side * 2 + 2] {
                let bytes = word.to_le_bytes::<32>();
                if bytes[30..] != [0, 0] {
                    return Err(Error::Invalid("shape: reserved bits"));
                }
                for level in bytes[..30].chunks_exact(6) {
                    let size = u32::from_le_bytes(level[..4].try_into().unwrap());
                    let spread = u16::from_le_bytes(level[4..].try_into().unwrap());
                    if (ended || size == 0) && (size != 0 || spread != 0) {
                        return Err(Error::Invalid("shape: noncanonical trailing level"));
                    }
                    if size == 0 {
                        ended = true;
                    } else if spread < last {
                        return Err(Error::Invalid("shape: decreasing spread"));
                    } else {
                        last = spread;
                    }
                }
            }
        }
        Ok(Self { words })
    }
}
