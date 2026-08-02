/// Hand-written tests for tetration, its inverses, pentation and the widened
/// parse grammar.
///
/// The fixtures check one call against one expected triple. This file checks
/// the things a pointwise comparison cannot say: that `slog` really does invert
/// `tetrate`, that `iteratedLog` really does undo `iteratedExp`, that a tower
/// of a given height has the height it claims. Those are the properties a game
/// depends on, and they hold by construction rather than by coincidence, so
/// they are safe to assert exactly where the reference's own values are not.
///
/// Ground-truth values come from `reference/unit_tests.js` in the vendored
/// JavaScript reference (break_eternity.js 2.1.3), which is where upstream
/// records the analytic tetration values it was built against.
///
/// Nothing here pins the last digits of a value downstream of `pow`, `log` or
/// `exp`: those are the host platform's libm, and V8 computes them differently
/// on arm64 and x64, so an exact assertion would pass on a developer's Mac and
/// fail in Linux CI. Tolerances and identities are used instead.
library;

import 'package:break_eternity/break_eternity.dart';
import 'package:test/test.dart';

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

/// Shorthand for [Decimal.parse], to keep the parameter tables readable.
Decimal d(String source) => Decimal.parse(source);

/// Asserts that [actual] and [expected] agree to within a relative [tolerance].
void expectClose(
  Decimal actual,
  Decimal expected,
  double tolerance, {
  required String reason,
}) {
  expect(
    actual.equalsWithin(expected, tolerance),
    isTrue,
    reason: '$reason: expected $expected, got $actual (tolerance $tolerance)',
  );
}

