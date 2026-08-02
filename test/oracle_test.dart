/// The native-`double` oracle suite.
///
/// Every operation is computed twice: once with [Decimal] and once with a
/// plain `double`, and the two answers are compared within a *relative*
/// tolerance. `double` is the oracle only where `double` is trustworthy, so a
/// case is skipped (never weakened) when the `double` answer overflows to
/// infinity, underflows to zero, or is NaN — those are exactly the cases this
/// library exists to get right, and they are covered by
/// `test/fixtures_test.dart` and `test/decimal_test.dart` instead.
///
/// The tolerances are not guesses. Measured over the value set below, the
/// worst relative disagreement between `Decimal` and `double` is 7.8e-14, and
/// most of that is not arithmetic error at all: it is the cost of the round
/// trip through the layered representation. `1.98e-241` alone comes back from
/// `Decimal.fromNum(...).toDouble()` with a relative error of 5.6e-14, because
/// above 9e15 (and below 1/9e15) a `Decimal` stores `log10` of the magnitude
/// and a `double` mantissa only has ~15.95 digits of it. Every group states
/// the tolerance it uses in its name; [_arithmeticTolerance] sits about an
/// order of magnitude above the measured worst case, which is loose enough to
/// absorb the representation error and far too tight to hide a real bug (a
/// real bug in this code shows up as a wrong factor or a wrong exponent, not
/// as a wrong 13th digit). [_powerTolerance] is two orders looser again, for
/// the operations that reach their answer through `log10` and `pow10` rather
/// than by multiplying; it is measured the same way.
///
/// Where the port *is* exact, that is asserted exactly: see the
/// "bit-exact" group, which pins every pair whose operands survive the round
/// trip unchanged.
library;

import 'dart:math' as math;

import 'package:break_eternity/break_eternity.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The combinators
// ---------------------------------------------------------------------------

/// The fundamental values: zero, the units, values either side of one, and the
/// three non-finite states.
///
/// `1.1`/`0.9` and their negations are here because they are the smallest
/// inputs that distinguish [Decimal.floor], [Decimal.ceil], [Decimal.round]
/// and [Decimal.truncate] from one another in all four sign/direction
/// combinations.
const List<double> _fundamentals = <double>[
  0,
  1,
  -1,
  1.1,
  -1.1,
  0.9,
  -0.9,
  double.infinity,
  double.negativeInfinity,
  double.nan,
];

/// A spread of magnitudes straddling every representation boundary.
///
/// `0.5` and `2` are layer 0; `1e-30` and `1e30` are layer 1 just past the
/// `1/9e15 .. 9e15` window, so they exercise the log-space paths while still
/// fitting in a `double`; `1.98e-241` and `7.23e222` are near the ends of a
/// `double`'s exponent range, so their products and quotients straddle
/// overflow and underflow. The odd mantissas are deliberate: a mantissa of 1
/// would hide errors that a mantissa of 7.23 exposes.
const List<double> _magnitudes = <double>[
  1.98e-241,
  1e-30,
  0.5,
  2,
  1e30,
  7.23e222,
];

/// The full combinator set. Binary operations are tested over all 256 ordered
/// pairs of these.
const List<double> _all = <double>[..._fundamentals, ..._magnitudes];

/// Extra layer-0 values for the supplementary `%` group.
///
/// [Decimal.operator %] can only be checked against the hardware remainder for
/// operands that round-trip exactly (see [_remainderGuard]), which rules out
/// every member of [_magnitudes]. These fill the gap: all are below 9e15, so
/// they are stored verbatim in `mag` and round-trip bit-for-bit, and they
/// include pairs with a large quotient (`1e15 % 0.25`), an exact division
/// (`1000 % 10`), and both signs.
const List<double> _layerZeroSpread = <double>[
  0,
  1,
  2,
  3,
  7,
  -7,
  10,
  1000,
  12345.678,
  1e15,
  -1e15,
  0.25,
  -0.25,
];

/// Exponents spanning the whole range over which `math.exp` is trustworthy.
///
/// [_all] is a poor value set for [Decimal.exp]: `e ^ 1e30` overflows a
/// `double` long before it troubles a `Decimal`, so every one of its large
/// members skips and what is left is a cluster around 1. These do not skip.
/// The range starts at -700, where `math.exp` is 9.9e-305 — the smallest
/// result still normal enough that a `double` carries full precision — and
/// stops at 710, the first entry that overflows. In between it straddles
/// 709.7, which is the reference's own cutoff between "hand it to `Math.exp`"
/// and "build the answer in log space", so both branches of [Decimal.exp] are
/// exercised against a `double` that can still hold the answer.
const List<double> _expSpread = <double>[
  -700,
  -100,
  -10,
  -2,
  -1,
  -0.5,
  -0.1,
  0,
  0.1,
  0.5,
  1,
  2,
  10,
  100,
  700,
  709.7,
  709.78,
  710,
];

/// Radicands for the supplementary `root` group, paired with [_rootDegrees].
///
/// Deliberately heavy on negatives, and on negatives at more than one layer:
/// the rule that a negative radicand survives an odd-integer degree is the one
/// thing `root` does that `pow` does not, and [_all] cannot reach it, because
/// its only odd-integer members are 1 and -1 and `pow` gets those right on its
/// own (see [_isOddInteger]).
const List<double> _rootRadicands = <double>[
  -1e30,
  -8,
  -2,
  -1.1,
  0,
  0.5,
  2,
  8,
  1e30,
  7.23e222,
];

/// Degrees for the supplementary `root` group.
///
/// Odd and even integers of both signs, so the parity rule is exercised in
/// every combination, plus two non-integers to pin the boundary: a negative
/// radicand under 0.5 is legal (it is a squaring), under 1.5 it is not.
const List<double> _rootDegrees = <double>[1, 2, 3, 4, 5, -1, -2, -3, 0.5, 1.5];

