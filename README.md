# break_eternity

Big numbers for idle and incremental games: a faithful Dart port of
break_eternity.js, representing values up to 10^^1e308 with fast,
constant-time arithmetic.

The odd name is inherited on purpose. [break_eternity.js][upstream] is the
de-facto standard for big numbers in incremental games, and its ports keep the
name across ecosystems — `BreakInfinity.cs` for C#, `break-eternity` for Rust,
`break_eternity.gd` for Godot. This is the Dart one.

[upstream]: https://github.com/Patashu/break_eternity.js

[![pub version](https://img.shields.io/pub/v/break_eternity.svg)](https://pub.dev/packages/break_eternity)
[![pub points](https://img.shields.io/pub/points/break_eternity)](https://pub.dev/packages/break_eternity/score)
[![CI](https://img.shields.io/github/actions/workflow/status/maximalcode/break_eternity/ci.yaml?branch=main&label=CI)](https://github.com/maximalcode/break_eternity/actions/workflows/ci.yaml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Why

A Dart `double` carries about 17 significant digits and tops out just under
`1.8e308`. Both limits bite in an incremental game. Integer counting goes wrong
silently past 2^53 — `9007199254740992 + 1` is still `9007199254740992` — and
crossing `1.8e308` is worse than wrong: the value becomes `Infinity`, every
number derived from it turns into `Infinity` or `NaN`, and the player's save is
unrecoverable. A few prestige layers with multiplicative upgrades is all it
takes to get there.

`BigInt` fixes exactness, but at the wrong price. Its cost scales with the size
of the number — a value near 10^100000 is tens of thousands of digits, and every
addition and multiplication walks all of them. A game loop running at 60fps and
touching hundreds of values per tick cannot afford that. `Decimal` instead
stores a `double` mantissa plus a *layer* count, so `1e300` and `10^^1e308` are
both exactly three doubles, and every operation costs the same handful of
floating-point instructions no matter how large the number is. The trade is
explicit: you give up exactness beyond ~17 significant digits — which no idle
game displays anyway — and get effectively unlimited range in return. If you
need exact integers rather than range, use `BigInt`; that is a different
problem and this package does not solve it.

## Install

```console
dart pub add break_eternity
```

```yaml
dependencies:
  break_eternity: ^0.1.0
```

## Quick start

```dart
import 'package:break_eternity/break_eternity.dart';

void main() {
  // `.dec` turns any num into a Decimal.
  final gold = 1e300.dec;
  final multiplier = 1e300.dec;

  // A plain double overflows here; Decimal does not.
  final total = gold * multiplier;
  print(total); // 1e600
  print(total.toDouble()); // Infinity — the double was never big enough

  // Operators take Decimal, so call `.dec` on numeric literals — but note
  // that `5e599` is not a valid double literal, so parse strings that big.
  final afterCosts = total - Decimal.parse('5e599');
  print(afterCosts); // 5e599

  // Comparison, parsing, and round-tripping through a save file.
  final threshold = Decimal.parse('1e500');
  print(afterCosts > threshold); // true
  print(Decimal.parse(afterCosts.toString()) == afterCosts); // true

  // Absurd is fine too: `ee1000` is 10^(10^1000).
  final absurd = Decimal.parse('ee1000');
  print(absurd * absurd); // ee1000.3010299956639813 — squaring barely moves it
}
```

A longer, idle-game-flavoured walkthrough lives in
[`example/break_eternity_example.dart`](example/break_eternity_example.dart).

## API surface

| Area | Members |
| --- | --- |
| Construction | `Decimal.fromNum`, `Decimal.fromComponents`, `Decimal.fromComponentsNoNormalize`, `Decimal.fromMantissaExponent`, `Decimal.parse`, `Decimal.tryParse`, `Decimal.from` |
| Extension | `DecimalNumExtension.dec` — `5.dec`, `1.5.dec` |
| Constants | `zero`, `one`, `negativeOne`, `two`, `ten`, `nan`, `infinity`, `negativeInfinity`, `numberMax`, `numberMin`, `layerSafeMax`, `layerSafeMin`, `layerMax`, `layerMin` |
| Components | `sign`, `layer`, `mag`, `mantissa`, `exponent`, `signum` |
| Predicates | `isNaN`, `isFinite`, `isInfinite`, `isNegative`, `isZero` |
| Arithmetic | `+`, `-` (binary and unary), `*`, `/`, `%`, `abs()`, `reciprocal()` |
| Rounding | `floor()`, `ceil()`, `round()`, `truncate()` |
| Ordering | `<`, `<=`, `>`, `>=`, `==`, `compareTo`, `compareMagnitudeTo`, `max`, `min`, `clamp`, `equalsWithin`, `compareWithin` |
| Logarithms | `log10()`, `absLog10()`, `pLog10()`, `log2()`, `ln()`, `log(base)` |
| Powers and roots | `pow()`, `pow10()`, `powBase()`, `root()`, `sqr()`, `sqrt()`, `cube()`, `cbrt()`, `exp()` |
| Game series helpers | `Decimal.affordGeometricSeries`, `Decimal.sumGeometricSeries`, `Decimal.affordArithmeticSeries`, `Decimal.sumArithmeticSeries`, `Decimal.efficiencyOfPurchase` |
| Conversion | `toDouble()`, `toString()`, `toStringAsFixed()`, `toStringAsExponential()`, `toStringAsPrecision()`, `toJson()` |

### Buying a batch without a loop

The series helpers are the reason a game reaches for this library rather than
just a big-number type. Once the player holds `ee1000` gold, "buy max" cannot be
a purchase loop — there is no integer number of iterations. All five helpers
answer their question in closed form, in constant time, at any scale.

```dart
// Generators cost 10 gold, each one 15% dearer than the last, and you own 42.
final n = Decimal.affordGeometricSeries(1e6.dec, 10.dec, 1.15.dec, 42.dec);
print(n); // 26 — the 43rd generator through the 68th
print(Decimal.sumGeometricSeries(n, 10.dec, 1.15.dec, 42.dec));
// 870433.5234942113, comfortably under the 1e6 available

// Prices that grow by a fixed step instead of a fixed ratio:
print(Decimal.affordArithmeticSeries(1e6.dec, 100.dec, 50.dec, 42.dec)); // 161

// And which of two upgrades is the better deal (lower is better):
print(Decimal.efficiencyOfPurchase(550.dec, 100.dec, 10.dec)); // 60.5
print(Decimal.efficiencyOfPurchase(600.dec, 100.dec, 12.dec)); // 56
```

`currentOwned` is the count you own *now*, not the index of the next purchase:
the first item ever bought costs `priceStart * priceRatio^0`. A `priceRatio` of
exactly 1 gives `NaN` — the formula divides by `log10(1)` — so use the
arithmetic pair, or plain division, for prices that do not grow.

## Status

**Milestones 1 and 2 are implemented.**

- **Milestone 1 — arithmetic and comparison.** Construction, the
  `sign`/`layer`/`mag` normalisation rules, addition, subtraction,
  multiplication, division, modulo, negation, `abs`, `reciprocal`, the rounding
  family, the full ordering and tolerance-comparison surface, and conversion to
  and from `num` and `String`.
- **Milestone 2 — logarithms, powers and the series helpers.** `log10`,
  `absLog10`, `pLog10`, `log2`, `ln` and `log(base)`; `pow`, `pow10`, `powBase`,
  `root`, `sqr`, `sqrt`, `cube`, `cbrt` and `exp`; and the five
  incremental-game series helpers listed in the API table above.

All of it is checked against the JavaScript reference with generated fixtures
(34 operations, over 26,000 cases replayed from break_eternity.js 2.1.3) and
against native `double` arithmetic with an oracle test suite. The whole suite
runs on both the Dart VM and dart2js.

**Not implemented yet.** These are genuinely absent from this release:

- **Tetration and everything above it**: `tetrate`, `slog`, `iteratedexp`,
  `iteratedlog`, `layeradd`, `pentate`, and `lambertw`. The representation
  already reaches 10^^1e308 and `parse` already reads `(e^N)M`, but the
  operations that navigate that space are milestone 3.
- Trigonometry, `factorial` and `gamma`.
- The full `parse` grammar (`^^`, `pentate`, `F` and `PT` notations). Until
  then `parse` accepts exactly the forms `toString` can emit — plain decimals,
  `MeX`, `eX` through five stacked `e`s, `(e^N)M`, `NaN`, `Infinity`,
  `-Infinity` — and throws a `FormatException` on anything else rather than
  guessing.

### Numerical fidelity

Where break_eternity.js calls `Math.log10` or `Math.log2`, this package calls a
software implementation (a port of the same fdlibm routines V8 ships) rather
than `dart:math`. That costs a little speed and buys two things: results are
identical on the VM, dart2js and Wasm, and exact inputs give exact answers —
`1e30.dec.log10()` is exactly 30, and `log2` is exact on every power of two in
the layer-0 range (2^-52 to 2^52), where the one-line spellings available in
`dart:math` are not. Above that range break_eternity.js is inexact itself, and
this port reproduces its answers rather than improving on them.

Two functions deliberately do *not* do this: `ln` and `exp` call `dart:math`'s
`log` and `exp` at layer 0, because that is precisely what the reference does
with `Math.log` and `Math.exp`. They are therefore the host platform's libm, and
their last bit can differ between the VM and the browser. If you need a
reproducible logarithm, use `log10` or `log2`.

Beyond that, this port and break_eternity.js can disagree in the last ulp,
because two different libm implementations are involved. It almost never
matters, with one exception worth knowing: `affordGeometricSeries` applies
`floor` to a ratio of logarithms, so when the money on hand is *exactly* the
price of a whole number of items, an ulp moves the answer by a whole item.
Around 1 exact round trip in 16,000 differs from the JavaScript answer by one.
Do not build game logic that depends on the count at an exact boundary.

## Differences from break_eternity.js

The behaviour is ported faithfully; the shape of the API is not, because the JS
API is not idiomatic Dart.

- **`Decimal` is an immutable value type.** The JS original mutates `this`
  inside `normalize()` and its constructors. Here all three fields are `final`
  and every operation returns a new `Decimal`. Existing values are never
  modified out from under you, so a `Decimal` can be shared, cached, or used as
  a map key without defensive copying.
- **One canonical name per operation.** The JS build ships alias families —
  `plus`/`add`, `times`/`mul`/`multiply`, `dividedBy`/`div`, `cmp`/`compare`.
  This package exposes a single Dart name for each, plus the natural operator.
- **Operators take `Decimal`, not `DecimalSource`.** JS accepts a number, a
  string, or a Decimal anywhere. Dart operators are statically typed, so write
  `gold * 2.dec` rather than `gold * 2`. Use `.dec` on numeric literals,
  `Decimal.parse` on strings, or `Decimal.from` when the input is genuinely
  dynamic.
- **`layer` is a `double`, never an `int`.** It is conceptually a non-negative
  integer, but storing it as a `double` keeps the NaN and Infinity states
  representable and, more importantly, makes results identical on the Dart VM
  and when compiled to JavaScript, where the two numeric types collapse into
  one. An earlier Dart attempt at this problem foundered on exactly that
  divergence, which is why CI runs the whole suite on both platforms.
- **`==` follows IEEE 754 for NaN.** Structural equality over the
  `sign`/`layer`/`mag` triple, except that a NaN `Decimal` is never equal to
  itself — matching `double`, and matching the JS `eq`.

## Credits and licence

This package is a port of
[break_eternity.js](https://github.com/Patashu/break_eternity.js) by
**Patashu**, used and redistributed under the MIT licence. The mathematics, the
normalisation rules, and the algorithm-level behaviour are theirs; any bugs in
the translation are mine.

The Dart port is likewise MIT licensed. See [LICENSE](LICENSE) for the full
text of both notices.