void main() {
  // ---------------------------------------------------------------------------
  // Ground truth from the reference's own unit tests
  // ---------------------------------------------------------------------------

  group('tetrate matches the reference ground truth', () {
    // reference/unit_tests.js, test_tetrate_ground_truth. The tolerances are
    // upstream's own: the analytic approximation is a table lookup with linear
    // interpolation, so it is only good to about three digits in the middle of
    // the critical section.
    final List<(num, Decimal, double)> cases = <(num, Decimal, double)>[
      (10.5, d('(e^9)299.92012356854593'), 1e-7),
      (10, d('(e^8)10000000000'), 1e-7),
      (4, d('ee10000000000'), 1e-7),
      (3.5, d('ee299.92012356854593'), 1e-7),
      (3, d('1e10000000000'), 1e-7),
      (2.5, d('8.320004641007381e299'), 1e-7),
      (2, d('1e10'), 1e-7),
      (1.5, d('299.92012356854604298'), 1e-7),
      (1.1, d('15.276013187671926546'), 1e-7),
      (1.09, d('14.590820857079513571'), 1e-3),
      (1.05, d('12.243921772755051706'), 1e-3),
      (1.01, d('10.398855358124287905'), 1e-3),
      (1, d('10'), 1e-7),
      (0.99, d('9.6227033506567471768'), 1e-2),
      (0.95, d('8.3015402222604663760'), 1e-2),
      (0.91, d('7.2270053728541153571'), 1e-2),
      (0.5, d('2.4770056063449647580'), 1e-7),
      (-1, Decimal.zero, 1e-7),
      (-1.1, d('-0.073413324316674049650'), 1e-7),
      (-1.5, d('-0.40458426287953460128'), 1e-7),
      (-1.9, d('-1.1345680321718982860'), 1e-7),
      (-1.99, d('-2.1357989167988367351'), 1e-3),
      (-1.999, d('-3.1358003090926477386'), 1e-3),
      (-1.9999, d('-4.1357992057580525630'), 1e-3),
      (-1.99999, d('-5.1357990829699223045'), 1e-3),
    ];

    for (final (num height, Decimal expected, double tolerance) in cases) {
      test('10^^$height', () {
        expectClose(
          10.dec.tetrate(height),
          expected,
          tolerance,
          reason: '10^^$height',
        );
      });
    }

    test('10^^-2 and below are NaN', () {
      expect(10.dec.tetrate(-2).isNaN, isTrue);
      expect(10.dec.tetrate(-2.1).isNaN, isTrue);
      expect(10.dec.tetrate(-3).isNaN, isTrue);
    });
  });

  group('slog matches the reference ground truth', () {
    // reference/unit_tests.js, test_slog_ground_truth: the same table read
    // backwards, which is the real check that the two are inverses.
    final List<(Decimal, num, double)> cases = <(Decimal, num, double)>[
      (d('(e^9)299.92012356854593'), 10.5, 1e-7),
      (d('(e^8)10000000000'), 10, 1e-7),
      (d('ee10000000000'), 4, 1e-7),
      (d('ee299.92012356854593'), 3.5, 1e-7),
      (d('1e10000000000'), 3, 1e-7),
      (d('8.320004641007381e299'), 2.5, 1e-7),
      (d('1e10'), 2, 1e-7),
      (d('299.92012356854604298'), 1.5, 1e-7),
      (d('15.276013187671926546'), 1.1, 1e-7),
      (d('14.590820857079513571'), 1.09, 1e-4),
      (d('12.243921772755051706'), 1.05, 1e-3),
      (d('10.398855358124287905'), 1.01, 1e-4),
      (d('10'), 1, 1e-7),
      (d('9.6227033506567471768'), 0.99, 1e-3),
    ];

    for (final (Decimal value, num expected, double tolerance) in cases) {
      test('slog($value)', () {
        expectClose(
          value.slog(),
          Decimal.fromNum(expected),
          tolerance,
          reason: 'slog($value)',
        );
      });
    }
  });

  // ---------------------------------------------------------------------------
  // Identities, which hold by construction rather than by coincidence
  // ---------------------------------------------------------------------------

  group('tetration identities', () {
    test('x^^1 == x and x^^0 == 1', () {
      for (final Decimal x in <Decimal>[
        d('2'),
        d('10'),
        d('0.5'),
        d('1e100'),
        d('ee100'),
        d('-3'),
      ]) {
        expect(x.tetrate(1), x, reason: '$x^^1');
        expect(x.tetrate(0), Decimal.one, reason: '$x^^0');
      }
    });

    test('1^^x == 1 for every height', () {
      for (final num h in <num>[0, 1, 2, 3.5, -1, 1e100, double.infinity]) {
        expect(Decimal.one.tetrate(h), Decimal.one, reason: '1^^$h');
      }
    });

    test('x^^n is x^(x^^(n-1)) for whole heights', () {
      // The defining recurrence. Exact rather than approximate, because both
      // sides reach the same `pow` calls in the same order.
      for (final Decimal x in <Decimal>[d('2'), d('3'), d('10'), d('1.5')]) {
        for (int n = 1; n <= 4; n++) {
          expect(
            x.tetrate(n),
            x.pow(x.tetrate(n - 1)),
            reason: '$x^^$n == $x^($x^^${n - 1})',
          );
        }
      }
    });

    test('10^^n is a layer-n tower of tens', () {
      // This is the whole reason the representation exists: tetrating 10 to
      // height n is exactly "n layers", at no cost.
      for (final int n in <int>[3, 4, 10, 1000, 1000000, 1000000000]) {
        final Decimal tower = 10.dec.tetrate(n);
        expect(tower.layer, n - 2, reason: '10^^$n layer');
        expect(tower.mag, 10000000000.0, reason: '10^^$n mag');
      }
    });

    test('iteratedExp is tetrate under another name', () {
      for (final Decimal x in <Decimal>[d('2'), d('10'), d('0.5')]) {
        for (final num h in <num>[0, 1, 2, 3, 2.5, -1]) {
          for (final bool linear in <bool>[false, true]) {
            expect(
              x.iteratedExp(h, linear: linear),
              x.tetrate(h, linear: linear),
              reason: '$x iteratedExp $h (linear: $linear)',
            );
          }
        }
      }
    });

    test('iteratedLog undoes iteratedExp for whole heights', () {
      for (final Decimal base in <Decimal>[d('2'), d('10'), d('3')]) {
        for (final int times in <int>[1, 2, 3]) {
          final Decimal tower = base.iteratedExp(times, payload: d('5'));
          expectClose(
            tower.iteratedLog(base: base, times: times),
            d('5'),
            1e-9,
            reason: '$base iteratedExp/iteratedLog $times',
          );
        }
      }
    });

    test('iteratedLog with a negative count is tetrate', () {
      for (final Decimal x in <Decimal>[d('2'), d('1e100')]) {
        for (final num times in <num>[-1, -2, -3]) {
          expect(
            x.iteratedLog(base: Decimal.ten, times: times),
            Decimal.ten.tetrate(-times, payload: x),
            reason: '$x iteratedLog $times',
          );
        }
      }
    });

    test('iteratedLog base 10 peels one layer per step', () {
      expect(d('1e100').iteratedLog(), d('100'));
      expect(d('1e10000000000').iteratedLog(times: 2), d('10'));
      expect(d('ee100').iteratedLog(times: 2), d('100'));
    });
  });

  group('slog inverts tetrate', () {
    test('slog(base^^h) == h across bases and heights', () {
      for (final Decimal base in <Decimal>[
        d('2'),
        d('3'),
        d('10'),
        d('1e10'),
      ]) {
        for (final num h in <num>[1, 2, 3, 4, 1.5, 2.5, 10, 100]) {
          final Decimal tower = base.tetrate(h);
          if (!tower.isFinite) {
            continue;
          }
          expectClose(
            tower.slog(base: base),
            Decimal.fromNum(h),
            1e-9,
            reason: 'slog($base^^$h)',
          );
        }
      }
    });

    test('slog of a layer-n tower of tens is n', () {
      for (final int n in <int>[3, 4, 5, 10, 100]) {
        expectClose(
          Decimal.fromComponents(1, n - 2, 1e10).slog(),
          Decimal.fromNum(n),
          1e-12,
          reason: 'slog of a height-$n tower',
        );
      }
    });

    test('slog is monotonically increasing', () {
      // A super-logarithm that is not monotonic would break every progress bar
      // and sort order built on it.
      final List<Decimal> ascending = <Decimal>[
        d('0'),
        d('0.5'),
        d('1'),
        d('2'),
        d('10'),
        d('100'),
        d('1e10'),
        d('1e100'),
        d('1e1000'),
        d('ee16'),
        d('ee100'),
        d('eee16'),
        d('(e^10)16'),
        d('(e^1000)16'),
      ];
      for (int i = 1; i < ascending.length; i++) {
        expect(
          ascending[i - 1].slog() < ascending[i].slog(),
          isTrue,
          reason: 'slog(${ascending[i - 1]}) < slog(${ascending[i]})',
        );
      }
    });

    test('a degenerate base has no super-logarithm', () {
      for (final Decimal base in <Decimal>[d('1'), d('0'), d('-2')]) {
        expect(
          d('100').slog(base: base).isNaN,
          isTrue,
          reason: 'slog base $base',
        );
      }
    });
  });

  group('layerAdd', () {
    test('a whole diff is exactly that many layers', () {
      expect(d('100').layerAdd10(1), d('1e100'));
      expect(d('1e100').layerAdd10(-1), d('100'));
      expect(d('100').layerAdd10(2), d('1e1e100'));
      expect(d('1e1e100').layerAdd10(-2), d('100'));
    });

    test('two half-layers make a whole one', () {
      // The defining property of a fractional layer: applying it twice is the
      // same as applying the whole thing once.
      for (final Decimal x in <Decimal>[d('2'), d('10'), d('100'), d('1e10')]) {
        expectClose(
          x.layerAdd10(0.5).layerAdd10(0.5),
          x.layerAdd10(1),
          1e-9,
          reason: '$x layerAdd10 0.5 twice',
        );
      }
    });

    test('layerAdd10 is layerAdd base 10', () {
      for (final Decimal x in <Decimal>[d('3'), d('100'), d('1e100')]) {
        for (final num diff in <num>[1, -1, 2, 0.5]) {
          expectClose(
            x.layerAdd10(diff),
            x.layerAdd(diff, Decimal.ten),
            1e-9,
            reason: '$x layerAdd $diff',
          );
        }
      }
    });

    test('adding then subtracting the same diff round-trips', () {
      for (final Decimal x in <Decimal>[d('3'), d('100'), d('1e100')]) {
        for (final num diff in <num>[1, 2, 0.5, 1.5]) {
          expectClose(
            x.layerAdd10(diff).layerAdd10(-diff),
            x,
            1e-9,
            reason: '$x layerAdd10 +/-$diff',
          );
        }
      }
    });
  });

  group('lambertW', () {
    test('W(x) * e^W(x) == x, which is the definition', () {
      for (final Decimal x in <Decimal>[
        d('1'),
        d('2'),
        d('10'),
        d('100'),
        d('1e10'),
        d('0.5'),
        d('0.1'),
        d('-0.1'),
        d('-0.2'),
        d('-0.3'),
      ]) {
        final Decimal w = x.lambertW();
        expectClose(w * w.exp(), x, 1e-9, reason: 'W($x) * e^W($x)');
      }
    });

    test('the non-principal branch satisfies the same identity', () {
      for (final Decimal x in <Decimal>[
        d('-0.1'),
        d('-0.2'),
        d('-0.3'),
        d('-0.35'),
        d('-1e-10'),
      ]) {
        final Decimal w = x.lambertW(principal: false);
        expectClose(w * w.exp(), x, 1e-9, reason: 'W_-1($x) * e^W_-1($x)');
      }
    });

    test('known special values', () {
      expect(Decimal.zero.lambertW(), Decimal.zero);
      // W(1) is the omega constant.
      expectClose(
        Decimal.one.lambertW(),
        d('0.5671432904097838'),
        1e-15,
        reason: 'W(1)',
      );
      // Exact, unlike the rest: the solver short-circuits z == 1 to the omega
      // constant rather than iterating.
      expect(Decimal.one.lambertW(), d('0.5671432904097838'));
      // W(e) is exactly 1, since 1 * e^1 == e.
      expectClose(
        Decimal.fromNum(2.718281828459045).lambertW(),
        Decimal.one,
        1e-12,
        reason: 'W(e)',
      );
    });

    test('below -1/e both branches leave the reals', () {
      for (final Decimal x in <Decimal>[d('-0.4'), d('-1'), d('-100')]) {
        expect(x.lambertW().isNaN, isTrue, reason: 'W($x)');
        expect(x.lambertW(principal: false).isNaN, isTrue, reason: 'W_-1($x)');
      }
    });

    test('the non-principal branch is undefined above zero', () {
      for (final Decimal x in <Decimal>[d('1'), d('0.5'), d('1e100')]) {
        expect(x.lambertW(principal: false).isNaN, isTrue, reason: 'W_-1($x)');
      }
    });
  });

  group('pentation', () {
    test('x^^^1 == x and x^^^0 == 1', () {
      for (final Decimal x in <Decimal>[d('2'), d('3'), d('0.5')]) {
        expect(x.pentate(1), x, reason: '$x^^^1');
        expect(x.pentate(0), Decimal.one, reason: '$x^^^0');
      }
    });

    test('x^^^n is x^^(x^^^(n-1)) for whole heights', () {
      for (final Decimal x in <Decimal>[d('2'), d('1.5')]) {
        for (int n = 1; n <= 3; n++) {
          expect(
            x.pentate(n),
            x.tetrate(x.pentate(n - 1).toDouble()),
            reason: '$x^^^$n',
          );
        }
      }
    });

    test('2^^^3 is 65536', () {
      // 2^^^3 == 2^^(2^^2) == 2^^4 == 65536.
      expect(2.dec.pentate(3), 2.dec.tetrate(4));
      // Not an exact assertion: 2^2 goes through log10 and pow10, so the tower
      // is 65536 only to within a rounding error — and by how much depends on
      // the platform's `pow`.
      expectClose(2.dec.pentate(3), d('65536'), 1e-12, reason: '2^^^3');
    });

    test('pentaLog inverts pentate', () {
      for (final Decimal base in <Decimal>[d('2'), d('3')]) {
        for (final int h in <int>[1, 2, 3]) {
          final Decimal tower = base.pentate(h);
          if (!tower.isFinite) {
            continue;
          }
          expectClose(
            tower.pentaLog(base: base),
            Decimal.fromNum(h),
            1e-9,
            reason: 'pentaLog($base^^^$h)',
          );
        }
      }
    });

    test('a base at or below 1 has no penta-logarithm', () {
      for (final Decimal base in <Decimal>[d('1'), d('0.5'), d('0'), d('-2')]) {
        expect(
          d('100').pentaLog(base: base).isNaN,
          isTrue,
          reason: 'pentaLog base $base',
        );
      }
    });
  });

  group('the infinite power tower', () {
    test('converges only between e^-e and e^(1/e)', () {
      // Above e^(1/e) == 1.4446... the tower explodes; below e^-e == 0.0659...
      // it oscillates forever.
      expect(d('1.5').tetrate(double.infinity), Decimal.infinity);
      expect(d('2').tetrate(double.infinity), Decimal.infinity);
      expect(d('0.06').tetrate(double.infinity).isNaN, isTrue);
      expect(d('-2').tetrate(double.infinity).isNaN, isTrue);
    });

    test('the limit satisfies x^L == L', () {
      for (final Decimal x in <Decimal>[
        d('1.1'),
        d('1.2'),
        d('1.4'),
        d('0.5'),
        d('0.1'),
      ]) {
        final Decimal limit = x.tetrate(double.infinity);
        expect(limit.isFinite, isTrue, reason: '$x^^inf is finite');
        expectClose(x.pow(limit), limit, 1e-9, reason: '$x^L == L');
      }
    });

    test('sqrt(2)^^Infinity is 2, the classic example', () {
      expectClose(
        Decimal.fromNum(1.4142135623730951).tetrate(double.infinity),
        Decimal.two,
        1e-9,
        reason: 'sqrt(2)^^inf',
      );
    });
  });

  group('the linear approximation', () {
    test('agrees with the analytic one at whole heights', () {
      // The two definitions differ only between integers; on them they must be
      // the same number, or `linear` would silently change existing saves.
      for (final Decimal base in <Decimal>[d('2'), d('3'), d('10'), d('1.5')]) {
        for (final int h in <int>[0, 1, 2, 3, 4]) {
          expect(
            base.tetrate(h, linear: true),
            base.tetrate(h),
            reason: '$base^^$h',
          );
        }
      }
    });

    test('differs between integers, and is still monotonic', () {
      for (final Decimal base in <Decimal>[d('2'), d('10')]) {
        Decimal? previous;
        for (int i = 0; i <= 40; i++) {
          final Decimal current = base.tetrate(i / 10, linear: true);
          if (previous != null) {
            expect(
              previous < current,
              isTrue,
              reason: '$base^^${i / 10} > $base^^${(i - 1) / 10}',
            );
          }
          previous = current;
        }
      }
    });
  });

  // ---------------------------------------------------------------------------
  // The widened parse grammar
  // ---------------------------------------------------------------------------

  group('parse: hyper-operator forms', () {
    test('x^y is a power', () {
      // 10^3 and 10^100 are exact: an integer power of ten is a table lookup.
      expect(d('10^3'), d('1000'));
      expect(d('10^100'), d('1e100'));
      // A base that is not ten reaches `pow`, which is not.
      expectClose(d('2^-3'), d('0.125'), 1e-12, reason: '2^-3');
      // `pow` routes through log10 and pow10, so it is not exact on a power of
      // two — 2^10 comes out as 1024.0000000000002, in this port and in
      // break_eternity.js alike.
      expect(d('2^10'), 2.dec.pow(10.dec));
      expectClose(d('2^10'), d('1024'), 1e-12, reason: '2^10');
    });

    test('x^^y is a tetration', () {
      expect(d('10^^3'), 10.dec.tetrate(3));
      expect(d('2^^4'), 2.dec.tetrate(4));
      expect(d('10^^3.5'), 10.dec.tetrate(3.5));
      expectClose(d('2^^4'), d('65536'), 1e-12, reason: '2^^4');
    });

    test('x^^^y is a pentation', () {
      expect(d('2^^^3'), 2.dec.pentate(3));
      expect(d('2^^^2'), 2.dec.pentate(2));
      expectClose(d('2^^^3'), d('65536'), 1e-12, reason: '2^^^3');
    });

    test('a semicolon supplies the payload', () {
      expect(d('10^^3;5'), 10.dec.tetrate(3, payload: d('5')));
      expect(d('2^^4;3'), 2.dec.tetrate(4, payload: d('3')));
      expect(d('2^^^2;2'), 2.dec.pentate(2, payload: d('2')));
      // An unreadable payload falls back to 1 rather than failing.
      expect(d('10^^3;'), 10.dec.tetrate(3));
    });
  });

  group('parse: tetration shorthands', () {
    test('XpY and X PT Y are a tower of tens', () {
      expect(d('3p5'), 10.dec.tetrate(3, payload: d('5')));
      expect(d('3pt5'), 10.dec.tetrate(3, payload: d('5')));
      expect(d('2 pt 3'), 10.dec.tetrate(2, payload: d('3')));
      expect(d('3pt(5)'), 10.dec.tetrate(3, payload: d('5')));
    });

    test('XFY puts the payload first', () {
      expect(d('5f3'), 10.dec.tetrate(3, payload: d('5')));
      expect(d('(5)f3'), 10.dec.tetrate(3, payload: d('5')));
      // Which makes it the mirror image of the P form.
      expect(d('5f3'), d('3p5'));
    });

    test('a leading minus negates the whole result', () {
      expect(d('-3pt5'), -d('3pt5'));
      expect(d('-3p5'), -d('3p5'));
      expect(d('-5f3'), -d('5f3'));
    });

    test('the forms are case-insensitive', () {
      expect(d('10PT2'), d('10pt2'));
      expect(d('1F3'), d('1f3'));
      expect(d('3P5'), d('3p5'));
    });
  });

  group('parse: stacked exponents and separators', () {
    test('AeBeC is A times ten to the B-times-ten-to-the-C', () {
      // 2e3e4 is 2e30000, because 3e4 is 30000.
      expectClose(d('2e3e4'), d('2e30000'), 1e-12, reason: '2e3e4');
      expectClose(d('1e1e1'), d('1e10'), 1e-12, reason: '1e1e1');
      expect(d('2e3e4') > d('1e29999'), isTrue);
      expect(d('2e3e4') < d('1e30001'), isTrue);
    });

    test('thousands separators are ignored, all of them', () {
      // break_eternity.js strips only the first comma and so reads this as
      // 1000; see the note on Decimal.tryParse.
      expect(d('1,000'), d('1000'));
      expect(d('1,000,000'), d('1000000'));
      expect(d('1,234.5'), d('1234.5'));
    });

    test('an exponent a double cannot hold still parses', () {
      expect(d('1e400').layer, 1);
      expect(d('1e400').mag, 400);
      expect(d('1e-400').layer, 1);
      expect(d('1e-400').mag, -400);
    });
  });

  group('parse: layers with a fractional or negative exponent', () {
    test('(e^N)M with a whole N is still the plain layer form', () {
      expect(d('(e^7)16.5'), Decimal.fromComponents(1, 7, 16.5));
      expect(d('(e^0)5'), d('5'));
    });

    test('(e^N)M with a fractional or negative N goes through tetrate', () {
      expectClose(
        d('(e^2.5)3'),
        10.dec.tetrate(2.5, payload: d('3')),
        1e-12,
        reason: '(e^2.5)3',
      );
      // A negative layer is iterated logarithm: one log10 of 100 is 2. Not an
      // exact assertion, because `log(base)` at layer 0 is a ratio of
      // `dart:math` logarithms rather than the software log10.
      expectClose(d('(e^-1)100'), d('2'), 1e-12, reason: '(e^-1)100');
      expectClose(
        d('(e^-2)100'),
        d('0.30102999566398114'),
        1e-12,
        reason: '(e^-2)100',
      );
      expect(d('(e^10.5)1'), 10.dec.tetrate(10.5));
      // Eight logs of 1 runs out of number long before the eighth, in this
      // port and in break_eternity.js alike.
      expect(d('(e^-8)1').isNaN, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Regressions and edge cases
  // ---------------------------------------------------------------------------

  group('edge cases', () {
    test('0^^n oscillates between 0 and 1', () {
      // 0^0 is 1 here as it is in JavaScript, so 0^^1 is 0, 0^^2 is 1, and so
      // on. The payload is ignored entirely.
      expect(Decimal.zero.tetrate(1), Decimal.zero);
      expect(Decimal.zero.tetrate(2), Decimal.one);
      expect(Decimal.zero.tetrate(3), Decimal.zero);
      expect(Decimal.zero.tetrate(4), Decimal.one);
      expect(Decimal.zero.tetrate(2, payload: d('99')), Decimal.one);
    });

    test('a NaN height or base gives NaN', () {
      expect(10.dec.tetrate(double.nan).isNaN, isTrue);
      expect(Decimal.nan.tetrate(3).isNaN, isTrue);
      expect(Decimal.nan.slog().isNaN, isTrue);
      expect(Decimal.nan.lambertW().isNaN, isTrue);
      expect(Decimal.nan.pentate(2).isNaN, isTrue);
    });

    test('an enormous height finishes, thanks to the layer shortcut', () {
      // Without the "once each step only adds a layer, add them all at once"
      // shortcut this would loop 1e15 times.
      for (final num h in <num>[1e6, 1e10, 1e15, 1e300]) {
        expect(10.dec.tetrate(h).isFinite, isTrue, reason: '10^^$h');
        expect(2.dec.tetrate(h).isFinite, isTrue, reason: '2^^$h');
      }
      expect(10.dec.tetrate(1e15).layer, 1e15 - 2);
    });

    test('slog never exceeds what the representation can hold', () {
      // By definition the answer cannot be larger than the tallest tower a
      // Decimal can name.
      for (final Decimal x in <Decimal>[
        Decimal.layerMax,
        Decimal.layerSafeMax,
        Decimal.fromComponents(1, 1e300, 1e10),
      ]) {
        final Decimal result = x.slog();
        expect(result.isNaN, isFalse, reason: 'slog($x)');
        expect(result <= Decimal.fromNum(1.8e308), isTrue, reason: 'slog($x)');
      }
    });

    test('tetration results are normalised', () {
      // The layer shortcut builds its result without going through
      // normalisation, so it is the one place an invalid triple could escape.
      for (final num h in <num>[3, 4, 10, 1e6, 1e15]) {
        for (final Decimal base in <Decimal>[d('2'), d('10'), d('1e10')]) {
          final Decimal result = base.tetrate(h);
          expect(
            result,
            Decimal.fromComponents(result.sign, result.layer, result.mag),
            reason: '$base^^$h is normalised',
          );
        }
      }
    });
  });
}
