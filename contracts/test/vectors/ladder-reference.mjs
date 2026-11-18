// SPDX-License-Identifier: MIT
//
// Reference model of propAMM v2 ladder pricing (spec section 1 and the `LadderMath` NatSpec), written independently
// of the Solidity level walk. It expands one side of a shape into a book of (depth, unit price) levels, drops the
// first `consumed` base units (the depth the side's earlier fills took since the maker last refilled it), and defines
// the exact value function
//
//     V(b) = value of the first b base units of the book left, in quote units scaled by 1e26,
//
// then answers each of the four taker directions from V alone:
//
// | Taker                  | Target | Answer                                                                    |
// |------------------------|--------|---------------------------------------------------------------------------|
// | sells base, exact in   | base   | quoteOut = floor(V(amount) / 1e26)                                        |
// | buys base, exact out   | base   | quoteIn  = ceil(V(amount) / 1e26)                                         |
// | pays quote, exact in   | quote  | baseOut  = the largest b with V(b) <= amount * 1e26 (binary search)       |
// | wants quote, exact out | quote  | baseIn   = the smallest b with V(b) >= amount * 1e26 (binary search)      |
//
// Paying quote exact-in keeps the dust `amount * 1e26 - V(baseOut)` with the maker, and needs more depth than the
// book has when that dust could still buy one more base unit at the price of the book's last unit.
// A fill's `baseFilled` is what the venue adds to the side's `consumed`, so the next fill starts there; the `splits`
// section chains fills that way and records the one fill of their total that they never beat.
// Everything is BigInt; there is no floating point anywhere.
//
// The same file holds what the SDKs encode, so the Solidity libraries, the Rust SDK and the TypeScript SDK are held to
// one source: `hotWords` (HotWord fields and words), `prices` (exact decimal mids), `shapes` and `shapeRejects`
// (ladders and their canonical words), `posts` (order and cancel batches, packed and as `post(bytes)` calldata),
// `quotes` (one pair's posts, quotes and fills in order, with `Venue.quote`'s checks, consumption and inventory) and
// `outcomes` (one transaction's post calls, the `Posted` events the venue emits for them and which entries it stored).
// `fuzz.mjs` writes seeded random files in the same format. The `fields` entry of the JSON documents every field.
//
// Usage:
//   node contracts/test/vectors/ladder-reference.mjs           regenerate contracts/test/vectors/propamm-v2-ladder.json
//   node contracts/test/vectors/ladder-reference.mjs --check   exit 1 if the committed vectors differ from a fresh generation

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// ---------------------------------------------------------------------------------------------------------------------
// Units (spec section 1)
// ---------------------------------------------------------------------------------------------------------------------

/** `mid` is quote per 1 base with 18 decimals. */
export const PRICE_ONE = 10n ** 18n;
/** Spreads and widens are in 0.1 bp, so 100% is 1e5 of them. */
export const SPREAD_ONE = 100_000n;
/** `widthScale` and `depthScale` are in 1/1000. */
export const SCALE_ONE = 1_000n;
/** A level's price factor is held over this: 100% of spread times the width denominator. */
export const FACTOR_ONE = SPREAD_ONE * SCALE_ONE;
/** V(b) numerators are quote units times this. */
export const VALUE_ONE = PRICE_ONE * FACTOR_ONE;

export const UINT128_MAX = (1n << 128n) - 1n;

// ---------------------------------------------------------------------------------------------------------------------
// Encodings (HotWord and ShapeWord NatSpec)
// ---------------------------------------------------------------------------------------------------------------------

/** Hot-word fields, least-significant first. */
const HOT_LAYOUT = [
  ['mid', 96],
  ['bidWiden', 16],
  ['askWiden', 16],
  ['widthScale', 16],
  ['depthScale', 16],
  ['shapeId', 8],
  ['validUntil', 40],
  ['seq', 32],
  ['flags', 16],
];

export function packHot(fields) {
  let word = 0n;
  let at = 0n;
  for (const [name, bits] of HOT_LAYOUT) {
    const v = BigInt(fields[name] ?? 0);
    if (v < 0n || v >> BigInt(bits) !== 0n) throw new Error(`hot field ${name} out of range: ${v}`);
    word += v * 2n ** at;
    at += BigInt(bits);
  }
  return word;
}

export function unpackHot(word) {
  const out = {};
  let rest = BigInt(word);
  for (const [name, bits] of HOT_LAYOUT) {
    const m = 2n ** BigInt(bits);
    out[name] = rest % m;
    rest /= m;
  }
  return out;
}

const SIZE_BITS = 32n;
const SPREAD_BITS = 16n;
const SLOT_BITS = SIZE_BITS + SPREAD_BITS;
const LEVELS_PER_WORD = 5;
const MAX_LEVELS = 10;

/** Encodes one side, given as `[size, spread]` pairs (at most 10), into its two words. */
export function encodeSide(levels) {
  if (levels.length > MAX_LEVELS) throw new Error('too many levels');
  const words = [0n, 0n];
  levels.forEach(([size, spread], i) => {
    const s = BigInt(size);
    const sp = BigInt(spread);
    if (s <= 0n || s >= 2n ** SIZE_BITS || sp < 0n || sp >= 2n ** SPREAD_BITS) throw new Error('bad level');
    const slot = s + sp * 2n ** SIZE_BITS;
    words[Math.floor(i / LEVELS_PER_WORD)] += slot * 2n ** (SLOT_BITS * BigInt(i % LEVELS_PER_WORD));
  });
  return words;
}

/** All ten raw slots of a side, canonical or not. */
function rawSlots(w0, w1) {
  const slots = [];
  for (const word of [w0, w1]) {
    for (let j = 0n; j < BigInt(LEVELS_PER_WORD); j++) {
      const slot = (word / 2n ** (SLOT_BITS * j)) % 2n ** SLOT_BITS;
      slots.push([slot % 2n ** SIZE_BITS, slot / 2n ** SIZE_BITS]);
    }
  }
  return slots;
}

/** The levels a side holds: every slot before the first empty one. */
export function decodeSide(w0, w1) {
  const levels = [];
  for (const [size, spread] of rawSlots(w0, w1)) {
    if (size === 0n) break;
    levels.push([size, spread]);
  }
  return levels;
}

export const REASON_RESERVED_BITS = 1;
export const REASON_NON_CANONICAL = 2;
export const REASON_SPREAD_DECREASES = 3;

/** `ShapeWord.checkSide`: 0 when canonical, else the reason for the first rule broken. */
export function sideReason(w0, w1) {
  const reserved = 2n ** (SLOT_BITS * BigInt(LEVELS_PER_WORD));
  if (w0 / reserved !== 0n || w1 / reserved !== 0n) return REASON_RESERVED_BITS;
  const levels = decodeSide(w0, w1);
  for (let i = 1; i < levels.length; i++) if (levels[i][1] < levels[i - 1][1]) return REASON_SPREAD_DECREASES;
  const [e0, e1] = encodeSide(levels);
  return e0 === w0 && e1 === w1 ? 0 : REASON_NON_CANONICAL;
}

/** `ShapeWord.check` over [bid w0, bid w1, ask w0, ask w1]. */
export function shapeReason(words) {
  return sideReason(words[0], words[1]) || sideReason(words[2], words[3]);
}

// ---------------------------------------------------------------------------------------------------------------------
// Pricing
// ---------------------------------------------------------------------------------------------------------------------

/**
 * Expands the side a taker walks into its book: `depth` in base units and `price`, the value of one base unit
 * (quote units x 1e26). `baseIn` means the taker sells base and walks the bids. A bid level whose factor is at or
 * below zero, and every level after it, is dropped (the bid floor). Levels with no effective size are dropped too.
 */
export function book(hot, sizeUnit, baseIn, levels) {
  const widen = baseIn ? hot.bidWiden : hot.askWiden;
  const out = [];
  for (const [size, spread] of levels) {
    // spread x widthScale/1000 + widen, in 0.1 bp, is `offset / SCALE_ONE`.
    const offset = BigInt(spread) * BigInt(hot.widthScale) + BigInt(widen) * SCALE_ONE;
    const factor = baseIn ? FACTOR_ONE - offset : FACTOR_ONE + offset;
    if (factor <= 0n) break;
    const depth = (BigInt(size) * BigInt(hot.depthScale) * BigInt(sizeUnit)) / SCALE_ONE;
    if (depth > 0n) out.push({ depth, price: BigInt(hot.mid) * factor });
  }
  return out;
}



/** The book left after `consumed` base units were already taken from its top. */
export function remainingBook(levels, consumed) {
  let skip = BigInt(consumed);
  const out = [];
  for (const { depth, price } of levels) {
    const drop = skip < depth ? skip : depth;
    skip -= drop;
    if (depth > drop) out.push({ depth: depth - drop, price });
  }
  return out;
}

export const totalDepth = (levels) => levels.reduce((s, l) => s + l.depth, 0n);

/** V(b). Throws past the book's depth. */
export function value(levels, base) {
  let left = BigInt(base);
  let v = 0n;
  for (const { depth, price } of levels) {
    const t = left < depth ? left : depth;
    v += t * price;
    left -= t;
  }
  if (left !== 0n) throw new Error('value past depth');
  return v;
}

/** The largest b in [0, depth] with V(b) <= budget. */
function maxBaseWithin(levels, budget) {
  let lo = 0n;
  let hi = totalDepth(levels);
  while (lo < hi) {
    const m = (lo + hi + 1n) / 2n;
    if (value(levels, m) <= budget) lo = m;
    else hi = m - 1n;
  }
  return lo;
}

/** The smallest b in [0, depth] with V(b) >= budget; the caller checks V(depth) >= budget first. */
function minBaseCovering(levels, budget) {
  let lo = 0n;
  let hi = totalDepth(levels);
  while (lo < hi) {
    const m = (lo + hi) / 2n;
    if (value(levels, m) >= budget) hi = m;
    else lo = m + 1n;
  }
  return lo;
}

const ceilDiv = (a, b) => (a + b - 1n) / b;

export const DIRECTIONS = {
  sellBaseExactIn: { baseIn: true, exactIn: true },
  buyBaseExactOut: { baseIn: false, exactIn: false },
  payQuoteExactIn: { baseIn: false, exactIn: true },
  wantQuoteExactOut: { baseIn: true, exactIn: false },
};

export function directionOf(baseIn, exactIn) {
  return Object.keys(DIRECTIONS).find((k) => DIRECTIONS[k].baseIn === baseIn && DIRECTIONS[k].exactIn === exactIn);
}

/**
 * Prices one fill after `consumed` base units of the side are gone. Returns `{ amountIn, amountOut, baseFilled }` or
 * `{ error }` with `InsufficientDepth` (the book left can't cover the fill) or `ZeroFill` (either side of the result
 * is 0). `amount` must be at least 1.
 */
export function priceLeg({ hot, sizeUnit, baseIn, exactIn, levels, amount, consumed = 0n }) {
  amount = BigInt(amount);
  if (amount <= 0n) throw new Error('amount must be positive');
  const b = remainingBook(book(hot, sizeUnit, baseIn, levels), consumed);
  const depth = totalDepth(b);
  let r;
  switch (directionOf(baseIn, exactIn)) {
    case 'sellBaseExactIn':
      if (amount > depth) return { error: 'InsufficientDepth' };
      r = { amountIn: amount, amountOut: value(b, amount) / VALUE_ONE, baseFilled: amount };
      break;
    case 'buyBaseExactOut':
      if (amount > depth) return { error: 'InsufficientDepth' };
      r = { amountIn: ceilDiv(value(b, amount), VALUE_ONE), amountOut: amount, baseFilled: amount };
      break;
    case 'payQuoteExactIn': {
      const budget = amount * VALUE_ONE;
      const base = maxBaseWithin(b, budget);
      if (base === depth) {
        const last = b[b.length - 1];
        if (last === undefined || budget - value(b, depth) >= last.price) return { error: 'InsufficientDepth' };
      }
      r = { amountIn: amount, amountOut: base, baseFilled: base };
      break;
    }
    case 'wantQuoteExactOut': {
      const budget = amount * VALUE_ONE;
      if (value(b, depth) < budget) return { error: 'InsufficientDepth' };
      const base = minBaseCovering(b, budget);
      r = { amountIn: base, amountOut: amount, baseFilled: base };
      break;
    }
  }
  if (r.amountIn === 0n || r.amountOut === 0n) return { error: 'ZeroFill' };
  return r;
}

// ---------------------------------------------------------------------------------------------------------------------
// Vector generation
// ---------------------------------------------------------------------------------------------------------------------

