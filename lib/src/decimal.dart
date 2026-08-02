/// The [Decimal] type: an immutable arbitrary-magnitude number.
///
/// This file is a direct port of the `Decimal` class in the vendored
/// JavaScript reference (`reference/index.ts`, break_eternity.js 2.1.3 by
/// Patashu, MIT). Method order follows the reference so the two can be read
/// side by side, and every non-obvious line cites the function it came from.
///
/// The one structural difference: the reference mutates `this` inside
/// `normalize()` and the `fromX` methods, while this port is immutable. Where
/// the reference writes `this.sign = ...; this.normalize(); return this;` we
/// compute the triple and construct a fresh [Decimal].
library;

import 'dart:math' as math;

import 'constants.dart';
import 'critical_values.dart';

/// A number of the form `sign * 10^10^10^...(layer times)... mag`.
///
/// A `Decimal` is immutable: every operation returns a new value, and the
/// three fields are `final double`s. It can represent numbers from
/// `10^^(1.79e308)` down to its reciprocal, in constant time per operation.
///
/// ```dart
/// final a = Decimal.fromNum(1e300);
/// print(a * a); // 1e600
/// print(Decimal.parse('ee16')); // ee16, i.e. 10^10^16
/// ```
///
/// The representation is normalised (see [Decimal.fromComponents]), so two
/// `Decimal`s denote the same number if and only if their triples are equal —
/// which is what [operator ==] tests.
class Decimal implements Comparable<Decimal> {
  /// Creates a `Decimal` from an already-normalised triple.
  ///
  /// Private and deliberately cheap: it performs no validation whatsoever.
  /// The reference calls this `fromComponents_noNormalize`/`FC_NN`.
  const Decimal._(this.sign, this.layer, this.mag);

  /// Turns the given components into a valid (normalised) `Decimal`.
  ///
  /// This is the reference's `FC`. Use it whenever the components were
  /// computed rather than copied; it applies the seven normalisation rules
  /// documented on [_normalize].
  ///
  /// ```dart
  /// // 1e100 does not fit in a layer-0 mag, so it moves up a layer.
  /// final d = Decimal.fromComponents(1, 0, 1e100);
  /// print([d.sign, d.layer, d.mag]); // [1.0, 1.0, 100.0]
  /// ```
  ///
  /// **Cost note.** Normalisation walks *down* one layer per iteration, so in
  /// principle a huge [layer] costs time linear in [layer]. The case that
  /// actually reaches that loop — a magnitude of zero, which never grows — is
  /// short-circuited to its (identical) answer, so `(1, 1e15, 0)` is now
  /// instant rather than a multi-day hang. A non-zero magnitude always escapes
  /// the loop within about three iterations, because it grows by an
  /// exponentiation each time. No arithmetic on already-normalised values can
  /// reach the slow path either.
  factory Decimal.fromComponents(double sign, double layer, double mag) =>
      _normalize(sign, layer, mag);

  /// Turns the given components into a `Decimal` without normalising them.
  ///
  /// The result is only a valid `Decimal` if the components were already
  /// normalised. Callers outside this library should prefer
  /// [Decimal.fromComponents]; this exists for hot paths (and for tests that
  /// need to construct deliberately malformed values).
  const factory Decimal.fromComponentsNoNormalize(
    double sign,
    double layer,
    double mag,
  ) = Decimal._;

  /// Converts an `int` or `double` into a `Decimal`.
  ///
  /// `double.nan` becomes [nan] and the infinities become [infinity] /
  /// [negativeInfinity]. Reference: `fromNumber`.
  factory Decimal.fromNum(num value) {
    final double v = value.toDouble();
    return _normalize(v.sign, 0, v.abs());
  }

  /// Creates the `Decimal` equal to `mantissa * 10^exponent`.
  ///
  /// Provided for break_infinity.js compatibility; the pair is not stored, it
  /// is immediately folded into the layer/mag representation. Reference:
  /// `fromMantissaExponent`.
  factory Decimal.fromMantissaExponent(double mantissa, double exponent) =>
      _normalize(mantissa.sign, 1, exponent + _log10(mantissa.abs()));

  /// Parses [source], throwing a [FormatException] if it cannot be read.
  ///
  /// See [tryParse] for the accepted grammar.
  factory Decimal.parse(String source) {
    final Decimal? result = tryParse(source);
    if (result == null) {
      throw FormatException('Not a valid Decimal', source);
    }
    return result;
  }

  /// Creates a `Decimal` from a [Decimal], a [num] or a [String].
  ///
  /// This is the equivalent of the reference's `DecimalSource` union. Throws
  /// an [ArgumentError] for any other type, and a [FormatException] if a
  /// string fails to parse.
  factory Decimal.from(Object value) {
    if (value is Decimal) {
      return value;
    }
    if (value is num) {
      return Decimal.fromNum(value);
    }
    if (value is String) {
      return Decimal.parse(value);
    }
    throw ArgumentError.value(
      value,
      'value',
      'Expected a Decimal, num or String',
    );
  }

  // ---------------------------------------------------------------------------
  // Static constants
  // ---------------------------------------------------------------------------
  //
  // The values the reference builds with FC_NN (already-normalised triples) are
  // `const` here, so they can be used in const contexts; the ones it builds
  // with FC have to go through normalisation and are therefore `final`.

  /// The number 0, the only `Decimal` whose [sign] is zero.
  static const Decimal zero = Decimal._(0, 0, 0);

  /// The number 1.
  static const Decimal one = Decimal._(1, 0, 1);

  /// The number -1.
  static const Decimal negativeOne = Decimal._(-1, 0, 1);

  /// The number 2.
  static const Decimal two = Decimal._(1, 0, 2);

  /// The number 10.
  static const Decimal ten = Decimal._(1, 0, 10);

  /// The not-a-number value: all three components are `double.nan`.
  ///
  /// Like `double.nan`, it is not equal to itself — see [operator ==].
  static const Decimal nan = Decimal._(double.nan, double.nan, double.nan);

  /// Positive infinity, the triple `(1, inf, inf)`.
  static const Decimal infinity = Decimal._(
    1,
    double.infinity,
    double.infinity,
  );

  /// Negative infinity, the triple `(-1, inf, inf)`.
  static const Decimal negativeInfinity = Decimal._(
    -1,
    double.infinity,
    double.infinity,
  );

  /// The largest finite `double`, about 1.7976931348623157e308.
  static final Decimal numberMax = Decimal.fromComponents(
    1,
    0,
    double.maxFinite,
  );

  /// The smallest positive `double` (subnormal), about 5e-324.
  static final Decimal numberMin = Decimal.fromComponents(1, 0, 5e-324);

  /// The largest `Decimal` for which adding one to [layer] is still exact.
  ///
  /// About `10^^(9.007e15)`. Values above this are too big for `pow`/`exp`/
  /// `log` to affect at all, though tetration still moves them.
  static final Decimal layerSafeMax = Decimal.fromComponents(
    1,
    // Number.MAX_SAFE_INTEGER, i.e. 2^53 - 1.
    9007199254740991,
    expLimit - 1,
  );

  /// The smallest `Decimal` for which adding one to [layer] is still exact.
  ///
  /// About `1 / 10^^(9.007e15)`.
  static final Decimal layerSafeMin = Decimal.fromComponents(
    1,
    9007199254740991,
    -(expLimit - 1),
  );

  /// The largest finite value a `Decimal` can hold, about `10^^(1.79e308)`.
  static final Decimal layerMax = Decimal.fromComponents(
    1,
    double.maxFinite,
    expLimit - 1,
  );

  /// The smallest non-zero value a `Decimal` can hold, about
  /// `1 / 10^^(1.79e308)`.
  static final Decimal layerMin = Decimal.fromComponents(
    1,
    double.maxFinite,
    -(expLimit - 1),
  );

  // ---------------------------------------------------------------------------
  // Fields
  // ---------------------------------------------------------------------------

  /// The sign: `-1.0`, `0.0` or `1.0` (or `double.nan` in the NaN state).
  final double sign;

  /// How many times 10 is raised to a power, as a non-negative integral value.
  ///
  /// Stored as a `double` rather than an `int` so that the NaN and infinity
  /// states are representable and so that behaviour is identical on the Dart
  /// VM and when compiled to JavaScript or Wasm.
  final double layer;

  /// The magnitude: the exponent at the top of the tower of tens.
  ///
  /// At layer 0 this is the number itself. At layer >= 1 a negative `mag`
  /// means the reciprocal of the corresponding positive-`mag` number.
  final double mag;

  // ---------------------------------------------------------------------------
  // Normalisation
  // ---------------------------------------------------------------------------

  /// Computes the normalised form of the triple `(sign, layer, mag)`.
  ///
  /// Reference: `normalize()`. That function mutates and returns `this`; the
  /// early `return this` statements there become early `return Decimal._(...)`
  /// here, which matters — several of them deliberately skip the later rules.
  ///
  /// Afterwards all of the following hold, unless one of the numbers is not
  /// finite or `layer` is not an integer (both error states):
  ///
  /// 1. Any zero is totally zero `(0, 0, 0)`, any NaN is totally NaN.
  /// 2. At layer 0, `mag` is 0 or `1/9e15 < mag < 9e15`, and the sign lives
  ///    in [sign] rather than in a negative `mag`.
  /// 3. At layer >= 1, `15.954... <= mag.abs() < 9e15`.
  /// 4. Positive infinity is `(1, inf, inf)`, negative infinity is
  ///    `(-1, inf, inf)`.
  ///
  /// Everything else in this class assumes its inputs satisfy those
  /// invariants. Garbage in, garbage out.
  static Decimal _normalize(double sign, double layer, double mag) {
    // Rule 1: anything partially zero is totally zero. The third clause
    // catches layer >= 1 values whose mag has underflowed to -Infinity, i.e.
    // 10^-inf.
    if (sign == 0 ||
        (mag == 0 && layer == 0) ||
        (mag == double.negativeInfinity && layer > 0 && layer.isFinite)) {
      return zero;
    }

    // Rule 2: at layer 0 the sign lives in `sign`, never in `mag`.
    if (layer == 0 && mag < 0) {
      mag = -mag;
      sign = -sign;
    }

    // Rule 3: infinities collapse to (sign, inf, inf). `sign` is passed
    // through untouched, exactly as the reference does — it does not force it
    // to +-1, and it returns before the NaN check at the bottom.
    if (mag.isInfinite || layer.isInfinite) {
      return Decimal._(sign, double.infinity, double.infinity);
    }

    // Rule 4: layer 0 shifts to the "first negative layer" once mag gets too
    // small to keep resolution, e.g. 1e-20 becomes (1, 1, -20).
    if (layer == 0 && mag < firstNegLayer) {
      return Decimal._(sign, layer + 1, _log10(mag));
    }

    double absmag = mag.abs();
    double signmag = mag.sign;

    // Rule 5: a mag too big for a double's integer range moves up a layer.
    // One step always suffices: log10 of anything <= 1.8e308 is under 309.
    if (absmag >= expLimit) {
      return Decimal._(sign, layer + 1, signmag * _log10(absmag));
    }

    // Rule 6a: a zero magnitude never grows, so the loop below degenerates into
    // counting `layer` down one step at a time — 10^15 iterations for
    // `(e^1e15)0`, and for `layer >= 2^54` it never terminates at all, because
    // `layer -= 1` is a no-op once adjacent doubles are more than 1 apart.
    // That is reachable from [parse] with a 22-byte string, so jump straight to
    // the value the loop would arrive at: `signmag` is 0, so every iteration
    // recomputes `mag` as `0 * 10^0 == 0`, and only the final one — the pass
    // where `layer` reaches 0 — sets it to `10^0 == 1`. The answer is
    // bit-identical to the loop's, so fidelity to the reference is preserved;
    // this only refuses to spend an eternity getting there.
    //
    // Guarded on an integral layer because a fractional one steps past 0
    // without landing on it, leaving `mag` at 0. A NaN `sign` still has to come
    // out as NaN, which is what the tail of this method would have done.
    if (mag == 0 && layer > 0 && layer == layer.floorToDouble()) {
      return sign.isNaN ? nan : Decimal._(sign, 0, 1);
    }

    // Rule 6: a mag too small for its layer moves back down, repeatedly.
    while (absmag < layerDown && layer > 0) {
      layer -= 1;
      if (layer == 0) {
        mag = math.pow(10, mag).toDouble();
      } else {
        mag = signmag * math.pow(10, absmag).toDouble();
        absmag = mag.abs();
        signmag = mag.sign;
      }
    }
    if (layer == 0) {
      if (mag < 0) {
        // Landing back on layer 0 can reintroduce a negative mag.
        mag = -mag;
        sign = -sign;
      } else if (mag == 0) {
        // Excessive rounding can give us all zeroes.
        sign = 0;
      }
    }

    // Rule 7: any NaN is totally NaN.
    if (sign.isNaN || layer.isNaN || mag.isNaN) {
      return nan;
    }

    return Decimal._(sign, layer, mag);
  }

  // ---------------------------------------------------------------------------
  // Parsing
  // ---------------------------------------------------------------------------