// ---------------------------------------------------------------------------
// Tolerances
// ---------------------------------------------------------------------------

/// Relative tolerance for arithmetic, ~13x the measured worst case of 7.8e-14.
const double _arithmeticTolerance = 1e-12;

/// Relative tolerance for the operations that go through `log10` and `pow10`.
///
/// [Decimal.pow] and everything built on it do not multiply: they take a
/// logarithm, scale it, and exponentiate. That costs about two decimal digits,
/// because an absolute error of `d` in a base-10 exponent becomes a relative
/// error of `10^d - 1` in the answer, and the exponent of a value like
/// `7.23e222` is only known to about 1e-14 in the first place. Measured over
/// the value set below the worst disagreement is 3.3e-13, at
/// `7.23e222 ^ -1.1`; this sits about 30x above that. It is still far too
/// tight to hide a wrong constant, a wrong branch or a dropped sign, which is
/// what a real bug in these methods looks like.
const double _powerTolerance = 1e-11;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

typedef _UnaryDecimalOp = Decimal Function(Decimal a);
typedef _UnaryDoubleOp = double Function(double a);
typedef _BinaryDecimalOp = Decimal Function(Decimal a, Decimal b);
typedef _BinaryDoubleOp = double Function(double a, double b);

/// Renders [value] the way this file wants to see it in a test name.
///
/// `double.toString()` prints `Infinity`/`NaN` already, but going through this
/// helper keeps the names stable if that ever changes.
String _label(double value) {
  if (value.isNaN) {
    return 'NaN';
  }
  if (value == double.infinity) {
    return 'Infinity';
  }
  if (value == double.negativeInfinity) {
    return '-Infinity';
  }
  return value.toString();
}

/// `1e-12`, for embedding a tolerance in a group name.
String _formatTolerance(double tolerance) =>
    tolerance == 0 ? 'exact' : tolerance.toStringAsExponential(0);

/// Fails unless [actual] and [expected] agree to within a *relative*
/// [tolerance].
///
/// Relative, not absolute, because the whole point of the value set is that it
/// spans 460 orders of magnitude: an absolute tolerance that is meaningful for
/// `1.1` would accept literally any answer for `7.23e222`, and one meaningful
/// for `1.98e-241` would reject every answer above 1.
///
/// The error is scaled by the larger of the two magnitudes, so the check is
/// symmetric and cannot be gamed by a tiny `actual`. A NaN on either side (a
/// `Decimal` that went NaN where `double` did not) yields a NaN error, which
/// fails the comparison — as it should.
void _expectClose(
  double actual,
  double expected,
  double tolerance,
  String what,
) {
  // Catches the exact hits, including `0.0 == -0.0`, before dividing by zero.
  if (actual == expected) {
    return;
  }
  final double scale = math.max(actual.abs(), expected.abs());
  final double error = (actual - expected).abs() / scale;
  expect(
    error <= tolerance,
    isTrue,
    reason:
        '$what\n'
        '  double  : $expected\n'
        '  Decimal : $actual\n'
        '  relative error ${error.toStringAsExponential(3)} exceeds '
        '${_formatTolerance(tolerance)}',
  );
}

/// Compares one case, either as a number or as a shared domain error.
///
/// When [domainError] is set, the caller has declared that this input has no
/// answer at all — `log10(-1)`, `(-1.1) ^ 0.5` — and that both sides say so.
/// Two things are then asserted: that the `double` oracle really is NaN (which
/// keeps the caller's predicate honest, so a mistake in it shows up as a
/// failure rather than as a silently weakened test), and that the `Decimal` is
/// NaN too. Otherwise this is [_expectClose] on `toDouble()`.
void _expectMatch(
  Decimal got,
  double want,
  double tolerance,
  String what,
  bool domainError,
) {
  if (domainError) {
    expect(
      want.isNaN,
      isTrue,
      reason:
          '$what\n  the oracle claims a domain error, but double says $want',
    );
    expect(
      got.isNaN,
      isTrue,
      reason: '$what\n  double is NaN, so Decimal must be NaN, but it is $got',
    );
    return;
  }
  _expectClose(got.toDouble(), want, tolerance, what);
}

/// `, 17 of 18 cases live`, for a group that skips enough to be worth counting.
///
/// Only asked for where the skips are the interesting part — [Decimal.exp]
/// overflows a `double` almost immediately, so without this a reader has no
/// way to tell a thorough group from an empty one at a glance. Counted rather
/// than written down, so it cannot go stale when the value set changes.
String _liveCountSuffix(List<Object?> skips, bool announce) {
  if (!announce) {
    return '';
  }
  final int live = skips.where((Object? skip) => skip == null).length;
  return ', $live of ${skips.length} cases live';
}

/// Why this case cannot be judged against `double`, or `null` if it can.
///
/// [zeroIsGenuine] says whether a `double` result of zero means "the answer
/// really is zero" (`2 - 2`, `floor(0.9)`, `1 / Infinity`) or "the answer was
/// too small for a `double`" (`1.98e-241 * 1.98e-241`). In the second case
/// `Decimal` is right and `double` is wrong, so there is nothing to compare.
String? _skipReason(double want, {required bool zeroIsGenuine}) {
  if (want.isNaN) {
    return 'the double oracle is NaN';
  }
  if (want.isInfinite) {
    return 'the double oracle overflows to infinity';
  }
  if (want == 0 && !zeroIsGenuine) {
    return 'the double oracle underflows to zero';
  }
  return null;
}

/// Whether [value] survives `Decimal.fromNum(value).toDouble()` unchanged.
///
/// True for everything at layer 0 (where `mag` *is* the number) and for the
/// infinities; false for NaN and for anything stored in log space.
bool _roundTripsExactly(double value) =>
    !value.isNaN && value.dec.toDouble() == value;

