// SPDX-License-Identifier: MIT
//
// Seeded random vectors in the format of propamm-v2-ladder.json, from the same BigInt reference model
// (ladder-reference.mjs), so the Solidity, Rust and TypeScript replays can check one random set the way they check the
// committed one. One seed gives one file, byte for byte, so each CI job regenerates it from the commit and every
// implementation checks the same cases; a failure names the seed, and the same command reproduces it anywhere.
//
// Usage:
//   node contracts/test/vectors/fuzz.mjs [--seed 0x...] [--scale N] [--out path]
//
// --seed   a 64-bit seed (default 0x70726f70616d6d32); CI uses the first 16 hex digits of the commit
// --scale  multiplies every section's case count (default 1)
// --out    the output file (default contracts/test/vectors/fuzz/<seed>.json). Forge reads files only under
//          contracts/test/vectors (foundry.toml fs_permissions), and fuzz/ is git-ignored.
//
// Then point a replay at it with PROPAMM_VECTORS (a path relative to the repository root, or absolute):
//   PROPAMM_VECTORS=<file> forge test --match-path contracts/test/v2/LadderMathVectors.t.sol
//   PROPAMM_VECTORS=<file> cargo test -p propamm-sdk --test vectors
//   PROPAMM_VECTORS=<file> npm --prefix sdk/ts run test:vectors          (and test:e2e:vectors, on a local Anvil)
// bin/equivalence runs all four.

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  BASE_HOT,
  DIRECTIONS,
  EUR,
  EXPIRED,
  LIVE,
  MAX_MID,
  MAX_UINT16,
  MAX_UINT32,
  MAX_UINT40,
  OFF_FLAGS,
  POST_SELECTOR,
  PRICE_ONE,
  QuoteCase,
  QUOTE_TIME,
  REFILL_FLAGS,
  SIDES,
  UINT128_MAX,
  VALUE_ONE,
  book,
  decodeSide,
  encodeSide,
  formatPrice,
  hex32,
  hotWordVector,
  makeVector,
  outcomeVector,
  postVector,
  priceVector,
  remainingBook,
  renderVectors,
  rng,
  shapeReason,
  shapeRejectVector,
  shapeVector,
  totalDepth,
  unpackHot,
  value,
} from './ladder-reference.mjs';

const DIRS = Object.keys(DIRECTIONS);
const MAX_SIZE_UNIT = (1n << 64n) - 1n;
/** What a fill may take from the Anvil taker, and what a case may fund the venue with, per token. */
const FILL_BUDGET = 10n ** 15n;
const ceilDiv = (a, b) => (a + b - 1n) / b;

/** The reference's splitmix64, plus the draws the cases below use. */
function draw(seed) {
  const r = rng(seed);
  const chance = (n) => r.between(0n, BigInt(n - 1)) === 0n;
  /** Log-uniform in [1, max]: every magnitude is as likely. */
  const magnitude = (max) => {
    const bits = r.between(1n, BigInt(max.toString(2).length));
    const hi = (1n << bits) - 1n;
    return r.between(1n, hi < max ? hi : max);
  };
  const int = (lo, hi) => Number(r.between(BigInt(lo), BigInt(hi)));
  /** Uniform over all 256 bits (one draw covers 192). */
  const word = () => (r.between(0n, (1n << 128n) - 1n) << 128n) | r.between(0n, (1n << 128n) - 1n);
  return { ...r, chance, magnitude, int, word };
}

/** A canonical ladder: up to `maxLevels` levels, nondecreasing spreads. */
function ladder(d, { maxLevels = 10, maxSize = MAX_UINT32, minLevels = 0 } = {}) {
  const levels = [];
  let spread = d.chance(3) ? 0n : d.between(0n, 300n);
  for (let i = d.int(minLevels, maxLevels); i > 0; i--) {
    levels.push([d.chance(10) ? 1n : d.magnitude(maxSize), spread]);
    spread += d.chance(3) ? 0n : d.between(0n, d.chance(4) ? 20_000n : 500n);
    if (spread > MAX_UINT16) spread = MAX_UINT16;
  }
  return levels;
}

