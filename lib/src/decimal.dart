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
      _normalize(mantissa.sign, 1, exponent + log10(mantissa.abs()));

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
      return Decimal._(sign, layer + 1, log10(mag));
    }

    double absmag = mag.abs();
    double signmag = mag.sign;

    // Rule 5: a mag too big for a double's integer range moves up a layer.
    // One step always suffices: log10 of anything <= 1.8e308 is under 309.
    if (absmag >= expLimit) {
      return Decimal._(sign, layer + 1, signmag * log10(absmag));
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
  /// Milestone 1 accepts exactly the grammar [toString] can emit, after
  /// trimming surrounding whitespace:
  ///
  /// * `NaN`, `Infinity`, `-Infinity` (case-insensitive);
  /// * a plain decimal number, e.g. `-12.5`;
  /// * scientific notation, e.g. `1.5e-300`;
  /// * a run of up to five leading `e`s, e.g. `ee15.9`, `-eee1234`;
  /// * the layer syntax `(e^N)M`, e.g. `(e^7)16.5`, for integral `N >= 0`.
  ///
  /// Anything else — `x^y`, `x^^y`, `x^^^y`, `XPY`, `XFY`, thousands
  /// separators, a fractional or negative layer in `(e^N)M` — returns `null`
  /// rather than a wrong number. TODO(m3): support the full grammar, which
  /// needs `pow`, `tetrate` and `pentate`.
  ///
  /// Note that JavaScript's `parseFloat` is lenient where Dart's
  /// `double.parse` is strict: `parseFloat('5 apples')` is `5`, while this
  /// returns `null`. Silently mis-parsing is the worse failure mode.
  static Decimal? tryParse(String source) {
    final String value = source.trim();
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
      // own output always parses; the value checks live here. A fractional or
      // negative layer needs `tetrate`, which milestone 1 does not have, and an
      // overflowing one is not a layer at all.
      final double? towerLayer = double.tryParse(tower.group(2)!);
      if (towerLayer == null ||
          !towerLayer.isFinite ||
          towerLayer < 0 ||
          towerLayer != towerLayer.floorToDouble()) {
        return null;
      }
      return _normalize(tower.group(1) == '-' ? -1 : 1, towerLayer, towerMag);
    }

    // Anything else containing a caret is pow/tetrate/pentate syntax.
    if (lower.contains('^')) {
      return null; // TODO(m3): x^y, x^^y and x^^^y.
    }

    final int ecount = 'e'.allMatches(lower).length;

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

    // A run of leading `e`s: `eee15.9` is 10^10^10^15.9. Reference: the
    // `!isFinite(mantissa)` branch of `fromString`.
    final RegExpMatch? repeated = _repeatedEPattern.firstMatch(lower);
    if (repeated != null) {
      final double? repeatedMag = double.tryParse(repeated.group(3)!);
      if (repeatedMag == null) {
        return null;
      }
      return _normalize(
        repeated.group(1) == '-' ? -1 : 1,
        repeated.group(2)!.length.toDouble(),
        repeatedMag,
      );
    }

    // `MeX` where the double parse above declined, i.e. very small or very
    // large exponents. Reference: the `ecount === 1` branch of `fromString`.
    if (ecount == 1) {
      final RegExpMatch? scientific = _scientificPattern.firstMatch(lower);
      if (scientific != null) {
        final double mantissa = double.parse(scientific.group(1)!);
        if (mantissa == 0) {
          return zero;
        }
        final double exponent = double.parse(scientific.group(2)!);
        // 2e10 is 10^log10(2e10), which is 10^(10 + log10(2)).
        return _normalize(mantissa.sign, 1, exponent + log10(mantissa.abs()));
      }
    }

    // TODO(m3): `AeBeC`, `XPY`, `X PT Y`, `XFY` and comma separators.
    return null;
  }

  /// The longest input [tryParse] will look at. See the guard in [tryParse].
  static const int _maxParseLength = 4096;

  /// `(e^N)M`, optionally signed. `N` accepts scientific notation as well as a
  /// plain digit run, because [toString] emits `(e^1e+21)16` for layers at or
  /// above 1e21 — including [layerMax] and [layerMin] — and a serialiser whose
  /// output its own parser rejects corrupts saves. Non-integral, negative and
  /// overflowing layers are matched here but rejected in [tryParse]: the
  /// reference falls back to `tetrate` for `(e^-8)1` and `(e^10.5)1`, which
  /// milestone 1 does not have.
  static final RegExp _layerPattern = RegExp(
    r'^([+-]?)\(e\^(\d+(?:\.\d+)?(?:e[+-]?\d+)?)\)(.+)$',
  );

  /// A signed run of `e`s followed by a plain decimal magnitude, e.g. `-ee-16`.
  static final RegExp _repeatedEPattern = RegExp(
    r'^([+-]?)(e+)(-?\d+(?:\.\d+)?)$',
  );

  /// `MeX`, both parts plain decimals.
  static final RegExp _scientificPattern = RegExp(
    r'^([+-]?\d+(?:\.\d+)?)e([+-]?\d+(?:\.\d+)?)$',
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
      final double exp = log10(mag).floorToDouble();
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
      return log10(mag).floorToDouble();
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
      if ((b.mag - log10(a.mag)).abs() > maxSignificantDigits) {
        return a;
      }
      final double magdiff = math.pow(10, log10(a.mag) - b.mag).toDouble();
      final double mantissa = b.sign + a.sign * magdiff;
      return _normalize(mantissa.sign, 1, b.mag + log10(mantissa.abs()));
    }

    if (layerA == 1 && layerB == 0) {
      if ((a.mag - log10(b.mag)).abs() > maxSignificantDigits) {
        return a;
      }
      final double magdiff = math.pow(10, a.mag - log10(b.mag)).toDouble();
      final double mantissa = b.sign + a.sign * magdiff;
      return _normalize(mantissa.sign, 1, log10(b.mag) + log10(mantissa.abs()));
    }

    // Short-circuits 3 and 4: both operands are layer 1.
    if ((a.mag - b.mag).abs() > maxSignificantDigits) {
      return a;
    }
    final double magdiff = math.pow(10, a.mag - b.mag).toDouble();
    final double mantissa = b.sign + a.sign * magdiff;
    return _normalize(mantissa.sign, 1, b.mag + log10(mantissa.abs()));
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
      return _normalize(a.sign * b.sign, 1, a.mag + log10(b.mag));
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
  /// `(-5).remainder(2)`. Reference: `mod()` with `floored: false`;
  /// TODO(m3): expose the floored variant.
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

/// Signed log10: `sign(n) * log10(|n|)`. Reference: `f_maglog10`.
double _magLog10(double n) => n.sign * log10(n.abs());

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
  final double numDigits = log10(value.abs()).ceilToDouble();
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
