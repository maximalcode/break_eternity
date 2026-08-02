/// Lookup tables and scalar helpers for tetration and its inverses.
///
/// A direct port of `reference/index.ts` lines 43-206 and 3665-3728. This
/// library lives under `lib/src/` and is not exported from
/// `package:break_eternity/break_eternity.dart`; the members are documented
/// anyway for the next reader.
///
/// Tetration to a non-integer height has no single agreed-upon definition. The
/// reference picks an *analytic* approximation for bases up to 10, implemented
/// as a lookup table of `base^^h` sampled at `h = 0.0, 0.1, ... 1.0` for ten
/// bases, with linear interpolation in between; above base 10 it falls back to
/// a plain linear approximation. Those tables are what lives here. The
/// background, and the provenance of the numbers, is
/// <https://github.com/Patashu/break_eternity.js/issues/22>.
library;

import 'dart:math' as math;

/// `W(1, 0)`, the omega constant: the `x` with `x * e^x == 1`.
///
/// JS: `OMEGA`.
const double omega = 0.56714329040978387299997;

/// `e^(1/e)`, the largest base whose infinite power tower converges.
///
/// Above this, `base^^Infinity` is infinite; at or below it the tower settles
/// on a finite limit. The reference writes this literal out in six places, so
/// it gets a name here. JS: the bare constant `1.44466786100976613366`.
const double tetrationConvergenceLimit = 1.44466786100976613366;

/// `e^-e`, the smallest base whose infinite power tower converges.
///
/// Between this and [tetrationConvergenceLimit] the tower settles on a finite
/// limit; below it the iteration oscillates without ever converging. JS: the
/// bare constant `0.06598803584531253708`.
const double tetrationConvergenceFloor = 0.06598803584531253708;

/// A hair below [tetrationConvergenceLimit], where the two solutions of
/// `b^x == x` are close enough together that the Lambert W evaluation stops
/// separating them.
///
/// Bases above this are hotfixed to treat both solutions as `e`, exactly as the
/// reference does. JS: the bare constant `1.444667861009099`.
const double tetrationConvergenceHotfix = 1.444667861009099;

/// The bases the critical-section tables are sampled at.
///
/// JS: `critical_headers`. The second entry is `e`, which is why the
/// interpolation in [criticalSection] cannot simply index by base.
const List<double> criticalHeaders = <double>[
  2.0,
  2.718281828459045,
  3.0,
  4.0,
  5.0,
  6.0,
  7.0,
  8.0,
  9.0,
  10.0,
];

/// `base^^h` for each base in [criticalHeaders] at `h = 0.0, 0.1, ... 1.0`.
///
/// Row `i` corresponds to `criticalHeaders[i]`; column `j` to a height of
/// `j / 10`. Every row therefore starts at 1 (`b^^0 == 1`) and ends at its own
/// base (`b^^1 == b`). JS: `critical_tetr_values`.
const List<List<double>> criticalTetrValues = <List<double>>[
  // Base 2
  <double>[
    1.0,
    1.0891180521811203,
    1.1789767925673957,
    1.2701455431742086,
    1.3632090180450092,
    1.4587818160364217,
    1.5575237916251419,
    1.6601571006859253,
    1.767485818836978,
    1.8804192098842727,
    2.0,
  ],
  // Base e
  <double>[
    1.0,
    1.1121114330934079,
    1.231038924931609,
    1.3583836963111375,
    1.4960519303993531,
    1.6463542337511945,
    1.8121385357018724,
    1.996971324618307,
    2.2053895545527546,
    2.4432574483385254,
    2.718281828459045,
  ],
  // Base 3
  <double>[
    1.0,
    1.1187738849693603,
    1.2464963939368214,
    1.38527004705667,
    1.5376664685821402,
    1.7068895236551784,
    1.897001227148399,
    2.1132403089001035,
    2.362480153784171,
    2.6539010333870774,
    3.0,
  ],
  // Base 4
  <double>[
    1.0,
    1.1367350847096405,
    1.2889510672956703,
    1.4606478703324786,
    1.6570295196661111,
    1.8850062585672889,
    2.1539465047453485,
    2.476829779693097,
    2.872061932789197,
    3.3664204535587183,
    4.0,
  ],
  // Base 5
  <double>[
    1.0,
    1.1494592900767588,
    1.319708228183931,
    1.5166291280087583,
    1.748171114438024,
    2.0253263297298045,
    2.3636668498288547,
    2.7858359149579424,
    3.3257226212448145,
    4.035730287722532,
    5.0,
  ],
  // Base 6
  <double>[
    1.0,
    1.159225940787673,
    1.343712473580932,
    1.5611293155111927,
    1.8221199554561318,
    2.14183924486326,
    2.542468319282638,
    3.0574682501653316,
    3.7390572020926873,
    4.6719550537360774,
    6.0,
  ],
  // Base 7
  <double>[
    1.0,
    1.1670905356972596,
    1.3632807444991446,
    1.5979222279405536,
    1.8842640123816674,
    2.2416069644878687,
    2.69893426559423,
    3.3012632110403577,
    4.121250340630164,
    5.281493033448316,
    7.0,
  ],
  // Base 8
  <double>[
    1.0,
    1.1736630594087796,
    1.379783782386201,
    1.6292821855668218,
    1.9378971836180754,
    2.3289975651071977,
    2.8384347394720835,
    3.5232708454565906,
    4.478242031114584,
    5.868592169644505,
    8.0,
  ],
  // Base 9
  <double>[
    1.0,
    1.1793017514670474,
    1.394054150657457,
    1.65664127441059,
    1.985170999970283,
    2.4069682290577457,
    2.9647310119960752,
    3.7278665320924946,
    4.814462547283592,
    6.436522247411611,
    9.0,
  ],
  // Base 10
  <double>[
    1.0,
    1.1840100246247336,
    1.4061375836156955,
    1.6802272208863964,
    2.026757028388619,
    2.4770056063449646,
    3.080525271755482,
    3.9191964192627284,
    5.135152840833187,
    6.989961179534715,
    10.0,
  ],
];

