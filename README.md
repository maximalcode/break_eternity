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
| Predicates | `isNaN`, `isFinite`, `isInfinite`, `isNegative`, `isZero`, `isInteger` |
| Arithmetic | `+`, `-` (binary and unary), `*`, `/`, `~/`, `%`, `mod()`, `abs()`, `reciprocal()` |
| Rounding | `floor()`, `ceil()`, `round()`, `truncate()` |
| Ordering | `<`, `<=`, `>`, `>=`, `==`, `compareTo`, `compareMagnitudeTo`, `max`, `min`, `clamp`, `equalsWithin`, `compareWithin` |
| Logarithms | `log10()`, `absLog10()`, `pLog10()`, `log2()`, `ln()`, `log(base)` |
| Powers and roots | `pow()`, `pow10()`, `powBase()`, `root()`, `sqr()`, `sqrt()`, `cube()`, `cbrt()`, `exp()` |
| Tetration | `tetrate()`, `iteratedExp()`, `iteratedLog()`, `slog()`, `layerAdd()`, `layerAdd10()`, `lambertW()` |
| Pentation | `pentate()`, `pentaLog()` |
| Game series helpers | `Decimal.affordGeometricSeries`, `Decimal.sumGeometricSeries`, `Decimal.affordArithmeticSeries`, `Decimal.sumArithmeticSeries`, `Decimal.efficiencyOfPurchase` |
| Conversion | `toDouble()`, `toInt()`, `toIntOrNull()`, `toIntClamped()`, `toBigInt()`, `toString()`, `toStringAsFixed()`, `toStringAsExponential()`, `toStringAsPrecision()`, `toJson()` |

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

**Milestones 1 to 3 are implemented.**

- **Milestone 1 — arithmetic and comparison.** Construction, the
  `sign`/`layer`/`mag` normalisation rules, addition, subtraction,
  multiplication, division, modulo, negation, `abs`, `reciprocal`, the rounding
  family, the full ordering and tolerance-comparison surface, and conversion to
  and from `num` and `String`.
- **Milestone 2 — logarithms, powers and the series helpers.** `log10`,
  `absLog10`, `pLog10`, `log2`, `ln` and `log(base)`; `pow`, `pow10`, `powBase`,
  `root`, `sqr`, `sqrt`, `cube`, `cbrt` and `exp`; and the five
  incremental-game series helpers listed in the API table above.
- **Milestone 3 — tetration and above.** `tetrate` and `iteratedExp`, their
  inverses `slog` and `iteratedLog`, the fractional-layer shifts `layerAdd` and
  `layerAdd10`, `lambertW` on both real branches, and `pentate` with `pentaLog`.
  Plus the full `parse` grammar (see below).

All of it is checked against the JavaScript reference with generated fixtures
(44 operations, over 32,000 cases replayed from break_eternity.js 2.1.3) and
against native `double` arithmetic with an oracle test suite. The whole suite
runs on both the Dart VM and dart2js.

**Not implemented yet.** These are genuinely absent from this release:

- The super-root family — `ssqrt`, `linearSroot` and `linearPentaRoot` — which
  ask "what number, tetrated to height n, gives this?" `slog` answers the other
  inverse question (what height), and is the one an idle game actually needs.
- Trigonometry, `factorial` and `gamma`.

### Reading and writing numbers

`toString` emits plain decimals, `MeX`, `eX` through five stacked `e`s, and
`(e^N)M`, plus `NaN`, `Infinity` and `-Infinity`. `parse` reads all of those
back and rather more besides:

```dart
Decimal.parse('1e400');      // an exponent no double can hold
Decimal.parse('2e3e4');      // 2e30000 — stacked exponents
Decimal.parse('(e^7)16.5');  // the layer form, fractional N included
Decimal.parse('10^3');       // a power
Decimal.parse('10^^3');      // a tetration, 10^10^10
Decimal.parse('10^^3;5');    // ...with 5 at the top of the tower
Decimal.parse('2^^^3');      // a pentation
Decimal.parse('3pt5');       // the PT/P shorthand: 10^^3 with 5 on top
Decimal.parse('5f3');        // the F shorthand, payload first
Decimal.parse('1,000,000');  // thousands separators are ignored
```

