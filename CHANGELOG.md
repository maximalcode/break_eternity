# Changelog

## 0.1.0

Initial release: the core `Decimal` value type.

- `sign`/`layer`/`mag` representation covering values up to 10^^1e308, ported
  from break_eternity.js 2.1.3.
- Arithmetic: `+`, `-`, `*`, `/`, `%`, negation, `abs`, `reciprocal`, and the
  rounding family (`floor`, `ceil`, `round`, `truncate`).
- Full comparison surface including tolerance-based variants.
- Conversions to and from `num` and `String`.
- Logarithms: `log10`, `absLog10`, `pLog10`, `log2`, `ln` and `log(base)`.
- Powers and roots: `pow`, `pow10`, `powBase`, `root`, `sqr`, `sqrt`, `cube`,
  `cbrt` and `exp`.
- The incremental-game series helpers, in closed form and constant time at any
  scale: `affordGeometricSeries`, `sumGeometricSeries`,
  `affordArithmeticSeries`, `sumArithmeticSeries` and `efficiencyOfPurchase`.
  These are what let a game offer "buy max" when the player's balance has long
  since passed the point where a purchase loop could terminate.
- `mod(other, floored: true)` alongside `%`, which is the truncated-division
  modulo. The two agree on positive operands and differ in sign otherwise.
- Tetration and its inverses: `tetrate`, `iteratedExp`, `iteratedLog`, `slog`,
  `layerAdd`, `layerAdd10` and `lambertW` (both real branches), plus `pentate`
  and `pentaLog` one level above. Non-integer heights use the reference's
  analytic approximation for bases up to 10 and its linear one above that; pass
  `linear: true` to force the linear approximation everywhere. Heights are a
  plain `num`, as they are in the original — a tower taller than 1.8e308 is not
  representable regardless.
- The full `parse` grammar: `x^y`, `x^^y`, `x^^^y` (each optionally carrying a
  payload after a semicolon), the `XpY` / `X PT Y` / `XFY` tetration
  shorthands, stacked exponents such as `2e3e4`, `(e^N)M` with a negative or
  fractional `N`, exponents no double can hold such as `1e400`, and thousands
  separators.
- Verified against the JavaScript reference implementation with generated
  fixtures (44 operations, 32,561 cases) and a native-`double` oracle suite,
  both run on the Dart VM and on dart2js.
- Self-contained software `log10` and `log2` (no dependency on the host C
  library's `log`), so results are identical on the Dart VM, dart2js and Wasm,
  and exact inputs give exact answers: `1e30.dec.log10()` is exactly 30, and
  `log2` is exact on every power of two between 2^-52 and 2^52 (above that the
  reference is inexact too, and this port matches it). `ln`, `exp` and `pow`
  keep calling `dart:math`, because the reference calls `Math.log`, `Math.exp`
  and `Math.pow`; they are the functions whose last bit is platform-dependent.
  ECMAScript leaves `Math.pow`'s accuracy implementation-defined, and compiled
  to JavaScript it differs by architecture — `7.dec.sqr()` is
  `48.99999999999999` on macOS/arm64 and exactly `49` on Linux/x64 — so
  anything reached through `pow` is portable to a tolerance, not to the bit.

Two deliberate divergences from the reference, both introduced with the
tetration work and both in the same direction — refusing rather than guessing:

- `parse` rejects input JavaScript's lenient `parseFloat` would accept. The
  reference reads `5 apples` as `5`, `garbagee5` as `1e5`, and a 400-digit
  integer as `0`; all three raise a `FormatException` here.
- `parse` strips every thousands separator. The reference uses `String.replace`
  with a string pattern, which removes only the first, so it reads `1,000,000`
  as `1000`.

Also worth knowing: `<=` and `>=` follow IEEE 754 here, while the reference
defines them as `!gt` and `!lt` and so reports NaN as satisfying both. The
places inside tetration where that changes an answer — `slog` of a NaN, mainly
— reproduce the reference's result explicitly, so the fixtures still match.

Note on the software `log2`: an earlier draft computed it as
`log10(x) / log10(2)`, which returns `-10.999999999999998` for 2^-11 where
JavaScript returns exactly `-11`. It is now a port of the same fdlibm
`__ieee754_log2` that V8 ships, verified bit-identical to `Math.log2` on a
39,000-value corpus on the VM and a 56,000-value corpus under dart2js.

Hardening against hostile save data, from a pre-release security review. Save
strings are attacker-controlled in a shipped game, so `parse` and `tryParse`
must always terminate and must never throw anything but `FormatException`:

- `(e^N)0` no longer hangs. Normalising a zero magnitude walked the layer-down
  loop one step at a time — about 60 days for `N` of 1e15, and genuinely
  forever for `N` at or above 2^54, where subtracting 1 from the layer stops
  changing the double. The result is now computed directly; it is the same
  value the loop would have reached, so every generated fixture still matches.
- `tryParse` rejects inputs longer than 4096 characters instead of raising
  `StackOverflowError` out of the regex engine. Diverges from the reference,
  which would parse a multi-megabyte literal.
- `(e^N)M` accepts an `N` in scientific notation, so values at or above layer
  1e21 — including `Decimal.layerMax` and `Decimal.layerMin` — round-trip
  through `toString`/`parse` instead of producing an unloadable save.
- `toStringAsPrecision` clamps rather than throwing `RangeError` for
  magnitudes below 1 at 16 or more digits. Costs at most five digits of
  double-rounding noise, which the reference emits.
