/// Hand-written tests for the incremental-game series helpers, and for the
/// log/pow identities that a pointwise oracle cannot express.
///
/// The fixture and oracle suites check one call at a time against one expected
/// triple. The things that actually break a game are *relations between* calls:
/// that `sumGeometricSeries` and `affordGeometricSeries` are exact inverses, so
/// a shop never overcharges; that `sqrt` and `sqr` undo each other; that
/// `pow10` and `log10` undo each other. Those are what live here.
///
/// Every expected value in this file was produced by running the same
/// expression against the vendored JavaScript reference
/// (`reference/break_eternity.umd.js`, break_eternity.js 2.1.3) under node.
/// Where the reference's answer is visibly *wrong* — the several places where
/// double precision defeats the closed-form formula — the test asserts the
/// reference's answer anyway and says so, because this is a port and a silent
/// divergence is worse than a documented wart.
library;

import 'package:break_eternity/break_eternity.dart';
import 'package:test/test.dart';

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

/// Shorthand for [Decimal.parse], to keep the parameter tables readable.
Decimal d(String source) => Decimal.parse(source);

/// Asserts that [actual] and [expected] agree to within a relative [tolerance].
///
/// The tolerance is [Decimal.equalsWithin]'s: relative, applied to the
/// magnitudes, so at layer 0 it is a relative error on the value and higher up
/// it is a relative error on the exponent.
void expectClose(
  Decimal actual,
  Decimal expected,
  double tolerance, {
  required String reason,
}) {
  expect(
    actual.equalsWithin(expected, tolerance),
    isTrue,
    reason:
        '$reason: expected $expected, got $actual '
        '(tolerance $tolerance)',
  );
}

/// The largest answer for which a purchase count is still meaningful.
///
/// Both series formulas compute the total cost of `n` items in doubles. Once
/// `n` is past about 1e15 a single extra item is smaller than one ulp of the
/// total, so "buying one more costs strictly more" stops being a statement
/// about the maths and becomes a statement about rounding. 1e12 leaves three
/// decimal orders of headroom; the reference behaves identically, and the
/// round-trip sweep below skips anything above it rather than pretending.
final Decimal roundTripLimit = d('1e12');

/// Checks the geometric round trip for one set of shop parameters.
///
/// Returns whether the case was actually checked (false if it was skipped for
/// being outside the resolvable range), so the sweep can assert it covered a
/// meaningful number of them.
bool checkGeometricRoundTrip(
  Decimal money,
  Decimal priceStart,
  Decimal priceRatio,
  Decimal currentOwned,
) {
  final Decimal n = Decimal.affordGeometricSeries(
    money,
    priceStart,
    priceRatio,
    currentOwned,
  );
  if (n.isNaN || n.isInfinite || n < Decimal.zero || n > roundTripLimit) {
    return false;
  }

  final String what =
      'money=$money start=$priceStart ratio=$priceRatio owned=$currentOwned '
      '-> n=$n';

  final Decimal cost = Decimal.sumGeometricSeries(
    n,
    priceStart,
    priceRatio,
    currentOwned,
  );
  expect(
    cost <= money,
    isTrue,
    reason:
        '$what: buying n costs $cost, which is more than the $money '
        'available — the shop would overcharge',
  );

  final Decimal costOfOneMore = Decimal.sumGeometricSeries(
    n + Decimal.one,
    priceStart,
    priceRatio,
    currentOwned,
  );
  expect(
    costOfOneMore > money,
    isTrue,
    reason:
        '$what: buying n+1 costs only $costOfOneMore, which the $money '
        'available covers — the player was undersold',
  );
  return true;
}

/// Checks the arithmetic round trip for one set of shop parameters.
///
/// See [checkGeometricRoundTrip] for the return value.
bool checkArithmeticRoundTrip(
  Decimal money,
  Decimal priceStart,
  Decimal priceAdd,
  Decimal currentOwned,
) {
  final Decimal n = Decimal.affordArithmeticSeries(
    money,
    priceStart,
    priceAdd,
    currentOwned,
  );
  if (n.isNaN || n.isInfinite || n < Decimal.zero || n > roundTripLimit) {
    return false;
  }

  final String what =
      'money=$money start=$priceStart add=$priceAdd owned=$currentOwned '
      '-> n=$n';

  final Decimal cost = Decimal.sumArithmeticSeries(
    n,
    priceStart,
    priceAdd,
    currentOwned,
  );
  expect(
    cost <= money,
    isTrue,
    reason:
        '$what: buying n costs $cost, which is more than the $money '
        'available — the shop would overcharge',
  );

  final Decimal costOfOneMore = Decimal.sumArithmeticSeries(
    n + Decimal.one,
    priceStart,
    priceAdd,
    currentOwned,
  );
  expect(
    costOfOneMore > money,
    isTrue,
    reason:
        '$what: buying n+1 costs only $costOfOneMore, which the $money '
        'available covers — the player was undersold',
  );
  return true;
}

// -----------------------------------------------------------------------------
// Parameter tables for the round-trip sweeps
// -----------------------------------------------------------------------------
//
// The money values are deliberately *not* round. When the money on hand is
// exactly the total of some prefix of the series, `floor()` sits on a knife
// edge and an ulp either way decides the answer; the reference gets those
// wrong about as often as it gets them right (see the "knife-edge totals"
// group below, which pins that behaviour instead of hiding it).

/// Resource amounts to sweep, spanning layer 0 up to the edge of `double`.
final List<Decimal> sweepMoney = <Decimal>[
  d('13.7'),
  d('271.828'),
  d('3141.59'),
  d('1.234567e5'),
  d('6.02214e9'),
  d('1.7e13'),
  d('8.8e21'),
  d('4.669e60'),
  d('2.71828e120'),
  d('1.61803e250'),
];

/// Starting prices to sweep.
final List<Decimal> sweepStart = <Decimal>[
  Decimal.one,
  d('3'),
  Decimal.ten,
  d('137'),
  d('1e4'),
  d('6.7e9'),
];