/// The values from [_all] that a `Decimal` can hold without losing a bit.
final List<double> _exactValues = _all.where(_roundTripsExactly).toList();

/// Refuses `%` cases whose operands do not round-trip exactly.
///
/// [Decimal.operator %] delegates to the hardware remainder whenever both
/// operands fit in a `double`, so on exact operands it is exact. On inexact
/// ones it is not merely imprecise, it is meaningless: `remainder` is an exact
/// operation on whatever it is handed, so perturbing `7.23e222` by one part in
/// 1e14 moves the true remainder modulo `1.98e-241` by ~1e209 — the answers
/// disagree in the first digit, and rightly so. Comparing them would test
/// nothing but the round-trip error, so those pairs are skipped here and left
/// to the JavaScript-generated fixtures.
String? _remainderGuard(double a, double b) =>
    _roundTripsExactly(a) && _roundTripsExactly(b)
    ? null
    : 'an operand does not round-trip through Decimal exactly, and the '
          'remainder of a perturbed operand is not comparable';

/// Whether this pair trips the upstream `cmpabs` zero bug.
///
/// `cmpabs` starts by folding the sign of `mag` into the layer, so that a
/// reciprocal (`layer >= 1` with a negative `mag`, i.e. anything under
/// 1/9e15) sorts below layer 0:
///
/// ```js
/// const layera = this.mag > 0 ? this.layer : -this.layer;
/// ```
///
/// Zero has `mag == 0`, which is not `> 0`, so it takes the `-this.layer`
/// branch and comes out as `-0` — numerically equal to layer 0, not below it.
/// Comparing zero against `1e-30` therefore compares layer `-0` against layer
/// `-1` and concludes that `|0| > |1e-30|`.
///
/// This is not a porting mistake. break_eternity.js 2.1.3 does the same thing
/// (`new Decimal(0).cmpabs(new Decimal(1e-30)) === 1`), the fixtures generated
/// from it will encode it, and the contract says the reference wins on
/// behaviour — so the port is correct as specified and the *oracle* is the one
/// that has to stand aside. Note that signed `cmp` is unaffected: it settles
/// zero-versus-nonzero on the `sign` field before it ever reaches `cmpabs`.
bool _tripsCmpAbsZeroBug(double a, double b) {
  final Decimal da = a.dec;
  final Decimal db = b.dec;
  return (da.isZero && db.mag < 0) || (db.isZero && da.mag < 0);
}

/// Whether the logarithm of [a] is a domain error on both sides.
///
/// Every logarithm here is real-valued, so a negative argument is not a
/// limitation of `double` — it is a question with no answer: `math.log`
/// returns NaN and the reference returns [Decimal.nan]. That agreement is
/// asserted rather than skipped, because a port that returned some number for
/// `log10(-1)` would otherwise slip through disguised as a skip. NaN in, NaN
/// out for the same reason.
///
/// Zero is deliberately absent. `log10(0)` is `-Infinity` in IEEE and
/// [Decimal.nan] here (the reference gives up on `sign <= 0` as a whole), so
/// the two are not comparable and the case skips as an overflow.
bool _logDomainError(double a) => a.isNaN || a < 0;

/// Refuses `log(base)` cases whose base makes the double oracle meaningless.
///
/// A base of zero or one has no logarithm to speak of, and [Decimal.log] says
/// so with [Decimal.nan] — both are special-cased in the reference. The oracle
/// cannot say so, because it is a ratio: it divides by `log(0) == -Infinity`
/// and gets a signed zero, or by `log(1) == 0` and gets an infinity. Neither
/// disagreement is about the port.
String? _logBaseGuard(double a, double b) {
  if (b == 0) {
    return 'a base of zero is NaN in Decimal, while the double oracle divides '
        'by log(0) == -Infinity and returns a signed zero';
  }
  if (b == 1) {
    return 'a base of one has no logarithm (every power of 1 is 1): Decimal '
        'returns NaN, while the double oracle divides by log(1) == 0';
  }
  // Above layer 0, `log(base)` is `log10() / base.log10()`, and a `Decimal`
  // quotient involving an infinity comes back as that infinity whatever the
  // other operand is — `Decimal.infinity / Decimal.nan` is `Infinity`, not NaN.
  // So an infinite value swallows a base it should have choked on. The
  // negatives never get this far (`log` rejects a negative base outright), so
  // the only base left that a `double` would propagate is NaN.
  // break_eternity.js 2.1.3 answers `Infinity` here as well.
  if (a == double.infinity && !b.isFinite) {
    return 'an infinite value makes log10() infinite, and a Decimal quotient '
        'involving an infinity is that infinity regardless of the other '
        'operand, so the base is never consulted';
  }
  return null;
}

/// Refuses `pow` and `root` cases with a non-finite operand.
///
/// [Decimal.pow] is `10 ^ (log10(|a|) * b)` — a logarithm, a multiplication and
/// an exponentiation, none of which consults IEEE's table of special cases for
/// infinite arguments. The multiplication is the interesting one: a `Decimal`
/// product involving an infinity takes the sign of the *infinity* and drops the
/// other factor's, so `Decimal.fromNum(-0.5) * Decimal.infinity` is
/// `+Infinity`. Downstream of that, `0.9.dec.pow(Decimal.infinity)` is
/// `Infinity` where `math.pow(0.9, double.infinity)` is 0, and
/// `Decimal.infinity.pow((-1).dec)` is `Infinity` where `math.pow(inf, -1)` is
/// 0.
///
/// break_eternity.js 2.1.3 answers identically on all of them, so the port is
/// correct as specified and the oracle is the one that has to stand aside; the
/// JavaScript-generated fixtures pin the actual values.
String? _powNonFiniteGuard(double a, double b) => a.isFinite && b.isFinite
    ? null
    : 'pow goes through log10, multiplication and pow10, and a Decimal product '
          'involving an infinity keeps the sign of the infinity rather than of '
          'the product, so the IEEE special cases for infinite arguments are '
          'not reproduced here (nor are they upstream)';

