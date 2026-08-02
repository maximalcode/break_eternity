# Changelog

## 0.1.0

Initial release: the core `Decimal` value type.

- `sign`/`layer`/`mag` representation covering values up to 10^^1e308, ported
  from break_eternity.js 2.1.3.
- Arithmetic: `+`, `-`, `*`, `/`, `%`, negation, `abs`, `reciprocal`, and the
  rounding family (`floor`, `ceil`, `round`, `truncate`).
- Full comparison surface including tolerance-based variants.
- Conversions to and from `num` and `String`.
- Verified against the JavaScript reference implementation with generated
  fixtures and a native-`double` oracle suite.
- Self-contained software `log10` (no dependency on the host C library's
  `log`), so results are identical on the Dart VM, dart2js and Wasm.

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