  /// Parses [source], returning `null` instead of throwing on failure.
  ///
  /// The accepted grammar, after trimming surrounding whitespace, dropping any
  /// thousands separators and lowercasing:
  ///
  /// * `NaN`, `Infinity`, `-Infinity`;
  /// * a plain decimal number, e.g. `-12.5`;
  /// * scientific notation, e.g. `1.5e-300`, including exponents a `double`
  ///   cannot hold such as `1e400`;
  /// * a run of `e`s, e.g. `ee15.9`, `-eee1234`, and the stacked-exponent forms
  ///   `2e3e4` (which is `2e30000`) and above;
  /// * the layer syntax `(e^N)M`, e.g. `(e^7)16.5`. A negative or fractional
  ///   `N` is resolved through [tetrate];
  /// * `x^y`, `x^^y` and `x^^^y` for powers, tetration and pentation, the last
  ///   two optionally carrying a payload after a semicolon: `10^^3;5` is
  ///   `10.dec.tetrate(3, payload: 5.dec)`;
  /// * the tetration shorthands `XpY` and `X PT Y` — `3pt5` is a tower of
  ///   three tens with 5 on top — and `XFY`, which puts the payload first, so
  ///   `5f3` is the same number. Parentheses around either part are ignored.
  ///
  /// Two deliberate divergences from break_eternity.js, both in the same
  /// direction — refusing rather than guessing:
  ///
  /// * JavaScript's `parseFloat` stops at the first character it cannot use, so
  ///   the reference reads `5 apples` as `5` and, less obviously, `garbagee5`
  ///   as `1e5`. This returns `null` for both.
  /// * The reference strips only the *first* thousands separator, so it reads
  ///   `1,000,000` as `1000`. This strips all of them and reads `1000000`.
  ///
  /// Both cases are silent data corruption in a save file, which is worse than
  /// a [FormatException] from [parse].
  static Decimal? tryParse(String source) {
    String value = source.trim();
    // The length cap keeps a hostile save from exhausting the regex engine's
    // stack: a few megabytes of digits raises StackOverflowError, which is an
    // Error rather than an Exception and so escapes the `null on failure`
    // contract this method advertises. 4096 leaves three orders of magnitude of
    // headroom — [toString]'s longest possible output is 24 characters — while
    // staying far below the roughly 4 MB threshold where the stack gives out.
    // This is a deliberate divergence: the JavaScript reference would still
    // parse a multi-megabyte literal.
    if (value.isEmpty || value.length > _maxParseLength) {
      return null;
    }

    // Thousands separators are noise, never meaning. Reference: `IGNORE_COMMAS`
    // — which uses `String.replace` with a string pattern and so only ever
    // drops the first one.
    if (value.contains(',')) {
      value = value.replaceAll(',', '');
    }

    final String lower = value.toLowerCase();
    if (lower == 'nan') {
      return nan;
    }
    if (lower == 'infinity' || lower == '+infinity') {
      return infinity;
    }
    if (lower == '-infinity') {
      return negativeInfinity;
    }

    // The (e^N)M form. Reference: `fromString`, the `value.split("e^")` branch.
    final RegExpMatch? tower = _layerPattern.firstMatch(lower);
    if (tower != null) {
      final double? towerMag = double.tryParse(tower.group(3)!);
      if (towerMag == null) {
        return null;
      }
      // The pattern is deliberately permissive about `N` so that toString's
      // own output always parses; the value checks live here.
      final double? towerLayer = double.tryParse(tower.group(2)!);
      if (towerLayer == null) {
        return null;
      }
      final double towerSign = tower.group(1) == '-' ? -1 : 1;
      // A negative, fractional or overflowing layer is not a layer at all, so
      // the reference hands those to `tetrate`. Note that it takes the sign
      // from the tetration result, discarding the leading minus.
      if (towerLayer < 0 || towerLayer.remainder(1) != 0) {
        return ten.tetrate(towerLayer, payload: Decimal.fromNum(towerMag));
      }
      return _normalize(towerSign, towerLayer, towerMag);
    }

    // The hyper-operator forms and the tetration shorthands. Both fall through
    // to the exponent handling below when their parts are not numbers, exactly
    // as the reference does.
    if (lower.contains('^')) {
      final Decimal? hyper = _parseHyperOperator(lower);
      if (hyper != null) {
        return hyper;
      }
    }
    if (lower.contains('p') || lower.contains('f')) {
      final Decimal? shorthand = _parseTetrationShorthand(lower);
      if (shorthand != null) {
        return shorthand;
      }
    }

    final List<String> parts = lower.split('e');
    final int ecount = parts.length - 1;

    // Numbers that are exactly doubles (zero or one `e`). The reference
    // refuses the one-`e` shortcut below 1e-307, where doubles start losing
    // precision, and falls through to the mantissa/exponent path instead.
    if (ecount <= 1) {
      final double? asDouble = double.tryParse(lower);
      if (asDouble != null &&
          asDouble.isFinite &&
          (ecount == 0 || asDouble.abs() > 1e-307)) {
        return Decimal.fromNum(asDouble);
      }
    }
    if (ecount < 1) {
      // No `e` and not a double: the reference reads this as 0, which is how
      // `garbage` and a 400-digit integer both become zero over there.
      return null;
    }

    // Everything else is a mantissa, a run of `e`s and an exponent. Reference:
    // the tail of `fromString`, from `const mantissa = parseFloat(parts[0])`.
    final double? mantissa = _parseNumberPart(parts[0]);
    if (mantissa == null) {
      return null;
    }
    if (mantissa == 0) {
      return zero;
    }
    // The exponent, unlike the mantissa, has to be a real number: `ee15` is a
    // tower with no mantissa, but a bare `e` is not a number at all. The
    // reference reads both as NaN.
    final double? last = double.tryParse(parts[parts.length - 1]);
    if (last == null) {
      return null;
    }
    double exponent = last;
    if (ecount >= 2) {
      // `AeBeC` is `A * 10^(B * 10^C)`, so the second-to-last part folds into
      // the exponent as its own magnitude. JS: `f_maglog10`.
      final double? me = _parseNumberPart(parts[parts.length - 2]);
      if (me == null) {
        return null;
      }
      if (me.isFinite) {
        exponent *= me.sign;
        exponent += me.sign * _log10(me.abs());
      }
    }

    if (!mantissa.isFinite) {
      // No mantissa at all: `eee15.9` is a bare tower of `e`s.
      return _normalize(parts[0] == '-' ? -1 : 1, ecount.toDouble(), exponent);
    }
    if (ecount == 1) {
      // 2e10 is 10^log10(2e10), which is 10^(10 + log10(2)).
      return _normalize(mantissa.sign, 1, exponent + _log10(mantissa.abs()));
    }
    if (ecount == 2) {
      return Decimal.fromComponents(1, 2, exponent) * Decimal.fromNum(mantissa);
    }
    // At `eee` and above the mantissa is too small to be recognisable.
    return _normalize(mantissa.sign, ecount.toDouble(), exponent);
  }

  /// `x^y`, `x^^y` and `x^^^y`, the last two with an optional `;payload`.
  ///
  /// Returns null when the parts are not both finite numbers, which lets
  /// [tryParse] carry on to the other forms — the reference falls through the
  /// same way, by testing `isFinite` on its `parseFloat` results.
  static Decimal? _parseHyperOperator(String lower) {
    for (final (String operator, bool pentation) in const [
      ('^^^', true),
      ('^^', false),
    ]) {
      final List<String> parts = lower.split(operator);
      if (parts.length != 2) {
        continue;
      }
      final double? base = double.tryParse(parts[0]);
      if (base == null || !base.isFinite) {
        continue;
      }
      // `10^^3;5` is a tower of three tens with 5 at the top.
      final List<String> heightParts = parts[1].split(';');
      if (heightParts.length > 2) {
        continue;
      }
      final double? height = double.tryParse(heightParts[0]);
      if (height == null || !height.isFinite) {
        continue;
      }
      double payload = 1;
      if (heightParts.length == 2) {
        final double? given = double.tryParse(heightParts[1]);
        if (given != null && given.isFinite) {
          payload = given;
        }
      }
      final Decimal b = Decimal.fromNum(base);
      final Decimal p = Decimal.fromNum(payload);
      return pentation
          ? b.pentate(height, payload: p)
          : b.tetrate(height, payload: p);
    }

    final List<String> parts = lower.split('^');
    if (parts.length != 2) {
      return null;
    }
    final double? base = double.tryParse(parts[0]);
    final double? exponent = double.tryParse(parts[1]);
    if (base == null ||
        exponent == null ||
        !base.isFinite ||
        !exponent.isFinite) {
      return null;
    }
    return Decimal.fromNum(base).pow(Decimal.fromNum(exponent));
  }

  /// The three base-10 tetration shorthands: `X PT Y`, `XpY` and `XFY`.
  ///
  /// All three mean `10.tetrate(height, payload: payload)`; `F` is the one that
  /// writes the payload first. A leading minus negates the whole result rather
  /// than either part.
  static Decimal? _parseTetrationShorthand(String lower) {
    for (final String separator in const ['pt', 'p', 'f']) {
      final List<String> parts = lower.split(separator);
      if (parts.length != 2) {
        continue;
      }

      String head = parts[0];
      final bool negative = head.startsWith('-');
      if (negative) {
        head = head.substring(1);
      }

      final double? height;
      final double? given;
      if (separator == 'f') {
        given = double.tryParse(_stripParentheses(head));
        height = double.tryParse(_stripParentheses(parts[1]));
      } else {
        height = double.tryParse(head);
        given = double.tryParse(_stripParentheses(parts[1]));
      }
      if (height == null || !height.isFinite) {
        continue;
      }
      final double payload = (given == null || !given.isFinite) ? 1 : given;

      final Decimal result = ten.tetrate(
        height,
        payload: Decimal.fromNum(payload),
      );
      return negative ? -result : result;
    }
    return null;
  }

  /// Drops one `(` and one `)`, matching the reference's single-replacement
  /// `String.replace` calls on the `PT` / `P` / `F` operands.
  static String _stripParentheses(String value) =>
      value.replaceFirst('(', '').replaceFirst(')', '');

  /// One `e`-delimited piece of a number, as `parseFloat` would read it.
  ///
  /// Returns NaN — the reference's `parseFloat` result — for the pieces that
  /// carry no mantissa, which is how `ee15` and `-ee15` are told apart. Returns
  /// null for anything else Dart refuses, so that genuine garbage is rejected
  /// instead of being read as a number.
  static double? _parseNumberPart(String value) {
    if (value.isEmpty || value == '-' || value == '+') {
      return double.nan;
    }
    return double.tryParse(value);
  }

  /// The longest input [tryParse] will look at. See the guard in [tryParse].
  static const int _maxParseLength = 4096;

  /// `(e^N)M`, optionally signed. `N` accepts a sign and scientific notation as
  /// well as a plain digit run, because [toString] emits `(e^1e+21)16` for
  /// layers at or above 1e21 — including [layerMax] and [layerMin] — and a
  /// serialiser whose output its own parser rejects corrupts saves. Negative
  /// and non-integral layers are matched here and routed through [tetrate] in
  /// [tryParse], as the reference does for `(e^-8)1` and `(e^10.5)1`.
  static final RegExp _layerPattern = RegExp(
    r'^([+-]?)\(e\^([+-]?\d+(?:\.\d+)?(?:e[+-]?\d+)?)\)(.+)$',
  );

  // ---------------------------------------------------------------------------
  // Accessors
  // ---------------------------------------------------------------------------

  /// The break_infinity-style mantissa: the `M` in `M * 10^E`.
  ///
  /// Always in `(-10, 10)`. Past layer 2 the mantissa stops being meaningful
  /// (the number is bigger than 1e9e15) and this just returns [sign].
  /// Reference: the `m` getter.
  double get mantissa {
    if (sign == 0) {
      return 0;
    } else if (layer == 0) {
      final double exp = _log10(mag).floorToDouble();
      final double man;
      if (mag == 5e-324) {
        // The smallest subnormal divides badly; special-cased upstream too.
        man = 5;
      } else {
        man = mag / powerOf10(exp.toInt());
      }
      return sign * man;
    } else if (layer == 1) {
      final double residue = mag - mag.floorToDouble();
      return sign * math.pow(10, residue).toDouble();
    } else {
      return sign;
    }
  }

  /// The break_infinity-style base-10 exponent: the `E` in `M * 10^E`.
  ///
  /// Returns infinity for layer 3 and above, where the exponent itself is no
  /// longer a `double`. Reference: the `e` getter.
  double get exponent {
    if (sign == 0) {
      return 0;
    } else if (layer == 0) {
      return _log10(mag).floorToDouble();
    } else if (layer == 1) {
      return mag.floorToDouble();
    } else if (layer == 2) {
      return (mag.sign * math.pow(10, mag.abs()).toDouble()).floorToDouble();
    } else {
      return mag * double.infinity;
    }
  }

  /// Whether this is the not-a-number value.
  bool get isNaN => sign.isNaN || layer.isNaN || mag.isNaN;

  /// Whether this is finite *by `Decimal` standards*.
  ///
  /// A colossal value like `10^^(1e100)` is finite; only [infinity],
  /// [negativeInfinity] and [nan] are not.
  bool get isFinite => sign.isFinite && layer.isFinite && mag.isFinite;

  /// Whether this is [infinity] or [negativeInfinity].
  bool get isInfinite => !isNaN && !isFinite;

  /// Whether this is strictly less than zero. `false` for zero and for [nan].
  bool get isNegative => sign < 0;

  /// Whether this is exactly zero.
  bool get isZero => sign == 0;

  /// The sign as an `int`: -1, 0 or 1.
  ///
  /// [nan] reports 0, since `int` has no not-a-number value; test [isNaN]
  /// first if the difference matters. Reference: `sgn()`.
  int get signum {
    if (sign.isNaN) {
      return 0;
    }
    return sign > 0 ? 1 : (sign < 0 ? -1 : 0);
  }

  // ---------------------------------------------------------------------------
  // Conversion and formatting
  // ---------------------------------------------------------------------------

  /// This value as a `double`.
  ///
  /// Overflows to `double.infinity` above `double.maxFinite` and underflows to
  /// zero below `double.minPositive`. Reference: `toNumber()`.
  double toDouble() {
    if (mag == double.infinity && layer == double.infinity && sign == 1) {
      return double.infinity;
    }
    if (mag == double.infinity && layer == double.infinity && sign == -1) {
      return double.negativeInfinity;
    }
    if (!layer.isFinite) {
      return double.nan;
    }
    if (layer == 0) {
      return sign * mag;
    } else if (layer == 1) {
      return sign * math.pow(10, mag).toDouble();
    }
    // Any normalised Decimal at layer 2+ overflows a double.
    return mag > 0
        ? (sign > 0 ? double.infinity : double.negativeInfinity)
        : 0.0;
  }

  /// A string representation, in the notation that fits the magnitude.
  ///
  /// * layer 0 with `1e-7 < mag < 1e21` (or zero): a plain number, `12.5`;
  /// * layer 0 outside that range, and layer 1: `MeX`, `1.5e-300`;
  /// * layers 2 to 5: one `e` per layer then the magnitude, `ee15.9`;
  /// * layer 6 and up: `(e^7)16.5`;
  /// * plus `NaN`, `Infinity` and `-Infinity`.
  ///
  /// ```dart
  /// print(Decimal.fromNum(5));                  // 5
  /// print(Decimal.fromNum(1e300) * Decimal.fromNum(1e300)); // 1e600
  /// print(Decimal.fromComponents(1, 3, 100));   // eee100
  /// ```
  ///
  /// Reference: `toString()`. The numbers are rendered by
  /// [_jsNumberToString] rather than `double.toString()`, so the output is
  /// character-for-character what JavaScript would print.
  @override
  String toString() {
    if (isNaN) {
      return 'NaN';
    }
    if (mag == double.infinity || layer == double.infinity) {
      return sign == 1 ? 'Infinity' : '-Infinity';
    }

    if (layer == 0) {
      if ((mag < 1e21 && mag > 1e-7) || mag == 0) {
        return _jsNumberToString(sign * mag);
      }
      return '${_jsNumberToString(mantissa)}e${_jsNumberToString(exponent)}';
    } else if (layer == 1) {
      return '${_jsNumberToString(mantissa)}e${_jsNumberToString(exponent)}';
    } else {
      final String prefix = sign == -1 ? '-' : '';
      if (layer <= maxEsInARow) {
        return '$prefix${'e' * layer.toInt()}${_jsNumberToString(mag)}';
      }
      return '$prefix(e^${_jsNumberToString(layer)})${_jsNumberToString(mag)}';
    }
  }

