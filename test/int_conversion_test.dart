/// Tests for the `int` and `BigInt` conversions and truncating division.
///
/// These have no counterpart in break_eternity.js and so no fixtures: the
/// reference targets JavaScript, which has one numeric type and no separate
/// integer to convert to. This is one of the few places where going beyond the
/// reference's surface is clearly right rather than a divergence to justify.
///
/// The load-bearing decision is the range. A [Decimal] holds an exact integer
/// only while it is at layer 0; at layer 1 and above `mag` is a *logarithm*,
/// so reconstructing the value goes through `pow` and loses the low digits —
/// `Decimal.fromNum(9005000000000000)` comes back as 9005000000000007. Every
/// conversion here therefore refuses above layer 0 rather than returning a
/// number that is quietly wrong, which is the specific failure that motivated
/// the API.
library;

import 'package:break_eternity/break_eternity.dart';
import 'package:test/test.dart';

void main() {
  group('isInteger', () {
    test('is true for whole layer-0 values and false for fractions', () {
      expect(0.dec.isInteger, isTrue);
      expect(42.dec.isInteger, isTrue);
      expect((-42).dec.isInteger, isTrue);
      expect(42.5.dec.isInteger, isFalse);
      expect((-0.5).dec.isInteger, isFalse);
    });

    test('is true above layer 0, where no fraction is representable', () {
      // Past 2^53 consecutive doubles are more than 1 apart, so there is no
      // room left to hold a fractional part.
      expect(Decimal.parse('1e20').isInteger, isTrue);
      expect(Decimal.parse('1e600').isInteger, isTrue);
      expect(Decimal.parse('ee15').isInteger, isTrue);
    });

    test('is false for NaN and the infinities', () {
      expect(Decimal.nan.isInteger, isFalse);
      expect(Decimal.infinity.isInteger, isFalse);
      expect(Decimal.negativeInfinity.isInteger, isFalse);
    });
  });

  group('toInt', () {
    test('truncates toward zero, matching int and double', () {
      expect(42.5.dec.toInt(), equals(42));
      expect((-42.5).dec.toInt(), equals(-42));
      expect(42.5.toInt(), equals(42));
      expect((-42.5).toInt(), equals(-42));
    });

    test('round-trips every layer-0 integer exactly', () {
      for (int x = -1000000; x <= 1000000; x += 7919) {
        expect(x.dec.toInt(), equals(x));
      }
      expect(8999999999999999.dec.toInt(), equals(8999999999999999));
    });

    test('throws rather than approximating above layer 0', () {
      // The whole point of the API. Each of these has a plausible-looking
      // answer that would be wrong in its low digits.
      for (final String source in <String>[
        '9000000000000001',
        '9.005e15',
        '1e16',
        '1e20',
        '1e600',
      ]) {
        expect(
          () => Decimal.parse(source).toInt(),
          throwsA(isA<RangeError>()),
          reason: source,
        );
      }
    });

    test('throws on NaN and the infinities', () {
      expect(() => Decimal.nan.toInt(), throwsUnsupportedError);
      expect(() => Decimal.infinity.toInt(), throwsUnsupportedError);
      expect(() => Decimal.negativeInfinity.toInt(), throwsUnsupportedError);
    });

    test('is not the same as toDouble().toInt(), which saturates silently', () {
      // The bug this method exists to prevent: on the VM the double route
      // returns int64 max for 1e20, with no error of any kind.
      expect(Decimal.parse('1e20').toDouble().toInt(), isNot(equals(0)));
      expect(() => Decimal.parse('1e20').toInt(), throwsA(isA<RangeError>()));
    });
  });

  group('toIntOrNull', () {
    test('agrees with toInt wherever toInt succeeds', () {
      for (final int x in <int>[0, 1, -1, 42, -42, 8999999999999999]) {
        expect(x.dec.toIntOrNull(), equals(x.dec.toInt()));
      }
    });

    test('returns null instead of throwing', () {
      expect(Decimal.parse('1e20').toIntOrNull(), isNull);
      expect(Decimal.nan.toIntOrNull(), isNull);
      expect(Decimal.infinity.toIntOrNull(), isNull);
      expect(Decimal.negativeInfinity.toIntOrNull(), isNull);
    });
  });

  group('toIntClamped', () {
    test('passes through values that already fit', () {
      expect(42.dec.toIntClamped(), equals(42));
      expect((-42).dec.toIntClamped(), equals(-42));
    });

    test('saturates at the default bound in the direction of the sign', () {
      expect(Decimal.parse('1e40').toIntClamped(), equals(9000000000000000));
      expect(Decimal.parse('-1e40').toIntClamped(), equals(-9000000000000000));
    });

    test('honours explicit bounds', () {
      expect(Decimal.parse('1e40').toIntClamped(max: 100), equals(100));
      expect(Decimal.parse('-1e40').toIntClamped(min: -100), equals(-100));
      expect(500.dec.toIntClamped(max: 100), equals(100));
      expect((-500).dec.toIntClamped(min: -100), equals(-100));
      expect(50.dec.toIntClamped(min: 0, max: 100), equals(50));
    });

    test('saturates the infinities', () {
      expect(Decimal.infinity.toIntClamped(max: 7), equals(7));
      expect(Decimal.negativeInfinity.toIntClamped(min: -7), equals(-7));
    });

    test('rejects NaN and inverted bounds', () {
      expect(() => Decimal.nan.toIntClamped(), throwsArgumentError);
      expect(() => 1.dec.toIntClamped(min: 10, max: 5), throwsArgumentError);
    });
  });

  group('toBigInt', () {
    test('is exact on layer-0 integers', () {
      expect(42.dec.toBigInt(), equals(BigInt.from(42)));
      expect((-42).dec.toBigInt(), equals(BigInt.from(-42)));
      expect(42.9.dec.toBigInt(), equals(BigInt.from(42)));
      expect((-42.9).dec.toBigInt(), equals(BigInt.from(-42)));
    });

    test('keeps going where toInt refuses', () {
      expect(
        Decimal.parse('1e20').toBigInt(),
        equals(BigInt.parse('100000000000000000000')),
      );
      expect(Decimal.parse('1e300').toBigInt().toString().length, equals(301));
    });

    test('throws once the value leaves the double range', () {
      // Layer 2 and above overflow a double, so there is nothing to convert.
      expect(() => Decimal.parse('1e600').toBigInt(), throwsUnsupportedError);
      expect(() => Decimal.parse('ee15').toBigInt(), throwsUnsupportedError);
      expect(() => Decimal.nan.toBigInt(), throwsUnsupportedError);
    });
  });

  group('operator ~/', () {
    test('truncates toward zero, matching int and double', () {
      expect((7.dec ~/ 2.dec).toInt(), equals(7 ~/ 2));
      expect(((-7).dec ~/ 2.dec).toInt(), equals(-7 ~/ 2));
      expect((7.dec ~/ (-2).dec).toInt(), equals(7 ~/ -2));
      expect(((-7).dec ~/ (-2).dec).toInt(), equals(-7 ~/ -2));
    });

    test('differs from (a / b).floor() on negatives, which is the point', () {
      // The trap the operator exists to close: the obvious hand-rolled
      // version rounds toward negative infinity instead of toward zero.
      expect(((-7).dec ~/ 2.dec).toInt(), equals(-3));
      expect(((-7).dec / 2.dec).floor().toInt(), equals(-4));
    });

    test('agrees with int ~/ across a sweep of signs', () {
      for (int a = -50; a <= 50; a += 3) {
        for (int b = -12; b <= 12; b++) {
          if (b == 0) {
            continue;
          }
          expect((a.dec ~/ b.dec).toInt(), equals(a ~/ b), reason: '$a ~/ $b');
        }
      }
    });

    test('survives beyond the double range', () {
      expect(
        (Decimal.parse('1e600') ~/ Decimal.parse('1e300')).toString(),
        equals('1e300'),
      );
    });

    test('division by zero gives a non-finite result, not a throw', () {
      // Matching `double`, and matching `/` on this type.
      expect((1.dec ~/ 0.dec).isFinite, isFalse);
    });
  });
}