/// Whether `a ^ b` is a domain error on both sides.
///
/// A negative base has no real power at a non-integer exponent: `math.pow`
/// returns NaN, and [Decimal.pow] returns [Decimal.nan] once it finds the
/// exponent's parity is neither 0 nor 1. Both sides mean it, so it is asserted.
/// Only finite operands reach here — [_powNonFiniteGuard] has taken the rest.
bool _powDomainError(double a, double b) =>
    a < 0 && b.isFinite && b != b.roundToDouble();

/// Whether [value] is an odd integer, the degrees at which a negative radicand
/// still has a real root.
///
/// Mirrors the reference's `mod(2, floored: true) == 1` test, which
/// [Decimal.root] uses to decide whether to take the root of the magnitude and
/// put the sign back. The floored and truncated moduli disagree on the sign of
/// the answer for a negative operand but not on its magnitude, so taking the
/// absolute value of `remainder` gets to the same place.
bool _isOddInteger(double value) =>
    value.isFinite &&
    value == value.roundToDouble() &&
    value.remainder(2).abs() == 1;

/// `a` to the power `1 / b`, with the odd-root rule IEEE `pow` does not have.
///
/// `math.pow` refuses every negative base at a non-integer exponent, so it
/// calls `math.pow(-8, 1 / 3)` NaN — but -8 does have a real cube root, and
/// both [Decimal.root] and ordinary mathematics say it is -2. The oracle has to
/// do the same thing [Decimal.root] does: take the root of the magnitude and
/// put the sign back. It is not circular to compute the oracle this way —
/// `math.pow` still does all the arithmetic, and the identity being asserted
/// (`(-x).root(odd) == -(x.root(odd))`) is a fact about roots, not a copy of
/// the implementation.
double _rootOracle(double a, double b) => a < 0 && _isOddInteger(b)
    ? -math.pow(-a, 1 / b).toDouble()
    : math.pow(a, 1 / b).toDouble();

/// Whether `a.root(b)` is a domain error on both sides.
///
/// A negative radicand has no real root at an even-integer or fractional
/// degree, and neither side pretends otherwise. The odd-integer degrees are
/// excluded because those are precisely the ones that do have an answer.
bool _rootDomainError(double a, double b) =>
    !_isOddInteger(b) && _powDomainError(a, 1 / b);

/// Refuses `root` cases with a degree of zero, then defers to [_powNonFiniteGuard].
///
/// `a.root(b)` is `a.pow(1 / b)`, and `Decimal.zero.reciprocal()` is
/// [Decimal.nan] rather than infinity — a documented divergence of its own —
/// so every zeroth root is NaN here. The oracle instead raises to the power
/// `1 / 0 == Infinity` and gets 0, 1 or infinity depending on the radicand.
String? _rootGuard(double a, double b) => b == 0
    ? 'a zeroth root raises to the power of the reciprocal of zero, which is '
          'NaN in Decimal rather than infinity, so the answer is NaN while the '
          'double oracle raises to the power of Infinity'
    : _powNonFiniteGuard(a, b);

/// Refuses `sqrt` cases the reference does not answer sensibly.
///
/// [Decimal.sqrt] dispatches on [Decimal.layer], and only the layer-0 branch
/// goes through `math.sqrt`; the others manipulate the magnitude directly and
/// never look at the sign or check that the magnitude is positive. So the
/// square root of anything below `1/9e15` takes `log10` of a negative `mag` and
/// comes out NaN, and the square root of a negative above `9e15` comes out as a
/// perfectly confident number. break_eternity.js 2.1.3 agrees on both
/// (`new Decimal(1e-30).sqrt()` is NaN there too), so these are skipped rather
/// than accommodated, and the fixtures record what the reference actually says.
String? _sqrtGuard(double a) {
  final Decimal d = a.dec;
  if (d.layer > 0 && d.mag < 0) {
    return 'upstream break_eternity.js bug: sqrt() at layer 1 evaluates '
        'log10(mag), and the mag of a value below 1/9e15 is negative, so the '
        'answer is NaN';
  }
  if (d.layer > 0 && d.sign < 0) {
    return 'upstream break_eternity.js bug: sqrt() only consults the sign at '
        'layer 0, so the square root of a negative above 9e15 is a number '
        'rather than NaN';
  }
  return null;
}

/// Refuses `exp` of negative infinity.
///
/// [Decimal.exp] dispatches on [Decimal.layer] too, and [Decimal.negativeInfinity]
/// is `sign == -1` at an infinite layer, so it lands in the layer-2+ branch:
/// that adds a layer and hands back an infinity, making `e ^ -Infinity` come
/// out as `Infinity` instead of 0. break_eternity.js 2.1.3 does the same.
String? _expGuard(double a) => a == double.negativeInfinity
    ? 'Decimal.exp() dispatches on layer, and -Infinity lands in the layer-2+ '
          'branch, so it returns Infinity where the double oracle returns 0'
    : null;