  /// This value in exponential notation with [digits] digits after the point.
  ///
  /// [digits] must be in the range 0..20. JavaScript's `toExponential` accepts
  /// up to 100, but this delegates to `double.toStringAsExponential`, which
  /// throws `RangeError` above 20. Padding a `double` out to 100 digits emits
  /// digits it does not actually carry, so the narrower range is not a real
  /// loss of information.
  ///
  /// Reference: `toExponential(places)`.
  String toStringAsExponential(int digits) {
    if (layer == 0) {
      return (sign * mag).toStringAsExponential(digits);
    }
    return _toStringWithDecimalPlaces(digits);
  }

  /// This value with exactly [digits] digits after the decimal point.
  ///
  /// Only layer-0 values can honour that literally; above layer 0 the digit
  /// count applies to the magnitude instead.
  ///
  /// [digits] must be in the range 0..20; see [toStringAsExponential] for why.
  ///
  /// Reference: `toFixed(places)`.
  String toStringAsFixed(int digits) {
    if (layer == 0) {
      return (sign * mag).toStringAsFixed(digits);
    }
    return _toStringWithDecimalPlaces(digits);
  }

  /// This value with [digits] significant digits.
  ///
  /// [digits] in 1..15 is always safe. `0` throws, matching JavaScript. Above
  /// 15 the derived count of digits after the point can exceed the 20 that
  /// `double.toStringAsFixed` allows — for magnitudes below 1 it would
  /// otherwise throw `RangeError`, so it is clamped to 20 instead. That costs
  /// at most five digits, all of them past the seventeenth significant digit
  /// and therefore double-rounding noise; the JavaScript reference, which has
  /// no such ceiling, emits them. Returning a marginally shorter string beats
  /// throwing on an argument this method documents as valid.
  ///
  /// Reference: `toPrecision(places)`.
  String toStringAsPrecision(int digits) {
    final double e = exponent;
    if (e <= -7) {
      return toStringAsExponential(digits - 1);
    }
    if (digits > e) {
      return toStringAsFixed((digits - e - 1).clamp(0, 20).toInt());
    }
    return toStringAsExponential(digits - 1);
  }

  /// This value as a JSON-friendly string; delegates to [toString].
  ///
  /// Round-trips through [Decimal.parse] for every value milestone 1 can
  /// produce.
  String toJson() => toString();

  /// [toString] with the mantissa and magnitude rounded to [places] decimals.
  ///
  /// Reference: `toStringWithDecimalPlaces(places)`.
  String _toStringWithDecimalPlaces(int places) {
    if (layer == 0) {
      if ((mag < 1e21 && mag > 1e-7) || mag == 0) {
        return (sign * mag).toStringAsFixed(places);
      }
      return '${_places(mantissa, places)}e${_places(exponent, places)}';
    } else if (layer == 1) {
      return '${_places(mantissa, places)}e${_places(exponent, places)}';
    } else {
      final String prefix = sign == -1 ? '-' : '';
      if (layer <= maxEsInARow) {
        return '$prefix${'e' * layer.toInt()}${_places(mag, places)}';
      }
      return '$prefix(e^${_jsNumberToString(layer)})${_places(mag, places)}';
    }
  }

  // ---------------------------------------------------------------------------
  // Arithmetic
  // ---------------------------------------------------------------------------

  /// The absolute value: `this` if `this >= 0`, `-this` otherwise.
  ///
  /// Note that `Decimal.nan.abs()` is `(1, NaN, NaN)` rather than the
  /// canonical all-NaN triple, because the reference's `abs()` rewrites only
  /// the sign and skips normalisation. It still reports [isNaN], and this port
  /// keeps the quirk deliberately so fixtures match.
  Decimal abs() => Decimal._(sign == 0 ? 0 : 1, layer, mag);

  /// The negation: given `X`, returns `-X`. Reference: `neg()`.
  Decimal operator -() => Decimal._(-sign, layer, mag);

  /// This value rounded to the nearest integer, halves rounding up.
  ///
  /// Anything at layer 1 or above is already an integer as far as a `Decimal`
  /// can tell, and is returned unchanged. Reference: `round()`.
  Decimal round() {
    if (mag < 0) {
      return zero;
    }
    if (layer == 0) {
      return _normalize(sign, 0, _jsRound(mag));
    }
    return this;
  }

  /// The largest integer that is less than or equal to this value.
  ///
  /// Reference: `floor()`.
  Decimal floor() {
    if (mag < 0) {
      // Numbers between 0 and 1 (in absolute value) live at layer >= 1 with a
      // negative mag.
      return sign == -1 ? negativeOne : zero;
    }
    if (sign == -1) {
      return -(-this).ceil();
    }
    if (layer == 0) {
      return _normalize(sign, 0, mag.floorToDouble());
    }
    return this;
  }

  /// The smallest integer that is greater than or equal to this value.
  ///
  /// Reference: `ceil()`.
  Decimal ceil() {
    if (mag < 0) {
      // 10^10^-100 is still greater than 0, so its ceiling is 1.
      return sign == 1 ? one : zero;
    }
    if (sign == -1) {
      return -(-this).floor();
    }
    if (layer == 0) {
      return _normalize(sign, 0, mag.ceilToDouble());
    }
    return this;
  }

  /// The integer part: like [floor] for positives, like [ceil] for negatives.
  ///
  /// Reference: `trunc()`.
  Decimal truncate() {
    if (mag < 0) {
      return zero;
    }
    if (layer == 0) {
      return _normalize(sign, 0, mag.truncateToDouble());
    }
    return this;
  }

  /// The sum of this and [other].
  ///
  /// Addition is where the layered representation earns its keep, so this is
  /// the most carefully ported method in the file. Reference: `add()`. Four
  /// short-circuits do the work, in order:
  ///
  /// 1. either operand at layer 2 or above — the smaller one cannot possibly
  ///    perturb the larger, so the larger (by absolute value) is returned;
  /// 2. an *effective* layer difference of 2 or more, where "effective" means
  ///    `layer * mag.sign` so that reciprocals count as negative layers;
  /// 3. magnitudes further apart than [maxSignificantDigits], where the
  ///    smaller one falls off the end of the `double`;
  /// 4. otherwise the layer-1 identity `10^a + 10^b = 10^(b + log10(1 +
  ///    10^(a-b)))`, evaluated as `b.mag + log10(mantissa)`.
  ///
  /// ```dart
  /// print(Decimal.fromNum(1) + Decimal.fromNum(2)); // 3
  /// print(Decimal.fromComponents(1, 2, 100) + Decimal.one); // ee100
  /// // Above layer 0 the digits live in log space, so exact decimal sums are
  /// // not recoverable — the JavaScript original prints this too:
  /// print(Decimal.fromNum(1e300) + Decimal.fromNum(1e300));
  /// // 1.9999999999998694e300
  /// ```
  Decimal operator +(Decimal other) {
    // Infinity + -Infinity = NaN.
    if ((this == infinity && other == negativeInfinity) ||
        (this == negativeInfinity && other == infinity)) {
      return nan;
    }

    // Infinity/NaN check: a non-finite layer swallows everything.
    if (!layer.isFinite) {
      return this;
    }
    if (!other.layer.isFinite) {
      return other;
    }

    // Adding zero to anything returns the other number.
    if (sign == 0) {
      return other;
    }
    if (other.sign == 0) {
      return this;
    }

    // Adding a number to its own negation is 0, no matter how large.
    if (sign == -other.sign && layer == other.layer && mag == other.mag) {
      return zero;
    }

    // Short-circuit 1.
    if (layer >= 2 || other.layer >= 2) {
      return _maxAbs(other);
    }

    final Decimal a;
    final Decimal b;
    if (_cmpAbs(other) > 0) {
      a = this;
      b = other;
    } else {
      a = other;
      b = this;
    }

    if (a.layer == 0 && b.layer == 0) {
      return Decimal.fromNum(a.sign * a.mag + b.sign * b.mag);
    }

    final double layerA = a.layer * a.mag.sign;
    final double layerB = b.layer * b.mag.sign;

    // Short-circuit 2.
    if (layerA - layerB >= 2) {
      return a;
    }

    if (layerA == 0 && layerB == -1) {
      // a is layer 0, b is a layer-1 reciprocal (something below 1/9e15).
      if ((b.mag - _log10(a.mag)).abs() > maxSignificantDigits) {
        return a;
      }
      final double magdiff = math.pow(10, _log10(a.mag) - b.mag).toDouble();
      final double mantissa = b.sign + a.sign * magdiff;
      return _normalize(mantissa.sign, 1, b.mag + _log10(mantissa.abs()));
    }

    if (layerA == 1 && layerB == 0) {
      if ((a.mag - _log10(b.mag)).abs() > maxSignificantDigits) {
        return a;
      }
      final double magdiff = math.pow(10, a.mag - _log10(b.mag)).toDouble();
      final double mantissa = b.sign + a.sign * magdiff;
      return _normalize(
        mantissa.sign,
        1,
        _log10(b.mag) + _log10(mantissa.abs()),
      );
    }

    // Short-circuits 3 and 4: both operands are layer 1.
    if ((a.mag - b.mag).abs() > maxSignificantDigits) {
      return a;
    }
    final double magdiff = math.pow(10, a.mag - b.mag).toDouble();
    final double mantissa = b.sign + a.sign * magdiff;
    return _normalize(mantissa.sign, 1, b.mag + _log10(mantissa.abs()));
  }

  /// The difference between this and [other]. Reference: `sub()`.
  Decimal operator -(Decimal other) => this + (-other);

  /// The product of this and [other].
  ///
  /// Reference: `mul()`. Note two upstream quirks reproduced verbatim, since
  /// the fixtures are generated from that code: `Infinity * 0` is [nan] but
  /// `0 * Infinity` is [infinity] (the reference tests `this` twice where it
  /// meant to test the argument), and `-Infinity * -Infinity` is [infinity]
  /// while `Infinity * -Infinity` is [negativeInfinity].
  Decimal operator *(Decimal other) {
    // Infinity * -Infinity = -Infinity.
    if ((this == infinity && other == negativeInfinity) ||
        (this == negativeInfinity && other == infinity)) {
      return negativeInfinity;
    }

    // Infinity * 0 = NaN. (See the doc comment: the second clause is the
    // reference's typo, faithfully preserved.)
    if ((mag == double.infinity && other == zero) ||
        (this == zero && mag == double.infinity)) {
      return nan;
    }

    // -Infinity * -Infinity = Infinity.
    if (this == negativeInfinity && other == negativeInfinity) {
      return infinity;
    }

    // Infinity/NaN check.
    if (!layer.isFinite) {
      return this;
    }
    if (!other.layer.isFinite) {
      return other;
    }

    // Anything times zero is zero.
    if (sign == 0 || other.sign == 0) {
      return zero;
    }

    // A number times its own reciprocal is +-1, no matter how large.
    if (layer == other.layer && mag == -other.mag) {
      return Decimal._(sign * other.sign, 0, 1);
    }

    // Which number is bigger in terms of its multiplicative distance from 1?
    final Decimal a;
    final Decimal b;
    if (layer > other.layer ||
        (layer == other.layer && mag.abs() > other.mag.abs())) {
      a = this;
      b = other;
    } else {
      a = other;
      b = this;
    }

    if (a.layer == 0 && b.layer == 0) {
      return Decimal.fromNum(a.sign * b.sign * a.mag * b.mag);
    }

    // Layer 3+, or two layers apart: the smaller factor cannot move the
    // bigger one at all.
    if (a.layer >= 3 || a.layer - b.layer >= 2) {
      return _normalize(a.sign * b.sign, a.layer, a.mag);
    }

    if (a.layer == 1 && b.layer == 0) {
      return _normalize(a.sign * b.sign, 1, a.mag + _log10(b.mag));
    }

    if (a.layer == 1 && b.layer == 1) {
      return _normalize(a.sign * b.sign, 1, a.mag + b.mag);
    }

    if ((a.layer == 2 && b.layer == 1) || (a.layer == 2 && b.layer == 2)) {
      // Multiplying at layer 2 is adding one layer down.
      final Decimal newmag =
          _normalize(a.mag.sign, a.layer - 1, a.mag.abs()) +
          _normalize(b.mag.sign, b.layer - 1, b.mag.abs());
      return _normalize(
        a.sign * b.sign,
        newmag.layer + 1,
        newmag.sign * newmag.mag,
      );
    }

    throw StateError('Bad arguments to *: $this, $other');
  }

  /// The quotient of this and [other]. Reference: `div()`.
  Decimal operator /(Decimal other) => this * other.reciprocal();

  /// The reciprocal, `1 / this`.
  ///
  /// `Decimal.zero.reciprocal()` is [nan], not infinity, matching the
  /// reference. Reference: `recip()`.
  Decimal reciprocal() {
    if (mag == 0) {
      return nan;
    } else if (mag == double.infinity) {
      return zero;
    } else if (layer == 0) {
      return _normalize(sign, 0, 1 / mag);
    } else {
      return _normalize(sign, layer, -mag);
    }
  }

  /// The remainder of `this / other`, with the sign of `this`.
  ///
  /// This is truncated-division modulo, the same convention as
  /// `num.remainder` and JavaScript's `%` — *not* Dart's `%` on `num`, which
  /// is always non-negative. So `(-5).dec % 2.dec` is `-1`, matching
  /// `(-5).remainder(2)`. See [mod] for the floored convention, where it would
  /// be `1`. Reference: `mod()` with `floored: false`.
  Decimal operator %(Decimal other) {
    final Decimal magnitude = other.abs();

    if (this == zero || magnitude == zero) {
      return zero;
    }

    // If both sides survive the trip through double, use the hardware
    // remainder: it avoids the precision loss of the general path below.
    final double numThis = toDouble();
    final double numOther = magnitude.toDouble();
    if (numThis.isFinite &&
        numOther.isFinite &&
        numThis != 0 &&
        numOther != 0) {
      return Decimal.fromNum(numThis.remainder(numOther));
    }

    if (this - magnitude == this) {
      // `other` is too small to register against `this`.
      return zero;
    }
    if (magnitude - this == magnitude) {
      // `this` is too small to register against `other`.
      return this;
    }
    if (sign == -1) {
      return -(abs() % magnitude);
    }
    return this - (this / magnitude).floor() * magnitude;
  }