/// `slog_base(x)` sampled on the same grid as [criticalTetrValues].
///
/// The inverse view of the same data: row `i` is base `criticalHeaders[i]`, and
/// column `j` holds the super-logarithm of a value `j / 10` of the way through
/// the critical section, running from -1 up to 0. JS: `critical_slog_values`.
const List<List<double>> criticalSlogValues = <List<double>>[
  // Base 2
  <double>[
    -1.0,
    -0.9194161097107025,
    -0.8335625019330468,
    -0.7425599821143978,
    -0.6466611521029437,
    -0.5462617907227869,
    -0.4419033816638769,
    -0.3342645487554494,
    -0.224140440909962,
    -0.11241087890006762,
    0.0,
  ],
  // Base e
  <double>[
    -1.0,
    -0.90603157029014,
    -0.80786507256596,
    -0.7064666939634,
    -0.60294836853664,
    -0.49849837513117,
    -0.39430303318768,
    -0.29147201034755,
    -0.19097820800866,
    -0.09361896280296,
    0.0,
  ],
  // Base 3
  <double>[
    -1.0,
    -0.9021579584316141,
    -0.8005762598234203,
    -0.6964780623319391,
    -0.5911906810998454,
    -0.486050182576545,
    -0.3823089430815083,
    -0.28106046722897615,
    -0.1831906535795894,
    -0.08935809204418144,
    0.0,
  ],
  // Base 4
  <double>[
    -1.0,
    -0.8917227442365535,
    -0.781258746326964,
    -0.6705130326902455,
    -0.5612813129406509,
    -0.4551067709033134,
    -0.35319256652135966,
    -0.2563741554088552,
    -0.1651412821106526,
    -0.0796919581982668,
    0.0,
  ],
  // Base 5
  <double>[
    -1.0,
    -0.8843387974366064,
    -0.7678744063886243,
    -0.6529563724510552,
    -0.5415870994657841,
    -0.4352842206588936,
    -0.33504449124791424,
    -0.24138853420685147,
    -0.15445285440944467,
    -0.07409659641336663,
    0.0,
  ],
  // Base 6
  <double>[
    -1.0,
    -0.8786709358426346,
    -0.7577735191184886,
    -0.6399546189952064,
    -0.527284921869926,
    -0.4211627631006314,
    -0.3223479611761232,
    -0.23107655627789858,
    -0.1472057700818259,
    -0.07035171210706326,
    0.0,
  ],
  // Base 7
  <double>[
    -1.0,
    -0.8740862815291583,
    -0.7497032990976209,
    -0.6297119746181752,
    -0.5161838335958787,
    -0.41036238255751956,
    -0.31277212146489963,
    -0.2233976621705518,
    -0.1418697367979619,
    -0.06762117662323441,
    0.0,
  ],
  // Base 8
  <double>[
    -1.0,
    -0.8702632331800649,
    -0.7430366914122081,
    -0.6213373075161548,
    -0.5072025698095242,
    -0.40171437727184167,
    -0.30517930701410456,
    -0.21736343968190863,
    -0.137710238299109,
    -0.06550774483471955,
    0.0,
  ],
  // Base 9
  <double>[
    -1.0,
    -0.8670016295947213,
    -0.7373984232432306,
    -0.6143173985094293,
    -0.49973884395492807,
    -0.394584953527678,
    -0.2989649949848695,
    -0.21245647317021688,
    -0.13434688362382652,
    -0.0638072667348083,
    0.0,
  ],
  // Base 10
  <double>[
    -1.0,
    -0.8641642839543857,
    -0.732534623168535,
    -0.6083127477059322,
    -0.4934049257184696,
    -0.3885773075899922,
    -0.29376029055315767,
    -0.2083678561173622,
    -0.13155653399373268,
    -0.062401588652553186,
    0.0,
  ],
];