/// Runs [onDecimal] and [onDouble] over every value in [values].
void _unaryGroup({
  required String title,
  required String Function(String operand) label,
  required _UnaryDecimalOp onDecimal,
  required _UnaryDoubleOp onDouble,
  double tolerance = _arithmeticTolerance,
  List<double> values = _all,
  bool Function(double a)? zeroIsGenuine,
  bool Function(double a)? nanIsGenuine,
  String? Function(double a)? guard,
  bool announceLiveCount = false,
}) {
  final List<Object?> skips = <Object?>[
    for (final double a in values)
      guard?.call(a) ??
          ((nanIsGenuine?.call(a) ?? false)
              ? null
              : _skipReason(
                  onDouble(a),
                  zeroIsGenuine: zeroIsGenuine?.call(a) ?? true,
                )),
  ];
  final String suffix = _liveCountSuffix(skips, announceLiveCount);

  group(
    '$title (relative tolerance ${_formatTolerance(tolerance)}$suffix)',
    () {
      for (int i = 0; i < values.length; i++) {
        final double a = values[i];
        final String name = label(_label(a));
        final double want = onDouble(a);
        final bool domainError = nanIsGenuine?.call(a) ?? false;
        test(name, () {
          _expectMatch(onDecimal(a.dec), want, tolerance, name, domainError);
        }, skip: skips[i]);
      }
    },
  );
}

/// Runs [onDecimal] and [onDouble] over every ordered pair from [values].
///
/// The right-hand operand comes from [rightValues] when the two sides want
/// different value sets — an exponent or a degree is a different kind of thing
/// from the number it applies to, and useful ones (3, 4, 5) are not useful
/// magnitudes.
void _binaryGroup({
  required String title,
  required String symbol,
  required _BinaryDecimalOp onDecimal,
  required _BinaryDoubleOp onDouble,
  double tolerance = _arithmeticTolerance,
  List<double> values = _all,
  List<double>? rightValues,
  bool Function(double a, double b)? zeroIsGenuine,
  bool Function(double a, double b)? nanIsGenuine,
  String? Function(double a, double b)? guard,
  bool announceLiveCount = false,
}) {
  final List<double> rights = rightValues ?? values;
  final List<Object?> skips = <Object?>[
    for (final double a in values)
      for (final double b in rights)
        guard?.call(a, b) ??
            ((nanIsGenuine?.call(a, b) ?? false)
                ? null
                : _skipReason(
                    onDouble(a, b),
                    zeroIsGenuine: zeroIsGenuine?.call(a, b) ?? true,
                  )),
  ];
  final String suffix = _liveCountSuffix(skips, announceLiveCount);

  group(
    '$title (relative tolerance ${_formatTolerance(tolerance)}$suffix)',
    () {
      int i = 0;
      for (final double a in values) {
        for (final double b in rights) {
          final String name = '${_label(a)} $symbol ${_label(b)}';
          final double want = onDouble(a, b);
          final bool domainError = nanIsGenuine?.call(a, b) ?? false;
          final Object? skip = skips[i++];
          test(name, () {
            _expectMatch(
              onDecimal(a.dec, b.dec),
              want,
              tolerance,
              name,
              domainError,
            );
          }, skip: skip);
        }
      }
    },
  );
}