  /// The remainder of `this / other`, in either modulo convention.
  ///
  /// With [floored] false — the default, and what [operator %] does — the
  /// result takes the sign of `this`, as `num.remainder` and JavaScript's `%`
  /// do. With [floored] true it takes the sign of [other] instead, which is the
  /// convention number theory uses and the one Dart's own `%` on `num` follows
  /// for a positive divisor.
  ///
  /// The two agree whenever both operands are positive, and differ otherwise:
  ///
  /// ```dart
  /// print((-5).dec.mod(2.dec));                 // -1
  /// print((-5).dec.mod(2.dec, floored: true));  //  1
  /// print(5.dec.mod((-2).dec));                 //  1
  /// print(5.dec.mod((-2).dec, floored: true));  // -1
  /// ```
  ///
  /// Reference: `mod(value, floored)`, which it also exposes as `modulo` and
  /// `modular`; this port keeps one name for one function.
  Decimal mod(Decimal other, {bool floored = false}) {
    if (!floored) {
      return this % other;
    }
    final Decimal magnitude = other.abs();
    if (this == zero || magnitude == zero) {
      return zero;
    }
    Decimal absmod = abs() % magnitude;
    if ((sign == -1) != (other.sign == -1)) {
      absmod = magnitude - absmod;
    }
    return absmod * Decimal.fromNum(other.sign);
  }

  // ---------------------------------------------------------------------------
  // Comparison
  // ---------------------------------------------------------------------------

  /// Compares this to [other], returning a negative value, zero, or a
  /// positive value if this is smaller, equal to, or larger than [other].
  ///
  /// This is a *total* order, so it can be used with `List.sort`. NaN is the
  /// odd one out, and follows `double.compareTo`: [nan] compares equal to
  /// itself and greater than every other value, even [infinity]. The
  /// comparison *operators* disagree — they all report `false` against NaN,
  /// exactly as `double`'s do.
  @override
  int compareTo(Decimal other) {
    if (isNaN) {
      return other.isNaN ? 0 : 1;
    }
    if (other.isNaN) {
      return -1;
    }
    return _cmp(other);
  }

  /// Compares the absolute values of this and [other].
  ///
  /// Returns -1, 0 or 1 as `|this|` is less than, equal to, or greater than
  /// `|other|`. NaN sorts above everything, as in [compareTo].
  ///
  /// **This deliberately differs from the reference on NaN.** Upstream
  /// `cmpabs` returns 0 whenever either side is NaN (it compares with `>`/`<`,
  /// which are both false), so upstream `x.maxabs(NaN)` is `x`. Returning 0
  /// from a `Comparable`-style method would break sorting, so this returns a
  /// total order instead. The internal comparison used by `+` keeps the
  /// reference's behaviour, so arithmetic is unaffected.
  ///
  /// Reference: `cmpabs()`.
  int compareMagnitudeTo(Decimal other) {
    if (isNaN) {
      return other.isNaN ? 0 : 1;
    }
    if (other.isNaN) {
      return -1;
    }
    return _cmpAbs(other);
  }

  /// Whether this is strictly less than [other]. `false` if either is [nan].
  bool operator <(Decimal other) => !isNaN && !other.isNaN && _cmp(other) < 0;

  /// Whether this is less than or equal to [other]. `false` if either is
  /// [nan].
  ///
  /// (The reference defines `lte` as `!gt`, which makes `NaN <= x` true; that
  /// is a footgun, so this port follows `double` instead.)
  bool operator <=(Decimal other) => !isNaN && !other.isNaN && _cmp(other) <= 0;

  /// Whether this is strictly greater than [other]. `false` if either is
  /// [nan].
  bool operator >(Decimal other) => !isNaN && !other.isNaN && _cmp(other) > 0;

  /// Whether this is greater than or equal to [other]. `false` if either is
  /// [nan].
  bool operator >=(Decimal other) => !isNaN && !other.isNaN && _cmp(other) >= 0;

  /// Whether [other] is a `Decimal` denoting the same number.
  ///
  /// Equality is structural over the normalised triple, which is exactly
  /// numeric equality because normalisation is canonical.
  ///
  /// **[nan] is not equal to itself**, just like `double.nan`. That is
  /// surprising in a value type: it means `Decimal.nan != Decimal.nan`, that
  /// a `Set` can hold several NaNs, and that `list.contains(Decimal.nan)` is
  /// always `false`. Use [isNaN] to test for it, or [compareTo] (which does
  /// treat NaN as equal to itself) when you need a total order.
  @override
  bool operator ==(Object other) =>
      other is Decimal &&
      sign == other.sign &&
      layer == other.layer &&
      mag == other.mag;

  /// A hash consistent with [operator ==], over the three components.
  ///
  /// Two NaNs hash the same even though they are not equal — which is allowed
  /// (equal values must hash equally, not the converse) and matches `double`.
  @override
  int get hashCode => Object.hash(sign, layer, mag);

  /// Whichever of this and [other] is larger.
  ///
  /// Follows the reference, which resolves this with a single `<` test, so a
  /// [nan] operand is not contagious: `nan.max(x)` is [nan] but `x.max(nan)`
  /// is `x`. Check [isNaN] first if that matters.
  Decimal max(Decimal other) => this < other ? other : this;

  /// Whichever of this and [other] is smaller.
  ///
  /// Follows the reference; see the note on [max] about [nan].
  Decimal min(Decimal other) => this > other ? other : this;

  /// This value confined to the range `[lower, upper]`.
  ///
  /// Reference: `clamp(min, max)`.
  Decimal clamp(Decimal lower, Decimal upper) => max(lower).min(upper);

  /// Whether this and [other] agree to within a relative [tolerance].
  ///
  /// The tolerance is relative and is applied to the *magnitudes*, which is
  /// what makes it meaningful across layers: `1e-7` means "equal unless they
  /// differ by more than one part in 10^7 of the larger magnitude". Values
  /// whose layers differ by more than one are never close. Reference:
  /// `eq_tolerance()`.
  bool equalsWithin(Decimal other, [double tolerance = 1e-7]) {
    // Numbers that are too far away are never close.
    if (sign != other.sign) {
      return false;
    }
    if ((layer - other.layer).abs() > 1) {
      return false;
    }
    double magA = mag;
    double magB = other.mag;
    if (layer > other.layer) {
      magB = _magLog10(magB);
    }
    if (layer < other.layer) {
      magA = _magLog10(magA);
    }
    return (magA - magB).abs() <= tolerance * math.max(magA.abs(), magB.abs());
  }

  /// [compareTo], except that values within [tolerance] compare equal.
  ///
  /// Reference: `cmp_tolerance()`.
  int compareWithin(Decimal other, [double tolerance = 1e-7]) =>
      equalsWithin(other, tolerance) ? 0 : compareTo(other);

  /// The reference's `cmp()`: signed comparison assuming neither side is NaN.
  int _cmp(Decimal other) {
    if (sign > other.sign) {
      return 1;
    }
    if (sign < other.sign) {
      return -1;
    }
    final int magnitudes = _cmpAbs(other);
    return sign > 0 ? magnitudes : (sign < 0 ? -magnitudes : 0);
  }

  /// The reference's `cmpabs()`: unsigned comparison assuming neither side is
  /// NaN (a NaN operand makes every test below false, yielding 0).
  int _cmpAbs(Decimal other) {
    // A negative mag means a reciprocal, which sorts below layer 0.
    final double layerA = mag > 0 ? layer : -layer;
    final double layerB = other.mag > 0 ? other.layer : -other.layer;
    if (layerA > layerB) {
      return 1;
    }
    if (layerA < layerB) {
      return -1;
    }
    if (mag > other.mag) {
      return 1;
    }
    if (mag < other.mag) {
      return -1;
    }
    return 0;
  }

  /// The reference's `maxabs()`: whichever operand is larger in absolute
  /// value, keeping its own sign.
  Decimal _maxAbs(Decimal other) => _cmpAbs(other) < 0 ? other : this;

  // ---------------------------------------------------------------------------
  // Logarithms
  // ---------------------------------------------------------------------------

  /// "Positive log10": [log10] for non-negative values, zero for negatives.
  ///
  /// Useful for progress bars and other displays that take the logarithm of a
  /// resource which is not supposed to go negative, where a [nan] would poison
  /// the whole layout. [nan] itself still comes out as [nan].
  ///
  /// ```dart
  /// print(1000.dec.pLog10()); // 3
  /// print((-5).dec.pLog10()); // 0
  /// ```
  ///
  /// Reference: `pLog10()`.
  Decimal pLog10() {
    if (this < zero) {
      return zero;
    }
    return log10();
  }

  /// The base-10 logarithm of `this.abs()`.
  ///
  /// Differs from [log10] only in sign handling: negatives get a real answer
  /// here instead of [nan]. `Decimal.zero.absLog10()` is still [nan], because
  /// the logarithm of zero is not a `Decimal`. Reference: `absLog10()`.
  Decimal absLog10() {
    if (sign == 0) {
      return nan;
    } else if (layer > 0) {
      // reference/index.ts absLog10(), layer 1+ case: a layer is exactly one
      // application of 10^x, so the logarithm just peels one off.
      return _normalize(mag.sign, layer - 1, mag.abs());
    } else {
      return _normalize(1, 0, _log10(mag));
    }
  }

  /// The base-10 logarithm: the `X` with `10^X == this`.
  ///
  /// Zero and negatives give [nan]. Above layer 0 this is "subtract one from
  /// [layer] and renormalise", which is why the logarithm of a colossal number
  /// costs no more than the logarithm of a small one.
  ///
  /// ```dart
  /// print(1e100.dec.log10());                    // 100
  /// print(Decimal.fromComponents(1, 3, 100).log10()); // ee100
  /// ```
  ///
  /// Reference: `log10()`.
  Decimal log10() {
    if (sign <= 0) {
      return nan;
    } else if (layer > 0) {
      return _normalize(mag.sign, layer - 1, mag.abs());
    } else {
      return _normalize(sign, 0, _log10(mag));
    }
  }

  /// The logarithm of this value in the given [base]: the `X` with
  /// `base^X == this`.
  ///
  /// [nan] if either side is zero or negative, or if [base] is exactly 1
  /// (every power of 1 is 1, so the inverse does not exist).
  ///
  /// ```dart
  /// print(1024.dec.log(2.dec)); // 10
  /// ```
  ///
  /// Reference: `log(base)`, which the reference also exposes under the name
  /// `logarithm`; this port keeps one name for one function. When both sides
  /// are at layer 0 it is a ratio of `dart:math` `log`s — see the note on
  /// [ln] about that function's platform dependence — and otherwise a ratio of
  /// [log10]s, which is what makes the base meaningful across layers.
  ///
  /// Because of that split, `x.log(10.dec)` is not always bit-identical to
  /// `x.log10()`, and `x.log(2.dec)` is not always [log2]: the dedicated
  /// methods use the software logarithms in `constants.dart`, this one uses the
  /// host libm at layer 0. The reference has the identical split and the same
  /// disagreements, so this is fidelity rather than a defect — but prefer
  /// [log10] and [log2] when the base is 10 or 2, because they are exact on
  /// exact powers and reproducible across Dart targets.
  Decimal log(Decimal base) {
    if (sign <= 0) {
      return nan;
    }
    if (base.sign <= 0) {
      return nan;
    }
    if (base.sign == 1 && base.layer == 0 && base.mag == 1) {
      return nan;
    } else if (layer == 0 && base.layer == 0) {
      // reference/index.ts log(base), layer-0 fast path: a ratio of natural
      // logarithms, exactly as the reference computes it.
      return _normalize(sign, 0, math.log(mag) / math.log(base.mag));
    }

    return log10() / base.log10();
  }

  /// The base-2 logarithm: the `X` with `2^X == this`.
  ///
  /// Zero and negatives give [nan]. Reference: `log2()`.
  Decimal log2() {
    if (sign <= 0) {
      return nan;
    } else if (layer == 0) {
      return _normalize(sign, 0, _log2(mag));
    } else if (layer == 1) {
      // log2(10^mag) == mag * log2(10).
      return _normalize(mag.sign, 0, mag.abs() * 3.321928094887362);
    } else if (layer == 2) {
      // log2(10^10^mag) == 10^mag * log2(10), and log10 of that is
      // mag + log10(log2(10)) == mag - log10(log10(2)).
      return _normalize(mag.sign, 1, mag.abs() + 0.5213902276543247);
    } else {
      // Three layers up, multiplying by log2(10) is lost in the rounding.
      return _normalize(mag.sign, layer - 1, mag.abs());
    }
  }

  /// The natural (base-e) logarithm: the `X` with `e^X == this`.
  ///
  /// Zero and negatives give [nan]. Reference: `ln()`.
  ///
  /// The layer-0 case goes through `dart:math`'s `log`, exactly as the
  /// reference goes through `Math.log`. That is the host platform's libm, so
  /// unlike the software `log10` in `constants.dart` its last bit can differ
  /// between the VM and dart2js; it disagrees with V8 on 2 of the 679 `ln`
  /// fixture cases. Substituting `log10(x) / log10(e)` would be reproducible
  /// but disagrees on 19, and nothing in the representation depends on `ln`
  /// the way normalisation depends on `log10`, so fidelity wins.
  Decimal ln() {
    if (sign <= 0) {
      return nan;
    } else if (layer == 0) {
      return _normalize(sign, 0, math.log(mag));
    } else if (layer == 1) {
      // ln(10^mag) == mag * ln(10).
      return _normalize(mag.sign, 0, mag.abs() * 2.302585092994046);
    } else if (layer == 2) {
      // As in [log2]: log10(ln(10)) == -log10(log10(e)).
      return _normalize(mag.sign, 1, mag.abs() + 0.36221568869946325);
    } else {
      return _normalize(mag.sign, layer - 1, mag.abs());
    }
  }

  // ---------------------------------------------------------------------------
  // Powers and roots
  // ---------------------------------------------------------------------------

