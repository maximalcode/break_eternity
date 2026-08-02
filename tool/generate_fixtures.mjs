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

function write(op, cases) {
  const body = cases
    .map((c) => {
      const parts = [`"a":${JSON.stringify(c.a)}`];
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

  for (const op of Object.keys(counts).sort()) {
    process.stdout.write(`${op.padEnd(10)} ${counts[op]}\n`);
  }
}

main();
