/// Hand-written unit tests for the parts of [Decimal] that the numeric oracle
/// and the JSON fixtures cannot check.
///
/// The oracle test (`oracle_test.dart`) only sees values that survive a round
/// trip through `double`, and the fixture test (`fixtures_test.dart`) compares
/// component triples within a relative tolerance. Neither can assert that the
/// representation is *canonical*, that `NaN != NaN`, that `toString` emits the
/// documented spelling, or that `parse` rejects garbage instead of guessing.
/// That is what lives here.
///
/// Expected values were taken from the vendored JavaScript reference
/// (`reference/break_eternity.umd.js`, break_eternity.js 2.1.3) by running the
/// same expression there.
library;

import 'dart:math' as math;

import 'package:break_eternity/break_eternity.dart';
import 'package:test/test.dart';

// -----------------------------------------------------------------------------
// Normalisation invariants
// -----------------------------------------------------------------------------

/// `log10`, recomputed here so the invariant checker does not borrow the
/// implementation's own helper (a bug in it would then hide itself).
double log10(double x) => math.log(x) * math.log10e;

/// Exactly `2^e`, built by repeated multiplication so that no library call
/// (and in particular neither `math.pow` nor the implementation's own helpers)
/// can put a rounding error into the test's input.
double _exactPowerOfTwo(int e) {
  double result = 1.0;
  for (int i = 0; i < e.abs(); i++) {
    result = e < 0 ? result / 2.0 : result * 2.0;
  }
  return result;
}

/// The boundaries from the API contract, restated independently.
final double expLimit = 9e15;
final double layerDown = log10(9e15); // 15.954242509439325
final double firstNegLayer = 1 / 9e15; // 1.1111111111111112e-16

/// Asserts that [d] satisfies every post-normalisation invariant.
///
/// The non-finite states (NaN and the infinities) are checked separately and
/// are exempt: they deliberately break the magnitude bounds.
void expectNormalised(Decimal d, String description) {
  final String what = '$description -> (${d.sign}, ${d.layer}, ${d.mag})';

  if (d.isNaN) {
    // Everything that goes through `normalize` produces an all-NaN triple.
    // `abs()` is the one exception: like the reference it rewrites `sign`
    // without normalising, so `nan.abs()` is `(1, NaN, NaN)`. See the
    // dedicated test below.
    expect(d.layer.isNaN, isTrue, reason: '$what: a NaN layer');
    expect(d.mag.isNaN, isTrue, reason: '$what: a NaN mag');
    expect(
      d.sign.isNaN || d.sign == 1.0,
      isTrue,
      reason: '$what: sign is NaN, or 1 after abs()',
    );
    return;
  }

  expect(
    d.sign,
    anyOf(-1.0, 0.0, 1.0),
    reason: '$what: sign must be -1, 0 or 1',
  );

  if (d.isInfinite) {
    expect(
      d.layer,
      double.infinity,
      reason: '$what: infinity is (s, inf, inf)',
    );
    expect(d.mag, double.infinity, reason: '$what: infinity is (s, inf, inf)');
    expect(d.sign.abs(), 1.0, reason: '$what: infinity has sign +-1');
    return;
  }

  expect(d.layer.isFinite, isTrue, reason: '$what: finite values need a layer');
  expect(d.layer, greaterThanOrEqualTo(0.0), reason: '$what: layer >= 0');
  expect(
    d.layer,
    d.layer.floorToDouble(),
    reason: '$what: layer must be integral',
  );

  if (d.sign == 0) {
    // Rule 1: anything partially zero is totally zero.
    expect(d.layer, 0.0, reason: '$what: zero is exactly (0, 0, 0)');
    expect(d.mag, 0.0, reason: '$what: zero is exactly (0, 0, 0)');
    expect(d.mag.isNegative, isFalse, reason: '$what: zero mag is +0.0');
    return;
  }

  if (d.layer == 0) {
    // Rule 2: at layer 0 the sign lives in `sign`, never in `mag`, and the
    // magnitude stays inside the range where a double keeps full resolution.
    expect(d.mag, greaterThan(0.0), reason: '$what: layer-0 mag is positive');
    expect(
      d.mag,
      lessThan(expLimit),
      reason: '$what: layer-0 mag < 9e15, else it moves up a layer',
    );
    // The reference's rule 4 tests `mag < FIRST_NEG_LAYER`, so a mag of
    // exactly 1/9e15 stays at layer 0. The bound is therefore inclusive here
    // where the contract writes it strict.
    expect(
      d.mag,
      greaterThanOrEqualTo(firstNegLayer),
      reason: '$what: layer-0 mag >= 1/9e15, else it moves up a layer',
    );
    return;
  }

  // Rule 3: at layer >= 1 the magnitude is a logarithm and lives in the band
  // [log10(9e15), 9e15). Outside it the value belongs on a different layer.
  expect(
    d.mag.abs(),
    greaterThanOrEqualTo(layerDown),
    reason: '$what: layer>=1 needs |mag| >= 15.954..., else it moves down',
  );
  expect(
    d.mag.abs(),
    lessThan(expLimit),
    reason: '$what: layer>=1 needs |mag| < 9e15, else it moves up',
  );
}