  /// This value raised to the power [other].
  ///
  /// The general route is `10^(log10(|this|) * other)`, with the sign put back
  /// afterwards; the special cases in front of it are what make the identities
  /// hold exactly:
  ///
  /// * `0^0` is 1, every other `0^b` is 0;
  /// * `1^b` is 1 and `a^0` is 1, for every `b` and `a` including [nan];
  /// * `a^1` is `a`.
  ///
  /// A negative base only has a real power when the exponent is an integer:
  /// the result is negated for odd exponents, kept for even ones, and [nan]
  /// otherwise (`(-8)^(1/3)` is [nan] here — use [cbrt], which handles the
  /// sign itself).
  ///
  /// ```dart
  /// print(2.dec.pow(1000.dec));   // 1.071508607186271e301
  /// print(10.dec.pow(1e100.dec)); // ee100
  /// print((-2).dec.pow(3.dec));   // -7.999999999999999
  /// print((-2).dec.pow(0.5.dec)); // NaN
  /// ```
  ///
  /// The `-8` above is off by an ulp because the route through `log10` and
  /// `pow10` is not exact — the JavaScript original prints the same thing.
  ///
  /// Reference: `pow(value)`.
  Decimal pow(Decimal other) {
    final Decimal a = this;
    final Decimal b = other;

    // Special case: if a is 0, then return 0 (UNLESS b is 0, then return 1).
    if (a.sign == 0) {
      return b == zero ? one : a;
    }
    // Special case: if a is 1, then return 1.
    if (a.sign == 1 && a.layer == 0 && a.mag == 1) {
      return a;
    }
    // Special case: if b is 0, then return 1.
    if (b.sign == 0) {
      return one;
    }
    // Special case: if b is 1, then return a.
    if (b.sign == 1 && b.layer == 0 && b.mag == 1) {
      return a;
    }

    final Decimal result = (a.absLog10() * b).pow10();

    if (sign == -1) {
      // reference/index.ts pow(), negative-base case. `remainder` is used
      // rather than Dart's `%` because it is JavaScript's `%`: truncated
      // division, so the sign of the exponent does not change the parity.
      final double parity = b.toDouble().remainder(2).abs().remainder(2);
      if (parity == 1) {
        return -result;
      } else if (parity == 0) {
        return result;
      }
      // A fractional (or non-finite) exponent on a negative base.
      return nan;
    }

    return result;
  }

  /// 10 raised to the power of this value.
  ///
  /// For values above 1 this is just "add one to [layer]", which is how a
  /// `Decimal` reaches magnitudes a `double` cannot name. Reference: `pow10()`,
  /// whose four layer-1+ cases are:
  ///
  /// 1. positive sign, positive mag (`e15`, `ee15`): +1 layer;
  /// 2. negative sign, positive mag (`-e15`): +1 layer, both signs flipped;
  /// 3. and 4. negative mag (`e-15`): the layer-0 branch already handled
  ///    everything that is not 1 to within a rounding error, so the answer is 1.
  ///
  /// ```dart
  /// print(3.dec.pow10());    // 1000
  /// print(1e16.dec.pow10()); // ee16
  /// ```
  Decimal pow10() {
    if (this == infinity) {
      return infinity;
    }
    if (this == negativeInfinity) {
      return zero;
    }
    if (!layer.isFinite || !mag.isFinite) {
      return nan;
    }

    Decimal a = this;

    // Layer 0: if no precision is lost use the double power, else promote one
    // layer. The 0.1 floor is the reference's: below it the double result is
    // subnormal enough that the layered form carries more digits.
    if (a.layer == 0) {
      final double newmag = _pow10Double(a.sign * a.mag);
      if (newmag.isFinite && newmag.abs() >= 0.1) {
        return _normalize(1, 0, newmag);
      }
      if (a.sign == 0) {
        return one;
      }
      a = Decimal._(a.sign, a.layer + 1, _log10(a.mag));
    }

    if (a.sign > 0 && a.mag >= 0) {
      return _normalize(a.sign, a.layer + 1, a.mag);
    }
    if (a.sign < 0 && a.mag >= 0) {
      return _normalize(-a.sign, a.layer + 1, -a.mag);
    }
    // Both negative-mag cases are identical: one +/- rounding error.
    return one;
  }

  /// [base] raised to the power of this value: `base ^ this`.
  ///
  /// The mirror image of [pow], for when the exponent is the value in hand:
  /// `exponent.powBase(base)` reads the same way as `base.pow(exponent)` and
  /// returns the same number. Reference: `pow_base(value)`.
  Decimal powBase(Decimal base) => base.pow(this);

  /// The [degree]-th root: the `X` with `X ^ degree == this`.
  ///
  /// Equivalent to `pow(degree.reciprocal())`, except that a negative value
  /// under an odd-integer root keeps its sign instead of giving [nan] — the
  /// real cube root of -8 is -2.
  ///
  /// ```dart
  /// print(1e100.dec.root(2.dec)); // 1e50
  /// print((-8).dec.root(3.dec));  // -1.9999999999999998, i.e. -2
  /// ```
  ///
  /// Reference: `root(value)`.
  Decimal root(Decimal degree) {
    if (this < zero && degree.mod(two, floored: true) == one) {
      return -(-this).root(degree);
    }
    return pow(degree.reciprocal());
  }

  /// Base-e exponentiation: `e^this`.
  ///
  /// Reference: `exp()`. The hard-coded constants are `log10(e)` and
  /// `log10(log10(e))`, which convert between the natural and base-10 towers.
  ///
  /// Like [ln], the layer-0 branch calls `dart:math`'s `exp`, which is the host
  /// platform's libm rather than a software routine, exactly as the reference
  /// calls `Math.exp`. Its last bit therefore depends on the target: it
  /// disagrees with V8 on 3 of the 679 `exp` fixture cases on the Dart VM
  /// (`(-10).dec.exp()` is `0.000045399929762484854` here against
  /// `0.00004539992976248485` there) and agrees on all of them under dart2js,
  /// where `math.exp` *is* `Math.exp`. Everything above layer 0 goes through
  /// the software [_log10] and is reproducible.
  Decimal exp() {
    if (mag < 0) {
      // e^(something smaller than 1/9e15) is 1 to within a rounding error.
      return one;
    }
    if (layer == 0 && mag <= 709.7) {
      // The largest exponent whose result still fits in a double.
      return Decimal.fromNum(math.exp(sign * mag));
    } else if (layer == 0) {
      return _normalize(1, 1, sign * _log10(math.e) * mag);
    } else if (layer == 1) {
      return _normalize(1, 2, sign * (_log10(0.4342944819032518) + mag));
    } else {
      // Above layer 1 the factor of log10(e) is lost in the rounding.
      return _normalize(1, layer + 1, sign * mag);
    }
  }

  /// This value squared. Reference: `sqr()`.
  Decimal sqr() => pow(two);

  /// The square root: the non-negative `X` with `X * X == this`.
  ///
  /// [nan] for negative values. Reference: `sqrt()`; the layer-1 constant is
  /// `log10(2)`, since `sqrt(10^m) == 10^(m/2)` and dividing a mag by two is
  /// subtracting `log10(2)` one layer up.
  ///
  /// **Two inherited quirks, both faithful to break_eternity.js.** The layer-1
  /// branch takes `log10(mag)`, and a value below `1/9e15` is stored at layer 1
  /// with a *negative* mag, so `Decimal.fromNum(1e-30).sqrt()` is [nan] rather
  /// than `1e-15`; use `pow(0.5.dec)` or [cbrt], which take a different route.
  /// From layer 2 up the sign is never checked, so `(-inf).sqrt()` is `-inf`.
  ///
  /// The layer-1 branch is also the most visible consumer of the last-ulp
  /// residue in the software `log10` (see `constants.dart`): a handful of
  /// layer-1 magnitudes — `Decimal.fromComponents(1, 1, 19.652149670124494)`
  /// is one — come back a few ulps from what V8 produces, because the [pow10]
  /// that follows amplifies an ulp of the mag into ~5e-5 of the result. 0.3% of
  /// layer-1 mags in `[16, 26]` are affected. This is not a wrong constant or a
  /// wrong branch, and the residue is inherent to matching two different libms.
  Decimal sqrt() {
    if (layer == 0) {
      return Decimal.fromNum(math.sqrt(sign * mag));
    } else if (layer == 1) {
      return _normalize(1, 2, _log10(mag) - 0.3010299956639812);
    } else {
      // Halving one layer down, then putting the layer back.
      final Decimal result = Decimal._(sign, layer - 1, mag) / two;
      return _normalize(result.sign, result.layer + 1, result.mag);
    }
  }

  /// This value cubed. Reference: `cube()`.
  Decimal cube() => pow(_three);

  /// The cube root: the `X` with `X * X * X == this`, negative for negatives.
  ///
  /// Reference: `cbrt()`.
  Decimal cbrt() {
    if (this < zero) {
      return -(-this).pow(_oneThird);
    }
    return pow(_oneThird);
  }

  /// The number 3, for [cube].
  static const Decimal _three = Decimal._(1, 0, 3);

  /// One third, for [cbrt]: the `double` nearest 1/3, as the reference's `1/3`.
  static final Decimal _oneThird = Decimal.fromNum(1 / 3);

  // ---------------------------------------------------------------------------
  // Tetration and its inverses
  // ---------------------------------------------------------------------------
  //
  // Tetration is iterated exponentiation: `x^^n` is `x^x^x^...^x` with n copies
  // of x, right-associated. It is the operation the `sign`/`layer`/`mag`
  // representation is built around — `10^^n` is exactly "layer n" — so these
  // methods are where the type finally reaches the magnitudes it was designed
  // for.
  //
  // Non-integer heights are the hard part: there is no single agreed-upon
  // definition of `x^^2.5`. Every method here takes a `linear` flag with the
  // reference's meaning. False (the default) uses the analytic approximation
  // from the lookup tables in `critical_values.dart` for bases up to 10, and
  // the linear approximation above that; true forces the linear approximation
  // everywhere. Whole heights are unaffected either way.

  /// The convergence limit `e^(1/e)`, as a `Decimal`.
  static final Decimal _convergenceLimit = Decimal.fromNum(
    tetrationConvergenceLimit,
  );

  /// `-1/e`, below which the Lambert W function leaves the reals.
  ///
  /// The reference writes this as `-0.3678794411710499`, which is a hair above
  /// the true `-1/e`; the literal is kept as-is so the boundary lands in the
  /// same place.
  static final Decimal _lambertBranchPoint = Decimal.fromNum(
    -0.3678794411710499,
  );

  /// Below this, `lambertW(z)` is `z` to within a rounding error.
  static final Decimal _lambertLinearFloor = Decimal.fromNum(1e-300);

  /// `eee15`, the size above which `d_lambertw` stops converging reliably.
  ///
  /// Normalises to `(1, 2, 1e15)`; the reference spells it as the string
  /// `"eee15"`.
  static final Decimal _eee15 = Decimal.fromComponents(1, 3, 15);

  /// The number -2, for [pentaLog]'s lower bound.
  static const Decimal _negativeTwo = Decimal._(-1, 0, 2);

  /// The reference's `lte`, for the places where its NaN behaviour matters.
  ///
  /// break_eternity.js defines `lte` as `!gt` and `gte` as `!lt`, so a NaN
  /// operand comes out as *both* "less than or equal to" and "greater than or
  /// equal to" everything. [operator <=] deliberately follows `double` instead —
  /// every comparison against NaN is false — because that is what a Dart caller
  /// expects and what the rest of the language does.
  ///
  /// The tetration family is where that difference changes an answer rather
  /// than just a predicate: `Decimal.nan.slog()` reaches `copy <= one` and has
  /// to come out NaN rather than run the loop a hundred times. So those
  /// comparisons, and only those, are spelled the reference's way here.
  bool _lteNaNTrue(Decimal other) => !(this > other);

  /// The reference's `gte`, which is `!lt`. See [_lteNaNTrue].
  bool _gteNaNTrue(Decimal other) => !(this < other);