/// Price ratios to sweep: from a 0.1%-per-purchase creep up to 77x.
final List<Decimal> sweepRatio = <Decimal>[
  d('1.001'),
  d('1.01'),
  d('1.07'),
  d('1.1'),
  d('1.15'),
  d('1.25'),
  d('1.5'),
  Decimal.two,
  d('3'),
  Decimal.ten,
  d('77'),
];

/// Price increments to sweep for the arithmetic series.
final List<Decimal> sweepAdd = <Decimal>[
  d('0.5'),
  Decimal.one,
  Decimal.two,
  d('5'),
  d('50'),
  d('137'),
  d('1e4'),
  d('3.3e8'),
];

/// Counts already owned to sweep.
final List<Decimal> sweepOwned = <Decimal>[
  Decimal.zero,
  Decimal.one,
  Decimal.two,
  d('3'),
  d('7'),
  Decimal.ten,
  d('42'),
  d('100'),
  d('999'),
  d('1e4'),
];

// -----------------------------------------------------------------------------
// Values for the log/pow identity tests
// -----------------------------------------------------------------------------

/// Positive values spanning layer 0 through layer 4.
///
/// The smallest is 1e-15 rather than something tinier on purpose: below
/// `1/9e15` a `Decimal` moves to layer 1 with a negative mag, and the
/// reference's `sqrt` reads `Math.log10` of that negative mag and returns NaN.
/// That quirk gets its own test rather than being smuggled into the identity
/// sweeps.
final List<Decimal> identityValues = <Decimal>[
  d('1e-15'),
  d('1e-9'),
  d('0.001'),
  d('0.5'),
  Decimal.one,
  Decimal.two,
  d('3'),
  d('7'),
  Decimal.ten,
  d('137'),
  d('1e6'),
  d('1e15'),
  d('1e16'),
  d('1e100'),
  d('1e300'),
  Decimal.fromComponents(1, 1, 1000),
  Decimal.fromComponents(1, 1, 1e10),
  Decimal.fromComponents(1, 2, 20),
  Decimal.fromComponents(1, 2, 100),
  Decimal.fromComponents(1, 2, 1e10),
  Decimal.fromComponents(1, 3, 20),
  Decimal.fromComponents(1, 5, 1e10),
];

/// Exponents for `pow10`/`log10` and `exp`/`ln`, both signs.
///
/// Nothing smaller than 0.001 in absolute value: `10^1e-15` is 1 to the last
/// bit a `double` has, so `log10` of it is 0 and the identity is destroyed by
/// the representation rather than by the code. The lower end is where the
/// tolerance has to open up to 1e-12; from 0.5 up the round trip is exact.
final List<Decimal> exponentValues = <Decimal>[
  d('0.001'),
  d('0.5'),
  Decimal.one,
  Decimal.two,
  d('7'),
  Decimal.ten,
  d('137'),
  d('308.25'),
  d('1e6'),
  d('1e15'),
  d('1e16'),
  d('1e100'),
  d('1e300'),
  Decimal.fromComponents(1, 1, 1000),
  Decimal.fromComponents(1, 1, 1e10),
  Decimal.fromComponents(1, 2, 20),
  Decimal.fromComponents(1, 2, 1e10),
  Decimal.fromComponents(1, 4, 20),
];

