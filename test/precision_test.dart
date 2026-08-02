/// Executable specification of the precision rules the README states.
///
/// `pow` is computed in log space and `/` is multiplication by a reciprocal,
/// so neither is exact even when the true answer is. That is inherited from
/// break_eternity.js — the vendored reference produces bit-identical answers,
/// including the same 9,104 divergent quotients checked below — and it is the
/// price of a representation that reaches 10^^1e308. It is not a defect to be
/// fixed, and the fixture suite would fail loudly if anyone tried.
///
/// What this file is for is the *consequence*: applying `floor` to an inexact
/// power turns a one-ulp error into a whole-unit one, which is a real hazard in
/// the cost tables and threshold ladders these libraries exist to serve.
///
/// **Why almost nothing here pins an exact value.** `pow` bottoms out in the
/// host `Math.pow`, whose accuracy ECMAScript leaves implementation-defined and
/// which genuinely differs between architectures — `7.dec.sqr()` is
/// `48.99999999999999` on macOS/arm64 and exactly `49` on Linux/x64. Asserting
/// either would turn a portable property into a red CI job on half the matrix.
/// So the power tests assert *bounds* that hold everywhere, and only the tests
/// whose code path is pure IEEE arithmetic — division, which is a `double`
/// multiply and a `double` divide with no libm anywhere — pin exact counts.
/// Those were confirmed identical on the Dart VM and under dart2js.
library;

import 'dart:math' as math;

import 'package:break_eternity/break_eternity.dart';
import 'package:test/test.dart';

/// `base^exponent` in exact integer arithmetic, as the ground truth.
int _intPow(int base, int exponent) {
  int result = 1;
  for (int i = 0; i < exponent; i++) {
    result *= base;
  }
  return result;
}