  /// Tetration: this value raised to itself [height] times.
  ///
  /// `x.tetrate(n)` is `x^x^x^...^x` with `n` copies of `x`, evaluated from the
  /// top down. [payload] is what sits at the very top of the tower instead of
  /// the implicit 1, so `x.tetrate(n, payload: p)` is the result of applying
  /// `x^_` to `p` exactly `n` times.
  ///
  /// ```dart
  /// print(10.dec.tetrate(3));   // 1e10000000000
  /// print(2.dec.tetrate(4));    // 65536
  /// print(10.dec.tetrate(1e10)); // (e^10000000000)1
  /// ```
  ///
  /// A negative [height] is [iteratedLog] — undoing the tower — and an infinite
  /// one is the limit of the infinite power tower, which converges only for
  /// bases in `[e^-e, e^(1/e)]` and is [infinity] above that.
  ///
  /// This is not constant-time the way arithmetic is: it climbs the tower one
  /// exponentiation at a time, with a shortcut once each step is only adding a
  /// layer, and gives up after 10,000 iterations. Heights beyond a few thousand
  /// are cheap only because of that shortcut.
  ///
  /// Reference: `tetrate(height, payload, linear)`.
  Decimal tetrate(num height, {Decimal payload = one, bool linear = false}) {
    final double h = height.toDouble();

    // x^^1 == x^payload, and x^^0 == payload.
    if (h == 1) {
      return pow(payload);
    }
    if (h == 0) {
      return payload;
    }
    // 1^^x == 1, and (-1)^^x == (-1)^payload.
    if (this == one) {
      return one;
    }
    if (this == negativeOne) {
      return pow(payload);
    }

    if (h == double.infinity) {
      final double thisNum = toDouble();
      if (thisNum <= tetrationConvergenceLimit &&
          thisNum >= tetrationConvergenceFloor) {
        // Inside the convergence range. For bases above 1, `b^x == x` has two
        // solutions: the lower one is a stable equilibrium, the upper one is
        // not. Below 1 only the stable solution exists.
        final Decimal negln = -ln();
        Decimal lower = negln.lambertW() / negln;
        if (thisNum < 1) {
          return lower;
        }
        Decimal upper = negln.lambertW(principal: false) / negln;
        if (thisNum > tetrationConvergenceHotfix) {
          // Hotfix from the reference for the very edge of the range, where
          // the two solutions stop being distinguishable.
          upper = Decimal.fromNum(math.e);
          lower = upper;
        }
        if (payload == upper) {
          return upper;
        } else if (payload < upper) {
          return lower;
        }
        return infinity;
      } else if (thisNum > tetrationConvergenceLimit) {
        return infinity;
      }
      // Below e^-e the tower never converges, and a negative base goes complex
      // almost immediately.
      return nan;
    }

    // 0^^x oscillates — 0^^1 is 0, 0^^2 is 1, 0^^3 is 0 — because 0^0 is 1
    // here as it is in JavaScript. The payload is ignored, and non-integer
    // heights get a linear approximation.
    if (this == zero) {
      double result = (h + 1).remainder(2).abs();
      if (result > 1) {
        result = 2 - result;
      }
      return Decimal.fromNum(result);
    }

    if (h < 0) {
      return payload.iteratedLog(base: this, times: -h, linear: linear);
    }

    final double whole = h.truncateToDouble();
    final double fracheight = h - whole;
    Decimal p = payload;

    // Bases in (0, 1] — and bases up to e^(1/e) with a small enough payload —
    // flip-flop between two values and converge slowly, or never. Iterate up to
    // a bounded height and stop as soon as it settles.
    if (this > zero &&
        (this < one ||
            (_lteNaNTrue(_convergenceLimit) &&
                p._lteNaNTrue((-ln()).lambertW(principal: false) / (-ln())))) &&
        (h > 10000 || !linear)) {
      final double limitheight = math.min(10000.0, whole);
      if (p == one) {
        p = pow(Decimal.fromNum(fracheight));
      } else if (this < one) {
        p =
            p.pow(Decimal.fromNum(1 - fracheight)) *
            pow(p).pow(Decimal.fromNum(fracheight));
      } else {
        // The reference does not forward `linear` here; neither do we.
        p = p.layerAdd(fracheight, this);
      }
      for (double i = 0; i < limitheight; i++) {
        final Decimal old = p;
        p = pow(p);
        if (old == p) {
          return p;
        }
      }
      if (h > 10000 && h.ceilToDouble().remainder(2) == 1) {
        return pow(p);
      }
      return p;
    }

    if (fracheight != 0) {
      if (p == one) {
        if (this > ten || linear) {
          // Above base 10 the reference reverts to the linear approximation.
          p = pow(Decimal.fromNum(fracheight));
        } else {
          p = Decimal.fromNum(
            criticalSection(toDouble(), fracheight, criticalTetrValues),
          );
          // The critical-section grid starts at base 2, so smaller bases are
          // scaled onto it rather than read off it.
          if (this < two) {
            p = (p - one) * (this - one) + one;
          }
        }
      } else {
        if (this == ten) {
          p = p.layerAdd10(fracheight, linear: linear);
        } else if (this < one) {
          p =
              p.pow(Decimal.fromNum(1 - fracheight)) *
              pow(p).pow(Decimal.fromNum(fracheight));
        } else {
          p = p.layerAdd(fracheight, this, linear: linear);
        }
      }
    }

    for (double i = 0; i < whole; i++) {
      p = pow(p);
      if (!p.layer.isFinite || !p.mag.isFinite) {
        return _normalize(p.sign, p.layer, p.mag);
      }
      // Once each step only adds a layer, the remaining steps can be applied
      // all at once. This is what makes a height of 1e10 finish.
      if (p.layer - layer > 3) {
        return Decimal._(p.sign, p.layer + (whole - i - 1), p.mag);
      }
      // Give up after 10,000 iterations if nothing is happening.
      if (i > 10000) {
        return p;
      }
    }
    return p;
  }

  /// Iterated exponentiation: `this^_` applied to [payload] [height] times.
  ///
  /// Identical to [tetrate] — the two names describe the same operation from
  /// different directions, and the reference exposes both. Reference:
  /// `iteratedexp(height, payload, linear)`.
  Decimal iteratedExp(
    num height, {
    Decimal payload = one,
    bool linear = false,
  }) => tetrate(height, payload: payload, linear: linear);

  /// Repeated logarithm: `log(base)` applied to this value [times] times.
  ///
  /// The inverse of [iteratedExp], and equivalently `base.tetrate(-times,
  /// payload: this)`. Approximately subtracts [times] from this value's [slog]
  /// representation.
  ///
  /// ```dart
  /// print(Decimal.parse('1e10000000000').iteratedLog(times: 2)); // 10
  /// ```
  ///
  /// Reference: `iteratedlog(base, times, linear)`.
  Decimal iteratedLog({
    Decimal base = ten,
    num times = 1,
    bool linear = false,
  }) {
    final double t = times.toDouble();
    if (t < 0) {
      return base.tetrate(-t, payload: this, linear: linear);
    }

    Decimal result = this;
    double whole = t.truncateToDouble();
    final double fraction = t - whole;

    // Symmetric with tetrate's shortcut: while each step only removes a layer,
    // remove them all at once.
    if (result.layer - base.layer > 3) {
      final double layerloss = math.min(whole, result.layer - base.layer - 3);
      whole -= layerloss;
      result = Decimal._(result.sign, result.layer - layerloss, result.mag);
    }

    for (double i = 0; i < whole; i++) {
      result = result.log(base);
      if (!result.layer.isFinite || !result.mag.isFinite) {
        return _normalize(result.sign, result.layer, result.mag);
      }
      if (i > 10000) {
        return result;
      }
    }

    if (fraction > 0 && fraction < 1) {
      if (base == ten) {
        result = result.layerAdd10(-fraction, linear: linear);
      } else {
        result = result.layerAdd(-fraction, base, linear: linear);
      }
    }

    return result;
  }

  /// Super-logarithm: how tall a tower of [base] has to be to reach this value.
  ///
  /// One of tetration's two inverses, and the one that answers "how big is this
  /// number, really" for numbers too large for [log10] to say anything useful
  /// about. It grows so slowly that it never exceeds about 1.8e308 — a tower
  /// that tall is already the largest representable `Decimal`.
  ///
  /// ```dart
  /// print(Decimal.parse('1e10000000000').slog()); // 3
  /// print(Decimal.parse('(e^1000)1').slog());     // 1000
  /// ```
  ///
  /// The answer is found by binary search against [tetrate], starting from a
  /// cheap estimate and refining for [iterations] steps. That makes it markedly
  /// more expensive than [log10]; cache it rather than calling it every frame.
  ///
  /// Reference: `slog(base, iterations, linear)`.
  Decimal slog({
    Decimal base = ten,
    int iterations = 100,
    bool linear = false,
  }) {
    double stepSize = 0.001;
    bool hasChangedDirectionsOnce = false;
    bool previouslyRose = false;
    double result = _slogInternal(base, linear).toDouble();

    for (int i = 1; i < iterations; i++) {
      final Decimal candidate = base.tetrate(result, linear: linear);
      final bool currentlyRose = candidate > this;
      if (i > 1 && previouslyRose != currentlyRose) {
        hasChangedDirectionsOnce = true;
      }
      previouslyRose = currentlyRose;
      // Grow the step until the target is bracketed, then halve it.
      if (hasChangedDirectionsOnce) {
        stepSize /= 2;
      } else {
        stepSize *= 2;
      }
      stepSize = stepSize.abs() * (currentlyRose ? -1 : 1);
      result += stepSize;
      if (stepSize == 0) {
        break;
      }
    }
    return Decimal.fromNum(result);
  }

  /// The initial estimate [slog] refines: peel logarithms until the value lands
  /// in the critical section, then read the fractional part off the table.
  ///
  /// Reference: `slog_internal(base, linear)`.
  Decimal _slogInternal(Decimal base, bool linear) {
    // A base of 1 or less has no usable super-logarithm.
    if (base._lteNaNTrue(zero) || base == one) {
      return nan;
    }
    if (base < one) {
      // These small, wobbling bases only have answers at two points:
      // 0 < this < 1 is ambiguous (it happens repeatedly), this < 0 appears to
      // be impossible, and this > 1 is partially complex.
      if (this == one) {
        return zero;
      }
      if (this == zero) {
        return negativeOne;
      }
      return nan;
    }
    // slog_n(0) is -1.
    if (mag < 0 || this == zero) {
      return negativeOne;
    }
    if (base < _convergenceLimit) {
      // The infinite tower converges here, so anything above its limit is not
      // reachable at any height.
      final Decimal negln = -base.ln();
      final Decimal infTower = negln.lambertW() / negln;
      if (this == infTower) {
        return infinity;
      }
      if (this > infTower) {
        return nan;
      }
    }

    // An infinite tower has an infinite super-logarithm, and a negatively
    // infinite one has none. The reference reaches both the long way round: the
    // layer shortcut below computes `Infinity - Infinity` for the new layer, and
    // it then carries that invalid triple through the loop, where its `lte`
    // (which is `!gt`, so NaN satisfies it) decides the outcome. Dart's
    // comparisons treat a NaN layer as NaN throughout, so the answers are
    // stated. A base whose own layer is infinite is left alone: there the
    // subtraction never produces the invalid triple in the first place, and both
    // languages fall out of the loop with NaN.
    if (!layer.isFinite && base.layer.isFinite) {
      return sign > 0 ? infinity : nan;
    }

    double result = 0;
    Decimal copy = this;
    if (copy.layer - base.layer > 3) {
      final double layerloss = copy.layer - base.layer - 3;
      result += layerloss;
      copy = Decimal._(copy.sign, copy.layer - layerloss, copy.mag);
    }

    for (int i = 0; i < 100; i++) {
      if (copy < zero) {
        copy = base.pow(copy);
        result -= 1;
      } else if (copy._lteNaNTrue(one)) {
        if (linear) {
          return Decimal.fromNum(result + copy.toDouble() - 1);
        }
        return Decimal.fromNum(
          result + _slogCritical(base.toDouble(), copy.toDouble()),
        );
      } else {
        result += 1;
        copy = copy.log(base);
      }
    }
    return Decimal.fromNum(result);
  }

  /// The fractional part of [slog] inside the critical section `[0, 1]`.
  ///
  /// Reference: `slog_critical(base, height)`.
  static double _slogCritical(double base, double height) {
    // Above base 10 the reference reverts to the old linear approximation.
    if (base > 10) {
      return height - 1;
    }
    return criticalSection(base, height, criticalSlogValues);
  }

  /// Adds [diff] to this value's [layer], fractional layers included.
  ///
  /// Whole values of [diff] are exactly "wrap in another 10^", which costs
  /// nothing: `x.layerAdd10(1)` is `10^x`. Fractional values are the
  /// interesting case — `x.layerAdd10(0.5)` lands halfway between `x` and
  /// `10^x` in the sense that applying it twice gives `10^x`.
  ///
  /// ```dart
  /// print(100.dec.layerAdd10(1)); // 1e100
  /// print(1e100.dec.layerAdd10(-1)); // 100
  /// ```
  ///
  /// Equivalent to adding [diff] to the value's `slog(10)`. Reference:
  /// `layeradd10(diff, linear)`.
  Decimal layerAdd10(num diff, {bool linear = false}) {
    double d = diff.toDouble();
    double s = sign;
    double l = layer;
    double m = mag;

    if (d >= 1) {
      if (m < 0 && l > 0) {
        // A very small number (mag < 0, layer > 0) has to become 0 first.
        s = 0;
        m = 0;
        l = 0;
      } else if (s == -1 && l == 0) {
        // For values like (-3).layerAdd10(1) the sign moves into the mag.
        s = 1;
        m = -m;
      }
      final double add = d.truncateToDouble();
      d -= add;
      l += add;
    }
    if (d <= -1) {
      final double add = d.truncateToDouble();
      d -= add;
      l += add;
      if (l < 0) {
        for (int i = 0; i < 100; i++) {
          l += 1;
          m = _log10(m);
          if (!m.isFinite) {
            // Hitting a -Infinity mag means negative infinity, not zero:
            // `Decimal.zero.layerAdd10(-1)` arrives here.
            if (s == 0) {
              s = 1;
            }
            if (l < 0) {
              l = 0;
            }
            return _normalize(s, l, m);
          }
          if (l >= 0) {
            break;
          }
        }
      }
    }

    // Unreachable in practice, and deliberately kept anyway: the loop above
    // either lands on a non-negative layer or bails out on a non-finite mag
    // (repeated log10 reaches NaN within about five steps from any starting
    // point), so this is the reference's belt-and-braces, not a second path.
    while (l < 0) {
      l += 1;
      m = _log10(m);
    }
    if (s == 0) {
      // Having started from zero, a layer has to be put back by hand.
      s = 1;
      if (m == 0 && l >= 1) {
        l -= 1;
        m = 1;
      }
    }
    final Decimal result = _normalize(s, l, m);

    if (d != 0) {
      // Only ever a positive height with payload 1, so this cannot recurse.
      return result.layerAdd(d, ten, linear: linear);
    }
    return result;
  }

  /// Adds [diff] to this value's `slog(base)` representation.
  ///
  /// The [base]-general form of [layerAdd10]: closely related to tetrating to
  /// height [diff] and to taking [diff] iterated logarithms, but expressed as
  /// an offset rather than an absolute height.
  ///
  /// Reference: `layeradd(diff, base, linear)`.
  Decimal layerAdd(num diff, Decimal base, {bool linear = false}) {
    final double d = diff.toDouble();

    if (base > one && base._lteNaNTrue(_convergenceLimit)) {
      // Bases whose infinite tower converges need the extended super-logarithm,
      // because ordinary slog cannot describe values above `base^^Infinity`.
      final (Decimal excess, int range) = _excessSlog(this, base, linear);
      final double slogdest = excess.toDouble() + d;
      final Decimal negln = -base.ln();
      final Decimal lower = negln.lambertW() / negln;
      final Decimal upper = negln.lambertW(principal: false) / negln;
      Decimal slogzero = one;
      if (range == 1) {
        slogzero = (lower * upper).sqrt();
      } else if (range == 2) {
        slogzero = upper * two;
      }
      final Decimal slogone = base.pow(slogzero);
      final double wholeheight = slogdest.floorToDouble();
      final double fracheight = slogdest - wholeheight;
      final Decimal towertop =
          slogzero.pow(Decimal.fromNum(1 - fracheight)) *
          slogone.pow(Decimal.fromNum(fracheight));
      // `wholeheight` is whole, so this is safe even when it means iteratedlog.
      return base.tetrate(wholeheight, payload: towertop, linear: linear);
    }

    final double slogdest = slog(base: base, linear: linear).toDouble() + d;
    if (slogdest >= 0) {
      return base.tetrate(slogdest, linear: linear);
    } else if (!slogdest.isFinite) {
      return nan;
    } else if (slogdest >= -1) {
      return base.tetrate(slogdest + 1, linear: linear).log(base);
    }
    return base.tetrate(slogdest + 2, linear: linear).log(base).log(base);
  }