void main() {
  // -------------------------------------------------------------------------
  // The harness itself: if `toDouble` lies, every group below is worthless.
  // -------------------------------------------------------------------------

  group('toDouble round trip (relative tolerance 1e-12)', () {
    for (final double a in _all) {
      test(_label(a), () {
        if (a.isNaN) {
          expect(a.dec.isNaN, isTrue, reason: 'NaN must survive as NaN');
          return;
        }
        _expectClose(
          a.dec.toDouble(),
          a,
          _arithmeticTolerance,
          'Decimal.fromNum(${_label(a)}).toDouble()',
        );
      });
    }
  });

  group('predicates', () {
    for (final double a in _all) {
      test(_label(a), () {
        final Decimal d = a.dec;
        expect(d.isNaN, a.isNaN, reason: 'isNaN');
        expect(d.isInfinite, a.isInfinite, reason: 'isInfinite');
        expect(d.isFinite, a.isFinite, reason: 'isFinite');
        expect(d.isZero, a == 0, reason: 'isZero');
        // `double.isNegative` is true for -0.0 and false for NaN; `Decimal`
        // has no -0.0 (normalisation folds it into zero) and reports false for
        // NaN, so `a < 0` is the oracle that agrees with both.
        expect(d.isNegative, a < 0, reason: 'isNegative');
        // Documented divergence: `double.nan.sign` is NaN, but `signum`
        // returns an `int`, which has no NaN, so it reports 0.
        expect(d.signum, a.isNaN ? 0 : a.sign.toInt(), reason: 'signum');
      });
    }
  });

  // `mantissa * 10^exponent` should reconstruct the original number. Only
  // meaningful while the exponent still fits in a `double`, which is every
  // finite value here.
  group('mantissa and exponent (relative tolerance 1e-12)', () {
    for (final double a in _all.where((double v) => v.isFinite)) {
      final String name = '${_label(a)} == mantissa * 10^exponent';
      test(name, () {
        final Decimal d = a.dec;
        final double rebuilt = d.mantissa * math.pow(10, d.exponent).toDouble();
        _expectClose(rebuilt, a, _arithmeticTolerance, name);
      });
    }
  });

  // -------------------------------------------------------------------------
  // Unary operations
  // -------------------------------------------------------------------------

  _unaryGroup(
    title: 'unary -',
    label: (String a) => '-($a)',
    onDecimal: (Decimal a) => -a,
    onDouble: (double a) => -a,
  );

  _unaryGroup(
    title: 'abs',
    label: (String a) => '$a.abs()',
    onDecimal: (Decimal a) => a.abs(),
    onDouble: (double a) => a.abs(),
  );

  _unaryGroup(
    title: 'reciprocal',
    label: (String a) => '1 / $a',
    onDecimal: (Decimal a) => a.reciprocal(),
    onDouble: (double a) => 1 / a,
    // `1 / Infinity` is a real zero; nothing else in the set reciprocates to
    // zero without underflowing. (`Decimal.zero.reciprocal()` is NaN where
    // `1 / 0.0` is infinity — a documented divergence, skipped as an overflow.)
    zeroIsGenuine: (double a) => a.isInfinite,
  );

  _unaryGroup(
    title: 'floor',
    label: (String a) => '$a.floor()',
    onDecimal: (Decimal a) => a.floor(),
    onDouble: (double a) => a.floorToDouble(),
  );

  _unaryGroup(
    title: 'ceil',
    label: (String a) => '$a.ceil()',
    onDecimal: (Decimal a) => a.ceil(),
    onDouble: (double a) => a.ceilToDouble(),
  );

  _unaryGroup(
    title: 'round',
    label: (String a) => '$a.round()',
    onDecimal: (Decimal a) => a.round(),
    onDouble: (double a) => a.roundToDouble(),
    // `Decimal.round()` follows JavaScript's `Math.round`, which sends halves
    // towards +infinity, while `roundToDouble()` sends them away from zero.
    // They agree everywhere except on an exact negative half; the value set
    // contains none, but the guard keeps the group honest if it grows.
    guard: (double a) => a < 0 && a.isFinite && a - a.floorToDouble() == 0.5
        ? 'Decimal.round() rounds halves towards +infinity (JavaScript '
              'Math.round); double.roundToDouble() rounds them away from zero'
        : null,
  );

  _unaryGroup(
    title: 'truncate',
    label: (String a) => '$a.truncate()',
    onDecimal: (Decimal a) => a.truncate(),
    onDouble: (double a) => a.truncateToDouble(),
  );

  // -------------------------------------------------------------------------
  // Binary arithmetic
  // -------------------------------------------------------------------------

  // Addition and subtraction cannot underflow to zero from non-zero operands:
  // IEEE addition is correctly rounded, so a zero result is exact cancellation.
  _binaryGroup(
    title: 'operator +',
    symbol: '+',
    onDecimal: (Decimal a, Decimal b) => a + b,
    onDouble: (double a, double b) => a + b,
  );

  _binaryGroup(
    title: 'operator -',
    symbol: '-',
    onDecimal: (Decimal a, Decimal b) => a - b,
    onDouble: (double a, double b) => a - b,
  );

  _binaryGroup(
    title: 'operator *',
    symbol: '*',
    onDecimal: (Decimal a, Decimal b) => a * b,
    onDouble: (double a, double b) => a * b,
    // A product is zero only if a factor is; anything else that reaches zero
    // got there by underflow (`1.98e-241 * 1.98e-241`).
    zeroIsGenuine: (double a, double b) => a == 0 || b == 0,
  );

  _binaryGroup(
    title: 'operator /',
    symbol: '/',
    onDecimal: (Decimal a, Decimal b) => a / b,
    onDouble: (double a, double b) => a / b,
    // Zero over anything is zero, and anything over infinity is zero; every
    // other zero quotient here is an underflow (`1.98e-241 / 7.23e222`).
    zeroIsGenuine: (double a, double b) => a == 0 || b.isInfinite,
  );

  // The oracle is `remainder`, not `%`: `Decimal.operator %` is truncated
  // modulo (the sign follows the dividend, as in JavaScript), while Dart's `%`
  // on `num` is floored and never negative. `(-7).remainder(2) == -1`, which is
  // what a `Decimal` returns; `(-7) % 2 == 1`, which is not.
  _binaryGroup(
    title: 'operator %',
    symbol: '%',
    onDecimal: (Decimal a, Decimal b) => a % b,
    onDouble: (double a, double b) => a.remainder(b),
    guard: _remainderGuard,
  );

  // `%` above degenerates to the nine layer-0 fundamentals once the guard has
  // had its say, which is thin coverage for an operation this fiddly. These
  // pairs keep every value at layer 0 (so the guard passes) while varying the
  // quotient over fifteen orders of magnitude.
  _binaryGroup(
    title: 'operator % over layer-0 pairs',
    symbol: '%',
    onDecimal: (Decimal a, Decimal b) => a % b,
    onDouble: (double a, double b) => a.remainder(b),
    values: _layerZeroSpread,
    guard: _remainderGuard,
  );

  // -------------------------------------------------------------------------
  // Exactness
  // -------------------------------------------------------------------------

  // Where both operands round-trip through the representation unchanged, the
  // port routes through native `double` arithmetic and the answer must be
  // bit-identical — not close, identical. Locking that down stops a future
  // refactor from quietly moving the layer-0 fast path into log space.
  //
  // Division is deliberately absent: `a / b` is implemented as
  // `a * b.reciprocal()`, and `1.1 * (1 / 0.9)` is not required to equal
  // `1.1 / 0.9` in IEEE arithmetic. It happens to, for every pair here, but
  // asserting that would be asserting a coincidence.
  group('bit-exact on operands that round-trip through Decimal (exact)', () {
    // A result is only comparable bit-for-bit if it is itself exactly
    // representable; `Infinity - 1` and the like drop out.
    bool comparable(double want) => want.isFinite && _roundTripsExactly(want);

    for (final double a in _exactValues) {
      for (final double b in _exactValues) {
        final String name = '${_label(a)} and ${_label(b)}';
        final List<double> wants = <double>[
          a + b,
          a - b,
          a * b,
          a.remainder(b),
        ];
        // Without this, the 22 pairs involving an infinity would assert
        // nothing at all and still report as passing.
        final Object? skip = wants.any(comparable)
            ? null
            : 'no result of this pair is exactly representable';
        test(name, () {
          final Decimal da = a.dec;
          final Decimal db = b.dec;
          void check(String symbol, double want, Decimal got) {
            if (!comparable(want)) {
              return;
            }
            expect(
              got.toDouble(),
              want,
              reason: '${_label(a)} $symbol ${_label(b)} must be exact',
            );
          }

          check('+', wants[0], da + db);
          check('-', wants[1], da - db);
          check('*', wants[2], da * db);
          check('%', wants[3], da % db);
        }, skip: skip);
      }
    }
  });

  // -------------------------------------------------------------------------
  // Comparison
  // -------------------------------------------------------------------------

  // The relational operators mirror `double`'s exactly, NaN included: every
  // one of them is false when either side is NaN.
  group('comparison operators (exact)', () {
    for (final double a in _all) {
      for (final double b in _all) {
        final String name = '${_label(a)} vs ${_label(b)}';
        test(name, () {
          final Decimal da = a.dec;
          final Decimal db = b.dec;
          expect(da < db, a < b, reason: '$name : <');
          expect(da <= db, a <= b, reason: '$name : <=');
          expect(da > db, a > b, reason: '$name : >');
          expect(da >= db, a >= b, reason: '$name : >=');
          expect(da == db, a == b, reason: '$name : ==');
          // Equal values must hash equally. (The converse is not required,
          // and `Decimal.nan` is not equal to itself, so this only fires on
          // genuine equality.)
          if (da == db) {
            expect(da.hashCode, db.hashCode, reason: '$name : hashCode');
          }
        });
      }
    }
  });

  // `compareTo` is the total order, so it disagrees with the operators on NaN
  // in exactly the way `double.compareTo` does: NaN equals itself and sorts
  // above everything, `Infinity` included.
  group('compareTo (exact)', () {
    for (final double a in _all) {
      for (final double b in _all) {
        final String name = '${_label(a)} vs ${_label(b)}';
        test(name, () {
          expect(a.dec.compareTo(b.dec), a.compareTo(b), reason: '$name : cmp');
        });
      }
    }
  });

  group('compareMagnitudeTo (exact)', () {
    for (final double a in _all) {
      for (final double b in _all) {
        final String name = '|${_label(a)}| vs |${_label(b)}|';
        // See [_tripsCmpAbsZeroBug]: four pairs here are wrong, and are wrong
        // upstream too. Skipped rather than accommodated, so that fixing it in
        // break_eternity.js turns these green instead of leaving a weakened
        // assertion behind.
        final Object? skip = _tripsCmpAbsZeroBug(a, b)
            ? 'upstream break_eternity.js bug: cmpabs treats zero as layer -0 '
                  'and so ranks |0| above any value below 1/9e15'
            : null;
        test(name, () {
          expect(
            a.dec.compareMagnitudeTo(b.dec),
            a.abs().compareTo(b.abs()),
            reason: '$name : cmpabs',
          );
        }, skip: skip);
      }
    }
  });

  group('max and min (relative tolerance 1e-12)', () {
    for (final double a in _all) {
      for (final double b in _all) {
        final String name = '${_label(a)} vs ${_label(b)}';
        // `Decimal.max`/`min` resolve with a single `<`, so a NaN argument is
        // not contagious: `x.max(nan)` is `x` while `math.max(x, nan)` is NaN.
        // That is the reference's behaviour and it is documented on the
        // members; `test/decimal_test.dart` pins it directly.
        final Object? skip = a.isNaN || b.isNaN
            ? 'Decimal.max/min are not NaN-contagious, unlike math.max/min'
            : null;
        test(name, () {
          _expectClose(
            a.dec.max(b.dec).toDouble(),
            math.max(a, b),
            _arithmeticTolerance,
            '$name : max',
          );
          _expectClose(
            a.dec.min(b.dec).toDouble(),
            math.min(a, b),
            _arithmeticTolerance,
            '$name : min',
          );
        }, skip: skip);
      }
    }
  });

  // -------------------------------------------------------------------------
  // Logarithms
  // -------------------------------------------------------------------------

  // `dart:math` offers only a natural logarithm, so the oracle for the other
  // two bases is a division by `ln10`/`ln2`. For [Decimal.log10] and
  // [Decimal.log2] that is a genuinely independent computation — both go
  // through the software `log10` in `constants.dart`, a Sun-derived
  // `__ieee754_log10` carried so the port normalises identically on the VM and
  // in the browser — so the agreement below is evidence rather than a
  // restatement. [Decimal.ln] is the exception: at layer 0 it calls the same
  // `math.log` the oracle does, so those cases test the plumbing around it
  // (sign, normalisation, the round trip) and not the transcendental. Its
  // layer-1 cases, which reach the answer as `mag * ln(10)`, are independent
  // again.
  //
  // Above layer 0 a logarithm is not a computation at all — it is a decrement
  // of `layer` — so these groups are really two tests in one: the numeric
  // kernel at layer 0, and the bookkeeping that peels a layer off `1e30` and
  // `7.23e222` and lands on the right side of the layer boundary. Layer 2 and
  // up are out of reach here by construction, since no `double` can name an
  // input that reaches them; those branches belong to the fixtures.

  _unaryGroup(
    title: 'log10',
    label: (String a) => '$a.log10()',
    onDecimal: (Decimal a) => a.log10(),
    onDouble: (double a) => math.log(a) / math.ln10,
    nanIsGenuine: _logDomainError,
  );

  _unaryGroup(
    title: 'log2',
    label: (String a) => '$a.log2()',
    onDecimal: (Decimal a) => a.log2(),
    onDouble: (double a) => math.log(a) / math.ln2,
    nanIsGenuine: _logDomainError,
  );

  _unaryGroup(
    title: 'ln',
    label: (String a) => '$a.ln()',
    onDecimal: (Decimal a) => a.ln(),
    onDouble: (double a) => math.log(a),
    nanIsGenuine: _logDomainError,
  );

  // A logarithm in an arbitrary base is a ratio of logarithms on both sides,
  // so the two agree to within a rounding error wherever the base is one a
  // logarithm can have at all: [_logBaseGuard] takes 0 and 1, and everything
  // negative on either side is a shared domain error and asserted as one.
  _binaryGroup(
    title: 'log(base)',
    symbol: 'log base',
    onDecimal: (Decimal a, Decimal b) => a.log(b),
    onDouble: (double a, double b) => math.log(a) / math.log(b),
    nanIsGenuine: (double a, double b) =>
        _logDomainError(a) || _logDomainError(b),
    guard: _logBaseGuard,
    announceLiveCount: true,
  );

  // -------------------------------------------------------------------------
  // Powers and roots
  // -------------------------------------------------------------------------

  _binaryGroup(
    title: 'pow',
    symbol: '^',
    onDecimal: (Decimal a, Decimal b) => a.pow(b),
    onDouble: (double a, double b) => math.pow(a, b).toDouble(),
    tolerance: _powerTolerance,
    // A power is zero only when the base is: `0 ^ b` for positive `b`. Every
    // other zero here is a `double` giving up (`0.5 ^ 7.23e222`), which is the
    // case a `Decimal` exists to handle and so is nothing to compare against.
    // (`0 ^ negative` is infinity in IEEE and zero here, and skips as an
    // overflow of the oracle.)
    zeroIsGenuine: (double a, double b) => a == 0,
    nanIsGenuine: _powDomainError,
    guard: _powNonFiniteGuard,
    announceLiveCount: true,
  );

  // `root` is `pow` of a reciprocal, plus one rule of its own: a negative
  // radicand keeps its sign under an odd-integer degree instead of going NaN,
  // because the real cube root of -8 is -2. See [_rootOracle], which is where
  // that rule lives on the oracle's side.
  _binaryGroup(
    title: 'root',
    symbol: 'root',
    onDecimal: (Decimal a, Decimal b) => a.root(b),
    onDouble: _rootOracle,
    tolerance: _powerTolerance,
    zeroIsGenuine: (double a, double b) => a == 0,
    nanIsGenuine: _rootDomainError,
    guard: _rootGuard,
    announceLiveCount: true,
  );

  // [_all] holds no odd integer bigger than 1, so the group above never
  // actually reaches the odd-degree rule: at a degree of 1 or -1 the exponent
  // `1 / degree` is an integer, and `pow` already handles a negative base at an
  // integer exponent by itself, so deleting the rule outright would not change
  // a single answer up there. These degrees do reach it.
  _binaryGroup(
    title: 'root over integer degrees',
    symbol: 'root',
    onDecimal: (Decimal a, Decimal b) => a.root(b),
    onDouble: _rootOracle,
    tolerance: _powerTolerance,
    values: _rootRadicands,
    rightValues: _rootDegrees,
    zeroIsGenuine: (double a, double b) => a == 0,
    nanIsGenuine: _rootDomainError,
    guard: _rootGuard,
    announceLiveCount: true,
  );

  // The oracle is `a * a`, not `math.pow(a, 2)`: a squaring that agreed with
  // `pow` but not with multiplication would be a bug worth catching, and this
  // is the only group in the file positioned to catch it. Same for `cube`.
  _unaryGroup(
    title: 'sqr',
    label: (String a) => '$a.sqr()',
    onDecimal: (Decimal a) => a.sqr(),
    onDouble: (double a) => a * a,
    tolerance: _powerTolerance,
    zeroIsGenuine: (double a) => a == 0,
    nanIsGenuine: (double a) => a.isNaN,
  );

  _unaryGroup(
    title: 'cube',
    label: (String a) => '$a.cube()',
    onDecimal: (Decimal a) => a.cube(),
    onDouble: (double a) => a * a * a,
    tolerance: _powerTolerance,
    zeroIsGenuine: (double a) => a == 0,
    nanIsGenuine: (double a) => a.isNaN,
  );

  // The square root of a negative is NaN on both sides, so it is asserted —
  // but only at layer 0, which is as far as the reference bothers to check the
  // sign; see [_sqrtGuard] for what happens above it.
  _unaryGroup(
    title: 'sqrt',
    label: (String a) => '$a.sqrt()',
    onDecimal: (Decimal a) => a.sqrt(),
    onDouble: (double a) => math.sqrt(a),
    tolerance: _powerTolerance,
    zeroIsGenuine: (double a) => a == 0,
    nanIsGenuine: (double a) => a.isNaN || (a < 0 && a.dec.layer == 0),
    guard: _sqrtGuard,
  );

  // Unlike `sqrt`, `cbrt` has no domain to leave: every real has a real cube
  // root, and [Decimal.cbrt] handles the negatives by cube-rooting the
  // magnitude and putting the sign back, which is exactly what the oracle
  // below has to do to get an answer out of `math.pow`.
  _unaryGroup(
    title: 'cbrt',
    label: (String a) => '$a.cbrt()',
    onDecimal: (Decimal a) => a.cbrt(),
    onDouble: (double a) =>
        a < 0 ? -math.pow(-a, 1 / 3).toDouble() : math.pow(a, 1 / 3).toDouble(),
    tolerance: _powerTolerance,
    zeroIsGenuine: (double a) => a == 0,
    nanIsGenuine: (double a) => a.isNaN,
  );

  // `e ^ x` is never zero, so a `double` result of zero is always an underflow
  // and never an answer — hence the flat `false`.
  _unaryGroup(
    title: 'exp',
    label: (String a) => 'e ^ $a',
    onDecimal: (Decimal a) => a.exp(),
    onDouble: (double a) => math.exp(a),
    tolerance: _powerTolerance,
    zeroIsGenuine: (double a) => false,
    nanIsGenuine: (double a) => a.isNaN,
    guard: _expGuard,
    announceLiveCount: true,
  );

  // The group above spends most of its value set on inputs whose exponential
  // a `double` cannot hold; see [_expSpread] for the one that does not.
  _unaryGroup(
    title: 'exp over the double-representable domain',
    label: (String a) => 'e ^ $a',
    onDecimal: (Decimal a) => a.exp(),
    onDouble: (double a) => math.exp(a),
    tolerance: _powerTolerance,
    values: _expSpread,
    zeroIsGenuine: (double a) => false,
    announceLiveCount: true,
  );
}