function randomHot(d) {
  const pick16 = () => (d.chance(4) ? d.between(0n, MAX_UINT16) : d.between(0n, 2_000n));
  return {
    ...BASE_HOT,
    mid: d.chance(8) ? MAX_MID : d.magnitude(MAX_MID),
    bidWiden: d.chance(3) ? 0n : pick16(),
    askWiden: d.chance(3) ? 0n : pick16(),
    widthScale: d.chance(3) ? 1000n : d.between(0n, MAX_UINT16),
    depthScale: d.chance(8) ? MAX_UINT16 : d.between(1n, 5_000n),
    shapeId: d.between(0n, 255n),
    validUntil: d.between(0n, MAX_UINT40),
    seq: d.between(2n, MAX_UINT32),
    flags: d.between(0n, 3n),
  };
}

/** One random fill: amounts across every magnitude and on the edges of what the book left covers. */
function randomVector(d, n) {
  const hot = randomHot(d);
  const sizeUnit = d.chance(8) ? MAX_SIZE_UNIT : d.magnitude(MAX_SIZE_UNIT);
  const levels = ladder(d);
  const direction = DIRS[n % 4];
  const { baseIn, exactIn } = DIRECTIONS[direction];
  const full = book(hot, sizeUnit, baseIn, levels);
  const depth = totalDepth(full);
  const consumed = d.chance(3) ? 0n : d.chance(10) ? depth + d.between(0n, 10n) : d.between(0n, depth);
  const left = remainingBook(full, consumed);
  const leftDepth = totalDepth(left);
  const edge = baseIn === exactIn ? leftDepth : value(left, leftDepth) / VALUE_ONE;
  let amount = d.chance(2) ? d.magnitude(UINT128_MAX) : edge + d.between(0n, 4n) - 2n;
  if (amount < 1n) amount = 1n;
  if (amount > UINT128_MAX) amount = UINT128_MAX;
  return makeVector(`fuzz ${n} ${direction}`, { hot, sizeUnit, direction, levels, amount, consumed });
}

/** One order sent as parts chained through consumed, then the one fill of what the parts traded. */
function randomSplit(d, n, vectors) {
  for (let attempt = 0; attempt < 20; attempt++) {
    const hot = { ...BASE_HOT, mid: d.chance(2) ? d.between(PRICE_ONE / 2n, 2n * PRICE_ONE) : d.magnitude(MAX_MID) };
    const sizeUnit = d.pick([1n, 7n, EUR, d.magnitude(10n ** 9n)]);
    const levels = ladder(d, { minLevels: 1, maxSize: 1_000_000n });
    const direction = DIRS[n % 4];
    const { baseIn, exactIn } = DIRECTIONS[direction];
    const full = book(hot, sizeUnit, baseIn, levels);
    const start = d.chance(2) ? 0n : d.between(0n, totalDepth(full) / 2n);
    const rest = remainingBook(full, start);
    const base = (totalDepth(rest) * d.between(5n, 10n)) / 10n;
    const total = baseIn === exactIn ? base : value(rest, base) / VALUE_ONE;
    if (total < 4n) continue;
    const amounts = [];
    let left = total;
    for (let i = d.int(1, 5); i > 0 && left > 1n; i--) {
      const a = d.chance(4) ? d.between(1n, 3n) : d.between(1n, left - 1n);
      if (a >= left) break;
      amounts.push(a);
      left -= a;
    }
    amounts.push(left);
    const parts = [];
    const name = `fuzz split ${n} ${direction}`;
    let consumed = start;
    let traded = 0n;
    for (const [k, amount] of amounts.entries()) {
      parts.push(vectors.length);
      vectors.push(makeVector(`${name} part ${k + 1}/${amounts.length}`, { hot, sizeUnit, direction, levels, amount, consumed }));
      const v = vectors[vectors.length - 1];
      if (v.expect === 'ok') {
        consumed += BigInt(v.baseFilled);
        traded += amount;
      }
    }
    if (traded === 0n) {
      vectors.length = parts[0];
      continue;
    }
    const whole = vectors.length;
    vectors.push(makeVector(`${name} whole`, { hot, sizeUnit, direction, levels, amount: traded, consumed: start }));
    if (vectors[whole].expect !== 'ok') throw new Error(`${name}: the whole must fill`);
    return { name, whole, parts };
  }
  return null;
}