  /// A super-logarithm for bases in `(1, e^(1/e)]` that also works above
  /// `base^^Infinity`.
  ///
  /// Returns the value together with a range marker: 0 means below the lower
  /// solution of `b^x == x`, where ordinary [slog] applies; 1 means between the
  /// two solutions, with their geometric mean arbitrarily assigned a value of
  /// 0; 2 means above the upper solution, with twice that solution assigned 0.
  ///
  /// The numbers themselves carry little meaning — the *difference* between two
  /// of them does, which is all [layerAdd] needs. Reference: `excess_slog`,
  /// which is private there for the same reason.
  static (Decimal, int) _excessSlog(Decimal value, Decimal base, bool linear) {
    final double baseNum = base.toDouble();
    if (baseNum == 1 || baseNum <= 0) {
      return (nan, 0);
    }
    if (baseNum > tetrationConvergenceLimit) {
      return (value.slog(base: base, linear: linear), 0);
    }

    final Decimal negln = -base.ln();
    Decimal lower = negln.lambertW() / negln;
    Decimal upper = infinity;
    if (baseNum > 1) {
      upper = negln.lambertW(principal: false) / negln;
    }
    if (baseNum > tetrationConvergenceHotfix) {
      upper = Decimal.fromNum(math.e);
      lower = upper;
    }

    if (value < lower) {
      return (value.slog(base: base, linear: linear), 0);
    }
    if (value == lower) {
      return (infinity, 0);
    }
    if (value == upper) {
      return (negativeInfinity, 2);
    }

    // Above the upper solution the tower is increasing, below it (but above the
    // lower solution) it is decreasing; the two branches are mirror images.
    final bool above = value > upper;
    if (!above && !(value < upper && value > lower)) {
      throw StateError('Unhandled behaviour in excess_slog');
    }

    final Decimal slogzero = above ? upper * two : (lower * upper).sqrt();
    final Decimal slogone = base.pow(slogzero);
    double estimate = 0;

    if (above) {
      if (value._gteNaNTrue(slogzero) && value < slogone) {
        estimate = 0;
      } else if (value._gteNaNTrue(slogone)) {
        Decimal payload = slogone;
        estimate = 1;
        while (payload < value) {
          payload = base.pow(payload);
          estimate += 1;
          if (payload.layer > 3) {
            final double layersleft = (value.layer - payload.layer + 1)
                .floorToDouble();
            payload = base.iteratedExp(
              layersleft,
              payload: payload,
              linear: linear,
            );
            estimate += layersleft;
          }
        }
        if (payload > value) {
          payload = payload.log(base);
          estimate -= 1;
        }
      } else if (value < slogzero) {
        Decimal payload = slogzero;
        estimate = 0;
        while (payload > value) {
          payload = payload.log(base);
          estimate -= 1;
        }
      }
    } else {
      if (value._lteNaNTrue(slogzero) && value > slogone) {
        estimate = 0;
      } else if (value._lteNaNTrue(slogone)) {
        Decimal payload = slogone;
        estimate = 1;
        while (payload > value) {
          payload = base.pow(payload);
          estimate += 1;
        }
        if (payload < value) {
          payload = payload.log(base);
          estimate -= 1;
        }
      } else if (value > slogzero) {
        Decimal payload = slogzero;
        estimate = 0;
        while (payload < value) {
          payload = payload.log(base);
          estimate -= 1;
        }
      }
    }

    // Bisect the fractional height, interpolating the tower top as a weighted
    // geometric mean of the two whole-height anchors.
    double fracheight = 0;
    double stepSize = 0.5;
    Decimal guess = zero;
    while (stepSize > 1e-16) {
      final double tested = fracheight + stepSize;
      final Decimal towertop =
          slogzero.pow(Decimal.fromNum(1 - tested)) *
          slogone.pow(Decimal.fromNum(tested));
      // The reference does not forward `linear` to this call; neither do we.
      guess = base.iteratedExp(estimate, payload: towertop);
      if (guess == value) {
        return (Decimal.fromNum(estimate + tested), above ? 2 : 1);
      } else if (above ? guess < value : guess > value) {
        fracheight += stepSize;
      }
      stepSize /= 2;
    }
    if (!guess.equalsWithin(value, 1e-7)) {
      return (nan, 0);
    }
    return (Decimal.fromNum(estimate + fracheight), above ? 2 : 1);
  }

  /// The Lambert W function: the `w` with `w * e^w == this`.
  ///
  /// Also called the omega function or the product logarithm. It is
  /// multi-valued, but only two branches matter over the reals: [principal]
  /// selects `W_0` when true (defined for `this >= -1/e`) and `W_-1` when false
  /// (defined for `-1/e <= this <= 0`). Outside those domains the answer is
  /// complex, and this returns [nan].
  ///
  /// ```dart
  /// print(1.dec.lambertW()); // 0.5671432904097838, the omega constant
  /// ```
  ///
  /// Solved iteratively — by Newton's method at layer 0, by Halley's method
  /// above it. Very close to the branch point at `-1/e` the evaluation becomes
  /// inaccurate and can fail to converge, in which case this throws a
  /// [StateError] rather than returning a plausible wrong number; the reference
  /// throws there too.
  ///
  /// Reference: `lambertw(principal)`.
  Decimal lambertW({bool principal = true}) {
    if (this < _lambertBranchPoint) {
      return nan; // Complex.
    }
    if (principal) {
      if (abs() < _lambertLinearFloor) {
        return this;
      } else if (mag < 0) {
        return Decimal.fromNum(fLambertW(toDouble()));
      } else if (layer == 0) {
        return Decimal.fromNum(fLambertW(sign * mag));
      } else if (this < _eee15) {
        return _dLambertW(this);
      }
      // Numbers this large sometimes fail to converge, and at this size `ln` is
      // close enough.
      return ln();
    }
    if (sign == 1) {
      return nan; // Complex.
    }
    if (layer == 0) {
      return Decimal.fromNum(fLambertW(sign * mag, principal: false));
    } else if (layer == 1) {
      return _dLambertW(this, principal: false);
    }
    return -(-this).reciprocal().lambertW();
  }

  /// The Lambert W function evaluated in `Decimal` arithmetic, for magnitudes a
  /// `double` cannot hold.
  ///
  /// Halley's method, from
  /// [SciPy's `lambertw`](https://github.com/scipy/scipy/blob/main/scipy/special/xsf/lambertw.h).
  /// Reference: `d_lambertw`.
  static Decimal _dLambertW(
    Decimal z, {
    double tol = 1e-10,
    bool principal = true,
  }) {
    if (!z.mag.isFinite) {
      return z;
    }

    Decimal w;
    if (principal) {
      if (z == zero) {
        return zero;
      }
      if (z == one) {
        // Split out because the asymptotic series blows up here.
        return Decimal.fromNum(omega);
      }
      w = z.ln();
    } else {
      if (z == zero) {
        return negativeInfinity;
      }
      w = (-z).ln();
    }

    final Decimal tolerance = Decimal.fromNum(tol);
    for (int i = 0; i < 100; i++) {
      final Decimal ew = (-w).exp();
      final Decimal wewz = w - z * ew;
      final Decimal wn =
          w - wewz / (w + one - (w + two) * wewz / (two * w + two));
      if ((wn - w).abs() < wn.abs() * tolerance) {
        return wn;
      }
      w = wn;
    }

    throw StateError('Lambert W iteration failed to converge: $z');
  }

  /// Pentation: this value tetrated to itself [height] times.
  ///
  /// One level above [tetrate], and the last hyper-operation this package
  /// implements: `x.pentate(n)` is `x^^x^^...^^x` with `n` copies of `x`.
  /// [payload] plays the same role it does in [tetrate].
  ///
  /// ```dart
  /// print(2.dec.pentate(3)); // 65536, i.e. 2^^(2^^2)
  /// ```
  ///
  /// It saturates almost immediately: `10.pentate(3)` already overflows even a
  /// `Decimal`. There is no analytic approximation of pentation to non-integer
  /// heights, so those always use the linear one, whatever [linear] says about
  /// the tetration underneath.
  ///
  /// Reference: `pentate(height, payload, linear)`.
  Decimal pentate(num height, {Decimal payload = one, bool linear = false}) {
    final double oldheight = height.toDouble();
    double whole = oldheight.floorToDouble();
    final double fracheight = oldheight - whole;
    Decimal p = payload;
    Decimal prev = zero;
    Decimal prevTwo = zero;

    if (fracheight != 0) {
      if (p == one) {
        whole += 1;
        p = Decimal.fromNum(fracheight);
      } else {
        // Safe despite the recursion: pentaLog only pentates with payload 1.
        return pentate(
          (p.pentaLog(base: this, linear: linear) + Decimal.fromNum(oldheight))
              .toDouble(),
          linear: linear,
        );
      }
    }

    if (whole > 0) {
      for (double i = 0; i < whole;) {
        prevTwo = prev;
        prev = p;
        p = tetrate(p.toDouble(), linear: linear);
        i += 1;
        // Under the linear approximation, once both the base and the payload
        // are in (0, 1] they stay there, and x^^^p collapses to x^^p.
        if (this > zero && _lteNaNTrue(one) && p > zero && p._lteNaNTrue(one)) {
          return tetrate(whole - i, payload: p, linear: linear);
        }
        // Stop once it has settled. Bases close to 0 alternate between two
        // values rather than converging to one, hence the second test.
        if (p == prev ||
            (p == prevTwo && i.remainder(2) == whole.remainder(2))) {
          return _normalize(p.sign, p.layer, p.mag);
        }
        if (!p.layer.isFinite || !p.mag.isFinite) {
          return _normalize(p.sign, p.layer, p.mag);
        }
        if (i > 10000) {
          return p;
        }
      }
    } else {
      // Negative height is repeated slog, which is slow — but that is simply
      // what it means, and there are no layer shortcuts to take.
      for (double i = 0; i < -whole; i++) {
        prev = p;
        p = p.slog(base: this, linear: linear);
        if (p == prev) {
          return _normalize(p.sign, p.layer, p.mag);
        }
        if (!p.layer.isFinite || !p.mag.isFinite) {
          return _normalize(p.sign, p.layer, p.mag);
        }
        if (i > 100) {
          return p;
        }
      }
    }

    return p;
  }

  /// Penta-logarithm: how many times [base] has to be tetrated to reach this
  /// value.
  ///
  /// The inverse of [pentate], and even slower-growing than [slog] — for bases
  /// above 2 you will never see a result above 5.
  ///
  /// Found the same way [slog] is: an integer estimate, then a binary search
  /// against [pentate] for [iterations] steps. Both halves run whole pentation
  /// loops, so this is by far the most expensive method here; it is essentially
  /// unusable on values at or below -1.
  ///
  /// Reference: `penta_log(base, iterations, linear)`.
  Decimal pentaLog({
    Decimal base = ten,
    int iterations = 100,
    bool linear = false,
  }) {
    // Bases at or below 1 oscillate, so the logarithm has no meaning.
    if (base._lteNaNTrue(one)) {
      return nan;
    }
    if (this == one) {
      return zero;
    }
    if (this == infinity) {
      return infinity;
    }

    Decimal value = one;
    double result = 0;
    double stepSize = 1;

    if (this < negativeOne) {
      // Somewhere between -1 and -2, depending on the base, `base^^x == x`.
      // That x is `base^^^(-Infinity)`; nothing below it has an answer.
      if (_lteNaNTrue(_negativeTwo)) {
        return nan;
      }
      final Decimal limitcheck = base.tetrate(toDouble(), linear: linear);
      if (this == limitcheck) {
        return negativeInfinity;
      }
      if (this > limitcheck) {
        return nan;
      }
    }

    // Pentation runs through every tetration step anyway, so walking to the
    // nearest integer one step at a time beats calling pentate repeatedly.
    if (this > one) {
      while (value < this) {
        result++;
        value = base.tetrate(value.toDouble(), linear: linear);
        if (result > 1000) {
          return nan; // Almost certainly a limit rather than a slow climb.
        }
      }
    } else {
      while (value > this) {
        result--;
        value = value.slog(base: base, linear: linear);
        // The reference guards this loop with `result > 1000` on a counter that
        // only ever decreases, so its guard can never fire and it can spin
        // forever. The bound is applied in the direction it was plainly meant
        // to go. Any input that reaches it is one the reference never returns
        // from at all, so no observable behaviour changes.
        if (result < -100) {
          return nan;
        }
      }
    }

    for (int i = 1; i < iterations; i++) {
      final Decimal candidate = base.pentate(result, linear: linear);
      if (candidate == this) {
        break;
      }
      stepSize = stepSize.abs() * (candidate > this ? -1 : 1);
      result += stepSize;
      stepSize /= 2;
      if (stepSize == 0) {
        break;
      }
    }
    return Decimal.fromNum(result);
  }

  // ---------------------------------------------------------------------------
  // Incremental-game series helpers
  // ---------------------------------------------------------------------------
  //
  // Ported from the reference's `*_core` statics, which is where the real
  // formulas live; the reference's non-`_core` wrappers only coerce their
  // arguments.

