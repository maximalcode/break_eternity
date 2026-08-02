#!/usr/bin/env node
// Generates the JSON fixtures replayed by `test/fixtures_test.dart`.
//
// Ground truth is the vendored break_eternity.js 2.1.3 UMD bundle in
// `reference/`. Everything here is DETERMINISTIC: the input set comes from a
// hand-written mulberry32 PRNG with fixed seeds, never `Math.random()`, so
// re-running the script reproduces byte-identical fixtures.
//
//   node tool/generate_fixtures.mjs
//
// Output: test/fixtures/<op>.json, shaped as
//
//   {"op": "add", "cases": [{"a": [s,l,m], "b": [s,l,m], "r": [s,l,m]}, ...]}
//
// Components are JSON numbers, except that non-finite doubles are emitted as
// the strings "NaN" / "Infinity" / "-Infinity" (JSON has no literal for them);
// the Dart side decodes those back. Unary ops omit "b". The `cmp` op also
// carries an extra field "c" holding the raw comparison result (-1, 0, 1, or
// the string "NaN" when either operand is NaN) alongside the Decimal form of
// that same value in "r".
//
// The `normalize` op is the odd one out: its "a" is a RAW, possibly invalid
// component triple (built with fromComponents_noNormalize), and "r" is the
// result of normalising it.
//
// N-ARY OPS ("args" shape)
// ------------------------
// The incremental-game series helpers take three or four Decimal arguments, so
// the {a, b} shape does not fit them. Those files instead carry an "args"
// array holding every argument, in the reference's declaration order, and no
// "a"/"b" at all:
//
//   {"op": "efficiencyOfPurchase",
//    "cases": [{"args": [[s,l,m], [s,l,m], [s,l,m]], "r": [s,l,m]}, ...]}
//
// Argument order per op (same as break_eternity.js):
//
//   affordGeometricSeries    [resourcesAvailable, priceStart, priceRatio, currentOwned]
//   sumGeometricSeries       [numItems,           priceStart, priceRatio, currentOwned]
//   affordArithmeticSeries   [resourcesAvailable, priceStart, priceAdd,   currentOwned]
//   sumArithmeticSeries      [numItems,           priceStart, priceAdd,   currentOwned]
//   efficiencyOfPurchase     [cost, currentRpS, deltaRpS]
//
// Every element of "args" is a normalised component triple encoded exactly like
// "a"/"b"/"r" elsewhere in this file.

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

const bundle = require(join(repoRoot, 'reference', 'break_eternity.umd.js'));
const Decimal = bundle.default ?? bundle;

const OUT_DIR = join(repoRoot, 'test', 'fixtures');

// ---------------------------------------------------------------------------
// Deterministic PRNG (mulberry32). Fixed seed in, fixed stream out.
// ---------------------------------------------------------------------------