function randomShapeCheck(d, n) {
  const words = [...encodeSide(ladder(d)), ...encodeSide(ladder(d))];
  const kind = n % 4;
  if (kind === 1) words[d.int(0, 3)] ^= 1n << d.between(0n, 255n);
  if (kind === 2) words[d.int(0, 3)] = d.chance(2) ? d.word() : d.word() & ((1n << 240n) - 1n);
  if (kind === 3) {
    const w = d.int(0, 3);
    words[w] |= d.between(1n, MAX_UINT16) << (48n * d.between(0n, 4n));
  }
  return { name: `fuzz shape check ${n}`, words: words.map(hex32), reason: shapeReason(words) };
}

function randomHotWord(d, n) {
  const fields = {};
  const widths = { mid: 96n, bidWiden: 16n, askWiden: 16n, widthScale: 16n, depthScale: 16n, shapeId: 8n, validUntil: 40n, seq: 32n };
  for (const [field, bits] of Object.entries(widths)) {
    const max = (1n << bits) - 1n;
    fields[field] = d.chance(6) ? d.pick([0n, 1n, max]) : d.magnitude(max);
  }
  fields.flags = d.chance(4) ? d.between(0n, MAX_UINT16) : d.between(0n, 15n);
  return hotWordVector(`fuzz hot word ${n}`, fields);
}

function randomPrice(d) {
  if (d.chance(3)) return priceVector(formatPrice(d.chance(2) ? d.magnitude(MAX_MID) : MAX_MID - d.between(0n, 3n)));
  const alphabet = d.chance(4) ? '0123456789.+- e_,x' : '0123456789.';
  let text = '';
  for (let i = d.int(0, 40); i > 0; i--) text += alphabet[d.int(0, alphabet.length - 1)];
  return priceVector(text);
}

function randomShapeReject(d, n) {
  for (;;) {
    const sides = [ladder(d), ladder(d)];
    const s = d.int(0, 1);
    const levels = sides[s];
    const fault = d.int(0, 2);
    if (fault === 0) while (levels.length <= 10) levels.push([d.between(1n, MAX_UINT32), 65_535n]);
    if (fault === 1) levels.splice(d.int(0, levels.length), 0, [0n, d.between(0n, MAX_UINT16)]);
    if (fault === 2) {
      if (levels.length === 0 || levels[levels.length - 1][1] === 0n) continue;
      levels.push([d.between(1n, MAX_UINT32), levels[levels.length - 1][1] - d.between(1n, levels[levels.length - 1][1])]);
    }
    return shapeRejectVector(`fuzz shape reject ${n}`, sides[0], sides[1]);
  }
}

function randomPost(d, n) {
  const kind = d.chance(4) ? 'cancels' : 'orders';
  const requests = [];
  // Small pair indices, which the Anvil replay creates, and now and then a pool small enough to repeat one.
  const pool = d.chance(4) ? 3 : 16;
  for (let i = d.chance(20) ? 0 : d.int(1, 6); i > 0; i--) {
    const pairIndex = d.chance(10) ? d.int(0, 65_535) : d.int(0, pool - 1);
    const sequence = d.chance(25) ? d.int(0, 1) : d.chance(4) ? Number(MAX_UINT32) : d.int(2, 1_000_000);
    const mid = d.chance(2) ? d.between(PRICE_ONE / 2n, 2n * PRICE_ONE) : d.magnitude(MAX_MID);
    if (kind === 'cancels') {
      requests.push({ pairIndex, sequence, mid });
      continue;
    }
    const request = { pairIndex, mid, shapeId: d.int(0, 255), sequence, validUntil: d.chance(25) ? Number(MAX_UINT40) + d.int(1, 1_000) : d.int(0, Number(MAX_UINT40)) };
    // Each optional field is present half the time; absent means the default.
    if (d.chance(2)) request.bidWiden = d.int(0, 65_535);
    if (d.chance(2)) request.askWiden = d.int(0, 65_535);
    if (d.chance(2)) request.widthScale = d.int(0, 65_535);
    if (d.chance(2)) request.depthScale = d.int(0, 65_535);
    if (d.chance(2)) request.sides = d.pick(SIDES);
    if (d.chance(2)) request.refill = d.pick(SIDES);
    requests.push(request);
  }
  return postVector(`fuzz post ${n}`, kind, requests);
}