  /// How many more items you can afford when the price multiplies each time.
  ///
  /// The classic idle-game generator: the first one ever sold cost
  /// [priceStart], each subsequent one costs [priceRatio] times the last, and
  /// you already own [currentOwned] of them. Answers "how many can I buy right
  /// now with [resourcesAvailable]?", floored, so it is safe to feed straight
  /// into a purchase loop.
  ///
  /// ```dart
  /// // 1e6 gold, generators start at 10 gold and get 15% dearer each time,
  /// // and you already own 42.
  /// final n = Decimal.affordGeometricSeries(
  ///   1e6.dec, 10.dec, 1.15.dec, 42.dec,
  /// );
  /// print(n); // 26 — the 43rd generator through the 68th
  /// // Buying all 26 costs:
  /// print(Decimal.sumGeometricSeries(n, 10.dec, 1.15.dec, 42.dec));
  /// // 870433.5234942113, which is indeed under the 1e6 available
  /// ```
  ///
  /// [currentOwned] is the count you own *now*, not the index of the next
  /// purchase: the first item ever bought costs `priceStart * priceRatio^0`, so
  /// owning 42 means the next one costs `priceStart * priceRatio^42` (here
  /// 3542.49...). Passing the wrong one silently over- or undercharges by a
  /// whole step of the ratio.
  ///
  /// A [priceRatio] of exactly 1 gives [nan] (the formula divides by
  /// `log10(1)`); use [affordArithmeticSeries] for prices that do not grow, or
  /// plain division. Reference: `affordGeometricSeries_core`, adapted from the
  /// Trimps source.
  ///
  /// **Knife edges.** The answer is a ratio of two logarithms with a [floor]
  /// on the outside, so when the money on hand is *exactly* the price of a
  /// whole number of items, one ulp in that ratio moves the answer by a whole
  /// item. Two consequences worth knowing:
  ///
  /// * `Decimal.affordGeometricSeries(1.dec, 1.dec, 1.5.dec, 0.dec)` is 0, not
  ///   1, because `log10(1.5) / log10(1.5)` evaluates to `0.9999999999999999`.
  ///   break_eternity.js does the same.
  /// * On roughly 1 in 16,000 exact round trips this port and break_eternity.js
  ///   land on either side of the edge and differ by one — the software
  ///   `log10` in `constants.dart` and V8's `Math.log10` disagree in the last
  ///   ulp on about 0.09% of inputs. In the cases examined it was this port
  ///   that gave the mathematically correct count, but the honest summary is
  ///   that neither side is reliable to the last item at an exact boundary.
  ///
  /// Neither is a reason to distrust the result away from an exact boundary,
  /// but do not build a test that asserts a specific count at one.
  static Decimal affordGeometricSeries(
    Decimal resourcesAvailable,
    Decimal priceStart,
    Decimal priceRatio,
    Decimal currentOwned,
  ) {
    final Decimal actualStart = priceStart * priceRatio.pow(currentOwned);
    return (((resourcesAvailable / actualStart) * (priceRatio - one) + one)
                .log10() /
            priceRatio.log10())
        .floor();
  }

  /// What buying [numItems] more items costs when the price multiplies.
  ///
  /// The exact inverse of [affordGeometricSeries]: same [priceStart],
  /// [priceRatio] and [currentOwned] semantics, but here you name the count and
  /// get the price of the whole batch — the geometric series
  /// `a*r^k + a*r^(k+1) + ... + a*r^(k+n-1)`.
  ///
  /// ```dart
  /// // The next 10 generators, at 10 gold base, ratio 1.15, owning 42:
  /// print(Decimal.sumGeometricSeries(10.dec, 10.dec, 1.15.dec, 42.dec));
  /// // 71925.828439959
  /// // ...and just the next one, which is priceStart * priceRatio^42:
  /// print(Decimal.sumGeometricSeries(1.dec, 10.dec, 1.15.dec, 42.dec));
  /// // 3542.49539895394
  /// ```
  ///
  /// Reference: `sumGeometricSeries_core`.
  static Decimal sumGeometricSeries(
    Decimal numItems,
    Decimal priceStart,
    Decimal priceRatio,
    Decimal currentOwned,
  ) =>
      priceStart *
      priceRatio.pow(currentOwned) *
      (one - priceRatio.pow(numItems)) /
      (one - priceRatio);

  /// How many more items you can afford when the price grows by a fixed step.
  ///
  /// The additive cousin of [affordGeometricSeries]: the first item cost
  /// [priceStart] and every subsequent one costs [priceAdd] more than the last,
  /// so owning [currentOwned] means the next one costs
  /// `priceStart + currentOwned * priceAdd`.
  ///
  /// ```dart
  /// // 1e6 gold, upgrades start at 100 and cost 50 more each time,
  /// // and you already own 42.
  /// print(Decimal.affordArithmeticSeries(
  ///   1e6.dec, 100.dec, 50.dec, 42.dec,
  /// )); // 161 — the next one costs 100 + 42*50 == 2200
  /// ```
  ///
  /// Solves `n = (-(a - d/2) + sqrt((a - d/2)^2 + 2dS)) / d` for `n`, where `a`
  /// is the next price, `d` is [priceAdd] and `S` is [resourcesAvailable], then
  /// floors it. Reference: `affordArithmeticSeries_core`.
  static Decimal affordArithmeticSeries(
    Decimal resourcesAvailable,
    Decimal priceStart,
    Decimal priceAdd,
    Decimal currentOwned,
  ) {
    final Decimal actualStart = priceStart + currentOwned * priceAdd;
    final Decimal b = actualStart - priceAdd / two;
    final Decimal b2 = b.pow(two);
    return ((-b + (b2 + priceAdd * resourcesAvailable * two).sqrt()) / priceAdd)
        .floor();
  }

  /// What buying [numItems] more items costs when the price grows by a step.
  ///
  /// The inverse of [affordArithmeticSeries], and the arithmetic series
  /// `(n/2) * (2a + (n-1)d)` where `a` is the next price
  /// (`priceStart + currentOwned * priceAdd`) and `d` is [priceAdd].
  ///
  /// ```dart
  /// // The next 10 upgrades, at 100 base, +50 each, owning 42:
  /// print(Decimal.sumArithmeticSeries(10.dec, 100.dec, 50.dec, 42.dec));
  /// // 24250
  /// ```
  ///
  /// Reference: `sumArithmeticSeries_core`, adapted from mathwords.com.
  static Decimal sumArithmeticSeries(
    Decimal numItems,
    Decimal priceStart,
    Decimal priceAdd,
    Decimal currentOwned,
  ) {
    final Decimal actualStart = priceStart + currentOwned * priceAdd;
    return numItems / two * (actualStart * two + (numItems - one) * priceAdd);
  }

  /// How wasteful a purchase is: **lower is better**.
  ///
  /// Given a purchase that costs [cost] and raises your income by [deltaRpS]
  /// per second while you currently earn [currentRpS] per second, this scores
  /// it as `cost/currentRpS + cost/deltaRpS` — the time spent saving up plus
  /// the time the purchase takes to pay for itself. Compare the scores of two
  /// candidate purchases and buy the smaller one.
  ///
  /// ```dart
  /// // Earning 1000/s: a 5e4 building that adds 100/s, or a 2e5 one
  /// // that adds 500/s?
  /// final cheap = Decimal.efficiencyOfPurchase(5e4.dec, 1000.dec, 100.dec);
  /// final dear = Decimal.efficiencyOfPurchase(2e5.dec, 1000.dec, 500.dec);
  /// print(cheap); // 550
  /// print(dear);  // 600 — so the cheap one wins
  /// ```
  ///
  /// Reference: `efficiencyOfPurchase_core`, from Frozen Cookies.
  static Decimal efficiencyOfPurchase(
    Decimal cost,
    Decimal currentRpS,
    Decimal deltaRpS,
  ) => cost / currentRpS + cost / deltaRpS;
}

/// Formats [value] the way JavaScript's `Number.prototype.toString` would.
///
/// This helper exists because `double.toString()` is *not* the same function:
/// Dart prints `5.0` where JavaScript prints `5`, and `9e+15` where
/// JavaScript prints `9000000000000000`. Since [Decimal.toString] is a
/// documented, round-trippable format that users compare against the
/// JavaScript original (and against saved games written by it), the output has
/// to match character for character.
///
/// The strategy is to take Dart's shortest round-tripping digits — which are
/// the same digits ECMA-262 asks for — and re-lay them out per the
/// `Number::toString` algorithm: plain notation while the decimal point sits
/// within `10^-7 .. 10^21`, exponential outside it.
String _jsNumberToString(double value) {
  if (value.isNaN) {
    return 'NaN';
  }
  if (value.isInfinite) {
    return value.isNegative ? '-Infinity' : 'Infinity';
  }
  if (value == 0.0) {
    return '0'; // Also covers -0.0, which JavaScript prints as "0".
  }

  final bool negative = value.isNegative;
  String digits = value.abs().toString();

  // Split off Dart's exponent, if it used one ("1.5e-7" -> "1.5", -7).
  int exponent = 0;
  final int eIndex = digits.indexOf('e');
  if (eIndex >= 0) {
    exponent = int.parse(digits.substring(eIndex + 1));
    digits = digits.substring(0, eIndex);
  }

  // Fold the fractional part into the exponent ("1.5" -> "15", -1).
  final int dot = digits.indexOf('.');
  if (dot >= 0) {
    exponent -= digits.length - dot - 1;
    digits = digits.substring(0, dot) + digits.substring(dot + 1);
  }

  // Strip padding zeroes so `digits` holds the significant digits only.
  int first = 0;
  while (first < digits.length - 1 && digits.codeUnitAt(first) == 0x30) {
    first++;
  }
  digits = digits.substring(first);
  while (digits.length > 1 && digits.endsWith('0')) {
    digits = digits.substring(0, digits.length - 1);
    exponent++;
  }

  // ECMA-262 Number::toString: value == 0.<digits> * 10^n, with k digits.
  final int k = digits.length;
  final int n = k + exponent;
  final String prefix = negative ? '-' : '';

  if (k <= n && n <= 21) {
    return '$prefix$digits${'0' * (n - k)}';
  }
  if (0 < n && n <= 21) {
    return '$prefix${digits.substring(0, n)}.${digits.substring(n)}';
  }
  if (-6 < n && n <= 0) {
    return '${prefix}0.${'0' * -n}$digits';
  }
  final String suffix = n - 1 >= 0 ? '+${n - 1}' : '-${1 - n}';
  if (k == 1) {
    return '$prefix${digits}e$suffix';
  }
  return '$prefix${digits[0]}.${digits.substring(1)}e$suffix';
}

/// Rounds [x] to the nearest integer, halves going towards positive infinity.
///
/// `double.roundToDouble()` rounds halves *away from zero*, so it disagrees
/// with JavaScript's `Math.round` on negative halves: `-2.5` is `-2` there and
/// `-3` here. Subtracting the floor keeps the classic `floor(x + 0.5)` bug
/// (which would round `0.49999999999999994` up to 1) out of the picture.
double _jsRound(double x) {
  if (x.isNaN || x.isInfinite) {
    return x;
  }
  final double floor = x.floorToDouble();
  return x - floor >= 0.5 ? floor + 1 : floor;
}

/// The `log10` from `constants.dart`, under a name the class body can see.
///
/// [Decimal] has a `log10()` *method*, and a class member shadows an imported
/// top-level function throughout the class body, so `log10(x)` inside the class
/// would resolve to the no-argument method. This alias lives at the top level,
/// where the import is still visible, and every internal caller goes through
/// it. It is the fdlibm port in `constants.dart` — deliberately software rather
/// than `math.log(x) / math.ln10`, so results are identical on the VM, dart2js
/// and Wasm. Never add a second base-10 logarithm.
double _log10(double x) => log10(x);

/// The `log2` from `constants.dart`, under a name the class body can see.
///
/// Exactly the same shadowing problem as [_log10]: [Decimal] has a `log2()`
/// method. The implementation is the fdlibm `__ieee754_log2` port, which is
/// bit-identical to V8's `Math.log2` across a 39,000-value corpus on both the
/// VM and dart2js — see its own doc. Never add a second base-2 logarithm.
double _log2(double x) => log2(x);

/// `10^exponent` as a `double`. Reference: the `Math.pow(10, ...)` in `pow10`.
///
/// Integral exponents go through the exact lookup table in `constants.dart`
/// rather than `math.pow`, as a reproducibility guard: this is the step that
/// turns a layer-1 value back into a plain `double`, so an ulp lost here is an
/// ulp lost by every [Decimal.pow], [Decimal.root] and [Decimal.exp] result
/// that lands at layer 0.
///
/// On the two targets measured (Dart 3.12 VM on macOS arm64, and dart2js on
/// Node 24 on the same machine) the guard is a no-op: `math.pow(10, e)` is the
/// correctly rounded `double` for all 632 integral exponents in `[-323, 308]`
/// on both, and V8's `Math.pow(10, n)` agrees.
///
/// Do not read that as "the guard is unnecessary". Both measurements are from
/// one CPU architecture, and `math.pow` is demonstrably not architecture-stable
/// under dart2js: `Decimal.fromNum(-4).pow10()`, which reaches `math.pow` with
/// a *fractional* exponent by way of [Decimal._normalize], is exactly 1e-4 on
/// macOS/arm64 and 9.999999999999999e-5 on Linux/x64. ECMAScript leaves
/// `Math.pow`'s accuracy implementation-defined and the host libm the VM and
/// Wasm use is not specified to be exact either, so on an unmeasured host the
/// integral branch may well diverge too. The table costs one comparison.
///
/// Note that the exponent must be a `double`, not an `int`: `math.pow` with
/// two `int` arguments does exact *integer* arithmetic, which on the VM wraps
/// at 64 bits, so `math.pow(10, 22)` is `1864712049423024128`.
double _pow10Double(double exponent) {
  if (exponent == exponent.floorToDouble() &&
      exponent >= numberExpMin + 1 &&
      exponent <= numberExpMax) {
    return powerOf10(exponent.toInt());
  }
  return math.pow(10, exponent).toDouble();
}

/// Signed log10: `sign(n) * log10(|n|)`. Reference: `f_maglog10`.
double _magLog10(double n) => n.sign * _log10(n.abs());

/// [_decimalPlaces] rendered with JavaScript's number formatting.
///
/// The reference builds these strings by concatenating a `number` with `+`,
/// which invokes `Number::toString`; going through `double.toString()` instead
/// would print `ee16.0` where JavaScript prints `ee16`.
String _places(double value, int places) =>
    _jsNumberToString(_decimalPlaces(value, places));

/// Rounds [value] to [places] significant decimal places.
///
/// Reference: the `decimalPlaces` helper, itself lifted from
/// https://stackoverflow.com/a/37425022.
double _decimalPlaces(double value, int places) {
  final double len = places + 1.0;
  final double numDigits = _log10(value.abs()).ceilToDouble();
  final double rounded =
      _jsRound(value * math.pow(10, len - numDigits).toDouble()) *
      math.pow(10, numDigits - len).toDouble();
  final double fractionDigits = math.max(len - numDigits, 0);
  if (fractionDigits.isNaN) {
    // `value` is NaN, so `numDigits` and `rounded` are NaN too. JavaScript's
    // `Number.prototype.toFixed` coerces a NaN argument to 0, so the reference
    // evaluates `parseFloat(NaN.toFixed(NaN))` and gets NaN back. Dart's
    // `double.toInt()` throws `UnsupportedError` on NaN instead, which would
    // turn formatting a NaN `Decimal` into a crash rather than the string
    // "(e^NaN)NaN" that the reference produces.
    return double.nan;
  }
  return double.parse(rounded.toStringAsFixed(fractionDigits.toInt()));
}