function mulberry32(seed) {
  let a = seed >>> 0;
  return function next() {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Stable 32-bit hash of a string, so each op gets its own reproducible seed. */
function seedFor(name) {
  let h = 2166136261 >>> 0;
  for (let i = 0; i < name.length; i++) {
    h ^= name.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

// ---------------------------------------------------------------------------
// Boundary constants (mirrors of the reference's internals).
// ---------------------------------------------------------------------------

const EXP_LIMIT = 9e15;
const LAYER_DOWN = Math.log10(9e15); // 15.954589770191003
const FIRST_NEG_LAYER = 1 / 9e15;

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

function enc(x) {
  if (typeof x !== 'number') return String(x);
  if (Number.isNaN(x)) return 'NaN';
  if (x === Infinity) return 'Infinity';
  if (x === -Infinity) return '-Infinity';
  // -0 must survive as a distinguishable value; JSON.stringify(-0) is "0",
  // which is fine: the Dart side treats 0.0 and -0.0 as equal anyway.
  return x;
}

function triple(d) {
  return [enc(d.sign), enc(d.layer), enc(d.mag)];
}

// ---------------------------------------------------------------------------
// Value pool
// ---------------------------------------------------------------------------

const FC = (s, l, m) => Decimal.fromComponents(s, l, m);
const FCNN = (s, l, m) => Decimal.fromComponents_noNormalize(s, l, m);

/**
 * Hand-picked edge cases: signs, zero, the layer boundaries 9e15 / 1/9e15 /
 * 15.954..., double-precision extremes and the non-finite states.
 */
function curatedValues() {
  const fromNumbers = [
    0, 1, -1, 2, -2, 3, 10, -10, 0.5, -0.5, 1.1, -1.1, 0.9, -0.9,
    123.456, -123.456, 1e-7, 1e-15, 1e15, 1e21, 1e-21,
    EXP_LIMIT, -EXP_LIMIT, EXP_LIMIT - 1, EXP_LIMIT + 2,
    FIRST_NEG_LAYER, -FIRST_NEG_LAYER, FIRST_NEG_LAYER * 2,
    LAYER_DOWN, -LAYER_DOWN, 15.954, 15.955, 16,
    Number.MAX_VALUE, -Number.MAX_VALUE, Number.MIN_VALUE, 1e-323,
    1e308, 1e-308, Infinity, -Infinity, NaN,
  ].map((n) => new Decimal(n));

  const fromComponents = [];
  for (const sign of [1, -1]) {
    for (const layer of [1, 2, 3, 4, 5, 6]) {
      for (const mag of [
        LAYER_DOWN, LAYER_DOWN + 1e-9, 16, 17.5, 100, 1e3, 1e8,
        EXP_LIMIT - 1, EXP_LIMIT, -LAYER_DOWN, -16, -100,
      ]) {
        fromComponents.push(FC(sign, layer, mag));
      }
    }
  }

  return [...fromNumbers, ...fromComponents];
}

/** One pseudo-random Decimal spanning layers 0..6 and both signs. */
function randomValue(rng) {
  const roll = rng();

  // ~6% special states.
  if (roll < 0.02) return new Decimal(0);
  if (roll < 0.03) return new Decimal(rng() < 0.5 ? Infinity : -Infinity);
  if (roll < 0.04) return new Decimal(NaN);
  if (roll < 0.06) {
    // Values sitting right on a normalisation boundary.
    const bases = [EXP_LIMIT, FIRST_NEG_LAYER, LAYER_DOWN, 9e15 - 1];
    const b = bases[Math.floor(rng() * bases.length)];
    return FC(rng() < 0.5 ? 1 : -1, Math.floor(rng() * 4), b);
  }

  const sign = rng() < 0.5 ? 1 : -1;
  const layer = Math.floor(rng() * 7); // 0..6

  if (layer === 0) {
    // Log-uniform over the whole layer-0 window, plus a slice of small ints.
    if (rng() < 0.25) {
      return new Decimal(sign * Math.floor(rng() * 1000 + 1));
    }
    const exp = (rng() * 2 - 1) * 15.9;
    return new Decimal(sign * Math.pow(10, exp));
  }

  // Layer >= 1: mag lives in [15.954, 9e15). Sample log-uniformly over that
  // range so every decade of the exponent tower is represented, and
  // occasionally use a negative mag (which normalises the layer back down).
  const lo = Math.log10(LAYER_DOWN);
  const hi = Math.log10(EXP_LIMIT);
  let mag = Math.pow(10, lo + rng() * (hi - lo));
  if (rng() < 0.08) mag = -mag;
  return FC(sign, layer, mag);
}

function buildPool(seed, count) {
  const rng = mulberry32(seed);
  const pool = curatedValues();
  for (let i = 0; i < count; i++) pool.push(randomValue(rng));
  return pool;
}

// The shared pool every op samples from.
const POOL = buildPool(seedFor('pool'), 600);

// ---------------------------------------------------------------------------
// Case generation
// ---------------------------------------------------------------------------

const CURATED = curatedValues();

function unaryCases(op, fn, count) {
  const rng = mulberry32(seedFor(op));
  const cases = [];

  // Every curated value first, so the edge cases are always present.
  for (const a of CURATED) {
    cases.push({ a: triple(a), r: triple(fn(a)) });
  }
  for (let i = 0; i < count; i++) {
    const a = POOL[Math.floor(rng() * POOL.length)];
    cases.push({ a: triple(a), r: triple(fn(a)) });
  }
  return cases;
}

/**
 * Enumerates the (a, b) pairs a binary op is evaluated over: a strided
 * curated x curated cross-section followed by `count` seeded random pairs.
 * `emit(a, b)` fills in the result fields of each case.
 */
function binaryCases(op, emit, count) {
  const rng = mulberry32(seedFor(op));
  const cases = [];

  // A curated x curated cross-section (strided so the file stays a sane size).
  const stride = 53;
  for (let i = 0; i < CURATED.length; i++) {
    for (let j = (i * 3) % stride; j < CURATED.length; j += stride) {
      const a = CURATED[i];
      const b = CURATED[j];
      cases.push({ a: triple(a), b: triple(b), ...emit(a, b) });
    }
  }
  for (let i = 0; i < count; i++) {
    // Bias a third of the pairs towards "one curated, one random" so that
    // mixed-magnitude short-circuits get exercised too.
    const a = rng() < 0.33
      ? CURATED[Math.floor(rng() * CURATED.length)]
      : POOL[Math.floor(rng() * POOL.length)];
    const b = rng() < 0.33
      ? CURATED[Math.floor(rng() * CURATED.length)]
      : POOL[Math.floor(rng() * POOL.length)];
    cases.push({ a: triple(a), b: triple(b), ...emit(a, b) });
  }
  return cases;
}

/**
 * `normalize` is special: the input is a RAW (possibly invalid) component
 * triple, not a normalised Decimal, so it is built with
 * fromComponents_noNormalize and then normalised.
 */
function normalizeCases(count) {
  const rng = mulberry32(seedFor('normalize'));
  const cases = [];

  const rawCurated = [];
  const signs = [0, 1, -1];
  const layers = [0, 1, 2, 3, 4, 5, 6];
  const mags = [
    0, -0, 1, -1, 15.954, LAYER_DOWN, -LAYER_DOWN, 15.5, -15.5, 16, -16,
    EXP_LIMIT, -EXP_LIMIT, EXP_LIMIT - 1, EXP_LIMIT + 1e3, 1e17, -1e17,
    FIRST_NEG_LAYER, -FIRST_NEG_LAYER, FIRST_NEG_LAYER / 2, 1e-20, -1e-20,
    1e300, 1e-300, Infinity, -Infinity, NaN, 100, -100, 0.5, -0.5,
  ];
  for (const s of signs) {
    for (const l of layers) {
      for (const m of mags) rawCurated.push([s, l, m]);
    }
  }
  // A few explicitly non-finite / degenerate layers.
  for (const l of [Infinity, -Infinity, NaN]) {
    for (const m of [1, -1, 16, Infinity, NaN]) {
      rawCurated.push([1, l, m]);
      rawCurated.push([-1, l, m]);
    }
  }

  for (const [s, l, m] of rawCurated) {
    cases.push({ a: [enc(s), enc(l), enc(m)], r: triple(FCNN(s, l, m).normalize()) });
  }

  for (let i = 0; i < count; i++) {
    const s = signs[Math.floor(rng() * signs.length)];
    const l = Math.floor(rng() * 8);
    let m;
    const roll = rng();
    if (roll < 0.15) {
      m = mags[Math.floor(rng() * mags.length)];
    } else if (roll < 0.3) {
      // Just around the layer-up / layer-down thresholds.
      const base = rng() < 0.5 ? EXP_LIMIT : LAYER_DOWN;
      m = base * (1 + (rng() - 0.5) * 1e-3);
    } else {
      m = Math.pow(10, (rng() * 2 - 1) * 20) * (rng() < 0.5 ? 1 : -1);
    }
    cases.push({ a: [enc(s), enc(l), enc(m)], r: triple(FCNN(s, l, m).normalize()) });
  }

  return cases;
}

// ---------------------------------------------------------------------------
// Milestone 2: value pools for logarithms, powers, roots and the series
// helpers.
//
// The milestone-1 pool above is deliberately left untouched — its exact
// contents are baked into the already-committed fixtures. Everything below adds
// *new* pools that only the milestone-2 ops draw from.
// ---------------------------------------------------------------------------

/**
 * Values that matter to logs / powers specifically: the neighbourhood of 1
 * (where log changes sign and loses precision), e and the base-conversion
 * constants the reference hard-codes, exact powers of two and ten, and a few
 * high-layer towers.
 */
function powerCuratedValues() {
  const fromNumbers = [
    Math.E, 1 / Math.E, Math.E * Math.E, Math.LN10, Math.LN2, Math.SQRT2,
    2, 4, 8, 16, 32, 1024, 0.1, 0.01, 0.25, 0.125,
    1 - 1e-16, 1 + 1e-16, 1 - 1e-9, 1 + 1e-9, 0.999999999, 1.000000001,
    1e-5, 1e5, 1e100, 1e-100, 1e300, 1e-300, 709.7, 709.8, 710,
    // The magic constants baked into log2/ln/sqrt in the reference.
    3.321928094887362, 0.5213902276543247, 2.302585092994046,
    0.36221568869946325, 0.4342944819032518, 0.3010299956639812,
    -Math.E, -2, -4, -0.1, -1e100, -1e-100,
  ].map((n) => new Decimal(n));

  const fromComponents = [];
  for (const sign of [1, -1]) {
    for (const layer of [1, 2, 3, 4, 10]) {
      for (const mag of [
        LAYER_DOWN, 16, 20, 100, 1e6, 1e15, EXP_LIMIT - 1, -16, -100, -1e6,
      ]) {
        fromComponents.push(FC(sign, layer, mag));
      }
    }
  }

  return [...fromNumbers, ...fromComponents];
}

const POWER_CURATED = powerCuratedValues();

/** Curated inputs shared by every milestone-2 unary op. */
const M2_VALUES = [...CURATED, ...POWER_CURATED];

/** Random-draw pool shared by every milestone-2 op. */
const M2_POOL = [...POOL, ...POWER_CURATED];

/**
 * The *exponent* side of pow / root / powBase. Random layer-6 monsters make
 * every result overflow to infinity, so exponents get their own pool: small
 * integers (odd and even, which decide the sign of a negative base raised to
 * them), simple fractions, the layer boundaries, and only a handful of towers.
 */
function exponentValues() {
  const fromNumbers = [
    0, 1, -1, 2, -2, 3, -3, 4, -4, 5, 6, 7, 8, 10, -10, 100, -100,
    0.5, -0.5, 1 / 3, -1 / 3, 2 / 3, 1.5, -1.5, 2.5, 3.5, 0.1, -0.1,
    1e3, 1e6, 1e15, EXP_LIMIT, EXP_LIMIT + 2, 1e16, -1e15, 1e-3, 1e-15,
    FIRST_NEG_LAYER, LAYER_DOWN, -LAYER_DOWN,
    Infinity, -Infinity, NaN,
  ].map((n) => new Decimal(n));

  const fromComponents = [];
  for (const sign of [1, -1]) {
    for (const layer of [1, 2, 3]) {
      for (const mag of [16, 20, 100, 1e6, -20]) {
        fromComponents.push(FC(sign, layer, mag));
      }
    }
  }

  return [...fromNumbers, ...fromComponents];
}

const EXPONENTS = exponentValues();

/**
 * The *base* side of log(value, base). Base 1 and any nonpositive base are NaN
 * in the reference, and bases barely above 1 are the numerically delicate ones.
 */
function logBaseValues() {
  const fromNumbers = [
    0, 1, -1, -2, 2, 3, Math.E, 10, 100, 1e6, 1e15, 1e16, 1e100, 1e308,
    0.5, 0.1, 1e-6, 1e-100, 1 + 1e-9, 1 - 1e-9, 1.0000001, 0.9999999,
    Infinity, -Infinity, NaN,
  ].map((n) => new Decimal(n));

  const fromComponents = [];
  for (const sign of [1, -1]) {
    for (const layer of [1, 2, 3]) {
      for (const mag of [16, 100, 1e6, -100]) {
        fromComponents.push(FC(sign, layer, mag));
      }
    }
  }

  return [...fromNumbers, ...fromComponents];
}

const LOG_BASES = logBaseValues();

/** Every curated value, then `count` seeded draws from `pool`. */
function unaryCasesOver(op, fn, values, pool, count) {
  const rng = mulberry32(seedFor(op));
  const cases = [];
  for (const a of values) {
    cases.push({ a: triple(a), r: triple(fn(a)) });
  }
  for (let i = 0; i < count; i++) {
    const a = pool[Math.floor(rng() * pool.length)];
    cases.push({ a: triple(a), r: triple(fn(a)) });
  }
  return cases;
}

/**
 * Binary cases where the two operands come from *different* pools (a value and
 * an exponent, or a value and a logarithm base). Mirrors `binaryCases`: a
 * strided cross-section of the curated lists, then seeded random pairs.
 */
function binaryCasesOver(op, fn, aValues, aPool, bValues, bPool, count) {
  const rng = mulberry32(seedFor(op));
  const cases = [];

  const stride = 17;
  for (let i = 0; i < aValues.length; i++) {
    for (let j = (i * 5) % stride; j < bValues.length; j += stride) {
      const a = aValues[i];
      const b = bValues[j];
      cases.push({ a: triple(a), b: triple(b), r: triple(fn(a, b)) });
    }
  }

  for (let i = 0; i < count; i++) {
    const a = rng() < 0.4
      ? aValues[Math.floor(rng() * aValues.length)]
      : aPool[Math.floor(rng() * aPool.length)];
    const b = rng() < 0.6
      ? bValues[Math.floor(rng() * bValues.length)]
      : bPool[Math.floor(rng() * bPool.length)];
    cases.push({ a: triple(a), b: triple(b), r: triple(fn(a, b)) });
  }

  return cases;
}

// ---------------------------------------------------------------------------
// Milestone 2: the incremental-game series helpers (n-ary, "args" shape).
// ---------------------------------------------------------------------------

const D_ = (n) => new Decimal(n);

/** Money-ish amounts: what a save file actually holds. */
const RESOURCES = [
  0, 1, 10, 100, 1e3, 1e6, 1e9, 1e12, 1e15, 1e18, 1e30, 1e100, 1e308,
  0.5, 1e-6, -1, -1e6, Infinity, NaN,
].map(D_).concat([
  FC(1, 1, 20), FC(1, 1, 1e3), FC(1, 2, 20), FC(1, 3, 100), FC(-1, 1, 20),
]);

/** Opening price of the first unit. */
const PRICE_STARTS = [
  1, 2, 10, 15, 100, 1e3, 1e6, 1e15, 1e100, 0.5, 0, -10, Infinity, NaN,
].map(D_).concat([FC(1, 1, 20), FC(1, 2, 20)]);

/**
 * Cost multiplier per purchase. 1 exactly makes the closed form divide by
 * `log10(1) == 0`; ratios a hair above 1 are where the geometric series is
 * numerically delicate; ratios below 1 make the cost *fall*.
 */
const PRICE_RATIOS = [
  1, 1.0000001, 1 + 1e-12, 1.00001, 1.01, 1.07, 1.1, 1.15, 1.5, 2, 3, 10,
  1e3, 1e15, 1e100, 0.5, 0.9999999, 0.9, 0, -2, Infinity, NaN,
].map(D_).concat([FC(1, 1, 20), FC(1, 2, 20)]);

/** Cost increment per purchase, for the arithmetic series. */
const PRICE_ADDS = [
  0, 1, 2, 10, 100, 1e3, 1e6, 1e15, 1e100, -5, 0.5, 1e-9, Infinity, NaN,
].map(D_).concat([FC(1, 1, 20), FC(1, 2, 20)]);

/** How many you already own — often huge in a long-running save. */
const CURRENT_OWNED = [
  0, 1, 2, 10, 100, 1e3, 1e6, 1e15, 1e100, -1, -10, 0.5, NaN,
].map(D_).concat([FC(1, 1, 20), FC(1, 2, 20)]);

/** How many you are asking to buy. */
const NUM_ITEMS = [
  0, 1, 2, 10, 100, 1e3, 1e6, 1e15, 1e100, -1, 0.5, 1e-6, Infinity, NaN,
].map(D_).concat([FC(1, 1, 20), FC(1, 2, 20)]);

/** Production rates for efficiencyOfPurchase. */
const RATES = [
  0, 1, 10, 1e3, 1e6, 1e15, 1e100, 0.5, 1e-6, -1, -1e6, Infinity, NaN,
].map(D_).concat([FC(1, 1, 20), FC(1, 2, 20), FC(-1, 1, 20)]);

function gcd(a, b) {
  while (b !== 0) [a, b] = [b, a % b];
  return a;
}

/**
 * A stride that walks every element of a `len`-long list exactly once per
 * `len` steps (i.e. coprime with `len`), starting from the hint.
 */
function coprimeStride(len, hint) {
  let s = ((hint % len) + len) % len;
  if (s === 0) s = 1;
  for (let i = 0; i < len; i++) {
    const candidate = ((s + i - 1) % len) + 1;
    if (gcd(candidate, len) === 1) return candidate;
  }
  return 1;
}

/**
 * Enumerates argument tuples for an n-ary op. Each parameter walks its own pool
 * with a coprime stride, so `sweep` steps cover every value of every pool many
 * times over while never repeating the same combination early; then `count`
 * seeded random tuples are appended, occasionally reaching into the general
 * Decimal pool for genuinely adversarial inputs.
 */
function naryCases(op, fn, pools, sweep, count, focus = []) {
  const rng = mulberry32(seedFor(op));
  const cases = [];
  const push = (args) => {
    cases.push({ args: args.map(triple), r: triple(fn(...args)) });
  };

  for (const args of focus) push(args);

  const strides = pools.map((p, k) => coprimeStride(p.length, 1 + k * 4));
  for (let i = 0; i < sweep; i++) {
    push(pools.map((p, k) => p[(i * strides[k]) % p.length]));
  }

  for (let i = 0; i < count; i++) {
    push(pools.map((p) => (rng() < 0.9
      ? p[Math.floor(rng() * p.length)]
      : M2_POOL[Math.floor(rng() * M2_POOL.length)])));
  }

  return cases;
}

/**
 * The geometric helpers are at their most fragile when priceRatio sits on or
 * next to 1, so those ratios are crossed exhaustively with a handful of
 * plausible (amount, priceStart, currentOwned) triples rather than being left
 * to the sweep.
 */
function geometricFocus() {
  const ratios = [1, 1.0000001, 1 + 1e-12, 1 + 1e-15, 0.9999999, 1.07].map(D_);
  const rest = [
    [D_(0), D_(10), D_(0)],
    [D_(1), D_(10), D_(0)],
    [D_(1e6), D_(10), D_(0)],
    [D_(1e100), D_(10), D_(1e15)],
    [D_(1e308), D_(1e100), D_(1e100)],
    [FC(1, 1, 20), D_(10), FC(1, 1, 20)],
    [D_(-100), D_(10), D_(5)],
    [D_(1e15), D_(0.5), D_(1e6)],
  ];
  const out = [];
  for (const r of ratios) {
    for (const [amount, start, owned] of rest) {
      out.push([amount, start, r, owned]);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Ops
// ---------------------------------------------------------------------------

const N = 350; // random cases per op, on top of the curated ones

const UNARY = {
  neg: (a) => a.neg(),
  abs: (a) => a.abs(),
  recip: (a) => a.recip(),
  floor: (a) => a.floor(),
  ceil: (a) => a.ceil(),
  round: (a) => a.round(),
  trunc: (a) => a.trunc(),
};

const BINARY = {
  add: (a, b) => a.add(b),
  sub: (a, b) => a.sub(b),
  mul: (a, b) => a.mul(b),
  div: (a, b) => a.div(b),
  mod: (a, b) => a.mod(b),
};

// --- Milestone 2 -----------------------------------------------------------

/** Unary logs, powers and roots. Same {a, r} shape as the milestone-1 unaries. */
const M2_UNARY = {
  log10: (a) => a.log10(),
  absLog10: (a) => a.absLog10(),
  pLog10: (a) => a.pLog10(),
  log2: (a) => a.log2(),
  ln: (a) => a.ln(),
  // pow10 is the inverse of log10 and the step every power and root lands on,
  // so it gets its own file rather than being covered only through `pow`: the
  // exact-power-of-ten lookup table is on this path and nowhere else.
  pow10: (a) => a.pow10(),
  sqr: (a) => a.sqr(),
  cube: (a) => a.cube(),
  sqrt: (a) => a.sqrt(),
  cbrt: (a) => a.cbrt(),
  exp: (a) => a.exp(),
};

/**
 * Binary logs, powers and roots. Each entry names the pool the *second* operand
 * is drawn from, because a uniformly random layer-6 exponent would send nearly
 * every result to infinity.
 *
 * `powBase` is the reference's `pow_base`: `a.powBase(b)` is b^a, so `a` is the
 * exponent and `b` is the base — the pools are swapped accordingly.
 */
const M2_BINARY = {
  log: { fn: (a, b) => a.log(b), aValues: M2_VALUES, bValues: LOG_BASES },
  pow: { fn: (a, b) => a.pow(b), aValues: M2_VALUES, bValues: EXPONENTS },
  root: { fn: (a, b) => a.root(b), aValues: M2_VALUES, bValues: EXPONENTS },
  powBase: {
    fn: (a, b) => a.pow_base(b),
    aValues: EXPONENTS,
    bValues: M2_VALUES,
    aPool: EXPONENTS,
    bPool: M2_POOL,
  },
};

/**
 * The series helpers, in the reference's argument order. `pools[k]` is the pool
 * argument k is drawn from; see the "args" documentation at the top of the file.
 */
const M2_SERIES = {
  affordGeometricSeries: {
    fn: (r, s, ratio, owned) => Decimal.affordGeometricSeries(r, s, ratio, owned),
    pools: [RESOURCES, PRICE_STARTS, PRICE_RATIOS, CURRENT_OWNED],
    focus: geometricFocus(),
  },
  sumGeometricSeries: {
    fn: (n, s, ratio, owned) => Decimal.sumGeometricSeries(n, s, ratio, owned),
    pools: [NUM_ITEMS, PRICE_STARTS, PRICE_RATIOS, CURRENT_OWNED],
    focus: geometricFocus(),
  },
  affordArithmeticSeries: {
    fn: (r, s, add, owned) => Decimal.affordArithmeticSeries(r, s, add, owned),
    pools: [RESOURCES, PRICE_STARTS, PRICE_ADDS, CURRENT_OWNED],
  },
  sumArithmeticSeries: {
    fn: (n, s, add, owned) => Decimal.sumArithmeticSeries(n, s, add, owned),
    pools: [NUM_ITEMS, PRICE_STARTS, PRICE_ADDS, CURRENT_OWNED],
  },
  efficiencyOfPurchase: {
    fn: (cost, rps, delta) => Decimal.efficiencyOfPurchase(cost, rps, delta),
    pools: [RESOURCES, RATES, RATES],
  },
};

function write(op, cases) {
  const body = cases
    .map((c) => {
      const parts = [];
      if (c.args) parts.push(`"args":${JSON.stringify(c.args)}`);
      else parts.push(`"a":${JSON.stringify(c.a)}`);
      if (c.b) parts.push(`"b":${JSON.stringify(c.b)}`);
      parts.push(`"r":${JSON.stringify(c.r)}`);
      if (c.c !== undefined) parts.push(`"c":${JSON.stringify(enc(c.c))}`);
      return `    {${parts.join(',')}}`;
    })
    .join(',\n');
  const json = `{\n  "op": ${JSON.stringify(op)},\n  "cases": [\n${body}\n  ]\n}\n`;
  writeFileSync(join(OUT_DIR, `${op}.json`), json);
  return cases.length;
}

function main() {
  mkdirSync(OUT_DIR, { recursive: true });
  const counts = {};

  for (const [op, fn] of Object.entries(UNARY)) {
    counts[op] = write(op, unaryCases(op, fn, N));
  }
  for (const [op, fn] of Object.entries(BINARY)) {
    counts[op] = write(op, binaryCases(op, (a, b) => ({ r: triple(fn(a, b)) }), N));
  }

  // cmp yields an integer (or NaN when a NaN operand is involved). It is
  // written both as "c" and, for loaders that only understand triples, as the
  // Decimal form of that same value in "r".
  counts.cmp = write('cmp', binaryCases('cmp', (a, b) => {
    const c = a.cmp(b);
    return { r: triple(new Decimal(c)), c };
  }, N));

  counts.normalize = write('normalize', normalizeCases(N));

  // --- Milestone 2 ---------------------------------------------------------

  for (const [op, fn] of Object.entries(M2_UNARY)) {
    counts[op] = write(op, unaryCasesOver(op, fn, M2_VALUES, M2_POOL, N));
  }

  for (const [op, spec] of Object.entries(M2_BINARY)) {
    counts[op] = write(op, binaryCasesOver(
      op,
      spec.fn,
      spec.aValues,
      spec.aPool ?? M2_POOL,
      spec.bValues,
      spec.bPool ?? spec.bValues,
      N,
    ));
  }

  for (const [op, spec] of Object.entries(M2_SERIES)) {
    counts[op] = write(
      op,
      naryCases(op, spec.fn, spec.pools, 220, 180, spec.focus ?? []),
    );
  }

  const width = Math.max(...Object.keys(counts).map((k) => k.length));
  for (const op of Object.keys(counts).sort()) {
    process.stdout.write(`${op.padEnd(width)} ${counts[op]}\n`);
  }
}

main();
