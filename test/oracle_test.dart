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
/// as a wrong 13th digit).
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

// ---------------------------------------------------------------------------
// Tolerances
// ---------------------------------------------------------------------------

/// Relative tolerance for arithmetic, ~13x the measured worst case of 7.8e-14.
const double _arithmeticTolerance = 1e-12;

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
    reason: '$what\n'
        '  double  : $expected\n'
        '  Decimal : $actual\n'
        '  relative error ${error.toStringAsExponential(3)} exceeds '
        '${_formatTolerance(tolerance)}',
  );
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

/// Runs [onDecimal] and [onDouble] over every value in [values].
void _unaryGroup({
  required String title,
  required String Function(String operand) label,
  required _UnaryDecimalOp onDecimal,
  required _UnaryDoubleOp onDouble,
  double tolerance = _arithmeticTolerance,
  List<double> values = _all,
  bool Function(double a)? zeroIsGenuine,
  String? Function(double a)? guard,
}) {
  group('$title (relative tolerance ${_formatTolerance(tolerance)})', () {
    for (final double a in values) {
      final String name = label(_label(a));
      final double want = onDouble(a);
      final Object? skip = guard?.call(a) ??
          _skipReason(want, zeroIsGenuine: zeroIsGenuine?.call(a) ?? true);
      test(name, () {
        _expectClose(onDecimal(a.dec).toDouble(), want, tolerance, name);
      }, skip: skip);
    }
  });
}

/// Runs [onDecimal] and [onDouble] over every ordered pair from [values].
void _binaryGroup({
  required String title,
  required String symbol,
  required _BinaryDecimalOp onDecimal,
  required _BinaryDoubleOp onDouble,
  double tolerance = _arithmeticTolerance,
  List<double> values = _all,
  bool Function(double a, double b)? zeroIsGenuine,
  String? Function(double a, double b)? guard,
}) {
  group('$title (relative tolerance ${_formatTolerance(tolerance)})', () {
    for (final double a in values) {
      for (final double b in values) {
        final String name = '${_label(a)} $symbol ${_label(b)}';
        final double want = onDouble(a, b);
        final Object? skip = guard?.call(a, b) ??
            _skipReason(
              want,
              zeroIsGenuine: zeroIsGenuine?.call(a, b) ?? true,
            );
        test(name, () {
          _expectClose(
              onDecimal(a.dec, b.dec).toDouble(), want, tolerance, name);
        }, skip: skip);
      }
    }
  });
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
}