void main() {
  // ---------------------------------------------------------------------------
  // The property that matters: afford and sum are exact inverses
  // ---------------------------------------------------------------------------

  group('geometric series round trip', () {
    test('afford then sum never overcharges, and one more is unaffordable', () {
      int checked = 0;
      for (final Decimal money in sweepMoney) {
        for (final Decimal start in sweepStart) {
          for (final Decimal ratio in sweepRatio) {
            for (final Decimal owned in sweepOwned) {
              if (checkGeometricRoundTrip(money, start, ratio, owned)) {
                checked++;
              }
            }
          }
        }
      }
      // If a refactor ever makes affordGeometricSeries return NaN or something
      // enormous everywhere, the sweep above would pass vacuously.
      expect(checked, greaterThan(6000), reason: 'the sweep went vacuous');
    });

    test('the currentOwned offset is not off by one', () {
      // Buying one item when you own k must cost exactly the k-th price,
      // priceStart * priceRatio^k — this is the assertion that catches an
      // off-by-one in the offset, because owning k means the *next* purchase
      // is the (k+1)-th and costs ratio^k, not ratio^(k+1) or ratio^(k-1).
      for (final Decimal owned in sweepOwned) {
        for (final Decimal ratio in <Decimal>[d('1.15'), Decimal.two, d('3')]) {
          final Decimal single = Decimal.sumGeometricSeries(
            Decimal.one,
            Decimal.ten,
            ratio,
            owned,
          );
          expectClose(
            single,
            Decimal.ten * ratio.pow(owned),
            1e-12,
            reason: 'the next price when owning $owned at ratio $ratio',
          );
        }
      }
    });

    test('the series telescopes: n then m more costs the same as n + m', () {
      for (final Decimal ratio in <Decimal>[
        d('1.07'),
        d('1.15'),
        Decimal.two,
      ]) {
        for (final Decimal owned in <Decimal>[Decimal.zero, d('7'), d('100')]) {
          for (final Decimal n in <Decimal>[Decimal.one, d('5'), d('40')]) {
            for (final Decimal m in <Decimal>[Decimal.one, d('3'), d('25')]) {
              final Decimal split =
                  Decimal.sumGeometricSeries(n, Decimal.ten, ratio, owned) +
                  Decimal.sumGeometricSeries(m, Decimal.ten, ratio, owned + n);
              final Decimal whole = Decimal.sumGeometricSeries(
                n + m,
                Decimal.ten,
                ratio,
                owned,
              );
              expectClose(
                split,
                whole,
                1e-12,
                reason: 'buying $n then $m at ratio $ratio owning $owned',
              );
            }
          }
        }
      }
    });
  });

  group('arithmetic series round trip', () {
    test('afford then sum never overcharges, and one more is unaffordable', () {
      int checked = 0;
      for (final Decimal money in sweepMoney) {
        for (final Decimal start in sweepStart) {
          for (final Decimal add in sweepAdd) {
            for (final Decimal owned in sweepOwned) {
              if (checkArithmeticRoundTrip(money, start, add, owned)) {
                checked++;
              }
            }
          }
        }
      }
      expect(checked, greaterThan(3000), reason: 'the sweep went vacuous');
    });

    test('the currentOwned offset is not off by one', () {
      // Owning k means the next item costs priceStart + k * priceAdd. All of
      // these are exact in doubles, so exact equality is the right assertion.
      for (final Decimal owned in sweepOwned) {
        for (final Decimal add in <Decimal>[Decimal.one, d('50'), d('1e4')]) {
          expect(
            Decimal.sumArithmeticSeries(Decimal.one, d('100'), add, owned),
            d('100') + owned * add,
            reason: 'the next price when owning $owned at +$add',
          );
        }
      }
    });

    test('the series telescopes: n then m more costs the same as n + m', () {
      for (final Decimal add in <Decimal>[Decimal.one, d('50'), d('1e4')]) {
        for (final Decimal owned in <Decimal>[Decimal.zero, d('7'), d('100')]) {
          for (final Decimal n in <Decimal>[Decimal.one, d('5'), d('40')]) {
            for (final Decimal m in <Decimal>[Decimal.one, d('3'), d('25')]) {
              final Decimal split =
                  Decimal.sumArithmeticSeries(n, d('100'), add, owned) +
                  Decimal.sumArithmeticSeries(m, d('100'), add, owned + n);
              final Decimal whole = Decimal.sumArithmeticSeries(
                n + m,
                d('100'),
                add,
                owned,
              );
              expectClose(
                split,
                whole,
                1e-12,
                reason: 'buying $n then $m at +$add owning $owned',
              );
            }
          }
        }
      }
    });
  });

  group('monotonicity', () {
    // A shop's "buy max" button reads wrong to a player if either of these
    // ever inverts: more gold must never buy fewer, and owning more must never
    // buy more. Both are guarded to counts above zero — below zero the
    // formulas are extrapolating a debt rather than pricing a purchase, and
    // the arithmetic one is not monotone there (see "knife-edge totals").

    test('more resources never afford fewer items', () {
      int checked = 0;
      for (int i = 0; i < sweepMoney.length - 1; i++) {
        for (final Decimal start in sweepStart) {
          for (final Decimal ratio in sweepRatio) {
            for (final Decimal owned in sweepOwned) {
              final Decimal poorer = Decimal.affordGeometricSeries(
                sweepMoney[i],
                start,
                ratio,
                owned,
              );
              final Decimal richer = Decimal.affordGeometricSeries(
                sweepMoney[i + 1],
                start,
                ratio,
                owned,
              );
              if (poorer.isNaN ||
                  richer.isNaN ||
                  poorer <= Decimal.zero ||
                  richer > roundTripLimit) {
                continue;
              }
              checked++;
              expect(
                richer >= poorer,
                isTrue,
                reason:
                    'start=$start ratio=$ratio owned=$owned: '
                    '${sweepMoney[i]} affords $poorer but '
                    '${sweepMoney[i + 1]} affords only $richer',
              );
            }
          }
        }
      }
      expect(checked, greaterThan(3000), reason: 'the sweep went vacuous');
    });

    test('owning more never affords more', () {
      int checked = 0;
      for (final Decimal money in sweepMoney) {
        for (final Decimal start in sweepStart) {
          for (final Decimal add in sweepAdd) {
            for (int j = 0; j < sweepOwned.length - 1; j++) {
              final Decimal fewer = Decimal.affordArithmeticSeries(
                money,
                start,
                add,
                sweepOwned[j],
              );
              final Decimal more = Decimal.affordArithmeticSeries(
                money,
                start,
                add,
                sweepOwned[j + 1],
              );
              if (fewer.isNaN ||
                  more.isNaN ||
                  more <= Decimal.zero ||
                  fewer > roundTripLimit) {
                continue;
              }
              checked++;
              expect(
                more <= fewer,
                isTrue,
                reason:
                    'money=$money start=$start add=$add: owning '
                    '${sweepOwned[j]} affords $fewer but owning '
                    '${sweepOwned[j + 1]} affords $more',
              );
            }
          }
        }
      }
      expect(checked, greaterThan(1000), reason: 'the sweep went vacuous');
    });
  });

  // ---------------------------------------------------------------------------
  // Small cases verifiable by hand
  // ---------------------------------------------------------------------------

  group('hand-computed geometric values', () {
    // A shop selling at 10 with a 15% markup per purchase: prices are
    // 10, 11.5, 13.225, 15.20875, ...
    final Decimal start = Decimal.ten;
    final Decimal ratio = d('1.15');

    test('the first purchase costs priceStart', () {
      expect(
        Decimal.sumGeometricSeries(Decimal.one, start, ratio, Decimal.zero),
        Decimal.ten,
      );
    });

    test('the second purchase costs 11.5', () {
      expect(
        Decimal.sumGeometricSeries(Decimal.one, start, ratio, Decimal.one),
        d('11.5'),
      );
    });

    test('the third purchase costs 13.225', () {
      expectClose(
        Decimal.sumGeometricSeries(Decimal.one, start, ratio, Decimal.two),
        d('13.225'),
        1e-14,
        reason: 'the third price, 10 * 1.15^2',
      );
    });

    test('the first two together cost 21.5', () {
      final Decimal sum = Decimal.sumGeometricSeries(
        Decimal.two,
        start,
        ratio,
        Decimal.zero,
      );
      expectClose(sum, d('21.5'), 1e-14, reason: '10 + 11.5');
      // ...but not to the last bit. The closed form is
      // a * (1 - r^n) / (1 - r), and with r = 1.15 that route loses an ulp.
      // The JavaScript reference prints exactly this, so pin it: a change here
      // means the port stopped tracking the reference's arithmetic.
      expect(sum.toString(), '21.499999999999996');
    });

    test('the first three together cost 34.725', () {
      expectClose(
        Decimal.sumGeometricSeries(d('3'), start, ratio, Decimal.zero),
        d('34.725'),
        1e-14,
        reason: '10 + 11.5 + 13.225',
      );
    });

    test('buying nothing costs nothing', () {
      expect(
        Decimal.sumGeometricSeries(Decimal.zero, start, ratio, Decimal.zero),
        Decimal.zero,
      );
    });

    test('a doubling shop sums to 2^n - 1', () {
      // priceStart 1, ratio 2: 1 + 2 + 4 + 8 == 15, exactly representable.
      expect(
        Decimal.sumGeometricSeries(
          d('4'),
          Decimal.one,
          Decimal.two,
          Decimal.zero,
        ),
        d('15'),
      );
      // Ten of them is 1023, which the closed form misses by an ulp.
      expect(
        Decimal.sumGeometricSeries(
          Decimal.ten,
          Decimal.one,
          Decimal.two,
          Decimal.zero,
        ).toString(),
        '1023.0000000000002',
      );
    });

    test('a doubling shop: 1023 buys ten, 1022 buys nine', () {
      expect(
        Decimal.affordGeometricSeries(
          d('1023'),
          Decimal.one,
          Decimal.two,
          Decimal.zero,
        ),
        Decimal.ten,
      );
      expect(
        Decimal.affordGeometricSeries(
          d('1022'),
          Decimal.one,
          Decimal.two,
          Decimal.zero,
        ),
        d('9'),
      );
    });

    test('exactly enough for one, and a hair short of it', () {
      expect(
        Decimal.affordGeometricSeries(Decimal.ten, start, ratio, Decimal.zero),
        Decimal.one,
      );
      expect(
        Decimal.affordGeometricSeries(d('9.9'), start, ratio, Decimal.zero),
        Decimal.zero,
      );
    });

    test('21.5 buys two, 21.4 buys one', () {
      expect(
        Decimal.affordGeometricSeries(d('21.5'), start, ratio, Decimal.zero),
        Decimal.two,
      );
      expect(
        Decimal.affordGeometricSeries(d('21.4'), start, ratio, Decimal.zero),
        Decimal.one,
      );
    });

    test('the dartdoc example holds', () {
      // 1e6 gold, generators at 10 with a 15% markup, already owning 42.
      final Decimal n = Decimal.affordGeometricSeries(
        d('1e6'),
        start,
        ratio,
        d('42'),
      );
      expect(n, d('26'));
      final Decimal cost = Decimal.sumGeometricSeries(n, start, ratio, d('42'));
      expect(cost.toString(), '870433.5234942113');
      expect(cost < d('1e6'), isTrue);
      expect(
        Decimal.sumGeometricSeries(d('27'), start, ratio, d('42')).toString(),
        '1004541.0474172971',
      );
      expect(
        Decimal.sumGeometricSeries(
          Decimal.one,
          start,
          ratio,
          d('42'),
        ).toString(),
        '3542.49539895394',
      );
    });
  });

  group('hand-computed arithmetic values', () {
    // Upgrades starting at 100 and costing 50 more each time:
    // 100, 150, 200, 250, ...
    final Decimal start = d('100');
    final Decimal add = d('50');

    test('the first three purchases cost 100, 150 and 200', () {
      expect(
        Decimal.sumArithmeticSeries(Decimal.one, start, add, Decimal.zero),
        d('100'),
      );
      expect(
        Decimal.sumArithmeticSeries(Decimal.one, start, add, Decimal.one),
        d('150'),
      );
      expect(
        Decimal.sumArithmeticSeries(Decimal.one, start, add, Decimal.two),
        d('200'),
      );
    });

    test('running totals are 100, 250 and 450', () {
      expect(
        Decimal.sumArithmeticSeries(Decimal.one, start, add, Decimal.zero),
        d('100'),
      );
      expect(
        Decimal.sumArithmeticSeries(Decimal.two, start, add, Decimal.zero),
        d('250'),
      );
      expect(
        Decimal.sumArithmeticSeries(d('3'), start, add, Decimal.zero),
        d('450'),
      );
    });

    test('buying nothing costs nothing', () {
      expect(
        Decimal.sumArithmeticSeries(Decimal.zero, start, add, Decimal.zero),
        Decimal.zero,
      );
    });

    test('the classic 1 + 2 + ... + 100 == 5050', () {
      expect(
        Decimal.sumArithmeticSeries(
          d('100'),
          Decimal.one,
          Decimal.one,
          Decimal.zero,
        ),
        d('5050'),
      );
      expect(
        Decimal.affordArithmeticSeries(
          d('5050'),
          Decimal.one,
          Decimal.one,
          Decimal.zero,
        ),
        d('100'),
      );
      expect(
        Decimal.affordArithmeticSeries(
          d('5049'),
          Decimal.one,
          Decimal.one,
          Decimal.zero,
        ),
        d('99'),
      );
    });

    test('exactly enough for one, and a hair short of it', () {
      expect(
        Decimal.affordArithmeticSeries(d('100'), start, add, Decimal.zero),
        Decimal.one,
      );
      expect(
        Decimal.affordArithmeticSeries(d('99'), start, add, Decimal.zero),
        Decimal.zero,
      );
      expect(
        Decimal.affordArithmeticSeries(d('250'), start, add, Decimal.zero),
        Decimal.two,
      );
      expect(
        Decimal.affordArithmeticSeries(d('249'), start, add, Decimal.zero),
        Decimal.one,
      );
    });

    test('the dartdoc example holds', () {
      final Decimal n = Decimal.affordArithmeticSeries(
        d('1e6'),
        start,
        add,
        d('42'),
      );
      expect(n, d('161'));
      // Owning 42, the next one costs 100 + 42*50 == 2200.
      expect(
        Decimal.sumArithmeticSeries(Decimal.one, start, add, d('42')),
        d('2200'),
      );
      expect(Decimal.sumArithmeticSeries(n, start, add, d('42')), d('998200'));
      expect(
        Decimal.sumArithmeticSeries(n + Decimal.one, start, add, d('42')),
        d('1008450'),
      );
      expect(
        Decimal.sumArithmeticSeries(Decimal.ten, start, add, d('42')),
        d('24250'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Edge cases
  // ---------------------------------------------------------------------------

  group('degenerate price curves', () {
    test('a ratio of exactly 1 gives NaN both ways', () {
      // The geometric formulas divide by `priceRatio.log10()` and by
      // `1 - priceRatio`, both of which are zero at a ratio of 1. The
      // reference returns NaN rather than special-casing it; a game with flat
      // prices should divide instead, or use the arithmetic pair with an
      // increment of zero.
      expect(
        Decimal.affordGeometricSeries(
          d('100'),
          Decimal.ten,
          Decimal.one,
          Decimal.zero,
        ).isNaN,
        isTrue,
      );
      expect(
        Decimal.sumGeometricSeries(
          d('5'),
          Decimal.ten,
          Decimal.one,
          Decimal.zero,
        ).isNaN,
        isTrue,
      );
    });

    test('a ratio just above 1 behaves like near-flat pricing', () {
      // At +0.00001% per purchase, 100 buys nine items priced at ~10 each,
      // and ten of them total just over 100.
      final Decimal near = d('1.0000001');
      expect(
        Decimal.affordGeometricSeries(
          d('100'),
          Decimal.ten,
          near,
          Decimal.zero,
        ),
        d('9'),
      );
      expect(
        Decimal.sumGeometricSeries(
          Decimal.ten,
          Decimal.ten,
          near,
          Decimal.zero,
        ).toString(),
        '100.00004500844139',
      );
      expect(
        Decimal.affordGeometricSeries(
          d('1e6'),
          Decimal.ten,
          near,
          Decimal.zero,
        ),
        d('99503'),
      );
    });

    test('an increment of exactly 0 gives NaN for afford but not for sum', () {
      // affordArithmeticSeries divides by priceAdd; sumArithmeticSeries does
      // not, so flat prices still sum correctly there.
      expect(
        Decimal.affordArithmeticSeries(
          d('1e6'),
          d('100'),
          Decimal.zero,
          Decimal.zero,
        ).isNaN,
        isTrue,
      );
      expect(
        Decimal.sumArithmeticSeries(
          d('5'),
          d('100'),
          Decimal.zero,
          Decimal.zero,
        ),
        d('500'),
      );
    });

    test('prices that shrink (ratio below 1) give NaN for afford', () {
      // resourcesAvailable/actualStart * (ratio - 1) + 1 goes negative once
      // you can afford more than 1/(1 - ratio) items, and log10 of a negative
      // is NaN. The sum still works: 10 + 5 + 2.5 + 1.25 + 0.625 == 19.375.
      expect(
        Decimal.affordGeometricSeries(
          d('1e6'),
          Decimal.ten,
          d('0.5'),
          Decimal.zero,
        ).isNaN,
        isTrue,
      );
      expect(
        Decimal.sumGeometricSeries(d('5'), Decimal.ten, d('0.5'), Decimal.zero),
        d('19.375'),
      );
    });

    test('a negative increment gives NaN for afford', () {
      expect(
        Decimal.affordArithmeticSeries(
          d('1e6'),
          d('100'),
          -Decimal.one,
          Decimal.zero,
        ).isNaN,
        isTrue,
      );
    });
  });

  group('degenerate resource amounts', () {
    test('zero resources afford nothing', () {
      expect(
        Decimal.affordGeometricSeries(
          Decimal.zero,
          Decimal.ten,
          d('1.15'),
          Decimal.zero,
        ),
        Decimal.zero,
      );
      expect(
        Decimal.affordArithmeticSeries(
          Decimal.zero,
          d('100'),
          d('50'),
          Decimal.zero,
        ),
        Decimal.zero,
      );
    });

    test('a small debt affords minus one item', () {
      // Being 5 in the hole means you would have to *sell* one item to get
      // back to solvent, which is what -1 says. Both formulas agree.
      expect(
        Decimal.affordGeometricSeries(
          -d('5'),
          Decimal.ten,
          d('1.15'),
          Decimal.zero,
        ),
        -Decimal.one,
      );
      expect(
        Decimal.affordArithmeticSeries(
          -d('5'),
          d('100'),
          d('50'),
          Decimal.zero,
        ),
        -Decimal.one,
      );
    });

    test('a large debt is nonsense in both formulas, faithfully', () {
      // The geometric formula takes log10 of a large negative number: NaN.
      expect(
        Decimal.affordGeometricSeries(
          -d('1e100'),
          Decimal.ten,
          d('1.15'),
          Decimal.zero,
        ).isNaN,
        isTrue,
      );
      // The arithmetic one takes sqrt(b^2 + 2*d*S) with S very negative; the
      // sum stays positive because b^2 is 1e4 and 2*d*S is -1e102... which it
      // is not, so the sqrt survives and the answer is a large *positive*
      // count. This is wrong, and it is what break_eternity.js returns:
      // 1.9999999999999347e49. Callers must clamp resources at zero.
      final Decimal wrong = Decimal.affordArithmeticSeries(
        -d('1e100'),
        d('100'),
        d('50'),
        Decimal.zero,
      );
      expect(wrong > Decimal.zero, isTrue);
      expect(wrong.toString(), '1.9999999999999347e49');
    });

    test('a negative count of items is a refund', () {
      expect(
        Decimal.sumGeometricSeries(
          -Decimal.one,
          Decimal.ten,
          d('1.15'),
          Decimal.zero,
        ).toString(),
        '-8.695652173913043',
      );
      expect(
        Decimal.sumArithmeticSeries(
          -Decimal.one,
          d('100'),
          d('50'),
          Decimal.zero,
        ),
        -d('50'),
      );
    });

    test('resources far beyond anything affordable still give a count', () {
      // 1e100 gold at 10 base with a 15% markup buys 1617 generators, and the
      // 1618th tips the total over 1e100.
      expect(
        Decimal.affordGeometricSeries(
          d('1e100'),
          Decimal.ten,
          d('1.15'),
          Decimal.zero,
        ),
        d('1617'),
      );
      expect(
        Decimal.sumGeometricSeries(
              d('1617'),
              Decimal.ten,
              d('1.15'),
              Decimal.zero,
            ) <
            d('1e100'),
        isTrue,
      );
      expect(
        Decimal.sumGeometricSeries(
              d('1618'),
              Decimal.ten,
              d('1.15'),
              Decimal.zero,
            ) >
            d('1e100'),
        isTrue,
      );
    });
  });

  group('huge currentOwned', () {
    test('owning 1e10 generators makes the next one unaffordable', () {
      // 10 * 1.15^1e10 is around e606978404 — a pocketful of 1e6 buys none.
      expect(
        Decimal.sumGeometricSeries(
          Decimal.one,
          Decimal.ten,
          d('1.15'),
          d('1e10'),
        ).toString(),
        '3.4365095386640756e606978404',
      );
      expect(
        Decimal.affordGeometricSeries(
          d('1e6'),
          Decimal.ten,
          d('1.15'),
          d('1e10'),
        ),
        Decimal.zero,
      );
    });

    test('the arithmetic offset survives 1e10 owned', () {
      expect(
        Decimal.sumArithmeticSeries(Decimal.one, d('100'), d('50'), d('1e10')),
        d('100') + d('1e10') * d('50'),
      );
    });

    test('1 + 2 + ... + 1e10', () {
      // n(n+1)/2 == 5.0000000005e19, which is past double integer precision,
      // so the closed form lands a few ulps off. The reference agrees.
      expect(
        Decimal.sumArithmeticSeries(
          d('1e10'),
          Decimal.one,
          Decimal.one,
          Decimal.zero,
        ).toString(),
        '5.000000000499987e19',
      );
    });
  });

  group('layer 2 and above', () {
    /// `ee100`, i.e. 10^10^100.
    final Decimal ee100 = Decimal.fromComponents(1, 2, 100);

    test('an ee100 fortune affords an e101 pile of generators', () {
      final Decimal n = Decimal.affordGeometricSeries(
        ee100,
        Decimal.ten,
        d('1.15'),
        Decimal.zero,
      );
      expect(n, Decimal.fromComponents(1, 1, 101.21682676097079));
      // And the round trip is exact at this scale: the answer's own precision
      // is coarser than a single generator, so the total lands back on ee100.
      expect(
        Decimal.sumGeometricSeries(n, Decimal.ten, d('1.15'), Decimal.zero),
        ee100,
      );
    });

    test('an ee100 fortune affords an ee99.7 pile of upgrades', () {
      final Decimal n = Decimal.affordArithmeticSeries(
        ee100,
        d('100'),
        d('50'),
        Decimal.zero,
      );
      expect(n, Decimal.fromComponents(1, 2, 99.69897000433602));
      expect(
        Decimal.sumArithmeticSeries(n, d('100'), d('50'), Decimal.zero),
        ee100,
      );
    });

    test('an ee100 price tag: one purchase costs ee100', () {
      expect(
        Decimal.sumGeometricSeries(Decimal.one, ee100, d('1.15'), Decimal.zero),
        ee100,
      );
      expect(
        Decimal.affordGeometricSeries(ee100, ee100, Decimal.two, Decimal.zero),
        Decimal.one,
      );
    });

    test('at layer 2 a huge currentOwned is lost in the rounding', () {
      // 1.15^1e10 is e6e8, utterly negligible against ee100, so owning ten
      // billion generators does not change what an ee100 fortune affords.
      // Faithful to the reference, and a fine thing for a game: at that scale
      // the count is a display value, not an inventory.
      expect(
        Decimal.affordGeometricSeries(ee100, Decimal.ten, d('1.15'), d('1e10')),
        Decimal.affordGeometricSeries(
          ee100,
          Decimal.ten,
          d('1.15'),
          Decimal.zero,
        ),
      );
    });
  });

  group('knife-edge totals', () {
    // When the money on hand is *exactly* a series total, floor() sits on the
    // boundary and an ulp in either direction decides the answer. These are
    // the two cases where the reference gets it wrong; they are pinned so the
    // port is known to track it, not so the behaviour is endorsed.

    test(
      '1 gold at a base price of 1 buys nothing, though it should buy one',
      () {
        // log10(1.5) / log10(1.5) comes out as 0.9999999999999999 rather than 1,
        // and the floor takes it to 0.
        expect(
          Decimal.affordGeometricSeries(
            Decimal.one,
            Decimal.one,
            d('1.5'),
            Decimal.zero,
          ),
          Decimal.zero,
        );
        expect(
          Decimal.sumGeometricSeries(
            Decimal.one,
            Decimal.one,
            d('1.5'),
            Decimal.zero,
          ),
          Decimal.one,
        );
      },
    );

    test('the geometric sum can exceed the money by an ulp at the boundary', () {
      // affordGeometricSeries says one item is affordable with 1e12 in hand,
      // and sumGeometricSeries then prices that one item at 1000000000000.0042.
      final Decimal money = d('1e12');
      final Decimal n = Decimal.affordGeometricSeries(
        money,
        d('100'),
        d('1e10'),
        Decimal.one,
      );
      expect(n, Decimal.one);
      final Decimal cost = Decimal.sumGeometricSeries(
        n,
        d('100'),
        d('1e10'),
        Decimal.one,
      );
      expect(cost > money, isTrue);
      expect(cost.toString(), '1000000000000.0042');
    });

    test('the arithmetic formula loses everything to cancellation', () {
      // priceStart 1e30 with 1 gold in hand: the answer is obviously 0, but
      // b = 1e30 - 5e9 and sqrt(b^2 + 2*1e10*1) both round to 1e30, and the
      // difference of two 1e30s that should be zero comes out as 1.6e16.
      // Divided by the 1e10 increment that is 1643130 items. A game must not
      // call these helpers with a priceStart 30 orders above the resources on
      // hand; there is nothing the port can do about it that the reference
      // does not also do.
      expect(
        Decimal.affordArithmeticSeries(
          Decimal.one,
          d('1e30'),
          d('1e10'),
          d('1e6'),
        ),
        d('1643130'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // efficiencyOfPurchase
  // ---------------------------------------------------------------------------

  group('efficiencyOfPurchase', () {
    test('the dartdoc example: the cheaper building wins', () {
      // Earning 1000/s. Option A costs 5e4 and adds 100/s: 50s to save up plus
      // 500s to pay for itself. Option B costs 2e5 and adds 500/s: 200s plus
      // 400s. Lower is better, so A wins on the combined score even though it
      // pays back more slowly.
      final Decimal cheap = Decimal.efficiencyOfPurchase(
        d('5e4'),
        d('1000'),
        d('100'),
      );
      final Decimal dear = Decimal.efficiencyOfPurchase(
        d('2e5'),
        d('1000'),
        d('500'),
      );
      expect(cheap, d('550'));
      expect(dear, d('600'));
      expect(cheap < dear, isTrue);
    });

    test('doubling both rates halves the score', () {
      expect(
        Decimal.efficiencyOfPurchase(d('100'), Decimal.ten, Decimal.ten),
        d('20'),
      );
      expect(Decimal.efficiencyOfPurchase(d('100'), d('20'), d('20')), d('10'));
    });

    test('the score is linear in cost', () {
      for (final Decimal cost in <Decimal>[d('1'), d('137'), d('1e30')]) {
        expectClose(
          Decimal.efficiencyOfPurchase(cost * Decimal.two, d('1e6'), d('1e3')),
          Decimal.efficiencyOfPurchase(cost, d('1e6'), d('1e3')) * Decimal.two,
          1e-12,
          reason: 'twice the cost at $cost',
        );
      }
    });

    test('it stays meaningful past the double range', () {
      // 1e100 / 1e50 + 1e100 / 1e40 == 1e50 + 1e60, dominated by the second.
      expectClose(
        Decimal.efficiencyOfPurchase(d('1e100'), d('1e50'), d('1e40')),
        d('1e60'),
        1e-10,
        reason: 'an e100 purchase against e50 and e40 income',
      );
      expect(
        Decimal.efficiencyOfPurchase(
          d('1e100'),
          d('1e50'),
          d('1e40'),
        ).toString(),
        '1.0000000000999976e60',
      );
    });

    test('zero income anywhere gives NaN', () {
      // A division by zero, which this library resolves to NaN rather than
      // infinity — so a game must guard against a currentRpS of 0 before
      // ranking purchases.
      expect(
        Decimal.efficiencyOfPurchase(d('100'), Decimal.zero, Decimal.ten).isNaN,
        isTrue,
      );
      expect(
        Decimal.efficiencyOfPurchase(d('100'), Decimal.ten, Decimal.zero).isNaN,
        isTrue,
      );
    });

    test('a negative cost flips the sign', () {
      expect(
        Decimal.efficiencyOfPurchase(-d('100'), Decimal.ten, Decimal.ten),
        -d('20'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Log and power identities
  // ---------------------------------------------------------------------------

  group('inverse identities', () {
    test('sqrt then sqr recovers the value', () {
      for (final Decimal x in identityValues) {
        expectClose(x.sqrt().sqr(), x, 1e-13, reason: 'sqrt($x)^2');
      }
    });

    test('cbrt then cube recovers the value', () {
      for (final Decimal x in identityValues) {
        expectClose(x.cbrt().cube(), x, 1e-13, reason: 'cbrt($x)^3');
      }
    });

    test('root(5) then pow(5) recovers the value', () {
      for (final Decimal x in identityValues) {
        expectClose(
          x.root(d('5')).pow(d('5')),
          x,
          1e-13,
          reason: 'root($x, 5)^5',
        );
      }
    });

    test('log10 then pow10 recovers the value', () {
      for (final Decimal x in identityValues) {
        expectClose(x.log10().pow10(), x, 1e-13, reason: 'pow10(log10($x))');
      }
    });

    test('ln then exp recovers the value', () {
      for (final Decimal x in identityValues) {
        expectClose(x.ln().exp(), x, 1e-13, reason: 'exp(ln($x))');
      }
    });

    test('log2 then a power of 2 recovers the value', () {
      for (final Decimal x in identityValues) {
        expectClose(
          x.log2().powBase(Decimal.two),
          x,
          1e-13,
          reason: '2^log2($x)',
        );
      }
    });

    test('log(base 7) then a power of 7 recovers the value', () {
      for (final Decimal x in identityValues) {
        expectClose(
          x.log(d('7')).powBase(d('7')),
          x,
          1e-13,
          reason: '7^log7($x)',
        );
      }
    });

    test('pow10 then log10 recovers the exponent', () {
      // The other direction, which needs its own value list: the exponent may
      // be negative, and it must not be so small that 10^x rounds to 1.
      for (final Decimal x in exponentValues) {
        expectClose(x.pow10().log10(), x, 1e-12, reason: 'log10(pow10($x))');
        expectClose(
          (-x).pow10().log10(),
          -x,
          1e-12,
          reason: 'log10(pow10(-$x))',
        );
      }
    });

    test('exp then ln recovers the exponent', () {
      for (final Decimal x in exponentValues) {
        expectClose(x.exp().ln(), x, 1e-12, reason: 'ln(exp($x))');
      }
    });

    test('an exponent too small to survive pow10 collapses to zero', () {
      // This is the representation's floor, not a defect, and it is why the
      // exponent list above stops at 0.001. At 1e-15 there are only a couple
      // of bits left in `10^x - 1`, so the round trip keeps about one and a
      // half significant figures...
      expect(d('1e-15').pow10().toString(), '1.0000000000000022');
      expect(d('1e-15').pow10().log10().toString(), '9.643274665532862e-16');
      expect(d('1e-15').exp().ln().toString(), '1.1102230246251559e-15');
      // ...and one decimal order further down there are none, so `10^x` is
      // exactly 1 and the exponent is gone for good.
      for (final Decimal x in <Decimal>[d('1e-16'), d('1e-300')]) {
        expect(x.pow10(), Decimal.one, reason: 'pow10($x)');
        expect(x.pow10().log10(), Decimal.zero, reason: 'log10(pow10($x))');
        expect(x.exp(), Decimal.one, reason: 'exp($x)');
        expect(x.exp().ln(), Decimal.zero, reason: 'ln(exp($x))');
      }
    });
  });

  group('identities that must hold exactly', () {
    test('sqr is pow(2) and cube is pow(3), to the last bit', () {
      for (final Decimal x in <Decimal>[
        ...identityValues,
        ...identityValues.map((Decimal x) => -x),
      ]) {
        expect(x.sqr(), x.pow(Decimal.two), reason: 'sqr($x)');
        expect(x.cube(), x.pow(d('3')), reason: 'cube($x)');
      }
    });

    test('powBase is pow with the arguments swapped, to the last bit', () {
      for (final Decimal x in identityValues) {
        expect(x.powBase(Decimal.two), Decimal.two.pow(x), reason: '2^$x');
        expect(Decimal.two.powBase(x), x.pow(Decimal.two), reason: '$x^2');
      }
    });

    test('sqr is not the same as multiplying by yourself', () {
      // pow() routes through log10 and pow10, so `x.sqr()` and `x * x` differ
      // by about one part in 1e15. Worth knowing before someone "optimises"
      // sqr into a multiplication and moves every fixture by an ulp.
      expect(d('7').sqr().toString(), '48.99999999999999');
      expect((d('7') * d('7')).toString(), '49');
      for (final Decimal x in identityValues) {
        expectClose(x.sqr(), x * x, 1e-13, reason: 'sqr($x) against $x * $x');
      }
    });

    test('absLog10 agrees with log10 on positives and ignores the sign', () {
      for (final Decimal x in identityValues) {
        expect(x.absLog10(), x.log10(), reason: 'absLog10($x)');
        expect((-x).absLog10(), x.log10(), reason: 'absLog10(-$x)');
      }
      expect(Decimal.zero.absLog10().isNaN, isTrue);
    });

    test('pLog10 is log10 on positives and zero on negatives', () {
      for (final Decimal x in identityValues) {
        expect(x.pLog10(), x.log10(), reason: 'pLog10($x)');
        expect((-x).pLog10(), Decimal.zero, reason: 'pLog10(-$x)');
      }
      expect(Decimal.zero.pLog10().isNaN, isTrue);
    });

    test('root(2) is sqrt and root(3) is cbrt, to within an ulp', () {
      for (final Decimal x in identityValues) {
        expectClose(x.root(Decimal.two), x.sqrt(), 1e-13, reason: 'root($x,2)');
        expectClose(x.root(d('3')), x.cbrt(), 1e-13, reason: 'root($x,3)');
      }
    });
  });

  group('log bases agree with each other', () {
    test('log(x, 10) is log10(x)', () {
      for (final Decimal x in identityValues) {
        expectClose(x.log(Decimal.ten), x.log10(), 1e-13, reason: 'log10($x)');
      }
    });

    test('log(x, 2) is log2(x)', () {
      for (final Decimal x in identityValues) {
        expectClose(x.log(Decimal.two), x.log2(), 1e-13, reason: 'log2($x)');
      }
    });

    test('log(x, e) is ln(x)', () {
      final Decimal e = Decimal.fromNum(2.718281828459045);
      for (final Decimal x in identityValues) {
        expectClose(x.log(e), x.ln(), 1e-13, reason: 'ln($x)');
      }
    });

    test('a base of exactly 1 gives NaN', () {
      expect(d('1000').log(Decimal.one).isNaN, isTrue);
    });
  });

  group('exponent arithmetic', () {
    test('pow(a + b) is pow(a) * pow(b)', () {
      for (final Decimal x in identityValues.take(15)) {
        expectClose(
          x.pow(d('5')) * x.pow(d('3')),
          x.pow(d('8')),
          1e-13,
          reason: '$x^5 * $x^3',
        );
      }
    });

    test('pow(a * b) is pow(a) then pow(b)', () {
      for (final Decimal x in identityValues.take(15)) {
        expectClose(
          x.pow(d('3')).pow(d('4')),
          x.pow(d('12')),
          1e-13,
          reason: '($x^3)^4',
        );
      }
    });

    test('pow10 walks up a layer, log10 walks back down', () {
      // The whole point of the representation: pow10 on a layer-n value is a
      // layer-(n+1) value with the same mag, and log10 undoes it exactly.
      for (final Decimal x in <Decimal>[
        d('1e16'),
        d('1e300'),
        Decimal.fromComponents(1, 1, 1e10),
        Decimal.fromComponents(1, 2, 1e10),
        Decimal.fromComponents(1, 3, 1e10),
      ]) {
        final Decimal up = x.pow10();
        expect(up.layer, x.layer + 1, reason: 'pow10($x) gains a layer');
        expect(up.mag, x.mag, reason: 'pow10($x) keeps the mag');
        expect(up.log10(), x, reason: 'log10(pow10($x))');
      }
    });
  });

  group('sqrt below the first negative layer', () {
    test('sqrt of anything under 1/9e15 is NaN', () {
      // Values below 1/9e15 are stored as layer 1 with a *negative* mag, and
      // the reference's layer-1 sqrt is `FC(1, 2, Math.log10(mag) - log10(2))`
      // — log10 of a negative number, hence NaN. break_eternity.js 2.1.3 does
      // exactly this; the port matches rather than quietly fixing it, since a
      // fix here would put the two libraries out of step on saved games.
      for (final Decimal x in <Decimal>[
        d('1e-16'),
        d('1e-17'),
        d('1e-30'),
        d('1e-300'),
      ]) {
        expect(x.layer, 1, reason: '$x is stored one layer up');
        expect(x.mag < 0, isTrue, reason: '$x has a negative mag');
        expect(x.sqrt().isNaN, isTrue, reason: 'sqrt($x)');
      }
      // Just above the boundary it works.
      expect(d('1e-15').layer, 0);
      expect(d('1e-15').sqrt().isNaN, isFalse);
    });

    test('cbrt and pow(1/2) are unaffected', () {
      // cbrt goes through pow(), which goes through absLog10/pow10 and never
      // touches the layer-1 sqrt shortcut.
      expect(d('1e-300').cbrt(), d('1e-100'));
      expectClose(
        d('1e-300').pow(d('0.5')),
        d('1e-150'),
        1e-13,
        reason: 'pow(1e-300, 0.5) as a workaround for sqrt',
      );
    });
  });
}
