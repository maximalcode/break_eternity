// An idle-game flavoured tour of break_eternity.
//
// Run it with:
//
//     dart run example/break_eternity_example.dart
//
// The scenario: a factory produces gold, and each prestige multiplies output.
// We run the same simulation twice — once with a plain `double`, once with a
// `Decimal` — and watch where the double gives up.

import 'package:break_eternity/break_eternity.dart';

void main() {
  _theSafeIntegerWall();
  _theOverflowWall();
  _lifeAboveTheWall();
  _theShop();
  _saveAndLoad();
}

/// 2^53 is where a `double` stops being able to count.
///
/// Below `9e15` a [Decimal] is a `double` — same value, same 17 significant
/// digits. Above it, both representations round, because [Decimal] buys range,
/// not exactness. It is worth knowing which problem you have.
void _theSafeIntegerWall() {
  print('--- 2^53: where counting breaks ---');

  const safeCount = 9007199254740992.0; // 2^53
  print('double : $safeCount + 1 = ${safeCount + 1}'); // unchanged

  final decimalCount = safeCount.dec;
  print('Decimal: $decimalCount + 1 = ${decimalCount + 1.dec}');
  print(
    'Both round here. Decimal keeps ~17 significant digits, exactly like a '
    'double — what it adds is range, which is the next wall.',
  );
  print('');
}

/// 1.8e308 is where a `double` stops being able to exist.
///
/// This is the failure that matters: the double does not merely lose digits,
/// it becomes `Infinity`, and everything computed from it afterwards is
/// `Infinity` or `NaN`. The [Decimal] simulation is unbothered.
void _theOverflowWall() {
  print('--- 1e308: where the double dies ---');

  const growthPerPrestige = 1e6;
  final decimalGrowth = growthPerPrestige.dec;

  var doubleGold = 1.0;
  var decimalGold = Decimal.one;

  int? doubleDiedAt;
  for (var prestige = 1; prestige <= 100; prestige++) {
    doubleGold *= growthPerPrestige;
    decimalGold *= decimalGrowth;

    if (doubleDiedAt == null && !doubleGold.isFinite) {
      doubleDiedAt = prestige;
      print('double overflowed to $doubleGold at prestige $prestige');
    }
  }

  print('after 100 prestiges');
  print('  double : $doubleGold');
  print('  Decimal: $decimalGold');
  print('  Decimal as a double: ${decimalGold.toDouble()}');
  print('');
}

/// Everything still works up there: arithmetic, ordering, ratios, formatting.
void _lifeAboveTheWall() {
  print('--- still a usable number at 1e600 ---');

  final gold = 1e300.dec * 1e300.dec;
  final upgradeCost = Decimal.parse('5e599');

  print('gold          = $gold');
  print('upgrade cost  = $upgradeCost');
  print('can afford?     ${gold > upgradeCost}');

  final remaining = gold - upgradeCost;
  print('after buying  = $remaining');

  // Ratios are the thing a double cannot give you: Infinity / Infinity is NaN,
  // so once you overflow you can no longer even tell how rich you are.
  final progress = gold / upgradeCost;
  print('gold / cost   = $progress (double would say NaN)');

  // Comparison and the rounding family behave as you would expect.
  print('max           = ${gold.max(upgradeCost)}');
  print('half, floored = ${(gold / 2.dec).floor()}');
  print('exponent      = ${gold.exponent}');
  print('layer / mag   = ${gold.layer} / ${gold.mag}');

  // And it keeps going far past anything a double can name.
  final absurd = Decimal.parse('ee1000'); // 10^(10^1000)
  print('absurd        = $absurd');
  print('absurd * 2    = ${absurd * 2.dec}'); // doubling changes nothing here
  print('');
}

/// The shop: buying a whole batch of generators without a purchase loop.
///
/// This is the part a game actually needs. When the player is holding `ee1000`
/// gold, "buy max" cannot be a loop — there is no integer count of iterations.
/// The series helpers answer it in closed form, in constant time.
void _theShop() {
  print('--- buy max ---');

  // Generators: the first cost 10 gold, each one after is 15% dearer.
  final gold = 1e6.dec;
  final owned = 42.dec;
  final affordable = Decimal.affordGeometricSeries(
    gold,
    10.dec,
    1.15.dec,
    owned,
  );
  final cost = Decimal.sumGeometricSeries(affordable, 10.dec, 1.15.dec, owned);
  print('gold $gold, owning $owned generators');
  print('  can buy       = $affordable');
  print('  which costs   = $cost');
  print(
    '  one more      = ${Decimal.sumGeometricSeries(affordable + Decimal.one, 10.dec, 1.15.dec, owned)} (over budget)',
  );

  // The same question at a scale no double can express.
  final hugeGold = Decimal.parse('e1000');
  print(
    'with $hugeGold gold you could buy '
    '${Decimal.affordGeometricSeries(hugeGold, 10.dec, 1.15.dec, owned)}',
  );

  // Upgrades whose price grows by a fixed step instead of a fixed ratio.
  final upgrades = Decimal.affordArithmeticSeries(gold, 100.dec, 50.dec, owned);
  print(
    'and $upgrades upgrades at 100 gold +50 each, costing '
    '${Decimal.sumArithmeticSeries(upgrades, 100.dec, 50.dec, owned)}',
  );

  // Which of two purchases is the better deal? Lower is better.
  final a = Decimal.efficiencyOfPurchase(550.dec, 100.dec, 10.dec);
  final b = Decimal.efficiencyOfPurchase(600.dec, 100.dec, 12.dec);
  print(
    'efficiency: 550-for-+10 = $a, 600-for-+12 = $b '
    '-> ${b < a ? 'the second' : 'the first'} is better',
  );
  print('');
}

/// `toString` and `parse` round-trip, which is what a save file needs.
void _saveAndLoad() {
  print('--- save / load ---');

  final gold = Decimal.parse('1e1234') * 1e300.dec;
  final saved = gold.toJson(); // same text as toString()
  final loaded = Decimal.parse(saved);

  print('saved   = $saved');
  print('loaded  = $loaded');
  print('equal?    ${loaded == gold}');

  // tryParse returns null instead of throwing, for untrusted save data.
  print('garbage = ${Decimal.tryParse('not a number')}');
}