/// Every [Decimal] mentioned by the contract as a named constant, plus a
/// spread of constructed values, so the invariant checker gets a wide net.
Iterable<MapEntry<String, Decimal>> get _normalisationCorpus sync* {
  yield MapEntry('zero', Decimal.zero);
  yield MapEntry('one', Decimal.one);
  yield MapEntry('negativeOne', Decimal.negativeOne);
  yield MapEntry('two', Decimal.two);
  yield MapEntry('ten', Decimal.ten);
  yield MapEntry('nan', Decimal.nan);
  yield MapEntry('infinity', Decimal.infinity);
  yield MapEntry('negativeInfinity', Decimal.negativeInfinity);
  yield MapEntry('numberMax', Decimal.numberMax);
  yield MapEntry('numberMin', Decimal.numberMin);
  yield MapEntry('layerSafeMax', Decimal.layerSafeMax);
  yield MapEntry('layerSafeMin', Decimal.layerSafeMin);
  yield MapEntry('layerMax', Decimal.layerMax);
  yield MapEntry('layerMin', Decimal.layerMin);

  const List<double> plainNumbers = <double>[
    0, -0.0, 1, -1, 0.5, -0.5, 9e15, -9e15, 8999999999999999, 1e15, //
    1 / 9e15, -1 / 9e15, 1e-16, 1e-20, 1e-300, 5e-324, 1e21, 1e100, //
    1.7976931348623157e308, double.nan, double.infinity,
    double.negativeInfinity,
  ];
  for (final double n in plainNumbers) {
    yield MapEntry('fromNum($n)', Decimal.fromNum(n));
  }

  const List<double> layers = <double>[0, 1, 2, 3, 4, 5, 6, 10];
  const List<double> mags = <double>[
    0, 1, -1, 10, -10, 15, -15, 15.9, 16, -16, 100, -100, //
    8999999999999999, -8999999999999999, 9e15, -9e15, 1e100,
  ];
  for (final double layer in layers) {
    for (final double mag in mags) {
      for (final double sign in <double>[1, -1]) {
        yield MapEntry(
          'fromComponents($sign, $layer, $mag)',
          Decimal.fromComponents(sign, layer, mag),
        );
      }
    }
  }

  // Very tall layers. A non-zero magnitude escapes the layer-down loop in about
  // three iterations because it grows by an exponentiation each time. The
  // zero-magnitude case, which used to spin ~1e15 times, is short-circuited —
  // see the hostile-input group for its regression tests.
  for (final double mag in <double>[1, -1, 15.9, 100, -100, 1e100, 0]) {
    yield MapEntry(
      'fromComponents(1, 1e15, $mag)',
      Decimal.fromComponents(1, 1e15, mag),
    );
  }
}