/** splitmix64, so the vector set is reproducible. */
export function rng(seed) {
  let s = BigInt(seed) & 0xffffffffffffffffn;
  const next = () => {
    s = (s + 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn;
    let z = s;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & 0xffffffffffffffffn;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & 0xffffffffffffffffn;
    return z ^ (z >> 31n);
  };
  /** Uniform-ish in [lo, hi]. */
  const between = (lo, hi) => {
    lo = BigInt(lo);
    hi = BigInt(hi);
    if (hi <= lo) return lo;
    const span = hi - lo + 1n;
    let r = 0n;
    for (let bits = 0n; bits < 192n; bits += 64n) r = (r << 64n) | next();
    return lo + (r % span);
  };
  const pick = (arr) => arr[Number(between(0, arr.length - 1))];
  return { between, pick };
}

export const hex32 = (v) => '0x' + BigInt(v).toString(16).padStart(64, '0');
export const hex = (v) => '0x' + BigInt(v).toString(16);
const cmp = (x, y) => (x < y ? -1 : x > y ? 1 : 0);

export const BASE_HOT = {
  mid: 1_085_000_000_000_000_000n,
  bidWiden: 0n,
  askWiden: 0n,
  widthScale: 1000n,
  depthScale: 1000n,
  shapeId: 0n,
  validUntil: 1_790_261_830n,
  seq: 2n,
  flags: 0n,
};

export const EUR = 1_000_000n;

/** Ladders, as `[size, spread]` per level. The same ladder is used for whichever side a vector walks. */
export const SHAPES = {
  companion: [[50_000, 20]],
  flat: [[200_000, 30]],
  unit: [[1, 0]],
  sloped: [[100_000, 20], [100_000, 40], [100_000, 60], [100_000, 80], [100_000, 100]],
  deepThenThin: [[800_000, 5], [700_000, 8], [100_000, 60], [100_000, 120], [100_000, 200]],
  sixLevels: [[10, 10], [10, 20], [10, 30], [10, 40], [10, 50], [10, 60]],
  equalSpreads: [[7, 15], [11, 15], [13, 15]],
  fine: [5, 6, 7, 8, 9, 10, 11, 12, 13, 14].map((t) => [20_000, t]),
  labNormal: [
    [50_000, 5],
    [100_000, 10],
    [150_000, 15],
    [250_000, 25],
    [400_000, 40],
    [500_000, 60],
    [750_000, 90],
    [1_000_000, 130],
    [1_500_000, 200],
    [2_000_000, 300],
  ],
  zeroSpreadTop: [[3, 0], [5, 0], [2, 1]],
  maxLevels: Array.from({ length: 10 }, () => [0xffffffff, 0xffff]),
};

export function makeVector(name, { hot, sizeUnit, direction, levels, amount, consumed = 0n }) {
  const { baseIn, exactIn } = DIRECTIONS[direction];
  const [w0, w1] = encodeSide(levels);
  if (BigInt(consumed) < 0n || BigInt(consumed) >= 1n << 120n) throw new Error('consumed out of the venue slot');
  const r = priceLeg({ hot, sizeUnit, baseIn, exactIn, levels, amount, consumed });
  return {
    name,
    direction,
    baseIn,
    exactIn,
    hot: hex32(packHot(hot)),
    mid: BigInt(hot.mid).toString(),
    widen: BigInt(baseIn ? hot.bidWiden : hot.askWiden).toString(),
    widthScale: BigInt(hot.widthScale).toString(),
    depthScale: BigInt(hot.depthScale).toString(),
    sizeUnit: BigInt(sizeUnit).toString(),
    w0: hex(w0),
    w1: hex(w1),
    amount: BigInt(amount).toString(),
    consumed: BigInt(consumed).toString(),
    expect: r.error ?? 'ok',
    amountIn: (r.amountIn ?? 0n).toString(),
    amountOut: (r.amountOut ?? 0n).toString(),
    baseFilled: (r.baseFilled ?? 0n).toString(),
  };
}

/** Amounts that sit on, just inside and just past every level edge of the book a fill would walk after `consumed`. */
export function edgeAmounts(hot, sizeUnit, direction, levels, consumed = 0n) {
  const { baseIn, exactIn } = DIRECTIONS[direction];
  const b = remainingBook(book(hot, sizeUnit, baseIn, levels), consumed);
  const out = new Set([1n]);
  let cum = 0n;
  const edges = [];
  for (const l of b) {
    cum += l.depth;
    edges.push(cum);
  }
  const quoteTarget = baseIn !== exactIn;
  edges.forEach((e, i) => {
    const last = i === edges.length - 1;
    if (!quoteTarget) {
      for (const d of [-1n, 0n, 1n]) out.add(e + d);
    } else {
      // Just short of, exactly on, and just past the quote value of the edge; on the last edge also one below.
      const v = value(b, e);
      for (const q of [v / VALUE_ONE, ceilDiv(v, VALUE_ONE), ceilDiv(v, VALUE_ONE) + 1n]) out.add(q);
      if (last) out.add(v / VALUE_ONE - 1n);
      // The edge's value plus exactly one unit at this level's price or the next one's, when that is a whole number
      // of quote units. Here the remainder after the edge ties the unit price: paying quote buys that unit when the
      // next level has the same price, and needs more depth than the book has when the edge is the last one.
      for (const next of [b[i], b[i + 1]]) {
        if (next !== undefined && (v + next.price) % VALUE_ONE === 0n) out.add((v + next.price) / VALUE_ONE);
      }
    }
  });
  if (b.length) {
    // A point inside the first and last levels.
    const firstMid = b[0].depth / 2n + 1n;
    const lastMid = cum - b[b.length - 1].depth / 3n;
    for (const base of [firstMid, lastMid]) out.add(quoteTarget ? value(b, base) / VALUE_ONE : base);
  }
  return [...out].filter((a) => a >= 1n && a <= UINT128_MAX).sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
}

export function generate() {
  const vectors = [];
  const splits = [];
  const add = (name, args) => vectors.push(makeVector(name, args));
  const dirs = Object.keys(DIRECTIONS);

  // The companion page: mid 1.0850, ask level 1 is 50k at 2 bp, so 1 EUR costs 1.085217 USD.
  add('companion: buy 1 EUR exact out at 1.085217', {
    hot: BASE_HOT,
    sizeUnit: EUR,
    direction: 'buyBaseExactOut',
    levels: SHAPES.companion,
    amount: EUR,
  });
  add('companion: pay 1.085217 USD exact in for 1 EUR', {
    hot: BASE_HOT,
    sizeUnit: EUR,
    direction: 'payQuoteExactIn',
    levels: SHAPES.companion,
    amount: 1_085_217n,
  });
  add('companion: sell 1 EUR exact in at 1.084783', {
    hot: BASE_HOT,
    sizeUnit: EUR,
    direction: 'sellBaseExactIn',
    levels: SHAPES.companion,
    amount: EUR,
  });
  add('companion: want 1.084783 USD exact out for 1 EUR', {
    hot: BASE_HOT,
    sizeUnit: EUR,
    direction: 'wantQuoteExactOut',
    levels: SHAPES.companion,
    amount: 1_084_783n,
  });

  // Level edges for every shape and direction at the base scalars.
  const edgeShapes = ['companion', 'flat', 'unit', 'sloped', 'deepThenThin', 'sixLevels', 'equalSpreads', 'fine'];
  for (const shape of edgeShapes) {
    const sizeUnit = shape === 'unit' || shape === 'sixLevels' || shape === 'equalSpreads' ? 1n : EUR;
    for (const direction of dirs) {
      for (const amount of edgeAmounts(BASE_HOT, sizeUnit, direction, SHAPES[shape], 0n)) {
        add(`edge ${shape} ${direction} ${amount}`, {
          hot: BASE_HOT,
          sizeUnit,
          direction,
          levels: SHAPES[shape],
          amount,
        });
      }
    }
  }

  // An irregular mid, so no level price is a whole number of quote units, walking across both words.
  const oddMid = { ...BASE_HOT, mid: 1_164_213_579_246_801_357n };
  for (const direction of dirs) {
    for (const amount of edgeAmounts(oddMid, 999_999n, direction, SHAPES.labNormal, 0n)) {
      add(`odd mid labNormal ${direction} ${amount}`, {
        hot: oddMid,
        sizeUnit: 999_999n,
        direction,
        levels: SHAPES.labNormal,
        amount,
      });
    }
  }

  // Scalars: widen, widthScale and depthScale, each on its own and together.
  const scalarHots = {
    widen: { ...BASE_HOT, bidWiden: 7n, askWiden: 13n },
    width0: { ...BASE_HOT, widthScale: 0n },
    width333: { ...BASE_HOT, widthScale: 333n },
    width2500: { ...BASE_HOT, widthScale: 2500n },
    depth1: { ...BASE_HOT, depthScale: 1n },
    depth333: { ...BASE_HOT, depthScale: 333n },
    depth1500: { ...BASE_HOT, depthScale: 1500n },
    depthMax: { ...BASE_HOT, depthScale: 65_535n },
    all: { ...oddMid, bidWiden: 25n, askWiden: 3n, widthScale: 1750n, depthScale: 667n },
  };
  for (const [label, hot] of Object.entries(scalarHots)) {
    for (const direction of dirs) {
      const amounts = edgeAmounts(hot, 12_345n, direction, SHAPES.sixLevels, 0n);
      // Keep the first edge, a word-crossing edge and the last three (the depth boundary).
      const chosen = [...new Set([amounts[0], amounts[Math.floor(amounts.length / 2)], ...amounts.slice(-3)])];
      for (const amount of chosen) {
        add(`scalar ${label} sixLevels ${direction} ${amount}`, {
          hot,
          sizeUnit: 12_345n,
          direction,
          levels: SHAPES.sixLevels,
          amount,
        });
      }
    }
  }

  // Consumed offsets: inside a level, on a level edge, across the word boundary, at and past the depth.
  {
    const hot = { ...oddMid, askWiden: 2n, bidWiden: 4n };
    const sizeUnit = 1_000n;
    for (const direction of dirs) {
      const { baseIn } = DIRECTIONS[direction];
      const full = book(hot, sizeUnit, baseIn, SHAPES.sixLevels);
      const edges = [];
      let cum = 0n;
      for (const l of full) edges.push((cum += l.depth));
      const offsets = [1n, edges[0] - 1n, edges[0], edges[0] + 1n, edges[4] - 1n, edges[4], edges[4] + 7n, cum - 1n];
      for (const consumed of offsets) {
        const amounts = edgeAmounts(hot, sizeUnit, direction, SHAPES.sixLevels, consumed);
        const chosen = [...new Set([amounts[0], amounts[1], ...amounts.slice(-3)])].filter(Boolean);
        for (const amount of chosen) {
          add(`consumed ${consumed} sixLevels ${direction} ${amount}`, {
            hot,
            sizeUnit,
            direction,
            levels: SHAPES.sixLevels,
            amount,
            consumed,
          });
        }
      }
      // An exhausted side: consumed to its depth, or past it (a shallower ladder posted under a deeper offset).
      for (const consumed of [cum, cum + 1n, cum * 3n]) {
        add(`consumed ${consumed} past depth ${direction}`, {
          hot,
          sizeUnit,
          direction,
          levels: SHAPES.sixLevels,
          amount: 1n,
          consumed,
        });
      }
    }
    // The bid floor still ends the side after an offset, and an offset into the floored levels finds nothing.
    const floored = { ...BASE_HOT, widthScale: 1667n };
    const floorLevels = [[1_000, 0], [1_000, 30_000], [1_000, 60_000]];
    for (const consumed of [500n * EUR, 1_000n * EUR, 1_500n * EUR, 2_000n * EUR]) {
      for (const amount of [1n, 500n * EUR, 500n * EUR + 1n]) {
        add(`consumed ${consumed} floor sellBaseExactIn ${amount}`, {
          hot: floored,
          sizeUnit: EUR,
          direction: 'sellBaseExactIn',
          levels: floorLevels,
          amount,
          consumed,
        });
      }
    }
  }

  // Split orders: one order sent as parts chained through `consumed`, each starting where the last stopped, and
  // the one fill of their total from the same offset. Equal parts, unit-sized dust, and uneven parts; every
  // direction, from a fresh side and from a consumed one.
  {
    const r = rng(0x73706c6974n);
    const cases = [
      ['sloped', BASE_HOT, EUR, SHAPES.sloped],
      ['odd mid labNormal', oddMid, 999_999n, SHAPES.labNormal],
      ['round par equal steps', { ...BASE_HOT, mid: PRICE_ONE }, 1n, [[3, 0], [5, 0], [2, 0], [4, 0], [6, 0], [1, 0]]],
      ['dear', { ...BASE_HOT, mid: 4_999_999_999_999_999_999_999_999n }, 3n, [[2, 0], [3, 50]]],
    ];
    for (const [label, hot, sizeUnit, levels] of cases) {
      for (const direction of dirs) {
        const { baseIn, exactIn } = DIRECTIONS[direction];
        const full = book(hot, sizeUnit, baseIn, levels);
        const depth = totalDepth(full);
        for (const start of [0n, depth / 3n]) {
          const rest = remainingBook(full, start);
          const restDepth = totalDepth(rest);
          if (restDepth < 4n) continue;
          // A total the side left covers whole: most of its base, or most of that base's quote value.
          const base = (restDepth * 9n) / 10n;
          const total = baseIn === exactIn ? base : value(rest, base) / VALUE_ONE;
          if (total < 4n) continue;
          const plans = {
            equal: Array.from({ length: 4 }, (_, i) => (i < 3 ? total / 4n : total - 3n * (total / 4n))),
            dust: [1n, 1n, 2n, 1n, 3n, total - 8n].filter((a) => a > 0n),
            uneven: (() => {
              const out = [];
              let left = total;
              for (let i = 0; i < 4 && left > 1n; i++) {
                const a = r.between(1n, left - 1n);
                out.push(a);
                left -= a;
              }
              out.push(left);
              return out;
            })(),
          };
          for (const [plan, amounts] of Object.entries(plans)) {
            if (amounts.reduce((s, a) => s + a, 0n) !== total || amounts.some((a) => a <= 0n)) continue;
            const name = `split ${label} ${direction} from ${start} ${plan}`;
            const parts = [];
            let consumed = start;
            let traded = 0n;
            amounts.forEach((amount, k) => {
              parts.push(vectors.length);
              add(`${name} part ${k + 1}/${amounts.length} ${amount}`, {
                hot,
                sizeUnit,
                direction,
                levels,
                amount,
                consumed,
              });
              const v = vectors[vectors.length - 1];
              // A part that reverts (dust that rounds to nothing) trades nothing and leaves the offset where it was.
              if (v.expect === 'ok') {
                consumed += BigInt(v.baseFilled);
                traded += amount;
              }
            });
            if (traded === 0n) throw new Error(`${name}: no part filled`);
            // The one fill the parts never beat: what they traded, sent whole from the same offset.
            const whole = vectors.length;
            add(`${name} whole ${traded}`, { hot, sizeUnit, direction, levels, amount: traded, consumed: start });
            if (vectors[whole].expect !== 'ok') throw new Error(`${name}: the whole must fill`);
            splits.push({ name, whole, parts });
          }
        }
      }
    }
  }

  // Bid floor: level factors at, just above and past zero. The asks never floor.
  {
    const floorLevels = [[1_000, 0], [1_000, 30_000], [1_000, 60_000], [1_000, 65_535]];
    const floors = [
      // 60,000 x 1.667 = 100,020 > 100,000: levels 3 and 4 are past the floor.
      ['pastAtWidth', { ...BASE_HOT, widthScale: 1667n }, floorLevels],
      // 60,000 + 40,000 widen = exactly 100%: level 3 is at the floor.
      ['atFloor', { ...BASE_HOT, bidWiden: 40_000n, askWiden: 40_000n }, floorLevels],
      // 60,000 + 39,999: level 3's factor is 1e-5, a positive price far below mid; level 4 is past.
      ['justAbove', { ...BASE_HOT, bidWiden: 39_999n, askWiden: 39_999n }, floorLevels],
      // Max width: every level after the first is past the floor.
      ['maxWidth', { ...BASE_HOT, widthScale: 65_535n }, floorLevels],
      // widen alone never reaches 100%, so the top level still fills.
      ['maxWiden', { ...BASE_HOT, bidWiden: 65_535n, askWiden: 65_535n }, floorLevels],
      // 9,999 x 10,001 = 1e8 - 1: level 2's factor is exactly 1 (price mid x 1e-8) and it fills; level 3 is past.
      ['factorOne', { ...BASE_HOT, widthScale: 10_001n }, [[1_000, 0], [1_000, 9_999], [1_000, 65_535]]],
      // 10,000 x 10,000 = exactly 1e8: level 3's factor is 0, the floor; level 2's factor is 10,000.
      ['factorZero', { ...BASE_HOT, widthScale: 10_000n }, [[1_000, 0], [1_000, 9_999], [1_000, 10_000]]],
      // 64,999 x 1,001 + 34,936 x 1,000 = 1e8 - 1: factor 1 again, reached with widen and width together.
      [
        'factorOneWiden',
        { ...BASE_HOT, widthScale: 1_001n, bidWiden: 34_936n, askWiden: 34_936n },
        [[1_000, 0], [1_000, 64_999], [1_000, 65_000]],
      ],
    ];
    for (const [label, hot, levels] of floors) {
      for (const direction of ['sellBaseExactIn', 'wantQuoteExactOut']) {
        for (const amount of edgeAmounts(hot, EUR, direction, levels, 0n)) {
          add(`floor ${label} ${direction} ${amount}`, { hot, sizeUnit: EUR, direction, levels, amount });
        }
      }
      // The same ladder on the ask side keeps every level.
      const askDepth = totalDepth(book(hot, EUR, false, levels));
      for (const amount of [askDepth, askDepth + 1n]) {
        add(`floor ${label} asks keep every level ${amount}`, {
          hot,
          sizeUnit: EUR,
          direction: 'buyBaseExactOut',
          levels,
          amount,
        });
      }
    }
  }

  // Round unit prices. At par with no spread one base unit costs exactly one quote unit, so paying a level's value
  // plus one unit's price is a common amount, and the remainder after that level ties the unit price exactly. The
  // taker must get the unit when the next level has the same price; past the last level the fill needs more depth
  // than the ladder holds. Round mids (0.5, 1, 2), zero widen, and zero spread or zero widthScale make every price a
  // whole number of quote units, so edgeAmounts emits these ties at every edge.
  {
    const par = { ...BASE_HOT, mid: PRICE_ONE };
    const rounds = [
      // [label, hot, sizeUnit, levels]
      ['par pair', par, 1n, [[1, 0], [1, 0]]],
      ['par unit', par, 1n, [[1, 0]]],
      ['par flat', par, EUR, [[200_000, 0]]],
      ['par equal steps', par, 1n, [[3, 0], [5, 0], [2, 0], [4, 0], [6, 0], [1, 0]]],
      // Spread 10,000 is 10%: asks at 1.1 and bids at 0.9 per unit, tying on edges where the base count allows it.
      ['par then spread', par, 1n, [[2, 0], [2, 0], [9, 10_000], [10, 10_000]]],
      // Half a quote unit per base unit: ties need an odd base count, so every edge here is odd.
      [
        'half width0',
        { ...par, mid: PRICE_ONE / 2n, widthScale: 0n },
        1n,
        [[1, 5], [2, 5], [4, 9], [2, 20], [6, 20], [2, 40]],
      ],
      ['double width0', { ...par, mid: 2n * PRICE_ONE, widthScale: 0n }, EUR, SHAPES.sloped],
    ];
    for (const [label, hot, sizeUnit, levels] of rounds) {
      for (const direction of dirs) {
        for (const amount of edgeAmounts(hot, sizeUnit, direction, levels)) {
          add(`round ${label} ${direction} ${amount}`, { hot, sizeUnit, direction, levels, amount });
        }
      }
    }
  }

  // Dust: expensive and cheap base units, where paying quote leaves visible dust or buys nothing at all.
  {
    const dear = { ...BASE_HOT, mid: 4_999_999_999_999_999_999_999_999n }; // ~5e6 quote units per base unit
    const cheap = { ...BASE_HOT, mid: 1_234_567_890_123n }; // ~1.2e-6 quote units per base unit
    const halfUnit = { ...BASE_HOT, mid: 500_000_000_000_000_000n };
    const cases = [
      ['dear', dear, 3n, [[2, 0], [3, 50]], [1n, 4_999_999n, 5_000_000n, 12_345_678n, 25_001_000n, 99_999_999n]],
      ['cheap', cheap, 1n, [[5_000_000, 0], [5_000_000, 10]], [1n, 2n, 7n, 12n, 13n]],
      ['halfUnit', halfUnit, 1n, [[5, 0], [5, 100]], [1n, 2n, 3n, 4n, 5n]],
    ];
    for (const [label, hot, sizeUnit, levels, amounts] of cases) {
      for (const direction of dirs) {
        for (const amount of amounts) {
          add(`dust ${label} ${direction} ${amount}`, { hot, sizeUnit, direction, levels, amount });
        }
      }
    }
  }

  // Empty ladders: no levels, or depth rounding to zero.
  for (const direction of dirs) {
    add(`empty side ${direction}`, { hot: BASE_HOT, sizeUnit: EUR, direction, levels: [], amount: 1n });
    add(`depth rounds to zero ${direction}`, {
      hot: { ...BASE_HOT, depthScale: 1n },
      sizeUnit: 999n,
      direction,
      levels: [[1, 0]],
      amount: 1n,
    });
  }

  // Zero spreads at the top and equal spreads: the price is flat across levels.
  for (const direction of dirs) {
    for (const amount of edgeAmounts(BASE_HOT, 1n, direction, SHAPES.zeroSpreadTop, 0n)) {
      add(`zero spreads ${direction} ${amount}`, {
        hot: BASE_HOT,
        sizeUnit: 1n,
        direction,
        levels: SHAPES.zeroSpreadTop,
        amount,
      });
    }
  }

  // Max field values with uint128 amounts: nothing overflows, results may exceed uint128.
  {
    const maxHot = {
      ...BASE_HOT,
      mid: (1n << 96n) - 1n,
      bidWiden: 0n,
      askWiden: 65_535n,
      widthScale: 65_535n,
      depthScale: 65_535n,
    };
    const maxUnit = (1n << 64n) - 1n;
    for (const direction of dirs) {
      for (const amount of [1n, 12_345_678_901_234_567_890n, UINT128_MAX]) {
        add(`max fields ${direction} ${amount}`, {
          hot: maxHot,
          sizeUnit: maxUnit,
          direction,
          levels: SHAPES.maxLevels,
          amount,
        });
      }

    }
  }

  // Random canonical ladders, scalars and amounts.
  const r = rng(0x70726f70616d6dn);
  for (let n = 0; n < 160; n++) {
    const count = Number(r.between(1, 10));
    let spread = r.between(0, 200);
    const levels = [];
    for (let i = 0; i < count; i++) {
      spread += r.pick([0n, 0n, r.between(1, 50), r.between(1, 2_000)]);
      if (spread > 65_535n) spread = 65_535n;
      levels.push([r.pick([r.between(1, 100), r.between(1, 1_000_000), r.between(1, 0xffffffff)]), spread]);
    }
    const hot = {
      ...BASE_HOT,
      mid: r.pick([
        r.between(1n, 10n ** 18n),
        r.between(9n * 10n ** 17n, 2n * 10n ** 18n),
        r.between(1n, (1n << 96n) - 1n),
      ]),
      bidWiden: r.pick([0n, r.between(0, 100), r.between(0, 65_535)]),
      askWiden: r.pick([0n, r.between(0, 100), r.between(0, 65_535)]),
      widthScale: r.pick([1000n, r.between(0, 3_000), r.between(0, 65_535)]),
      depthScale: r.pick([1000n, r.between(1, 3_000), r.between(1, 65_535)]),
    };
    const sizeUnit = r.pick([1n, EUR, r.between(1, 10n ** 9n), r.between(1, (1n << 64n) - 1n)]);
    const direction = dirs[n % 4];
    const { baseIn, exactIn } = DIRECTIONS[direction];
    const full = book(hot, sizeUnit, baseIn, levels);
    const depth = totalDepth(full);
    const rest = full;
    const restDepth = totalDepth(rest);
    let amount;
    if (baseIn === exactIn) {
      amount = r.pick([r.between(1, restDepth), r.between(1, restDepth + 2n), 1n]);
    } else {
      const v = restDepth > 0n ? value(rest, restDepth) : 0n;
      amount = r.pick([r.between(1, v / VALUE_ONE + 1n), r.between(1, ceilDiv(v, VALUE_ONE) + 2n), 1n]);
    }
    if (amount > UINT128_MAX) amount = r.between(1, UINT128_MAX);
    if (amount < 1n) amount = 1n;
    add(`random ${n} ${direction}`, { hot, sizeUnit, direction, levels, amount });
  }

  // Random fills from a random consumed offset, sometimes at or past the side's depth.
  for (let n = 0; n < 80; n++) {
    const count = Number(r.between(1, 10));
    let spread = r.between(0, 200);
    const levels = [];
    for (let i = 0; i < count; i++) {
      spread += r.pick([0n, r.between(1, 50), r.between(1, 2_000)]);
      if (spread > 65_535n) spread = 65_535n;
      levels.push([r.pick([r.between(1, 1_000), r.between(1, 1_000_000)]), spread]);
    }
    const hot = { ...BASE_HOT, mid: r.between(9n * 10n ** 17n, 2n * 10n ** 18n), widthScale: r.between(0, 3_000) };
    const sizeUnit = r.pick([1n, EUR, r.between(1, 10n ** 9n)]);
    const direction = dirs[n % 4];
    const { baseIn, exactIn } = DIRECTIONS[direction];
    const depth = totalDepth(book(hot, sizeUnit, baseIn, levels));
    const consumed = r.pick([r.between(0, depth), r.between(0, depth + 2n), depth]);
    const rest = remainingBook(book(hot, sizeUnit, baseIn, levels), consumed);
    const restDepth = totalDepth(rest);
    let amount;
    if (baseIn === exactIn) {
      amount = r.pick([r.between(1, restDepth + 1n), 1n]);
    } else {
      const v = restDepth > 0n ? value(rest, restDepth) : 0n;
      amount = r.pick([r.between(1, v / VALUE_ONE + 1n), r.between(1, ceilDiv(v, VALUE_ONE) + 2n), 1n]);
    }
    if (amount < 1n) amount = 1n;
    add(`random consumed ${n} ${direction}`, { hot, sizeUnit, direction, levels, amount, consumed });
  }

  // Rounding inside a level: base counts that are no level edge, and the quote amounts on either side of their value,
  // on prices that are never a whole number of quote units, so each fill's one rounding toward the maker shows.
  {
    const cases = [
      ['irregular', oddMid, 1n, [[1_000, 3], [1_000, 7], [5_000, 11]]],
      ['irregular wide', { ...oddMid, bidWiden: 9n, askWiden: 17n, widthScale: 1_333n }, 7n, [[100, 0], [300, 25], [700, 90]]],
      ['third', { ...BASE_HOT, mid: 333_333_333_333_333_333n }, 1n, [[10, 0], [10, 1]]],
      ['dear', { ...BASE_HOT, mid: 2_718_281_828_459_045_235_360n }, 1n, [[5, 0], [5, 3]]],
    ];
    for (const [label, hot, sizeUnit, levels] of cases) {
      for (const direction of dirs) {
        const { baseIn, exactIn } = DIRECTIONS[direction];
        const b = book(hot, sizeUnit, baseIn, levels);
        const depth = totalDepth(b);
        const bases = [1n, 2n, 3n, 7n, depth / 2n, depth - 1n].filter((x) => x >= 1n && x <= depth);
        const amounts = new Set();
        for (const base of bases) {
          if (baseIn === exactIn) {
            amounts.add(base);
            continue;
          }
          const v = value(b, base);
          for (const q of [v / VALUE_ONE - 1n, v / VALUE_ONE, ceilDiv(v, VALUE_ONE), ceilDiv(v, VALUE_ONE) + 1n]) amounts.add(q);
        }
        for (const amount of [...amounts].filter((a) => a >= 1n).sort(cmp)) {
          add(`rounding ${label} ${direction} ${amount}`, { hot, sizeUnit, direction, levels, amount });
        }
      }
    }
  }

  // InsufficientDepth over ZeroFill: a fill that rounds to nothing on a side with depth left is ZeroFill, and the same
  // fill on a side consumed to its depth, or past what a whole side holds, is InsufficientDepth.
  {
    const cheap = { ...BASE_HOT, mid: 1_234_567_890_123n }; // ~1.2e-6 quote units per base unit: one unit sells for 0
    const dear = { ...BASE_HOT, mid: 4_999_999_999_999_999_999_999_999n }; // ~5e6 quote units per base unit
    const levels = [[3, 0], [4, 5]];
    const cases = [
      ['cheap sell one unit', cheap, 'sellBaseExactIn', 1n],
      ['dear pay one quote unit', dear, 'payQuoteExactIn', 1n],
      ['dear pay just under one base unit', dear, 'payQuoteExactIn', 4_999_999n],
      ['dear want one quote unit', dear, 'wantQuoteExactOut', 1n],
      ['dear buy one unit', dear, 'buyBaseExactOut', 1n],
    ];
    for (const [label, hot, direction, amount] of cases) {
      const depth = totalDepth(book(hot, 1n, DIRECTIONS[direction].baseIn, levels));
      for (const consumed of [0n, depth - 1n, depth, depth + 1n]) {
        add(`precedence ${label} consumed ${consumed}`, { hot, sizeUnit: 1n, direction, levels, amount, consumed });
      }
    }
    add('precedence cheap sell past the whole side', { hot: cheap, sizeUnit: 1n, direction: 'sellBaseExactIn', levels, amount: 8n });
    add('precedence cheap sell the whole side', { hot: cheap, sizeUnit: 1n, direction: 'sellBaseExactIn', levels, amount: 7n });
  }

  // A level whose effective size floors to 0 holds nothing and is skipped: the side goes on past it, consumed or not.
  {
    const hot = { ...BASE_HOT, depthScale: 1n }; // effective size = size x sizeUnit / 1000
    const levels = [[1_000, 5], [999, 9], [2_000, 12], [1, 20], [3_000, 40]]; // effective 1, 0, 2, 0, 3
    for (const direction of dirs) {
      for (const consumed of [0n, 1n, 3n, 5n, 6n]) {
        for (const amount of edgeAmounts(hot, 1n, direction, levels, consumed)) {
          add(`skipped level ${direction} consumed ${consumed} ${amount}`, { hot, sizeUnit: 1n, direction, levels, amount, consumed });
        }
      }
    }
  }

  return { vectors, splits };
}

/** Shape encodings with the reason `ShapeWord.check` must return. */
export function generateShapeChecks() {
  const checks = [];
  const add = (name, words) => checks.push({ name, words: words.map(hex32), reason: shapeReason(words) });
  const side = (levels) => encodeSide(levels);
  const slot = (i, size, spread) => (BigInt(size) + BigInt(spread) * 2n ** SIZE_BITS) * 2n ** (SLOT_BITS * BigInt(i));

  add('empty shape', [0n, 0n, 0n, 0n]);
  add('one level each side', [...side([[1, 0]]), ...side([[5, 3]])]);
  add('ten levels each side', [...side(SHAPES.fine), ...side(SHAPES.labNormal)]);
  add('five levels, second word empty', [...side(SHAPES.sloped), ...side(SHAPES.deepThenThin)]);
  add('equal spreads', [...side(SHAPES.equalSpreads), 0n, 0n]);
  add('max levels', [...side(SHAPES.maxLevels), ...side(SHAPES.maxLevels)]);
  add('bid reserved bit 240', [2n ** 240n + 1n, 0n, 0n, 0n]);
  add('bid second word reserved bit 255', [side(SHAPES.fine)[0], side(SHAPES.fine)[1] + 2n ** 255n, 0n, 0n]);
  add('ask reserved bits', [0n, 0n, 1n, 2n ** 250n]);
  add('second word without a fifth level', [0n, 1n, 0n, 0n]);
  add('ask second word without a fifth level', [0n, 0n, side([[1, 1]])[0], 1n]);
  add('spread on the terminating level', [slot(0, 1, 5) + slot(1, 0, 5), 0n, 0n, 0n]);
  add('spread on an empty side', [slot(0, 0, 1), 0n, 0n, 0n]);
  add('level after a gap', [slot(0, 1, 0) + slot(2, 1, 0), 0n, 0n, 0n]);
  const fiveAt = (spread) => side(Array.from({ length: 5 }, () => [1, spread]))[0];
  add('level after a gap in the second word', [fiveAt(0), slot(1, 1, 1), 0n, 0n]);
  add('spread decreases', [slot(0, 1, 5) + slot(1, 1, 4), 0n, 0n, 0n]);
  add('spread decreases across words', [fiveAt(9), slot(0, 1, 8), 0n, 0n]);
  add('ask spread decreases', [0n, 0n, slot(0, 1, 2) + slot(1, 1, 1), 0n]);
  add('decrease before a non-canonical tail', [slot(0, 1, 5) + slot(1, 1, 4) + slot(3, 1, 9), 0n, 0n, 0n]);
  add('bid fine, ask non-canonical', [...side([[1, 1]]), slot(1, 1, 1), 0n]);
  add('bid non-canonical before ask reserved', [slot(1, 1, 0), 0n, 2n ** 241n, 0n]);

  // Random canonical sides, each also with one flipped bit.
  const r = rng(0x7368617065n);
  for (let n = 0; n < 40; n++) {
    const words = [];
    for (let s = 0; s < 2; s++) {
      const count = Number(r.between(0, 10));
      let spread = r.between(0, 100);
      const levels = [];
      for (let i = 0; i < count; i++) {
        spread += r.pick([0n, r.between(0, 1000)]);
        levels.push([r.between(1, 0xffffffff), spread > 65_535n ? 65_535n : spread]);
      }
      words.push(...side(levels));
    }
    add(`random canonical ${n}`, words);
    const flipped = [...words];
    const w = Number(r.between(0, 3));
    flipped[w] ^= 1n << r.between(0, 255);
    add(`random flipped ${n}`, flipped);
  }
  return checks;
}

// ---------------------------------------------------------------------------------------------------------------------
// What the SDKs encode: hot words, prices, shapes and post batches (HotWord NatSpec, `Venue.post`, spec section 2)
// ---------------------------------------------------------------------------------------------------------------------

export const MAX_UINT16 = (1n << 16n) - 1n;
export const MAX_UINT32 = (1n << 32n) - 1n;
export const MAX_UINT40 = (1n << 40n) - 1n;
export const MAX_MID = (1n << 96n) - 1n;

/** Hot-word flags: bits 0 and 1 switch a side off, bits 2 and 3 refill one, bits 4-15 are reserved. */
export const FLAG_BIDS_OFF = 1n;
export const FLAG_ASKS_OFF = 2n;
export const FLAG_REFILL_BIDS = 4n;
export const FLAG_REFILL_ASKS = 8n;
const FLAGS_REFILL = FLAG_REFILL_BIDS | FLAG_REFILL_ASKS;
const FLAGS_MASK = 15n;
const FLAGS_AT = 240n;

/** Both SDKs name a set of sides `both`, `bids`, `asks` or `neither` (the Rust SDK's `Sides`): the sides that take fills,
 * or that a post refills. */
export const SIDES = ['both', 'bids', 'asks', 'neither'];
export const OFF_FLAGS = { both: 0n, bids: FLAG_ASKS_OFF, asks: FLAG_BIDS_OFF, neither: FLAG_BIDS_OFF | FLAG_ASKS_OFF };
export const REFILL_FLAGS = { neither: 0n, bids: FLAG_REFILL_BIDS, asks: FLAG_REFILL_ASKS, both: FLAGS_REFILL };

/** The word `addPair` stores: `seq = 1`, everything else 0. */
export const INITIAL_FIELDS = {
  mid: 0n,
  bidWiden: 0n,
  askWiden: 0n,
  widthScale: 0n,
  depthScale: 0n,
  shapeId: 0n,
  validUntil: 0n,
  seq: 1n,
  flags: 0n,
};

export const flagsOf = (word) => BigInt(word) >> FLAGS_AT;
/** `HotWord.withoutRefill`: the word `post` stores and emits. */
export const withoutRefill = (word) => BigInt(word) & ~(FLAGS_REFILL << FLAGS_AT);
/** `HotWord.isWellFormed`: what `post` accepts, a nonzero mid and no reserved flag bits. */
export const isWellFormed = (word) => unpackHot(word).mid !== 0n && (flagsOf(word) & ~FLAGS_MASK) === 0n;

/** One hot word: every field, the word, the word `post` would store, and whether `post` accepts it. */
export function hotWordVector(name, fields) {
  const f = { ...INITIAL_FIELDS, ...fields };
  const word = packHot(f);
  return {
    name,
    mid: BigInt(f.mid).toString(),
    bidWiden: Number(f.bidWiden),
    askWiden: Number(f.askWiden),
    widthScale: Number(f.widthScale),
    depthScale: Number(f.depthScale),
    shapeId: Number(f.shapeId),
    validUntil: Number(f.validUntil),
    seq: Number(f.seq),
    flags: Number(f.flags),
    word: hex32(word),
    stored: hex32(withoutRefill(word)),
    wellFormed: isWellFormed(word),
  };
}

const MAX_FIELDS = {
  mid: MAX_MID,
  bidWiden: MAX_UINT16,
  askWiden: MAX_UINT16,
  widthScale: MAX_UINT16,
  depthScale: MAX_UINT16,
  shapeId: 255n,
  validUntil: MAX_UINT40,
  seq: MAX_UINT32,
  flags: 0n,
};

export function generateHotWords() {
  const out = [];
  const add = (name, fields) => out.push(hotWordVector(name, fields));
  add('initial word', {});
  add('companion', BASE_HOT);
  add('order', { mid: 1_085_000_000_000_000_000n, widthScale: 1000n, depthScale: 1000n, shapeId: 7n, validUntil: 1_800_000_060n, seq: 2n });
  add('cancel', { mid: PRICE_ONE, widthScale: 1000n, seq: 99n, flags: OFF_FLAGS.neither });
  for (let flags = 0n; flags <= FLAGS_MASK; flags++) add(`max fields, flags ${flags}`, { ...MAX_FIELDS, flags });
  for (const flags of [16n, 1n << 15n, 0xfff0n, 0xffffn]) add(`reserved flags ${flags}`, { ...BASE_HOT, flags });
  add('zero mid with a refill', { seq: 2n, flags: FLAGS_REFILL });
  add('zero mid, every other field max', { ...MAX_FIELDS, mid: 0n, flags: FLAGS_MASK });
  // Each field on its own, at 1 and at its maximum, so a shifted or truncated field shows.
  for (const [field, bits] of HOT_LAYOUT) {
    for (const v of [1n, (1n << BigInt(bits)) - 1n]) {
      add(`only ${field} ${v}`, { mid: field === 'mid' ? v : 1n, seq: field === 'seq' ? v : 2n, [field]: v });
    }
  }
  const r = rng(0x686f74n);
  for (let n = 0; n < 40; n++) {
    const fields = {};
    for (const [field, bits] of HOT_LAYOUT) fields[field] = r.between(0n, (1n << BigInt(bits)) - 1n);
    fields.flags = r.pick([r.between(0n, 3n), r.between(0n, FLAGS_MASK), r.between(0n, MAX_UINT16)]);
    if (n % 5 !== 0) fields.mid = r.between(1n, MAX_MID);
    if (n % 7 !== 0) fields.seq = r.between(2n, MAX_UINT32);
    add(`random ${n}`, fields);
  }
  return out;
}

/** An exact unsigned decimal with at most 18 places, scaled by 1e18, that is a nonzero uint96; else null. */
export function parsePrice(text) {
  if (typeof text !== 'string') return null;
  const dot = text.indexOf('.');
  const whole = dot < 0 ? text : text.slice(0, dot);
  const fraction = dot < 0 ? '' : text.slice(dot + 1);
  const digits = (s) => s.length > 0 && [...s].every((c) => c >= '0' && c <= '9');
  if (!digits(whole)) return null;
  if (dot >= 0 && (!digits(fraction) || fraction.length > 18)) return null;
  const scaled = BigInt(whole) * PRICE_ONE + (fraction === '' ? 0n : BigInt(fraction.padEnd(18, '0')));
  return scaled >= 1n && scaled <= MAX_MID ? scaled : null;
}

/** The shortest exact decimal for a scaled mid. */
export function formatPrice(mid) {
  const fraction = (BigInt(mid) % PRICE_ONE).toString().padStart(18, '0').replace(/0+$/, '');
  const whole = (BigInt(mid) / PRICE_ONE).toString();
  return fraction === '' ? whole : `${whole}.${fraction}`;
}

/** One price string: `mid` is its scaled value and `canonical` its shortest form, or `ok` is false and both are empty. */
export function priceVector(text) {
  const mid = parsePrice(text);
  return mid === null ? { text, ok: false, mid: '0', canonical: '' } : { text, ok: true, mid: mid.toString(), canonical: formatPrice(mid) };
}

export function generatePrices() {
  const accept = [
    '1',
    '1.085',
    '0.5',
    '0.000000000000000001',
    '79228162514.264337593543950335',
    '1.000',
    '1.10',
    '01.5',
    '007',
    '123456789.123456789123456789',
    '0.999999999999999999',
    '79228162514',
    // Leading zeros never overflow, however many.
    '000000000000000000000000000000000000000001.5',
    '1.000000000000000000',
  ];
  const reject = [
    '',
    '0',
    '0.0',
    '00',
    '0.000000000000000000',
    '-1',
    '+1',
    ' 1',
    '1 ',
    '1e18',
    '.1',
    '1.',
    '.',
    '1.2.3',
    'NaN',
    'Infinity',
    '0x10',
    '1,5',
    '1_000',
    '\u0661',
    '\uff11',
    '1\n',
    '1\t',
    '1.5\u0000',
    '1.0000000000000000001',
    '79228162514.264337593543950336',
    '79228162515',
    '9999999999999999999999999999999999999999999',
  ];
  const out = [...accept, ...reject].map(priceVector);
  for (const v of out.slice(0, accept.length)) if (!v.ok) throw new Error(`price ${v.text} must parse`);
  for (const v of out.slice(accept.length)) if (v.ok) throw new Error(`price ${JSON.stringify(v.text)} must not parse`);
  const r = rng(0x7072696365n);
  for (let n = 0; n < 30; n++) out.push(priceVector(formatPrice(r.pick([r.between(1n, PRICE_ONE), r.between(1n, MAX_MID)]))));
  return out;
}

const sizesOf = (levels) => levels.map(([size]) => Number(size));
const spreadsOf = (levels) => levels.map(([, spread]) => Number(spread));

/** One canonical shape, from its two ladders (`[size, spread]` per level) to its four words. */
export function shapeVector(name, bids, asks) {
  const words = [...encodeSide(bids), ...encodeSide(asks)];
  if (shapeReason(words) !== 0) throw new Error(`${name}: not canonical`);
  return {
    name,
    bidSizes: sizesOf(bids),
    bidSpreads: spreadsOf(bids),
    askSizes: sizesOf(asks),
    askSpreads: spreadsOf(asks),
    words: words.map(hex32),
  };
}

/** Why a shape builder must refuse two ladders: the first broken rule, bids before asks, level by level. */
export function shapeRejection(bids, asks) {
  for (const levels of [bids, asks]) {
    if (levels.length > MAX_LEVELS) return 'TooManyLevels';
    let last = 0n;
    for (const [size, spread] of levels) {
      if (BigInt(size) === 0n) return 'ZeroSize';
      if (BigInt(spread) < last) return 'SpreadDecreases';
      last = BigInt(spread);
    }
  }
  return null;
}

/** Two ladders a shape builder must refuse; both SDKs type sizes as uint32 and spreads as uint16. */
export function shapeRejectVector(name, bids, asks) {
  const error = shapeRejection(bids, asks);
  if (error === null) throw new Error(`${name}: the ladders are valid`);
  return { name, bidSizes: sizesOf(bids), bidSpreads: spreadsOf(bids), askSizes: sizesOf(asks), askSpreads: spreadsOf(asks), error };
}

export function generateShapes() {
  const out = [];
  const add = (name, bids, asks) => out.push(shapeVector(name, bids, asks));
  add('empty', [], []);
  add('one level each side', [[1, 0]], [[5, 3]]);
  add('companion', SHAPES.companion, SHAPES.companion);
  add('five levels, second word empty', SHAPES.sloped, SHAPES.deepThenThin);
  add('six levels, across the word boundary', SHAPES.sixLevels, SHAPES.sixLevels);
  add('ten levels each side', SHAPES.fine, SHAPES.labNormal);
  add('equal spreads', SHAPES.equalSpreads, SHAPES.zeroSpreadTop);
  add('max levels', SHAPES.maxLevels, SHAPES.maxLevels);
  add('bids only', SHAPES.labNormal, []);
  add('asks only', [], SHAPES.sloped);
  add('extreme spreads', [[1, 0], [0xffffffff, 65_535]], [[7, 65_535]]);
  const r = rng(0x6c6164646572n);
  const ladder = () => {
    const levels = [];
    let spread = r.between(0n, 300n);
    for (let i = Number(r.between(0n, 10n)); i > 0; i--) {
      levels.push([r.pick([1n, r.between(1n, 1_000_000n), r.between(1n, MAX_UINT32)]), spread]);
      spread += r.pick([0n, r.between(0n, 50n), r.between(0n, 20_000n)]);
      if (spread > MAX_UINT16) spread = MAX_UINT16;
    }
    return levels;
  };
  for (let n = 0; n < 30; n++) add(`random ${n}`, ladder(), ladder());
  return out;
}

export function generateShapeRejects() {
  const ten = SHAPES.fine;
  const out = [];
  const add = (name, bids, asks) => out.push(shapeRejectVector(name, bids, asks));
  add('eleven bid levels', [...ten, [1, 14]], []);
  add('eleven ask levels', [], [...ten, [1, 14]]);
  add('zero size first', [[0, 0]], []);
  add('zero size in the middle', [[1, 0], [0, 0], [1, 0]], []);
  add('zero size last of ten', [...ten.slice(0, 9), [0, 14]], []);
  add('zero size on the asks', [[1, 0]], [[1, 0], [0, 5]]);
  add('spread decreases', [[1, 5], [1, 4]], []);
  add('spread decreases across words', [...ten.slice(0, 5), [1, 8]], []);
  add('ask spread decreases', [], [[1, 2], [1, 1]]);
  add('bids fine, asks decrease', SHAPES.sloped, [[1, 20], [1, 19]]);
  add('both rules, size first', [[1, 9], [0, 3]], []);
  return out;
}

/** keccak256("post(bytes)")[:4]. The Solidity replay checks it against `IVenue.post.selector`, and both SDKs' calldata
 * starts with it. */
export const POST_SELECTOR = '0xbaf9b369';

/** The Rust SDK's `OrderRequest::new` defaults, which the TypeScript SDK's `Post.order` shares. */
const ORDER_DEFAULTS = { bidWiden: 0, askWiden: 0, widthScale: 1000, depthScale: 1000, sides: 'both', refill: 'neither' };

/** An order request's hot word fields. */
export function orderFields(request) {
  const q = { ...ORDER_DEFAULTS, ...request };
  if (!(q.sides in OFF_FLAGS) || !(q.refill in REFILL_FLAGS)) throw new Error('unknown sides');
  return {
    mid: BigInt(q.mid),
    bidWiden: BigInt(q.bidWiden),
    askWiden: BigInt(q.askWiden),
    widthScale: BigInt(q.widthScale),
    depthScale: BigInt(q.depthScale),
    shapeId: BigInt(q.shapeId),
    validUntil: BigInt(q.validUntil),
    seq: BigInt(q.sequence),
    flags: OFF_FLAGS[q.sides] | REFILL_FLAGS[q.refill],
  };
}

/** A cancel: both sides off, `depthScale` 0, `validUntil` 0 and shape 0, at the given mid; the rest as an order's. */
export const cancelFields = ({ pairIndex, sequence, mid }) =>
  orderFields({ pairIndex, mid, sequence, shapeId: 0, validUntil: 0, depthScale: 0, sides: 'neither' });

const word32 = (v) => BigInt(v).toString(16).padStart(64, '0');

/**
 * One order or cancel batch. In order: an empty batch is refused (`EmptyBatch`), then each request in turn: a pair
 * already in the batch (`DuplicatePair`), a `validUntil` past uint40 (`InvalidExpiry`), a sequence of 1 or less, which
 * a fresh pair's stored 1 already blocks (`InvalidSequence`). Mids are valid prices (the `prices` section covers them).
 * Otherwise `packed` is `post`'s bytes, `[uint16 pairIndex][bytes32 word]` per entry, big endian, `calldata` the call,
 * `posts` each entry's `[pairIndex, sequence]`, and, posted to pairs that were just added, `stored` the word each pair
 * then holds and `refills` the refill bits each entry applies (4 bids, 8 asks).
 */
export function postVector(name, kind, requests) {
  if (kind !== 'orders' && kind !== 'cancels') throw new Error('kind');
  let expect = requests.length === 0 ? 'EmptyBatch' : 'ok';
  const seen = new Set();
  const entries = [];
  for (const request of requests) {
    if (expect !== 'ok') break;
    if (parsePrice(formatPrice(BigInt(request.mid))) !== BigInt(request.mid)) throw new Error(`${name}: bad mid`);
    if (seen.has(request.pairIndex)) {
      expect = 'DuplicatePair';
      break;
    }
    seen.add(request.pairIndex);
    const fields = kind === 'cancels' ? cancelFields(request) : orderFields(request);
    if (fields.validUntil > MAX_UINT40) expect = 'InvalidExpiry';
    else if (fields.seq <= 1n) expect = 'InvalidSequence';
    else entries.push([request.pairIndex, packHot(fields), Number(fields.seq)]);
  }
  const requestsOut = requests.map((q) => ({ ...q, mid: BigInt(q.mid).toString() }));
  if (expect !== 'ok') return { name, kind, requests: requestsOut, expect, packed: '0x', calldata: '0x', posts: [], stored: [], refills: [] };
  const packed = entries.map(([pairIndex, word]) => pairIndex.toString(16).padStart(4, '0') + word32(word)).join('');
  const length = packed.length / 2;
  const calldata = POST_SELECTOR + word32(32) + word32(length) + packed.padEnd(Math.ceil(length / 32) * 64, '0');
  return {
    name,
    kind,
    requests: requestsOut,
    expect,
    packed: '0x' + packed,
    calldata,
    posts: entries.map(([pairIndex, , sequence]) => [pairIndex, sequence]),
    stored: entries.map(([, word]) => hex32(withoutRefill(word))),
    refills: entries.map(([, word]) => Number(flagsOf(word) & FLAGS_REFILL)),
  };
}

export function generatePosts() {
  const out = [];
  const add = (name, kind, requests) => out.push(postVector(name, kind, requests));
  const mid = 1_085_000_000_000_000_000n;
  const a = { pairIndex: 0x1234, mid, shapeId: 7, sequence: 2, validUntil: 1_800_000_060 };
  const b = { pairIndex: 0xabcd, mid: 2n * PRICE_ONE, shapeId: 255, sequence: Number(MAX_UINT32), validUntil: Number(MAX_UINT40) };
  const full = (pairIndex, sides, refill, extra = {}) => ({
    pairIndex,
    mid: 1_164_213_579_246_801_357n,
    bidWiden: 7,
    askWiden: 13,
    widthScale: 1_250,
    depthScale: 800,
    shapeId: 3,
    sequence: 2 + pairIndex,
    validUntil: 1_900_000_000,
    sides,
    refill,
    ...extra,
  });
  add('one order with defaults', 'orders', [a]);
  add('two orders, max sequence and expiry', 'orders', [a, b]);
  add('every field', 'orders', [full(0, 'both', 'neither')]);
  add('every side', 'orders', SIDES.map((sides, i) => full(i, sides, 'neither')));
  add('every refill', 'orders', SIDES.map((refill, i) => full(i, 'both', refill)));
  add('sides off and refilled', 'orders', SIDES.map((sides, i) => full(i, sides, SIDES[3 - i])));
  add('max fields', 'orders', [
    { pairIndex: 65_535, mid: MAX_MID, bidWiden: 65_535, askWiden: 65_535, widthScale: 65_535, depthScale: 65_535, shapeId: 255, sequence: Number(MAX_UINT32), validUntil: Number(MAX_UINT40), sides: 'neither', refill: 'both' },
  ]);
  add('min fields', 'orders', [{ pairIndex: 0, mid: 1n, bidWiden: 0, askWiden: 0, widthScale: 0, depthScale: 0, shapeId: 0, sequence: 2, validUntil: 0 }]);
  add('eight pairs', 'orders', Array.from({ length: 8 }, (_, i) => full(7 - i, SIDES[i % 4], SIDES[(i * 3) % 4], { sequence: 2 + i * 1_000 })));
  add('one cancel', 'cancels', [{ pairIndex: 42, sequence: 99, mid: PRICE_ONE }]);
  add('cancel batch', 'cancels', [0, 1, 2].map((pairIndex) => ({ pairIndex, sequence: 3 + pairIndex, mid: mid + BigInt(pairIndex) })));
  add('cancel at max sequence', 'cancels', [{ pairIndex: 65_535, sequence: Number(MAX_UINT32), mid: MAX_MID }]);
  add('empty orders', 'orders', []);
  add('empty cancels', 'cancels', []);
  add('duplicate pair', 'orders', [a, { ...b, pairIndex: a.pairIndex }]);
  add('duplicate cancel', 'cancels', [{ pairIndex: 1, sequence: 2, mid }, { pairIndex: 1, sequence: 3, mid }]);
  add('sequence 1', 'orders', [{ ...a, sequence: 1 }]);
  add('sequence 0', 'orders', [{ ...a, sequence: 0 }]);
  add('cancel at sequence 1', 'cancels', [{ pairIndex: 0, sequence: 1, mid }]);
  add('expiry past uint40', 'orders', [{ ...a, validUntil: Number(MAX_UINT40) + 1 }]);
  add('a duplicate before a bad sequence', 'orders', [a, { ...a, sequence: 1 }]);
  add('expiry before sequence', 'orders', [{ ...a, sequence: 1, validUntil: Number(MAX_UINT40) + 1 }]);
  add('the first bad entry decides', 'orders', [{ ...a, sequence: 1 }, { ...b, validUntil: Number(MAX_UINT40) + 1 }]);
  add('a bad entry after good ones', 'orders', [full(0, 'both', 'both'), full(1, 'bids', 'neither'), { ...full(2, 'both', 'neither'), sequence: 0 }]);
  return out;
}

/**
 * One transaction's post calls, such as a Tempo batch: `calls` are order or cancel batches in the `posts` section's
 * request form, sent in order to pairs just added (each stores `seq` 1). `Venue.post` walks every entry of every call in
 * that order: an entry whose sequence is above its pair's stored one is stored and emits `Posted` with the word as stored
 * (refill bits cleared); any other is skipped without an event. `posted` is those events in order, `[pairIndex, word]`,
 * and `outcomes` each call's entries, `[pairIndex, sequence]` in request order, split into `accepted` and `skipped`: what
 * the SDKs' `PostOutcome` must recover from the calls and `posted` alone.
 */
export function outcomeVector(name, calls) {
  const stored = new Map();
  const posted = [];
  const outcomes = calls.map(({ kind, requests }) => {
    const v = postVector(name, kind, requests);
    if (v.expect !== 'ok') throw new Error(`${name}: the SDKs refuse a call (${v.expect})`);
    const out = { accepted: [], skipped: [] };
    v.posts.forEach(([pairIndex, sequence], k) => {
      if (sequence > (stored.get(pairIndex) ?? 1)) {
        stored.set(pairIndex, sequence);
        posted.push([pairIndex, v.stored[k]]);
        out.accepted.push([pairIndex, sequence]);
      } else {
        out.skipped.push([pairIndex, sequence]);
      }
    });
    return out;
  });
  return { name, calls: calls.map(({ kind, requests }) => ({ kind, requests: requests.map((q) => ({ ...q, mid: BigInt(q.mid).toString() })) })), posted, outcomes };
}

export function generateOutcomes() {
  const out = [];
  const add = (name, calls) => out.push(outcomeVector(name, calls));
  const mid = 1_085_000_000_000_000_000n;
  const order = (pairIndex, sequence, extra = {}) => ({ pairIndex, mid, shapeId: 7, sequence, validUntil: 1_900_000_000, ...extra });
  const orders = (...requests) => ({ kind: 'orders', requests });
  const cancels = (...requests) => ({ kind: 'cancels', requests });
  const cancel = (pairIndex, sequence) => ({ pairIndex, sequence, mid });
  add('one call, every entry stored', [orders(order(0, 2), order(1, 3))]);
  add('an order then a cancel at its sequence: the cancel is stale', [orders(order(0, 5)), cancels(cancel(0, 5))]);
  add('a cancel then an order at its sequence: the order is stale', [cancels(cancel(0, 5)), orders(order(0, 5))]);
  add('an identical repeat is stale', [orders(order(0, 5)), orders(order(0, 5))]);
  add('an identical repeat after a newer post is stale', [orders(order(0, 5)), orders(order(0, 6)), orders(order(0, 5))]);
  add('a repeat at a higher sequence is a new post', [orders(order(0, 2)), orders(order(0, 3))]);
  add('a newer cancel supersedes, an older one is stale', [orders(order(0, 5)), cancels(cancel(0, 7)), cancels(cancel(0, 6))]);
  add('a refill is stored without its bits, so its repeat without one matches it and is stale', [
    orders(order(0, 5, { refill: 'both' })),
    orders(order(0, 5)),
  ]);
  add('the same entry with and without a refill, the refill second', [orders(order(1, 5)), orders(order(1, 5, { refill: 'asks' }))]);
  add('calls over several pairs', [
    orders(order(0, 3), order(1, 3)),
    orders(order(1, 3), order(2, 4, { sides: 'bids' })),
    cancels(cancel(0, 4), cancel(2, 4)),
  ]);
  add('every entry stale but the first', [orders(order(3, 9)), orders(order(3, 9)), cancels(cancel(3, 9)), orders(order(3, 8))]);
  return out;
}

// ---------------------------------------------------------------------------------------------------------------------
// Venue quotes: one pair's posts, quotes and fills in order (`Venue.post`, `Venue.quote`, `Venue.fill`)
// ---------------------------------------------------------------------------------------------------------------------

/** The block time every `quotes` case quotes at. Its words are live until `LIVE` or expired since `EXPIRED`, so any
 * clock between the two (a local chain's) gives the same answers. */
export const QUOTE_TIME = 1_800_000_000n;
export const LIVE = MAX_UINT40;
export const EXPIRED = 1_000_000n;

/**
 * What `Venue.quote` answers for one pair with no hook, no taker priority-fee cap and no halt: in order `ZeroAmount`,
 * `QuoteExpired(validUntil)`, `SideDisabled(baseIn)`, the ladder from the side's consumed depth (`InsufficientDepth`,
 * `ZeroFill`), `AmountOverflow`, then `InsufficientInventory(token, available, required)` with the token named `base` or
 * `quote`. A fill does the same and then moves consumption and inventory.
 */
export function venueQuote(state, { baseIn, exactIn, amount }) {
  if (amount === 0n) return { error: 'ZeroAmount', args: [] };
  const hot = unpackHot(state.hot);
  if (state.timestamp > hot.validUntil) return { error: 'QuoteExpired', args: [hot.validUntil] };
  const off = hot.flags & (baseIn ? FLAG_BIDS_OFF : FLAG_ASKS_OFF);
  if (hot.depthScale === 0n || off !== 0n) return { error: 'SideDisabled', args: [baseIn] };
  const words = state.shapes.get(Number(hot.shapeId)) ?? [0n, 0n, 0n, 0n];
  const levels = baseIn ? decodeSide(words[0], words[1]) : decodeSide(words[2], words[3]);
  const consumed = baseIn ? state.consumed.bids : state.consumed.asks;
  const r = priceLeg({ hot, sizeUnit: state.sizeUnit, baseIn, exactIn, levels, amount, consumed });
  if (r.error) return { error: r.error, args: [] };
  if (r.amountIn > UINT128_MAX || r.amountOut > UINT128_MAX) return { error: 'AmountOverflow', args: [] };
  const token = baseIn ? 'quote' : 'base';
  if (state.inventory[token] < r.amountOut) return { error: 'InsufficientInventory', args: [token, state.inventory[token], r.amountOut] };
  return r;
}

/**
 * One pair from `addPair` (consumption 0, the initial word) through steps, each recorded with its outcome and the pair's
 * state after it:
 * - `{ op: 'setShape', shapeId, bids, asks }` defines a shape (`words`).
 * - `{ op: 'post', fields }` posts one entry: `accepted` when its `seq` is above the stored one, which then becomes
 *   the word without its refill bits, and each refill bit zeroes its side's consumption.
 * - `{ op: 'quote' | 'fill', baseIn, exactIn, amount }`: `venueQuote`. An accepted fill adds its `baseFilled` to its
 *   side's consumption, `amountIn` to the inventory of the token it takes and takes `amountOut` from the other.
 */
export class QuoteCase {
  constructor(name, { sizeUnit, inventory }) {
    this.name = name;
    this.inventory0 = inventory.map(BigInt);
    this.steps = [];
    this.state = {
      sizeUnit: BigInt(sizeUnit),
      timestamp: QUOTE_TIME,
      hot: packHot(INITIAL_FIELDS),
      shapes: new Map(),
      consumed: { bids: 0n, asks: 0n },
      inventory: { base: this.inventory0[0], quote: this.inventory0[1] },
    };
  }

  /** What a quote or fill would return now, without recording it. */
  peek(step) {
    return venueQuote(this.state, { baseIn: step.baseIn, exactIn: step.exactIn, amount: BigInt(step.amount) });
  }

  apply(step) {
    const { state, name } = this;
    // Every step carries every field, so a typed JSON reader (Forge's) can read them all; those its op doesn't use are
    // zero or empty. `consumed` and `inventory` are always the pair's after the step.
    const out = {
      op: step.op,
      shapeId: 0,
      words: [],
      word: hex32(0n),
      accepted: false,
      baseIn: false,
      exactIn: false,
      amount: '0',
      expect: '',
      args: [],
      amountIn: '0',
      amountOut: '0',
      baseFilled: '0',
    };
    if (step.op === 'setShape') {
      const words = [...encodeSide(step.bids), ...encodeSide(step.asks)];
      if (shapeReason(words) !== 0) throw new Error(`${name}: shape ${step.shapeId} is not canonical`);
      state.shapes.set(Number(step.shapeId), words);
      Object.assign(out, { shapeId: Number(step.shapeId), words: words.map(hex32) });
    } else if (step.op === 'post') {
      const word = packHot({ ...INITIAL_FIELDS, ...step.fields });
      if (!isWellFormed(word)) throw new Error(`${name}: post would revert`);
      const accepted = unpackHot(word).seq > unpackHot(state.hot).seq;
      if (accepted) {
        const refill = flagsOf(word) & FLAGS_REFILL;
        state.hot = withoutRefill(word);
        if (refill & FLAG_REFILL_BIDS) state.consumed.bids = 0n;
        if (refill & FLAG_REFILL_ASKS) state.consumed.asks = 0n;
      }
      Object.assign(out, { word: hex32(word), accepted });
    } else if (step.op === 'quote' || step.op === 'fill') {
      const amount = BigInt(step.amount);
      if (amount < 0n || amount > UINT128_MAX) throw new Error(`${name}: amount past uint128`);
      const r = this.peek(step);
      if (!r.error && step.op === 'fill') {
        if (step.baseIn) state.consumed.bids += r.baseFilled;
        else state.consumed.asks += r.baseFilled;
        const [tokenIn, tokenOut] = step.baseIn ? ['base', 'quote'] : ['quote', 'base'];
        state.inventory[tokenIn] += r.amountIn;
        state.inventory[tokenOut] -= r.amountOut;
      }
      Object.assign(out, {
        baseIn: step.baseIn,
        exactIn: step.exactIn,
        amount: amount.toString(),
        expect: r.error ?? 'ok',
        args: (r.args ?? []).map(String),
        amountIn: (r.amountIn ?? 0n).toString(),
        amountOut: (r.amountOut ?? 0n).toString(),
        baseFilled: (r.baseFilled ?? 0n).toString(),
      });
    } else {
      throw new Error(`${name}: unknown step ${step.op}`);
    }
    out.consumed = [state.consumed.bids.toString(), state.consumed.asks.toString()];
    out.inventory = [state.inventory.base.toString(), state.inventory.quote.toString()];
    this.steps.push(out);
    return out;
  }

  vector() {
    return {
      name: this.name,
      sizeUnit: this.state.sizeUnit.toString(),
      timestamp: QUOTE_TIME.toString(),
      inventory: this.inventory0.map(String),
      steps: this.steps,
    };
  }
}

export function quoteVector(name, { sizeUnit, inventory, steps }) {
  const c = new QuoteCase(name, { sizeUnit, inventory });
  for (const step of steps) c.apply(step);
  return c.vector();
}

/** A hot word's fields for a `post` step: live, both scales 1x, both sides on. */
export const live = (fields) => ({ widthScale: 1000n, depthScale: 1000n, validUntil: LIVE, ...fields });
/** A taker step: `direction` as `DIRECTIONS` names it. */
export const take = (op, direction, amount) => ({ op, ...DIRECTIONS[direction], amount: BigInt(amount) });

export function generateQuotes() {
  const out = [];
  const add = (name, c) => out.push(quoteVector(name, c));
  const T = EUR; // one token of 6 decimals
  const sloped = {
    bids: [[1_000, 10], [2_000, 20], [3_000, 40]],
    asks: [[1_000, 10], [2_000, 25], [3_000, 50]],
  };
  const mid = 1_085_000_000_000_000_000n;
  const both = REFILL_FLAGS.both;

  add('every direction walks consumption, refills reset one side', {
    sizeUnit: EUR,
    inventory: [10n ** 13n, 10n ** 13n],
    steps: [
      { op: 'setShape', shapeId: 7, ...sloped },
      { op: 'post', fields: live({ mid, shapeId: 7n, seq: 2n, flags: both }) },
      take('quote', 'sellBaseExactIn', 1_500n * T),
      take('fill', 'sellBaseExactIn', 1_500n * T),
      take('fill', 'buyBaseExactOut', 2_500n * T),
      take('fill', 'payQuoteExactIn', 1_000n * T),
      take('fill', 'wantQuoteExactOut', 2_000n * T),
      take('quote', 'sellBaseExactIn', 10_000n * T),
      { op: 'post', fields: live({ mid: mid + 10n ** 15n, shapeId: 7n, seq: 3n }) },
      take('fill', 'sellBaseExactIn', 1_000n * T),
      take('quote', 'buyBaseExactOut', 3_000n * T),
      { op: 'post', fields: live({ mid, shapeId: 7n, seq: 4n, flags: REFILL_FLAGS.bids }) },
      take('quote', 'sellBaseExactIn', 6_000n * T),
      take('quote', 'sellBaseExactIn', 6_000n * T + 1n),
      take('fill', 'sellBaseExactIn', 6_000n * T - 1n),
      take('quote', 'wantQuoteExactOut', 1n),
      take('fill', 'sellBaseExactIn', 1n),
      take('quote', 'sellBaseExactIn', 1n),
    ],
  });

  add('consumption outlives a shallower ladder until a refill', {
    sizeUnit: EUR,
    inventory: [10n ** 13n, 10n ** 13n],
    steps: [
      { op: 'setShape', shapeId: 1, bids: [[5_000, 10]], asks: [[5_000, 10]] },
      { op: 'setShape', shapeId: 2, bids: [[1_000, 20]], asks: [[1_000, 20]] },
      { op: 'post', fields: live({ mid, shapeId: 1n, seq: 2n, flags: both }) },
      take('fill', 'sellBaseExactIn', 3_000n * T),
      { op: 'post', fields: live({ mid, shapeId: 2n, seq: 3n }) },
      take('quote', 'sellBaseExactIn', 1n),
      take('quote', 'wantQuoteExactOut', 1n),
      take('fill', 'buyBaseExactOut', 400n * T),
      take('fill', 'payQuoteExactIn', 600n * T),
      { op: 'post', fields: live({ mid, shapeId: 2n, seq: 4n, flags: both }) },
      take('quote', 'sellBaseExactIn', 1_000n * T),
      take('quote', 'sellBaseExactIn', 1_000n * T + 1n),
      { op: 'setShape', shapeId: 2, bids: [[2_000, 20]], asks: [[2_000, 20]] },
      take('fill', 'sellBaseExactIn', 1_500n * T),
      take('quote', 'sellBaseExactIn', 500n * T + 1n),
    ],
  });

  {
    const odd = 1_164_213_579_246_801_357n;
    const levels = [[10, 3], [10, 7]];
    add('rounding toward the maker, one unit at a time', {
      sizeUnit: 1n,
      inventory: [1_000_000n, 1_000_000n],
      steps: [
        { op: 'setShape', shapeId: 0, bids: levels, asks: levels },
        { op: 'post', fields: live({ mid: odd, seq: 2n, flags: both }) },
        take('fill', 'sellBaseExactIn', 1n),
        take('fill', 'sellBaseExactIn', 1n),
        take('fill', 'buyBaseExactOut', 1n),
        take('quote', 'payQuoteExactIn', 1n),
        take('fill', 'payQuoteExactIn', 2n),
        take('fill', 'payQuoteExactIn', 3n),
        take('fill', 'wantQuoteExactOut', 1n),
        take('fill', 'wantQuoteExactOut', 3n),
        take('fill', 'sellBaseExactIn', 7n),
        take('fill', 'buyBaseExactOut', 9n),
        take('quote', 'buyBaseExactOut', 9n),
        take('quote', 'buyBaseExactOut', 10n),
        take('fill', 'wantQuoteExactOut', 10n),
        take('quote', 'sellBaseExactIn', 1n),
      ],
    });
  }

  {
    const dear = 4_999_999_999_999_999_999_999_999n;
    add('dust: ZeroFill with depth left, InsufficientDepth without', {
      sizeUnit: 1n,
      inventory: [10n, 10n ** 9n],
      steps: [
        { op: 'setShape', shapeId: 0, bids: [[3, 0]], asks: [[3, 0], [4, 5]] },
        { op: 'post', fields: live({ mid: dear, seq: 2n }) },
        take('quote', 'payQuoteExactIn', 1n),
        take('quote', 'payQuoteExactIn', 4_999_999n),
        take('fill', 'payQuoteExactIn', 5_000_000n),
        take('fill', 'buyBaseExactOut', 6n),
        take('quote', 'payQuoteExactIn', 1n),
        take('quote', 'buyBaseExactOut', 1n),
        take('fill', 'sellBaseExactIn', 2n),
        take('fill', 'wantQuoteExactOut', 1n),
        take('quote', 'sellBaseExactIn', 1n),
        take('quote', 'wantQuoteExactOut', 1n),
      ],
    });
    const cheap = 1_234_567_890_123n;
    add('dust: a cheap base unit sells for nothing', {
      sizeUnit: 1n,
      inventory: [10n ** 9n, 10n ** 9n],
      steps: [
        { op: 'setShape', shapeId: 0, bids: [[5_000_000, 0], [5_000_000, 10]], asks: [[5_000_000, 0]] },
        { op: 'post', fields: live({ mid: cheap, seq: 2n }) },
        take('quote', 'sellBaseExactIn', 1n),
        take('fill', 'sellBaseExactIn', 1_000_000n),
        take('fill', 'sellBaseExactIn', 810_000n),
        take('quote', 'sellBaseExactIn', 810_000n),
        take('fill', 'wantQuoteExactOut', 1n),
        take('fill', 'buyBaseExactOut', 1n),
        take('fill', 'payQuoteExactIn', 1n),
        take('fill', 'sellBaseExactIn', 9_000_000n),
        take('quote', 'sellBaseExactIn', 1n),
        take('quote', 'wantQuoteExactOut', 1n),
      ],
    });
  }

  add("Venue.quote's checks in order", {
    sizeUnit: EUR,
    inventory: [10n ** 12n, 10n ** 12n],
    steps: [
      { op: 'setShape', shapeId: 0, ...sloped },
      take('quote', 'sellBaseExactIn', T),
      { op: 'post', fields: live({ mid, seq: 2n, flags: OFF_FLAGS.bids }) },
      take('quote', 'buyBaseExactOut', T),
      take('quote', 'payQuoteExactIn', T),
      take('quote', 'sellBaseExactIn', T),
      take('quote', 'sellBaseExactIn', 0n),
      { op: 'post', fields: live({ mid, seq: 3n, depthScale: 0n }) },
      take('quote', 'sellBaseExactIn', T),
      take('quote', 'wantQuoteExactOut', T),
      { op: 'post', fields: { ...live({ mid, seq: 4n, depthScale: 0n, flags: OFF_FLAGS.neither }), validUntil: EXPIRED } },
      take('quote', 'sellBaseExactIn', T),
      take('quote', 'buyBaseExactOut', 0n),
      { op: 'post', fields: { ...live({ mid, seq: 5n }), validUntil: QUOTE_TIME } },
      take('quote', 'sellBaseExactIn', T),
      { op: 'post', fields: { ...live({ mid, seq: 6n }), validUntil: QUOTE_TIME - 1n } },
      take('quote', 'sellBaseExactIn', T),
      { op: 'post', fields: live({ mid, seq: 7n, shapeId: 9n }) },
      take('quote', 'sellBaseExactIn', T),
      take('quote', 'payQuoteExactIn', T),
      { op: 'post', fields: live({ mid, seq: 8n, flags: OFF_FLAGS.asks | both }) },
      take('quote', 'sellBaseExactIn', T),
      take('fill', 'buyBaseExactOut', T),
    ],
  });

  add('inventory bounds the payout, after the ladder', {
    sizeUnit: EUR,
    inventory: [0n, 10n * T],
    steps: [
      { op: 'setShape', shapeId: 0, ...sloped },
      { op: 'post', fields: live({ mid, seq: 2n }) },
      take('quote', 'buyBaseExactOut', T),
      take('quote', 'sellBaseExactIn', 20n * T),
      take('quote', 'sellBaseExactIn', 100_000n * T),
      take('fill', 'sellBaseExactIn', 5n * T),
      take('fill', 'buyBaseExactOut', 5n * T),
      take('quote', 'buyBaseExactOut', 1n),
      take('quote', 'payQuoteExactIn', 2n * T),
      take('fill', 'wantQuoteExactOut', 4n * T),
      take('quote', 'wantQuoteExactOut', 10n * T),
    ],
  });

  add('stale posts change nothing, refills included', {
    sizeUnit: 1_000n,
    inventory: [10n ** 12n, 10n ** 12n],
    steps: [
      { op: 'setShape', shapeId: 4, ...sloped },
      { op: 'post', fields: live({ mid, shapeId: 4n, seq: 5n, flags: both }) },
      take('fill', 'sellBaseExactIn', 1_234_567n),
      take('fill', 'buyBaseExactOut', 2_345_678n),
      { op: 'post', fields: live({ mid: 2n * mid, shapeId: 4n, seq: 5n, flags: both }) },
      { op: 'post', fields: live({ mid: 2n * mid, shapeId: 4n, seq: 4n, flags: both }) },
      take('quote', 'sellBaseExactIn', 1_000_000n),
      { op: 'post', fields: live({ mid, shapeId: 4n, seq: 6n, flags: REFILL_FLAGS.asks }) },
      take('quote', 'buyBaseExactOut', 6_000_000n),
      take('quote', 'sellBaseExactIn', 6_000_000n),
      { op: 'post', fields: live({ mid, shapeId: 4n, seq: Number(MAX_UINT32), flags: both }) },
      take('quote', 'sellBaseExactIn', 6_000_000n),
      { op: 'post', fields: live({ mid, shapeId: 4n, seq: Number(MAX_UINT32), flags: both }) },
    ],
  });

  {
    const maxLevels = SHAPES.maxLevels;
    add('amounts past uint128 overflow before inventory', {
      sizeUnit: (1n << 64n) - 1n,
      inventory: [0n, 0n],
      steps: [
        { op: 'setShape', shapeId: 0, bids: maxLevels, asks: maxLevels },
        // Max width puts every bid level past the floor; the asks hold about 5e31 base units at about 3.5e12 each.
        { op: 'post', fields: { ...MAX_FIELDS, bidWiden: 0n, shapeId: 0n, seq: 2n } },
        take('quote', 'buyBaseExactOut', 10n ** 27n),
        take('quote', 'buyBaseExactOut', UINT128_MAX),
        take('quote', 'buyBaseExactOut', 1n),
        take('quote', 'payQuoteExactIn', UINT128_MAX),
        take('quote', 'sellBaseExactIn', 1n),
        // At 1x width the bids fill, about 2.7e10 quote units per base unit.
        { op: 'post', fields: { ...MAX_FIELDS, bidWiden: 0n, widthScale: 1000n, shapeId: 0n, seq: 3n } },
        take('quote', 'sellBaseExactIn', 10n ** 29n),
        take('quote', 'sellBaseExactIn', UINT128_MAX),
        take('quote', 'wantQuoteExactOut', UINT128_MAX),
        take('quote', 'sellBaseExactIn', 1n),
      ],
    });
  }

  add('the bid floor ends the side under consumption', {
    sizeUnit: EUR,
    inventory: [10n ** 13n, 10n ** 13n],
    steps: [
      { op: 'setShape', shapeId: 0, bids: [[1_000, 0], [1_000, 30_000], [1_000, 60_000]], asks: [[1_000, 0], [1_000, 60_000]] },
      { op: 'post', fields: live({ mid, seq: 2n, widthScale: 1_667n }) },
      take('quote', 'sellBaseExactIn', 2_000n * T),
      take('quote', 'sellBaseExactIn', 2_000n * T + 1n),
      take('fill', 'sellBaseExactIn', 1_500n * T),
      take('fill', 'wantQuoteExactOut', 100n * T),
      take('quote', 'sellBaseExactIn', 500n * T),
      take('fill', 'buyBaseExactOut', 2_000n * T),
      // A widen that floors the third bid level instead keeps the first two, and their consumption.
      { op: 'post', fields: live({ mid, seq: 3n, widthScale: 1_000n, bidWiden: 40_000n }) },
      take('quote', 'sellBaseExactIn', 300n * T),
      take('quote', 'sellBaseExactIn', 400n * T),
    ],
  });

  add('a level that floors to nothing is skipped', {
    sizeUnit: 1n,
    inventory: [10n ** 9n, 10n ** 9n],
    steps: [
      { op: 'setShape', shapeId: 0, bids: [[1_000, 5], [999, 9], [2_000, 12], [1, 20], [3_000, 40]], asks: [[1_000, 5], [999, 9], [2_000, 12]] },
      { op: 'post', fields: live({ mid, seq: 2n, depthScale: 1n }) },
      take('fill', 'sellBaseExactIn', 1n),
      take('fill', 'sellBaseExactIn', 2n),
      take('fill', 'wantQuoteExactOut', 2n),
      take('quote', 'sellBaseExactIn', 2n),
      take('fill', 'buyBaseExactOut', 3n),
      take('quote', 'payQuoteExactIn', 1_000n),
      { op: 'post', fields: live({ mid, seq: 3n, depthScale: 2n, flags: REFILL_FLAGS.asks }) },
      take('fill', 'payQuoteExactIn', 7n),
      take('quote', 'buyBaseExactOut', 3n),
    ],
  });

  add('splitting a buy never beats one fill', {
    sizeUnit: 7n,
    inventory: [10n ** 12n, 10n ** 12n],
    steps: [
      { op: 'setShape', shapeId: 0, bids: SHAPES.labNormal, asks: SHAPES.labNormal },
      { op: 'post', fields: live({ mid: 1_164_213_579_246_801_357n, seq: 2n, askWiden: 3n, widthScale: 1_750n, depthScale: 667n, flags: both }) },
      take('quote', 'buyBaseExactOut', 3_000_000n),
      take('fill', 'buyBaseExactOut', 1_000_001n),
      take('fill', 'buyBaseExactOut', 999_999n),
      take('fill', 'buyBaseExactOut', 1_000_000n),
      { op: 'post', fields: live({ mid: 1_164_213_579_246_801_357n, seq: 3n, askWiden: 3n, widthScale: 1_750n, depthScale: 667n, flags: both }) },
      take('fill', 'payQuoteExactIn', 1_234_567n),
      take('fill', 'payQuoteExactIn', 7n),
      take('fill', 'payQuoteExactIn', 2_345_678n),
    ],
  });
  return out;
}

// ---------------------------------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------------------------------

const FIELD_DOCS = {
  direction: 'sellBaseExactIn | buyBaseExactOut | payQuoteExactIn | wantQuoteExactOut',
  baseIn: 'the taker sells base, so the fill walks the bids',
  exactIn: 'amount is the input; otherwise it is the output',
  hot: 'the pair hot word (HotWord layout); mid, widen, widthScale and depthScale repeat its fields',
  widen: 'bidWiden when baseIn, else askWiden',
  sizeUnit: 'base units per shape size step',
  w0: 'the walked side\'s first shape word (levels 1-5)',
  w1: 'the walked side\'s second shape word (levels 6-10); 0 unless level 5 has size',
  consumed: 'base the walked side already gave up (the venue\'s consumed): the walk starts after it',
  expect: 'ok | InsufficientDepth | ZeroFill',
  amountIn: 'taker input when expect is ok, else 0',
  amountOut: 'taker output when expect is ok, else 0',
  baseFilled: 'base moved on this side when expect is ok; the venue adds it to the side\'s consumed',
  splits: 'one order sent as parts: whole is the vector index of one fill of the total, parts the indices of the parts, each from the consumed the last left',
  shapeChecks: 'four shape words (bid w0, bid w1, ask w0, ask w1) and the reason ShapeWord.check returns: 0 valid, 1 reserved bits, 2 non-canonical, 3 spread decreases',
  hotWords: 'every HotWord field (flags raw: bit 0 bids off, bit 1 asks off, bit 2 refill bids, bit 3 refill asks, 4-15 reserved), the packed word, the word post stores (refill bits cleared) and whether post accepts it (nonzero mid, no reserved bits); a stored word decodes only with flags 0-3',
  prices: 'a price string, whether it is an exact unsigned decimal of at most 18 places whose value is a nonzero uint96 (ok), its value scaled by 1e18 (mid) and its shortest form (canonical)',
  shapes: 'two canonical ladders as sizes and spreads per level, and their four shape words',
  shapeRejects: 'two ladders a shape builder must refuse, with the first broken rule (bids first, level by level): TooManyLevels, ZeroSize or SpreadDecreases',
  posts: 'an order or cancel batch (requests omit fields that take the defaults: no widen, both scales 1000, both sides, no refill; a cancel posts both sides off, depthScale 0, validUntil 0, shape 0), expect ok or the first refusal (EmptyBatch, then per request DuplicatePair, InvalidExpiry, InvalidSequence), the post bytes (packed), the post(bytes) calldata and each entry\'s [pairIndex, sequence]; posted to pairs just added, stored is the word each pair then holds and refills the refill bits each entry applies (4 bids, 8 asks)',
  quotes: 'one pair from addPair through its steps at block time timestamp, with no hook, cap or halt, inventory [base, quote] the venue holds: setShape (shapeId, words), post (word, accepted) or quote and fill (baseIn, exactIn, amount; expect ok or the venue error, with args as strings and the token named base or quote; amountIn, amountOut, baseFilled), each with consumed [bids, asks] and inventory [base, quote] after it (only an ok fill moves them). Every step has every field; an op leaves the ones it does not use zero or empty',
  outcomes: 'one transaction\'s post calls in order (calls, each an orders or cancels batch in the posts section\'s request form), sent to pairs just added (each stores seq 1): posted is the Posted events the venue emits, [pairIndex, stored word] in order, and outcomes each call\'s entries as [pairIndex, sequence] in request order, split into accepted (stored, an event) and skipped (stale: the pair already stored that sequence or a higher one, earlier in the transaction)',
};

/** The vector file for `sections` (the keys below, in this order), one entry per line. */
export function renderVectors(sections, description) {
  const lines = ['{', `  "description": ${JSON.stringify(description)},`, '  "fields": ' + JSON.stringify(FIELD_DOCS) + ','];
  const keys = ['vectors', 'splits', 'shapeChecks', 'hotWords', 'prices', 'shapes', 'shapeRejects', 'posts', 'quotes', 'outcomes'];
  if (sections.postSelector !== POST_SELECTOR) throw new Error('postSelector');
  lines.push(`  "postSelector": "${POST_SELECTOR}",`);
  keys.forEach((key, i) => {
    const entries = sections[key];
    if (!Array.isArray(entries)) throw new Error(`missing section ${key}`);
    lines.push(`  "${key}": [`, entries.map((e) => '    ' + JSON.stringify(e)).join(',\n'), i === keys.length - 1 ? '  ]' : '  ],');
  });
  lines.push('}', '');
  return lines.join('\n');
}

/** Every committed section. */
export function generateAll() {
  const { vectors, splits } = generate();
  return {
    postSelector: POST_SELECTOR,
    vectors,
    splits,
    shapeChecks: generateShapeChecks(),
    hotWords: generateHotWords(),
    prices: generatePrices(),
    shapes: generateShapes(),
    shapeRejects: generateShapeRejects(),
    posts: generatePosts(),
    quotes: generateQuotes(),
    outcomes: generateOutcomes(),
  };
}

const DESCRIPTION =
  'propAMM v2 vectors for LadderMath, the Venue quote path and what the SDKs encode, generated by contracts/test/vectors/ladder-reference.mjs. Do not edit.';

const here = dirname(fileURLToPath(import.meta.url));
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const out = join(here, 'propamm-v2-ladder.json');
  const sections = generateAll();
  const text = renderVectors(sections, DESCRIPTION);
  if (process.argv.includes('--check')) {
    if (readFileSync(out, 'utf8') !== text) {
      console.error(`${out} is stale: run node contracts/test/vectors/ladder-reference.mjs`);
      process.exit(1);
    }
    console.log(`${out} is up to date`);
  } else {
    writeFileSync(out, text);
    const counts = {};
    for (const v of sections.vectors) counts[`${v.direction} ${v.expect}`] = (counts[`${v.direction} ${v.expect}`] ?? 0) + 1;
    const sizes = Object.entries(sections)
      .filter(([, v]) => Array.isArray(v))
      .map(([k, v]) => `${v.length} ${k}`);
    console.log(`wrote ${sizes.join(', ')} to ${out}`);
    console.log(counts);
  }
}