Anything else raises a `FormatException` (or gives `null` from `tryParse`)
rather than guessing. That is stricter than break_eternity.js in two places,
both of which are silent save-file corruption over there: JavaScript's
`parseFloat` stops at the first character it cannot use, so the reference reads
`5 apples` as `5` and `garbagee5` as `1e5`; and it strips only the *first*
thousands separator, so it reads `1,000,000` as `1000`.

### Numerical fidelity

Where break_eternity.js calls `Math.log10` or `Math.log2`, this package calls a
software implementation (a port of the same fdlibm routines V8 ships) rather
than `dart:math`. That costs a little speed and buys two things: results are
identical on the VM, dart2js and Wasm, and exact inputs give exact answers —
`1e30.dec.log10()` is exactly 30, and `log2` is exact on every power of two in
the layer-0 range (2^-52 to 2^52), where the one-line spellings available in
`dart:math` are not. Above that range break_eternity.js is inexact itself, and
this port reproduces its answers rather than improving on them.

Three primitives deliberately do *not* do this, because the reference uses
their JavaScript equivalents directly: `ln` and `exp` call `dart:math`'s `log`
and `exp` at layer 0, and `pow` — with `sqr`, `cube`, `root`, `sqrt`, `cbrt`
and the series helpers that build on it — reaches `math.pow` whenever a result
lands back at layer 0 with a fractional exponent.

Those are the host platform's, and their last bit is not portable. ECMAScript
explicitly leaves `Math.pow`'s accuracy implementation-defined, and it really
does vary: compiled to JavaScript, `7.dec.sqr()` is `48.99999999999999` on
macOS/arm64 and exactly `49` on Linux/x64. The same is true of the original
break_eternity.js, so this is faithfulness rather than a regression — but do
not write a test that pins the last digit of anything that goes through `pow`,
and do not assume a save file's last ulp survives a move between architectures.
If you need a reproducible logarithm, use `log10` or `log2`.

Beyond that, this port and break_eternity.js can disagree in the last ulp,
because two different libm implementations are involved. It almost never
matters, with one exception worth knowing: `affordGeometricSeries` applies
`floor` to a ratio of logarithms, so when the money on hand is *exactly* the
price of a whole number of items, an ulp moves the answer by a whole item.
Around 1 exact round trip in 16,000 differs from the JavaScript answer by one.
Do not build game logic that depends on the count at an exact boundary.

### Do not `floor` a `pow`

The rule above has a sharp edge that is worth stating on its own, because it
bites in ordinary game code rather than in tests.

`pow` is computed in log space, as `10^(log10(a) * b)`. That is what lets it
reach magnitudes a `double` cannot name, and it means the result is *not exact
even when the true answer is an integer*:

```dart
2.dec.pow(3.dec);   // 7.999999999999999   — not 8
2.dec.pow(12.dec);  // 4095.999999999998   — not 4096
7.dec.sqr();        // 48.99999999999999   — not 49
64.dec.cbrt();      // 3.999999999999999   — not 4
```

93 of the 132 integer powers with base 2–12 and exponent 1–12 come out low.
On its own this is harmless — the error is one ulp, and every comparison and
display path absorbs it. Applying `floor` does not:

```dart
2.dec.pow(3.dec).floor();  // 7, not 8
```

That is a whole unit, and it is exactly what a cost table, a threshold ladder
or an XP curve does. A curve of the common shape `floor(base * k^(n/d))` lands
on an *exact integer* every time `d` divides `n`, so `floor` sits precisely on
the boundary and one ulp low drops it by one — silently, and cumulatively if
the terms are summed. Porting one real game's level curve to `Decimal` this way
made it disagree at 76 of 119 levels.