/// Interpolates [grid] at the given [base] and fractional [height].
///
/// [height] is a fraction of one whole tetration step, i.e. the `0 <= h <= 1`
/// piece that whole-number iteration cannot supply; it is clamped to that
/// range, and [base] is clamped to `[2, 10]`. The result is bilinear: first
/// between the two bracketing bases in [criticalHeaders], then between the two
/// bracketing tenths of height.
///
/// The height interpolation happens in log space when both endpoints are
/// positive, which the reference notes is noticeably more accurate near
/// `h = 1`. That path calls `dart:math`'s `log` and `pow`, which are the host
/// platform's libm — see the note on `Decimal.ln` about their last bit
/// depending on the target, and `Decimal.pow10` about `pow` differing between
/// CPU architectures under dart2js. The reference is on `Math.log`/`Math.pow`
/// here too, so this is fidelity rather than an oversight.
///
/// JS: `critical_section`. Its unused `linear` parameter is dropped.
double criticalSection(double base, double height, List<List<double>> grid) {
  // The grid covers 0.1 through 0.9; scale the fraction up to a column index.
  height *= 10;
  if (height < 0) {
    height = 0;
  }
  if (height > 10) {
    height = 10;
  }
  if (base < 2) {
    base = 2;
  }
  if (base > 10) {
    base = 10;
  }

  final double lowIndex = height.floorToDouble();
  final double highIndex = height.ceilToDouble();

  double lower = 0;
  double upper = 0;
  for (int i = 0; i < criticalHeaders.length; i++) {
    if (criticalHeaders[i] == base) {
      lower = _at(grid[i], lowIndex);
      upper = _at(grid[i], highIndex);
      break;
    } else if (i + 1 < criticalHeaders.length &&
        criticalHeaders[i] < base &&
        criticalHeaders[i + 1] > base) {
      // Between two sampled bases: blend the two rows first.
      final double basefrac =
          (base - criticalHeaders[i]) /
          (criticalHeaders[i + 1] - criticalHeaders[i]);
      lower =
          _at(grid[i], lowIndex) * (1 - basefrac) +
          _at(grid[i + 1], lowIndex) * basefrac;
      upper =
          _at(grid[i], highIndex) * (1 - basefrac) +
          _at(grid[i + 1], highIndex) * basefrac;
      break;
    }
  }

  final double frac = height - height.floorToDouble();
  if (lower <= 0 || upper <= 0) {
    // The slog table is all negatives, so it always lands here; so does any
    // row whose endpoint is exactly 0. Plain linear interpolation.
    return lower * (1 - frac) + upper * frac;
  }
  return math
      .pow(
        base,
        (math.log(lower) / math.log(base)) * (1 - frac) +
            (math.log(upper) / math.log(base)) * frac,
      )
      .toDouble();
}

/// Reads `row[index]`, yielding NaN for an index that is not a whole number.
///
/// A NaN height reaches [criticalSection] from `Decimal.tetrate(double.nan)`.
/// JavaScript reads `row[NaN]` as `undefined` and lets the arithmetic below
/// turn that into NaN; Dart throws on `double.nan.toInt()`, so the same outcome
/// is spelled out. [index] is always an already-clamped `floor` or `ceil`, so
/// there is no other way for it to be out of range.
double _at(List<double> row, double index) =>
    index.isNaN ? double.nan : row[index.toInt()];

/// The Lambert W function on a plain `double`: the `w` with `w * e^w == z`.
///
/// [principal] selects the branch: `W_0` when true (defined for `z >= -1/e`),
/// `W_-1` when false (defined for `-1/e <= z <= 0`).
///
/// Solved by Newton's method from a branch-dependent initial guess. Throws a
/// [StateError] if 100 iterations do not converge to within [tol], which is
/// what the reference does — it evaluates poorly very close to the branch point
/// at `-1/e`, and returning a silently wrong number there would be worse.
///
/// JS: `f_lambertw`, itself from <https://math.stackexchange.com/a/465183>.
double fLambertW(double z, {double tol = 1e-10, bool principal = true}) {
  if (!z.isFinite) {
    return z;
  }

  double w;
  if (principal) {
    if (z == 0) {
      return z;
    }
    if (z == 1) {
      return omega;
    }
    w = z < 10 ? 0 : math.log(z) - math.log(math.log(z));
  } else {
    if (z == 0) {
      return double.negativeInfinity;
    }
    w = z <= -0.1 ? -2 : math.log(-z) - math.log(-math.log(-z));
  }

  for (int i = 0; i < 100; i++) {
    final double wn = (z * math.exp(-w) + w * w) / (w + 1);
    if ((wn - w).abs() < tol * wn.abs()) {
      return wn;
    }
    w = wn;
  }

  throw StateError('Lambert W iteration failed to converge: $z');
}