/** One transaction's post calls that collide on purpose: four pairs, sequences 2 to 6, repeats of earlier calls (the
 * same words) and refills, so the stale entries `PostOutcome` must tell from stored ones come up often. */
function randomOutcome(d, n) {
  const calls = [];
  for (let c = d.int(1, 5); c > 0; c--) {
    if (calls.length > 0 && d.chance(4)) {
      calls.push(d.pick(calls));
      continue;
    }
    const kind = d.chance(3) ? 'cancels' : 'orders';
    const pairs = [0, 1, 2, 3].filter(() => d.chance(2));
    if (pairs.length === 0) pairs.push(d.int(0, 3));
    if (d.chance(2)) pairs.reverse();
    const requests = pairs.map((pairIndex) => {
      const sequence = d.int(2, 6);
      const mid = d.chance(2) ? PRICE_ONE : d.between(PRICE_ONE / 2n, 2n * PRICE_ONE);
      if (kind === 'cancels') return { pairIndex, sequence, mid };
      const request = { pairIndex, mid, shapeId: d.int(0, 3), sequence, validUntil: d.int(0, Number(MAX_UINT40)) };
      if (d.chance(3)) request.sides = d.pick(SIDES);
      if (d.chance(3)) request.refill = d.pick(SIDES);
      return request;
    });
    calls.push({ kind, requests });
  }
  return outcomeVector(`fuzz outcome ${n}`, calls);
}

/** A random pair life: shapes, posts with and without refills, sides and depth switched off, expiry, quotes and fills
 * that walk consumption to depth and past it. Fills stay within what the Anvil replay can fund; bigger ones quote. */
function randomQuoteCase(d, n) {
  const sizeUnit = d.pick([1n, 1_000n, EUR, 10n ** 9n, d.magnitude(10n ** 9n)]);
  const maxSize = (() => {
    const m = 10n ** 13n / sizeUnit;
    return m < 1n ? 1n : m > MAX_UINT32 ? MAX_UINT32 : m;
  })();
  const fund = () => (d.chance(5) ? d.between(0n, 10n ** 7n) : d.between(0n, FILL_BUDGET));
  const c = new QuoteCase(`fuzz quotes ${n}`, { sizeUnit, inventory: [fund(), fund()] });
  const shapeIds = [];
  const setShape = () => {
    const shapeId = d.chance(3) && shapeIds.length ? d.pick(shapeIds) : d.int(0, 255);
    c.apply({ op: 'setShape', shapeId, bids: ladder(d, { maxSize }), asks: ladder(d, { maxSize }) });
    if (!shapeIds.includes(shapeId)) shapeIds.push(shapeId);
  };
  setShape();
  let seq = 1n;
  const post = () => {
    seq += d.chance(8) ? 0n : d.chance(10) ? d.between(2n, 1_000n) : 1n;
    if (seq > MAX_UINT32) seq = MAX_UINT32;
    const fields = {
      mid: d.chance(10) ? d.magnitude(10n ** 24n) : d.between(PRICE_ONE / 2n, 2n * PRICE_ONE),
      bidWiden: d.chance(3) ? 0n : d.chance(10) ? d.between(60_000n, MAX_UINT16) : d.between(0n, 500n),
      askWiden: d.chance(3) ? 0n : d.between(0n, 500n),
      widthScale: d.chance(3) ? 1000n : d.between(0n, 3_000n),
      depthScale: d.chance(10) ? 0n : d.chance(4) ? 1000n : d.between(1n, 3_000n),
      shapeId: BigInt(d.chance(6) ? d.int(0, 255) : d.pick(shapeIds)),
      validUntil: d.chance(12) ? d.pick([EXPIRED, QUOTE_TIME - 1n, QUOTE_TIME]) : LIVE,
      seq,
      flags: (d.chance(6) ? d.pick([OFF_FLAGS.bids, OFF_FLAGS.asks, OFF_FLAGS.neither]) : 0n) | (d.chance(3) ? d.pick(Object.values(REFILL_FLAGS)) : 0n),
    };
    c.apply({ op: 'post', fields });
  };
  post();
  for (let step = d.int(8, 16); step > 0; step--) {
    const now = unpackHot(c.state.hot);
    const dead = now.validUntil < QUOTE_TIME || now.depthScale === 0n || now.flags !== 0n;
    if (d.chance(dead ? 2 : 6)) post();
    if (d.chance(12)) setShape();
    const direction = d.pick(DIRS);
    const { baseIn, exactIn } = DIRECTIONS[direction];
    // Scale the amount by what the walked side has left, as a base or a quote amount.
    const hot = unpackHot(c.state.hot);
    const words = c.state.shapes.get(Number(hot.shapeId)) ?? [0n, 0n, 0n, 0n];
    const levels = baseIn ? decodeSide(words[0], words[1]) : decodeSide(words[2], words[3]);
    const left = remainingBook(book(hot, c.state.sizeUnit, baseIn, levels), baseIn ? c.state.consumed.bids : c.state.consumed.asks);
    const leftDepth = totalDepth(left);
    const edge = baseIn === exactIn ? leftDepth : ceilDiv(value(left, leftDepth), VALUE_ONE);
    const roll = d.int(0, 19);
    let amount = roll === 0 ? 0n : roll <= 2 ? d.magnitude(UINT128_MAX) : roll <= 6 ? edge + d.between(0n, 4n) - 2n : d.between(1n, edge > 1n ? edge : 1n);
    if (amount < 0n) amount = 0n;
    if (amount > UINT128_MAX) amount = UINT128_MAX;
    const r = c.peek({ baseIn, exactIn, amount });
    // Fill only under a word live at any clock, so a replay on a local chain fills at whatever time it runs.
    const fillable = !r.error && r.amountIn <= FILL_BUDGET && hot.validUntil === LIVE && !d.chance(3);
    c.apply({ op: fillable ? 'fill' : 'quote', baseIn, exactIn, amount });
  }
  return c.vector();
}