If you need an exact integer power, compute it in `int` (or `BigInt`) while the
values still fit, and switch to `Decimal` above that. If you need a *threshold*,
compare against the unfloored value rather than flooring it. `round()` is not a
fix: it moves the failure to the halfway points instead of the integers.

`/` is inexact for a related reason — it is implemented as `a * b.reciprocal()`,
so it is not correctly rounded. 9,104 of the 40,000 quotients with both operands
in 1–200 differ from IEEE division, and `3.dec / 5.dec` is `0.6000000000000001`.

That one is far less dangerous in practice, and the distinction is worth
understanding rather than memorising. `floor(pow(...))` fails because the true
answer *is* an exact integer, so `floor` is balanced on the boundary and any
error at all decides it. A percentage applied to a quantity almost never lands
exactly on an integer, so the same one-ulp error is absorbed harmlessly. The
common basis-point idiom is exact for that reason: across 344,229 combinations
of `x` and `bp`, and again at operands near 1e9,

```dart
(x.dec * (10000 + bp).dec / 10000.dec).floor()
```

reproduced the integer `x * (10000 + bp) ~/ 10000` every single time. The rule
is not "avoid division" — it is **be careful wherever `floor` can sit on an
exact boundary**, which is the defining property of a power, not of a
percentage.

**All of this is faithful to break_eternity.js**, which produces bit-identical
answers — including the same 9,104 divergent quotients. It is the price of a
representation that reaches 10^^1e308, not a defect in the port, and
`test/precision_test.dart` pins it so that it cannot be "fixed" by accident.

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
- **`<=` and `>=` follow IEEE 754 too.** The JS build defines `lte` as `!gt`
  and `gte` as `!lt`, so over there a NaN is reported as *both* "less than or
  equal to" and "greater than or equal to" everything. Here every comparison
  against NaN is false, as it is for `double`. The handful of places inside
  tetration where the reference's answer depends on the difference reproduce it
  deliberately, so the results still match.
- **Heights and iteration counts are `num`, not `Decimal`.** `tetrate`,
  `pentate`, `iteratedLog` and `layerAdd` take a plain number for the height,
  exactly as the JS original does — a tower taller than 1.8e308 is not
  representable anyway. Payloads and bases are `Decimal`.
- **There are `int` conversions and a `~/` operator, which the reference has
  no need for.** JavaScript has one numeric type; Dart has two, and real code
  needs a genuine `int` for list indices, RNG bounds, `Duration` and database
  columns. See below.

### Getting an `int` back out

`toInt()` truncates toward zero, like `int` and `double` do, and **throws
rather than guessing** when the value will not fit. `toIntOrNull()` returns
null instead, `toIntClamped()` saturates at bounds you choose, and `toBigInt()`
keeps going for as long as a `double` can hold the value.

The limit is layer 0 — roughly `±9e15`. That is not a shortcoming of the
conversion, it is where the number stops existing. At layer 1 and above `mag`
holds a *logarithm* rather than the value, so there is no exact integer left to
return: `Decimal.fromNum(9005000000000000)` comes back through `toDouble` as
`9005000000000007`. Refusing is the only honest answer, and `toBigInt()` is the
escape hatch when an approximation is what you actually want.

Do not reach for `toDouble().toInt()` instead. On the VM it **saturates
silently** — `Decimal.parse('1e20').toDouble().toInt()` is `9223372036854775807`
with no error at all, which then shows up somewhere far away as an ETA of
"now" instead of "never".

`~/` exists for a similar reason: the obvious hand-rolled version is wrong.
`(a / b).floor()` rounds toward negative infinity, so it gives `-4` where
`-7 ~/ 2` is `-3`. `truncate()` is the correct analogue of `~/`; `floor()` is
not.

## Credits and licence

This package is a port of
[break_eternity.js](https://github.com/Patashu/break_eternity.js) by
**Patashu**, used and redistributed under the MIT licence. The mathematics, the
normalisation rules, and the algorithm-level behaviour are theirs; any bugs in
the translation are mine.

The Dart port is likewise MIT licensed. See [LICENSE](LICENSE) for the full
text of both notices.