void main() {
  group('pow is not exact on integer results', () {
    test('stays within a tight relative distance of the true integer', () {
      for (int base = 2; base <= 12; base++) {
        for (int exponent = 1; exponent <= 12; exponent++) {
          final double truth = _intPow(base, exponent).toDouble();
          final double got = base.dec.pow(exponent.dec).toDouble();
          expect(
            (got - truth).abs() / truth,
            lessThan(1e-14),
            reason:
                '$base^$exponent drifted further than one would expect '
                'from a log-space evaluation',
          );
        }
      }
    });

    test('floor() of it is either the true value or one less', () {
      // The whole point. On any given platform some of these land exact and
      // some land one low; which is which is not portable, so assert the set
      // of outcomes rather than the outcome. A caller who needs the integer
      // cannot rely on either, which is exactly the warning in the README.
      for (int base = 2; base <= 12; base++) {
        for (int exponent = 1; exponent <= 12; exponent++) {
          final int truth = _intPow(base, exponent);
          final Decimal floored = base.dec.pow(exponent.dec).floor();
          expect(
            floored.toDouble(),
            anyOf(equals(truth.toDouble()), equals((truth - 1).toDouble())),
            reason: 'floor($base^$exponent) should be $truth or ${truth - 1}',
          );
        }
      }
    });

    test('at least one integer power is not exact', () {
      // Deliberately weak: it asserts only that *somewhere* in a 132-case
      // sweep the inexactness is observable, which holds on every platform
      // seen so far without pinning which case or which direction. If a
      // future change made `pow` exact everywhere this would fail, and that
      // is the intended prompt to re-read the README section before
      // celebrating.
      bool anyInexact = false;
      for (int base = 2; base <= 12 && !anyInexact; base++) {
        for (int exponent = 1; exponent <= 12; exponent++) {
          if (base.dec.pow(exponent.dec).toDouble() !=
              _intPow(base, exponent).toDouble()) {
            anyInexact = true;
            break;
          }
        }
      }
      expect(anyInexact, isTrue);
    });

    test('the same hazard reaches sqr, cbrt and root', () {
      // These are documented as building on `pow`, so they inherit it. Bounds
      // again, not values.
      for (final (Decimal value, int truth) in <(Decimal, int)>[
        (7.dec.sqr(), 49),
        (64.dec.cbrt(), 4),
        (81.dec.root(4.dec), 3),
        (12.dec.cube(), 1728),
      ]) {
        expect(
          value.floor().toDouble(),
          anyOf(equals(truth.toDouble()), equals((truth - 1).toDouble())),
        );
      }
    });
  });

  group('the worked example from the README', () {
    // A RuneScape/Melvor-style level curve, the shape that motivated the
    // warning: floor(n + base * 2^(n/divisor)) summed into a running total.
    // Every multiple of the divisor makes the term an exact integer, putting
    // `floor` right on the boundary.
    const int curveBase = 300;
    const int divisor = 7;

    test('a Decimal port of the curve stays within one unit per term', () {
      // Bounding the damage is portable; the exact divergence is not. 76 of
      // 119 levels differ on macOS/arm64, but a platform where `pow` rounds
      // the other way would differ at none, and both are correct behaviour
      // for this library.
      for (int n = 1; n <= 119; n++) {
        final int stock = (n + curveBase * math.pow(2, n / divisor)).floor();
        final Decimal ported =
            (n.dec + curveBase.dec * 2.dec.pow((n / divisor).dec)).floor();
        expect(
          (ported.toDouble() - stock).abs(),
          lessThanOrEqualTo(1),
          reason: 'term $n drifted by more than one whole unit',
        );
      }
    });

    test('the terms at risk are exactly the multiples of the divisor', () {
      // Why the curve is safe in `double` but not in `Decimal`: only the
      // multiples of the divisor land on an integer boundary at all. Every
      // other term sits millions of ulps clear, so no plausible rounding
      // difference can move it.
      for (int n = 1; n <= 119; n++) {
        final double term = n + curveBase * math.pow(2, n / divisor).toDouble();
        final double distance = (term - term.floorToDouble()).abs().clamp(
          0.0,
          1.0,
        );
        final double gap = distance < 0.5 ? distance : 1 - distance;
        if (n % divisor == 0) {
          expect(gap, equals(0.0), reason: 'n=$n should be an exact integer');
        } else {
          expect(
            gap,
            greaterThan(1e-3),
            reason: 'n=$n should sit far clear of an integer boundary',
          );
        }
      }
    });
  });

  group('division is inexact but harmless', () {
    test('9104 of 40000 small quotients differ from IEEE division', () {
      // Exact count, and safe to pin: at layer 0 division is
      // `Decimal.fromNum(a.mag * (1 / b.mag))` — an IEEE multiply and an IEEE
      // divide, both correctly rounded by the hardware, with no libm in
      // sight. Verified identical on the Dart VM and under dart2js.
      int divergent = 0;
      for (int a = 1; a <= 200; a++) {
        for (int b = 1; b <= 200; b++) {
          if ((a.dec / b.dec).toDouble() != a / b) {
            divergent++;
          }
        }
      }
      expect(divergent, equals(9104));
    });

    test('3/5 is the canonical example', () {
      expect((3.dec / 5.dec).toDouble(), equals(0.6000000000000001));
      expect(0.6000000000000001, isNot(equals(3 / 5)));
    });

    test('the basis-point idiom is exact anyway', () {
      // The contrast that makes the rule make sense. A percentage applied to
      // a quantity essentially never lands on an integer, so the one-ulp
      // error has nowhere to do damage — unlike a power, where the true
      // answer *is* the boundary.
      for (int bp = 0; bp <= 20000; bp += 250) {
        for (int x = 1; x <= 2000; x += 13) {
          expect(
            (x.dec * (10000 + bp).dec / 10000.dec).floor().toDouble(),
            equals((x * (10000 + bp) ~/ 10000).toDouble()),
            reason: 'x=$x bp=$bp',
          );
        }
      }
    });

    test('and stays exact at operands near 1e9', () {
      for (int x = 1000000000; x < 1000000100; x++) {
        for (final int bp in <int>[250, 1200, 10000]) {
          expect(
            (x.dec * (10000 + bp).dec / 10000.dec).floor().toDouble(),
            equals((x * (10000 + bp) ~/ 10000).toDouble()),
            reason: 'x=$x bp=$bp',
          );
        }
      }
    });
  });
}