void main() {
  group('normalisation invariants', () {
    test('hold for every constructed value in the corpus', () {
      for (final MapEntry<String, Decimal> entry in _normalisationCorpus) {
        expectNormalised(entry.value, entry.key);
      }
    });

    test('hold for the results of arithmetic', () {
      final List<Decimal> operands = <Decimal>[
        Decimal.zero,
        Decimal.one,
        Decimal.negativeOne,
        Decimal.fromNum(1e-20),
        Decimal.fromNum(1e300),
        Decimal.fromComponents(1, 2, 100),
        Decimal.fromComponents(-1, 3, 16.5),
        Decimal.fromComponents(1, 6, 20),
        Decimal.infinity,
        Decimal.nan,
      ];
      for (final Decimal a in operands) {
        for (final Decimal b in operands) {
          expectNormalised(a + b, '$a + $b');
          expectNormalised(a - b, '$a - $b');
          expectNormalised(a * b, '$a * $b');
          expectNormalised(a / b, '$a / $b');
        }
        expectNormalised(-a, '-$a');
        expectNormalised(a.abs(), '$a.abs()');
        expectNormalised(a.reciprocal(), '$a.reciprocal()');
        expectNormalised(a.floor(), '$a.floor()');
        expectNormalised(a.ceil(), '$a.ceil()');
        expectNormalised(a.round(), '$a.round()');
        expectNormalised(a.truncate(), '$a.truncate()');
      }
    });

    test('a layer-0 magnitude of 9e15 or more moves up a layer', () {
      final Decimal d = Decimal.fromComponents(1, 0, 9e15);
      expect(d.layer, 1.0);
      expect(d.mag, closeTo(layerDown, 1e-12));
      // One below the limit still fits at layer 0.
      final Decimal below = Decimal.fromComponents(1, 0, 8999999999999999);
      expect(below.layer, 0.0);
      expect(below.mag, 8999999999999999.0);
    });

    test('a single layer-up step is always enough', () {
      // log10 of anything a double can hold is under 309, comfortably inside
      // the layer-1 band, so the reference does not loop here.
      final Decimal d = Decimal.fromComponents(1, 0, 1e100);
      expect(d.layer, 1.0);
      expect(d.mag, closeTo(100, 1e-9));
      final Decimal big = Decimal.fromComponents(1, 5, 1e100);
      expect(big.layer, 6.0);
      expect(big.mag, closeTo(100, 1e-9));
    });

    test('a too-small magnitude walks back down, possibly several layers', () {
      // Layer 1, mag 15: 10^15 fits in a double, so it collapses to layer 0.
      final Decimal one = Decimal.fromComponents(1, 1, 15);
      expect(one.layer, 0.0);
      expect(one.mag, 1e15);

      // Layer 2, mag 1: 10^1 = 10 is still under the layer-down threshold, so
      // it steps twice, ending at 10^10.
      final Decimal two = Decimal.fromComponents(1, 2, 1);
      expect(two.layer, 0.0);
      expect(two.mag, 1e10);

      // Layer 3, mag 1 steps down only twice: 10^10^1 = 1e10 > 15.954.
      final Decimal three = Decimal.fromComponents(1, 3, 1);
      expect(three.layer, 1.0);
      expect(three.mag, 1e10);

      // Right at the threshold it stays put.
      final Decimal held = Decimal.fromComponents(1, 2, 15.96);
      expect(held.layer, 2.0);
      expect(held.mag, 15.96);
    });

    test('the first negative layer catches magnitudes below 1/9e15', () {
      // Exactly 1/9e15 stays at layer 0 (the reference tests `<`, not `<=`).
      final Decimal atBoundary = Decimal.fromNum(1 / 9e15);
      expect(atBoundary.layer, 0.0);
      expect(atBoundary.mag, 1 / 9e15);

      // Anything smaller becomes a layer-1 value with a negative magnitude.
      final Decimal below = Decimal.fromNum(1e-20);
      expect(below.layer, 1.0);
      expect(below.mag, closeTo(-20, 1e-12));

      // ...and comes back down again when it grows.
      final Decimal back = Decimal.fromComponents(1, 1, -15.9);
      expect(back.layer, 0.0);
      expect(back.mag, closeTo(1.2589254117941662e-16, 1e-25));
      expectNormalised(back, 'FC(1, 1, -15.9)');
    });

    test('a negative layer-0 magnitude moves its sign into `sign`', () {
      final Decimal d = Decimal.fromComponents(1, 0, -5);
      expect(d.sign, -1.0);
      expect(d.mag, 5.0);
      // Two negatives cancel.
      final Decimal e = Decimal.fromComponents(-1, 0, -5);
      expect(e.sign, 1.0);
      expect(e.mag, 5.0);
    });

    test('a layer >= 1 negative magnitude means a reciprocal, not a sign', () {
      final Decimal d = Decimal.fromComponents(1, 1, -100);
      expect(d.sign, 1.0);
      expect(d.mag, -100.0);
      expect(d.isNegative, isFalse);
      expect(d < Decimal.one, isTrue);
      expect(d > Decimal.zero, isTrue);
    });
  });

  group('special states', () {
    test('zero is exactly (0, 0, 0)', () {
      for (final Decimal z in <Decimal>[
        Decimal.zero,
        Decimal.fromNum(0),
        Decimal.fromNum(0.0),
        Decimal.parse('0'),
        Decimal.fromComponents(0, 5, 100),
        Decimal.fromComponents(1, 0, 0),
        Decimal.one - Decimal.one,
      ]) {
        expect(z.sign, 0.0);
        expect(z.layer, 0.0);
        expect(z.mag, 0.0);
        expect(z, Decimal.zero);
        expect(z.isZero, isTrue);
        expect(z.signum, 0);
      }
    });

    test('-0.0 collapses to positive zero', () {
      final Decimal z = Decimal.fromNum(-0.0);
      expect(z, Decimal.zero);
      expect(z.sign.isNegative, isFalse, reason: 'sign must be +0.0, not -0.0');
      expect(z.mag.isNegative, isFalse, reason: 'mag must be +0.0, not -0.0');
      expect(z.isNegative, isFalse);
      expect(z.toString(), '0');
      expect((-0.0).dec, Decimal.zero);
      // Negating zero must not produce a -0.0 sign either.
      expect((-Decimal.zero).toString(), '0');
      expect(Decimal.fromComponents(1, 0, -0.0), Decimal.zero);
    });

    test('a magnitude that underflows to -Infinity above layer 0 is zero', () {
      // 10^-Infinity is 0. Rule 1's third clause.
      expect(
        Decimal.fromComponents(1, 3, double.negativeInfinity),
        Decimal.zero,
      );
    });

    test('NaN is all-NaN and is not equal to itself', () {
      final Decimal n = Decimal.nan;
      expect(n.sign.isNaN, isTrue);
      expect(n.layer.isNaN, isTrue);
      expect(n.mag.isNaN, isTrue);
      expect(n.isNaN, isTrue);
      expect(n.isFinite, isFalse);
      expect(n.isInfinite, isFalse);

      expect(n == n, isFalse, reason: 'NaN != NaN, like double.nan');
      expect(n == Decimal.nan, isFalse);
      expect(<Decimal>[n].contains(n), isFalse);

      // The operators all report false against NaN, like double's.
      expect(n < Decimal.one, isFalse);
      expect(n <= Decimal.one, isFalse);
      expect(n > Decimal.one, isFalse);
      expect(n >= Decimal.one, isFalse);
      expect(Decimal.one < n, isFalse);
      expect(Decimal.one >= n, isFalse);

      // compareTo is a total order, so there NaN *is* equal to itself.
      expect(n.compareTo(n), 0);
      expect(n.compareTo(Decimal.infinity), 1);
      expect(Decimal.infinity.compareTo(n), -1);

      expect(n.toString(), 'NaN');
      expect(Decimal.fromNum(double.nan).isNaN, isTrue);
      expect(Decimal.parse('NaN').isNaN, isTrue);
      expect(Decimal.parse('nan').isNaN, isTrue);
    });

    test('NaN is contagious through arithmetic', () {
      expect((Decimal.nan + Decimal.one).isNaN, isTrue);
      expect((Decimal.one + Decimal.nan).isNaN, isTrue);
      expect((Decimal.nan * Decimal.two).isNaN, isTrue);
      expect((Decimal.nan / Decimal.two).isNaN, isTrue);
      expect((Decimal.infinity / Decimal.infinity).isNaN, isTrue);
      expect((Decimal.zero.reciprocal()).isNaN, isTrue);
    });

    test('every NaN-producing path keeps the triple totally NaN', () {
      final List<Decimal> nans = <Decimal>[
        Decimal.nan,
        Decimal.fromNum(double.nan),
        double.nan.dec,
        Decimal.parse('NaN'),
        Decimal.fromComponents(double.nan, 0, 1),
        Decimal.fromComponents(1, 0, double.nan),
        -Decimal.nan,
        Decimal.nan.floor(),
        Decimal.nan.ceil(),
        Decimal.nan.round(),
        Decimal.nan.truncate(),
        Decimal.nan.reciprocal(),
        Decimal.nan + Decimal.one,
        Decimal.nan * Decimal.two,
        Decimal.infinity + Decimal.negativeInfinity,
      ];
      for (final Decimal n in nans) {
        expect(n.sign.isNaN, isTrue, reason: '$n sign');
        expect(n.layer.isNaN, isTrue, reason: '$n layer');
        expect(n.mag.isNaN, isTrue, reason: '$n mag');
      }
    });

    test('nan.abs() keeps the reference\'s (1, NaN, NaN) triple', () {
      // `abs()` rewrites `sign` without re-normalising, exactly as the
      // reference's `abs()` does (`FC_NN(this.sign === 0 ? 0 : 1, ...)`), so
      // the result is NaN with a non-NaN sign. Still NaN by every test that
      // matters; recorded here so a future "fix" is a deliberate divergence.
      final Decimal a = Decimal.nan.abs();
      expect(a.sign, 1.0);
      expect(a.layer.isNaN, isTrue);
      expect(a.mag.isNaN, isTrue);
      expect(a.isNaN, isTrue);
      expect(a.toString(), 'NaN');
    });

    test('infinity is (1, inf, inf) and -infinity is (-1, inf, inf)', () {
      expect(Decimal.infinity.sign, 1.0);
      expect(Decimal.infinity.layer, double.infinity);
      expect(Decimal.infinity.mag, double.infinity);
      expect(Decimal.negativeInfinity.sign, -1.0);
      expect(Decimal.negativeInfinity.layer, double.infinity);
      expect(Decimal.negativeInfinity.mag, double.infinity);

      expect(Decimal.fromNum(double.infinity), Decimal.infinity);
      expect(
        Decimal.fromNum(double.negativeInfinity),
        Decimal.negativeInfinity,
      );
      expect(double.infinity.dec, Decimal.infinity);
      expect(Decimal.parse('Infinity'), Decimal.infinity);
      expect(Decimal.parse('-Infinity'), Decimal.negativeInfinity);

      expect(Decimal.infinity.isInfinite, isTrue);
      expect(Decimal.infinity.isFinite, isFalse);
      expect(Decimal.infinity.isNaN, isFalse);
      expect(Decimal.negativeInfinity.isNegative, isTrue);
      expect(-Decimal.infinity, Decimal.negativeInfinity);
      expect(Decimal.infinity.abs(), Decimal.infinity);
      expect(Decimal.negativeInfinity.abs(), Decimal.infinity);

      expect(Decimal.infinity > Decimal.layerMax, isTrue);
      expect(Decimal.negativeInfinity < -Decimal.layerMax, isTrue);

      expect(Decimal.infinity.toString(), 'Infinity');
      expect(Decimal.negativeInfinity.toString(), '-Infinity');
      expect(Decimal.infinity.toDouble(), double.infinity);
      expect(Decimal.negativeInfinity.toDouble(), double.negativeInfinity);

      expect((Decimal.infinity + Decimal.negativeInfinity).isNaN, isTrue);
      expect(Decimal.infinity + Decimal.one, Decimal.infinity);
    });

    test('a colossal value is finite by Decimal standards', () {
      final Decimal huge = Decimal.fromComponents(1, 1e15, 100);
      expect(huge.isFinite, isTrue);
      expect(huge.isInfinite, isFalse);
      expect(Decimal.layerMax.isFinite, isTrue);
      expect(Decimal.layerMax < Decimal.infinity, isTrue);
      // ...but it does not fit in a double.
      expect(huge.toDouble(), double.infinity);
    });
  });

  group('beyond double range', () {
    test('1e308 * 1e308 is finite and equals 1e616', () {
      final Decimal a = Decimal.fromNum(1e308);
      final Decimal product = a * a;
      expect(product.isFinite, isTrue);
      expect(product.sign, 1.0);
      expect(product.layer, 1.0);
      expect(product.mag, closeTo(616, 1e-9));
      expect(product.toString(), '1e616');
      expect(product, Decimal.parse('1e616'));
      // A double cannot hold it; the whole point of the library.
      expect(1e308 * 1e308, double.infinity);
      expect(product.toDouble(), double.infinity);
      expectNormalised(product, '1e308 * 1e308');
    });

    test('the smallest subnormal squared is finite and non-zero', () {
      final Decimal tiny = Decimal.fromNum(5e-324);
      final Decimal square = tiny * tiny;
      expect(square.isFinite, isTrue);
      expect(square.isZero, isFalse);
      expect(square.layer, 1.0);
      expect(square.mag, closeTo(-646.6124306862316, 1e-6));
      expect(5e-324 * 5e-324, 0.0);
      expect(square.toDouble(), 0.0);
    });

    test('repeated squaring climbs layers without losing normalisation', () {
      Decimal d = Decimal.fromNum(1e300);
      for (int i = 0; i < 12; i++) {
        d = d * d;
        expectNormalised(d, 'square #$i');
      }
      // 1e300 doubled 12 times in the exponent: 300 * 2^12 = 1228800.
      expect(d.layer, 1.0);
      expect(d.mag, closeTo(1228800, 1e-3));
    });

    test('a layer-3 value round-trips through toString/parse', () {
      final Decimal d = Decimal.fromComponents(1, 3, 100);
      expect(d.toString(), 'eee100');
      final Decimal back = Decimal.parse(d.toString());
      expect(back, d);
      expect(back.sign, 1.0);
      expect(back.layer, 3.0);
      expect(back.mag, 100.0);
    });

    test('a layer-7 value round-trips through toString/parse', () {
      final Decimal d = Decimal.fromComponents(-1, 7, 16.5);
      expect(d.toString(), '-(e^7)16.5');
      expect(Decimal.parse(d.toString()), d);
    });
  });

  group('add short-circuits', () {
    test('short-circuit 1: layer >= 2 returns the larger magnitude', () {
      final Decimal ee20 = Decimal.fromComponents(1, 2, 20);
      final Decimal e999 = Decimal.parse('1e999');
      // 10^10^20 dwarfs 1e999 completely; the sum is the bigger operand,
      // bit for bit, in either order.
      expect(ee20 + e999, ee20);
      expect(e999 + ee20, ee20);
      expect(ee20 + Decimal.one, ee20);
      expect(Decimal.one + ee20, ee20);
      // maxabs keeps the *larger operand's* sign, not the larger value.
      expect(-ee20 + e999, -ee20);
      expect(e999 + -ee20, -ee20);
      // Two layer-2 values: the smaller vanishes.
      expect(ee20 + Decimal.fromComponents(1, 2, 18), ee20);
      expect(ee20 + Decimal.fromComponents(-1, 2, 18), ee20);
    });

    test('short-circuit 2: an effective layer gap of 2 returns the larger', () {
      // Effective layer is `layer * sign(mag)`, so a reciprocal counts as a
      // negative layer: 1e100 is +1, 1e-100 is -1, a gap of 2.
      final Decimal big = Decimal.parse('1e100');
      final Decimal small = Decimal.parse('1e-100');
      expect(big.layer, 1.0);
      expect(small.layer, 1.0);
      expect(small.mag.isNegative, isTrue);
      expect(big + small, big);
      expect(small + big, big);
      expect(big - small, big);
    });

    test('short-circuit 3: a gap beyond 17 digits returns the larger', () {
      final Decimal big = Decimal.parse('1e100');
      // 100 - 82 == 18 > maxSignificantDigits, so 1e82 falls off the end.
      expect(big + Decimal.parse('1e82'), big);
      expect(big + Decimal.parse('-1e82'), big);
      // Same for the layer-1 / layer-0 mixed branch: |20 - log10(1)| > 17.
      expect(Decimal.parse('1e20') + Decimal.one, Decimal.parse('1e20'));
      // ...and the layer-0 / negative-layer branch: |-300 - 0| > 17.
      expect(Decimal.one + Decimal.parse('1e-300'), Decimal.one);
      expect(Decimal.parse('1e-300') + Decimal.one, Decimal.one);
    });

    test('short-circuit 4: inside 17 digits the log-space formula runs', () {
      final Decimal big = Decimal.parse('1e100');
      // 100 - 90 == 10 <= 17, so the smaller operand *does* move the result.
      final Decimal sum = big + Decimal.parse('1e90');
      expect(sum, isNot(big));
      expect(sum.layer, 1.0);
      expect(sum.mag, closeTo(100.00000000004343, 1e-12));

      // 1e100 + 1e100 = 2e100, computed as 100 + log10(2).
      final Decimal doubled = big + big;
      expect(doubled.layer, 1.0);
      expect(doubled.mag, closeTo(100.30102999566398, 1e-12));
      expect(doubled.mantissa, closeTo(2, 1e-9));

      // The layer-1 / layer-0 branch, just inside the threshold.
      final Decimal mixed = Decimal.parse('1e17') + Decimal.one;
      expect(mixed.layer, 1.0);
      expect(mixed.mag, closeTo(17, 1e-12));

      // The layer-0 / negative-layer branch, just inside the threshold.
      final Decimal tiny = Decimal.one + Decimal.parse('1e-16');
      expect(tiny.layer, 0.0);
      expect(tiny.mag, closeTo(1, 1e-12));
    });

    test('exact cancellation is zero at any magnitude', () {
      final Decimal ee20 = Decimal.fromComponents(1, 2, 20);
      expect(ee20 + -ee20, Decimal.zero);
      expect(ee20 - ee20, Decimal.zero);
      expect(Decimal.layerMax - Decimal.layerMax, Decimal.zero);
    });

    test('adding zero returns the other operand unchanged', () {
      final Decimal e6 = Decimal.fromComponents(1, 6, 20);
      expect(Decimal.zero + e6, e6);
      expect(e6 + Decimal.zero, e6);
    });

    test('plain layer-0 addition is plain double addition', () {
      expect(Decimal.one + Decimal.two, Decimal.fromNum(3));
      expect((Decimal.fromNum(2.5) - Decimal.fromNum(4)).toDouble(), -1.5);
      // Including the usual binary-floating-point wart: this is 0.1 + 0.2 in
      // doubles, not the decimal 0.3, and the reference prints it the same.
      final Decimal sum = Decimal.fromNum(0.1) + Decimal.fromNum(0.2);
      expect(sum, Decimal.fromNum(0.1 + 0.2));
      expect(sum, isNot(Decimal.fromNum(0.3)));
      expect(sum.toString(), '0.30000000000000004');
    });
  });

  group('toString', () {
    test('layer-0 integral values print without a trailing .0', () {
      expect(Decimal.zero.toString(), '0');
      expect(Decimal.one.toString(), '1');
      expect(Decimal.negativeOne.toString(), '-1');
      expect(Decimal.two.toString(), '2');
      expect(Decimal.ten.toString(), '10');
      expect(5.dec.toString(), '5');
      expect(5.0.dec.toString(), '5');
      expect((-5).dec.toString(), '-5');
      expect(1000000.dec.toString(), '1000000');
      expect(8999999999999999.0.dec.toString(), '8999999999999999');
      expect(Decimal.fromNum(1e15).toString(), '1000000000000000');
    });

    test('layer-0 fractional values print plainly', () {
      expect(5.5.dec.toString(), '5.5');
      expect((-5.5).dec.toString(), '-5.5');
      expect(0.5.dec.toString(), '0.5');
      expect(Decimal.fromNum(1e-6).toString(), '0.000001');
    });

    test('outside 1e-7..1e21 the MeX form takes over', () {
      // The plain branch is `1e-7 < mag < 1e21`, both bounds exclusive.
      expect(Decimal.fromNum(1e-7).toString(), '1e-7');
      expect(Decimal.fromNum(1e-8).toString(), '1e-8');
      // The mantissa is `mag / 10^exponent` in floating point, so a mantissa
      // that is not a power of ten picks up a rounding error. The reference
      // prints exactly the same digits.
      expect(Decimal.fromNum(1.5e-8).toString(), '1.4999999999999998e-8');
      expect(Decimal.fromNum(1e21).toString(), '1e21');
      expect(Decimal.fromNum(1e100).toString(), '1e100');
      expect(Decimal.fromNum(-1e100).toString(), '-1e100');
      expect(Decimal.fromNum(1e-100).toString(), '1e-100');
    });

    test('layers 2 to 5 print as a run of es', () {
      expect(Decimal.fromComponents(1, 2, 16).toString(), 'ee16');
      expect(Decimal.fromComponents(1, 2, 16.5).toString(), 'ee16.5');
      expect(Decimal.fromComponents(-1, 2, 16.5).toString(), '-ee16.5');
      expect(Decimal.fromComponents(1, 2, -16).toString(), 'ee-16');
      expect(Decimal.fromComponents(1, 3, 100).toString(), 'eee100');
      expect(Decimal.fromComponents(1, 4, 100).toString(), 'eeee100');
      expect(Decimal.fromComponents(1, 5, 100).toString(), 'eeeee100');
    });

    test('layer 6 and up print as (e^N)M', () {
      expect(Decimal.fromComponents(1, 6, 20).toString(), '(e^6)20');
      expect(Decimal.fromComponents(-1, 6, 20).toString(), '-(e^6)20');
      expect(Decimal.fromComponents(1, 7, 16.5).toString(), '(e^7)16.5');
      expect(
        Decimal.fromComponents(1, 10, 1e15).toString(),
        '(e^10)1000000000000000',
      );
      expect(Decimal.fromComponents(1, 100, 16.5).toString(), '(e^100)16.5');
    });

    test('toJson delegates to toString', () {
      final Decimal d = Decimal.fromComponents(1, 4, 100);
      expect(d.toJson(), d.toString());
      expect(Decimal.parse(d.toJson()), d);
    });
  });

  group('parse round-trips', () {
    final Map<String, Decimal> cases = <String, Decimal>{
      // layer 0
      '0': Decimal.zero,
      '1': Decimal.one,
      '-1': Decimal.negativeOne,
      '5.5': Decimal.fromNum(5.5),
      '-5.5': Decimal.fromNum(-5.5),
      '1e-7': Decimal.fromNum(1e-7),
      '1e-8': Decimal.fromNum(1e-8),
      // layer 1
      '1e21': Decimal.fromNum(1e21),
      '1e100': Decimal.fromNum(1e100),
      '-1e100': Decimal.fromNum(-1e100),
      '1e-100': Decimal.fromNum(1e-100),
      '1e616': Decimal.fromNum(1e308) * Decimal.fromNum(1e308),
      // layers 2..6
      'ee16': Decimal.fromComponents(1, 2, 16),
      'ee16.5': Decimal.fromComponents(1, 2, 16.5),
      '-ee16.5': Decimal.fromComponents(-1, 2, 16.5),
      'ee-16': Decimal.fromComponents(1, 2, -16),
      'eee100': Decimal.fromComponents(1, 3, 100),
      'eeee100': Decimal.fromComponents(1, 4, 100),
      'eeeee100': Decimal.fromComponents(1, 5, 100),
      '(e^6)20': Decimal.fromComponents(1, 6, 20),
      '-(e^6)20': Decimal.fromComponents(-1, 6, 20),
      '(e^10)1000000000000000': Decimal.fromComponents(1, 10, 1e15),
    };

    test('every documented spelling parses to the expected triple', () {
      cases.forEach((String source, Decimal expected) {
        final Decimal parsed = Decimal.parse(source);
        expect(parsed, expected, reason: 'parse("$source")');
        expectNormalised(parsed, 'parse("$source")');
      });
    });

    test('toString is the inverse of parse for those spellings', () {
      cases.forEach((String source, Decimal expected) {
        expect(expected.toString(), source, reason: 'toString of "$source"');
      });
    });

    test('parse(toString(x)) == x across layers 0 to 6', () {
      final List<Decimal> values = <Decimal>[
        Decimal.zero,
        Decimal.one,
        Decimal.negativeOne,
        Decimal.fromNum(1234.5),
        Decimal.fromNum(-1e-8),
        Decimal.fromNum(1e100),
        Decimal.fromNum(-1e-100),
        Decimal.fromComponents(1, 2, 16.5),
        Decimal.fromComponents(-1, 2, -16.5),
        Decimal.fromComponents(1, 3, 1234.5),
        Decimal.fromComponents(-1, 4, 8999999999999999),
        Decimal.fromComponents(1, 5, 15.954242509439325),
        Decimal.fromComponents(-1, 6, 20),
        Decimal.infinity,
        Decimal.negativeInfinity,
      ];
      for (final Decimal d in values) {
        expect(Decimal.parse(d.toString()), d, reason: 'round trip of $d');
      }
      expect(Decimal.parse(Decimal.nan.toString()).isNaN, isTrue);
    });

    test('leading + and surrounding whitespace are accepted', () {
      expect(Decimal.parse('  5  '), Decimal.fromNum(5));
      expect(Decimal.parse('+5'), Decimal.fromNum(5));
      expect(Decimal.parse('+ee16'), Decimal.fromComponents(1, 2, 16));
      expect(Decimal.parse('INFINITY'), Decimal.infinity);
    });
  });

  group('parse failures', () {
    const List<String> garbage = <String>[
      '',
      '   ',
      'abc',
      'e',
      'ee',
      '5 apples',
      '1,000',
      '--5',
      '1e1e1',
      'infinity!',
      '(e^6)',
      '(e^)20',
      '(e^-8)1',
      '(e^10.5)1',
      '10^^3',
      '10^3',
      '10^^^3',
      '2 pt 3',
      '1F3',
    ];

    test('tryParse returns null for unsupported input', () {
      for (final String source in garbage) {
        expect(
          Decimal.tryParse(source),
          isNull,
          reason: 'tryParse("$source") should be null, not a wrong number',
        );
      }
    });

    test('parse throws FormatException for unsupported input', () {
      for (final String source in garbage) {
        expect(
          () => Decimal.parse(source),
          throwsA(isA<FormatException>()),
          reason: 'parse("$source")',
        );
      }
    });

    test('Decimal.from accepts Decimal, num and String only', () {
      expect(Decimal.from(Decimal.one), Decimal.one);
      expect(Decimal.from(5), Decimal.fromNum(5));
      expect(Decimal.from(5.5), Decimal.fromNum(5.5));
      expect(Decimal.from('1e100'), Decimal.fromNum(1e100));
      expect(() => Decimal.from(<int>[1]), throwsA(isA<ArgumentError>()));
      expect(() => Decimal.from(true), throwsA(isA<ArgumentError>()));
      expect(() => Decimal.from('nope'), throwsA(isA<FormatException>()));
    });
  });

  group('the .dec extension', () {
    test('matches Decimal.fromNum for ints and doubles', () {
      expect(5.dec, Decimal.fromNum(5));
      expect(5.dec, Decimal.one + Decimal.fromNum(4));
      expect((-5).dec, Decimal.fromNum(-5));
      expect(1.5.dec, Decimal.fromNum(1.5));
      expect(0.dec, Decimal.zero);
      expect(1e300.dec * 1e300.dec, Decimal.parse('1e600'));
      expect(double.infinity.dec, Decimal.infinity);
      expect(double.negativeInfinity.dec, Decimal.negativeInfinity);
      expect(double.nan.dec.isNaN, isTrue);
    });

    test('works on int expressions without an explicit toDouble', () {
      const int gold = 1000000;
      expect(gold.dec.toString(), '1000000');
      expect((gold.dec * gold.dec).toString(), '1000000000000');
    });
  });

  group('static constants', () {
    test('hold the values the contract names', () {
      expect(Decimal.zero.toDouble(), 0.0);
      expect(Decimal.one.toDouble(), 1.0);
      expect(Decimal.negativeOne.toDouble(), -1.0);
      expect(Decimal.two.toDouble(), 2.0);
      expect(Decimal.ten.toDouble(), 10.0);
      // numberMax does not survive the trip back through `double`: it is
      // stored as 10^308.2547..., and `pow` returns 1.7976931348623277e308,
      // a hair above `double.maxFinite`. The reference's `toNumber()` returns
      // Infinity here too.
      expect(Decimal.numberMax.toDouble(), double.infinity);
      expect(Decimal.numberMax.toString(), '1.7976931348623277e308');
      expect(Decimal.numberMin.toDouble(), greaterThan(0.0));
      expect(Decimal.numberMin.toDouble(), lessThan(1e-320));
      expect(Decimal.numberMax.layer, 1.0);
      expect(Decimal.numberMax.mag, closeTo(308.25471555991675, 1e-9));
      expect(Decimal.numberMin.layer, 1.0);
      expect(Decimal.numberMin.mag, closeTo(-323.3062153431158, 1e-9));
    });

    test('the layer limits are ordered and finite', () {
      expect(Decimal.layerSafeMax.layer, 9007199254740991.0);
      expect(Decimal.layerSafeMin.layer, 9007199254740991.0);
      expect(Decimal.layerMax.layer, double.maxFinite);
      expect(Decimal.layerMin.layer, double.maxFinite);
      expect(Decimal.layerMax.isFinite, isTrue);
      expect(Decimal.layerMin.isFinite, isTrue);
      expect(Decimal.layerSafeMax < Decimal.layerMax, isTrue);
      expect(Decimal.layerMin < Decimal.layerSafeMin, isTrue);
      expect(Decimal.layerMin > Decimal.zero, isTrue);
      expect(Decimal.layerMax > Decimal.numberMax, isTrue);
    });

    test('are structurally distinct, and equality is over the triple', () {
      expect(Decimal.one == Decimal.fromNum(1), isTrue);
      expect(Decimal.one == Decimal.negativeOne, isFalse);
      expect(Decimal.one.hashCode, Decimal.fromNum(1).hashCode);
      // A Decimal never equals a bare num, whatever its value.
      const Object rawZero = 0;
      expect(Decimal.zero == rawZero, isFalse);
    });
  });

  group('mantissa and exponent', () {
    test('reproduce break_infinity semantics at layers 0 and 1', () {
      expect(Decimal.zero.mantissa, 0.0);
      expect(Decimal.zero.exponent, 0.0);

      expect(Decimal.fromNum(5).mantissa, closeTo(5, 1e-12));
      expect(Decimal.fromNum(5).exponent, 0.0);
      expect(Decimal.fromNum(-5).mantissa, closeTo(-5, 1e-12));

      expect(Decimal.fromNum(1234.5).mantissa, closeTo(1.2345, 1e-12));
      expect(Decimal.fromNum(1234.5).exponent, 3.0);

      final Decimal e100 = Decimal.fromNum(1e100);
      expect(e100.layer, 1.0);
      expect(e100.mantissa, closeTo(1, 1e-12));
      expect(e100.exponent, 100.0);

      final Decimal e = Decimal.parse('2e100');
      expect(e.mantissa, closeTo(2, 1e-9));
      expect(e.exponent, 100.0);

      // The smallest subnormal is special-cased upstream.
      expect(Decimal.fromNum(5e-324).mantissa, closeTo(4.94, 0.1));
    });

    test('degrade gracefully past layer 2', () {
      final Decimal ee16 = Decimal.fromComponents(1, 2, 16);
      expect(ee16.mantissa, 1.0, reason: 'past layer 1 the mantissa is sign');
      expect(ee16.exponent, 1e16);

      final Decimal negEe16 = Decimal.fromComponents(-1, 2, 16);
      expect(negEe16.mantissa, -1.0);

      final Decimal eee100 = Decimal.fromComponents(1, 3, 100);
      expect(eee100.mantissa, 1.0);
      expect(eee100.exponent, double.infinity);
    });

    test('fromMantissaExponent rebuilds the pair', () {
      final Decimal d = Decimal.fromMantissaExponent(1.5, 300);
      expect(d.mantissa, closeTo(1.5, 1e-9));
      expect(d.exponent, 300.0);
      final Decimal neg = Decimal.fromMantissaExponent(-2, 1000);
      expect(neg.sign, -1.0);
      expect(neg.exponent, 1000.0);
      expectNormalised(neg, 'fromMantissaExponent(-2, 1000)');
    });

    test('signum and the boolean accessors', () {
      expect(Decimal.one.signum, 1);
      expect(Decimal.negativeOne.signum, -1);
      expect(Decimal.zero.signum, 0);
      expect(Decimal.nan.signum, 0);
      expect(Decimal.infinity.signum, 1);
      expect(Decimal.negativeInfinity.signum, -1);

      expect(Decimal.negativeOne.isNegative, isTrue);
      expect(Decimal.zero.isNegative, isFalse);
      expect(Decimal.nan.isNegative, isFalse);
      expect(Decimal.one.isZero, isFalse);
    });
  });

  group('fromComponentsNoNormalize', () {
    test('trusts the caller and is const-constructible', () {
      const Decimal d = Decimal.fromComponentsNoNormalize(1, 0, 5);
      expect(d, Decimal.fromNum(5));
      // Deliberately malformed: it is preserved verbatim, as documented.
      const Decimal bad = Decimal.fromComponentsNoNormalize(1, 0, 1e100);
      expect(bad.layer, 0.0);
      expect(bad.mag, 1e100);
      // ...and normalising it afterwards fixes it up.
      expect(
        Decimal.fromComponents(bad.sign, bad.layer, bad.mag),
        Decimal.fromNum(1e100),
      );
    });
  });

  // Regressions for issues found in the pre-release security review. Save data
  // is attacker-controlled in a shipped game — a player can edit their own
  // save, and cloud-synced or shared "import codes" cross a real trust
  // boundary — so `parse`/`tryParse` must terminate and must not throw.
  group('hostile input (security regressions)', () {
    test(
      'a zero magnitude at a huge layer resolves instantly, not eventually',
      () {
        // `(e^N)0` used to walk the layer-down loop one step at a time: roughly
        // 60 days for N = 1e15, and genuinely forever for N >= 2^54, where
        // `layer -= 1` stops changing the double at all. The answer is 1 for
        // every N, which is what the reference computes the slow way.
        const List<String> hostile = <String>[
          '(e^18014398509481984)0', // 2^54, the smallest non-terminating case
          '(e^1000000000000000)0',
          '(e^10000000000000000000)0',
          '(e^1e308)0',
          '(e^200000)-0',
          '(e^200000)0.0',
          '(e^200000)+0',
          '(e^200000)1e-400', // underflows to zero, so it hit the loop too
        ];
        for (final String source in hostile) {
          final Stopwatch sw = Stopwatch()..start();
          expect(Decimal.tryParse(source), Decimal.one, reason: source);
          sw.stop();
          expect(
            sw.elapsedMilliseconds,
            lessThan(500),
            reason: '$source took ${sw.elapsedMilliseconds}ms',
          );
        }
        // The short-circuit must not have changed the ordinary answers.
        expect(Decimal.tryParse('(e^6)0'), Decimal.one);
        expect(Decimal.tryParse('(e^1)0'), Decimal.one);
      },
    );

    test(
      'an oversized literal returns null instead of overflowing the stack',
      () {
        // Multi-megabyte digit runs used to raise StackOverflowError out of the
        // regex engine. That is an Error, not an Exception, so it escaped
        // `tryParse`'s "null on failure" contract entirely.
        for (final int digits in <int>[5000, 4200000]) {
          expect(Decimal.tryParse('1.${'2' * digits}e5'), isNull);
        }
        expect(() => Decimal.parse('9' * 100000), throwsFormatException);
        // Just under the cap still parses.
        expect(Decimal.tryParse('1.${'0' * 4000}e5'), Decimal.fromNum(100000));
      },
    );

    test('layerMax and layerMin survive a save round trip', () {
      // toString emits `(e^1e+21)16` for layers at or above 1e21, which the
      // parser used to reject — so serialising these constants produced a save
      // the library itself could not load.
      for (final Decimal d in <Decimal>[Decimal.layerMax, Decimal.layerMin]) {
        expect(Decimal.parse(d.toJson()), d, reason: d.toJson());
      }
    });

    test('invalid layers are still rejected after widening the pattern', () {
      const List<String> invalid = <String>[
        '(e^-8)1', // negative: needs tetrate
        '(e^10.5)1', // fractional: needs tetrate
        '(e^1e400)1', // overflows to infinity
        '(e^)20',
        '(e^1e+21)', // no magnitude
      ];
      for (final String source in invalid) {
        expect(Decimal.tryParse(source), isNull, reason: source);
        expect(
          () => Decimal.parse(source),
          throwsFormatException,
          reason: source,
        );
      }
    });

    test('toStringAsPrecision clamps instead of throwing below 1', () {
      // digits >= 16 on a magnitude in [1e-6, 1e-1) derived more than the 20
      // decimal places `double.toStringAsFixed` accepts, and threw RangeError
      // on an argument documented as valid.
      for (int digits = 1; digits <= 20; digits++) {
        for (final double v in <double>[1.5e-6, 1.5e-5, 0.015, 1.5, 1.5e3]) {
          expect(
            () => Decimal.fromNum(v).toStringAsPrecision(digits),
            returnsNormally,
            reason: 'v=$v digits=$digits',
          );
        }
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Exactness, which the fixtures' relative tolerance cannot assert
  // ---------------------------------------------------------------------------

  group('exact logarithms and powers', () {
    test('log2 is exact on every power of two it can name', () {
      // `log2` used to be `log10(x) / log10(2)`, which returns
      // -10.999999999999998 for 2^-11 where V8's `Math.log2` returns exactly
      // -11 — so `2^-11 .log2().ceil()` was -10 here and -11 in the reference.
      // It is now the fdlibm `__ieee754_log2` port, which reduces an exact
      // power of two to `f == 0` and returns the exponent with no rounding.
      // The layer-0 domain is 2^-52 .. 2^52; above that the reference itself
      // multiplies the mag by a rounded log2(10) and is inexact, and this port
      // matches it there.
      for (int e = -52; e <= 52; e++) {
        final double x = _exactPowerOfTwo(e);
        final Decimal got = Decimal.fromNum(x).log2();
        expect(
          got,
          Decimal.fromNum(e.toDouble()),
          reason: 'log2(2^$e) on x = $x gave ${got.mag} (sign ${got.sign})',
        );
      }
    });

    test('log10 and pow10 are exact inverses on exact powers of ten', () {
      // The lookup table in `constants.dart` exists for this: a game that
      // renders `1e30` must not be shown `9.999999999999918e29`.
      for (int e = -323; e <= 308; e++) {
        expect(
          Decimal.parse('1e$e').log10(),
          Decimal.fromNum(e.toDouble()),
          reason: 'log10(1e$e)',
        );
      }

      // pow10 only round-trips down to 1e-4. Below that `10^e` is under the
      // reference's 0.1 floor, so the layer-0 branch is abandoned and the
      // answer rebuilt one layer up, which costs the subnormal decades their
      // last digits: `Decimal.fromNum(-320).pow10()` is 1.0000000000002618e-320
      // rather than 1e-320. That is not a porting error — break_eternity.js
      // misses exactly the same 258 exponents (the two sets were compared
      // element by element against the vendored bundle), and all of them are
      // inside the `pow10` fixture.
      for (int e = -4; e <= 308; e++) {
        expect(
          Decimal.fromNum(e.toDouble()).pow10(),
          Decimal.parse('1e$e'),
          reason: 'pow10($e)',
        );
      }
    });

    test('pow and root agree with the dedicated square and cube helpers', () {
      // sqr/cube are `pow(2)`/`pow(3)` in the reference, so the identity has to
      // hold to the last bit, not to a tolerance.
      final List<Decimal> values = <Decimal>[
        Decimal.fromNum(2),
        Decimal.fromNum(-2),
        Decimal.fromNum(1e100),
        Decimal.fromNum(1e-100),
        Decimal.fromComponents(1, 2, 100),
        Decimal.fromComponents(-1, 3, 1000),
      ];
      for (final Decimal v in values) {
        expect(v.sqr(), v.pow(Decimal.two), reason: 'sqr($v)');
        expect(v.cube(), v.pow(Decimal.fromNum(3)), reason: 'cube($v)');
        // powBase is pow with the operands swapped, and nothing else.
        expect(
          Decimal.two.powBase(v),
          v.pow(Decimal.two),
          reason: 'powBase($v)',
        );
      }
    });
  });
}