export function fuzzSections(seed, scale = 1) {
  const d = draw(seed);
  const count = (n) => Math.max(1, Math.round(n * scale));
  const vectors = [];
  for (let n = 0; n < count(3000); n++) vectors.push(randomVector(d, n));
  const splits = [];
  for (let n = 0; n < count(60); n++) {
    const sp = randomSplit(d, n, vectors);
    if (sp) splits.push(sp);
  }
  const each = (k, f) => Array.from({ length: count(k) }, (_, n) => f(d, n));
  return {
    postSelector: POST_SELECTOR,
    vectors,
    splits,
    shapeChecks: each(300, randomShapeCheck),
    hotWords: each(600, randomHotWord),
    prices: each(300, randomPrice),
    shapes: each(200, (dd, n) => shapeVector(`fuzz shape ${n}`, ladder(dd), ladder(dd))),
    shapeRejects: each(100, randomShapeReject),
    posts: each(150, randomPost),
    quotes: each(24, randomQuoteCase),
    outcomes: each(60, randomOutcome),
  };
}

const here = dirname(fileURLToPath(import.meta.url));
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i < 0 ? fallback : process.argv[i + 1];
  };
  const seedText = arg('--seed', '0x70726f70616d6d32');
  if (!/^(0x[0-9a-fA-F]{1,16}|[0-9]{1,20})$/.test(seedText)) throw new Error(`--seed must be a 64-bit number: ${seedText}`);
  const seed = BigInt(seedText);
  const scale = Number(arg('--scale', '1'));
  if (!(scale > 0)) throw new Error('--scale must be positive');
  const out = resolve(arg('--out', join(here, 'fuzz', `${hex32(seed).slice(-16)}.json`)));
  const sections = fuzzSections(seed, scale);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, renderVectors(sections, `propAMM v2 random vectors, seed ${seedText}, scale ${scale}, generated by contracts/test/vectors/fuzz.mjs from ladder-reference.mjs.`));
  const sizes = Object.entries(sections)
    .filter(([, v]) => Array.isArray(v))
    .map(([k, v]) => `${v.length} ${k}`);
  console.log(`seed ${seedText}: wrote ${sizes.join(', ')} to ${out}`);
}
