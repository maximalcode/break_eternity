/// Internal numeric constants and lookup tables shared by the implementation.
///
/// Everything here is a direct port of the header of the vendored JavaScript
/// reference (`reference/index.ts`, lines 1-45). This library lives under
/// `lib/src/` and is not exported from `package:break_eternity/break_eternity.dart`;
/// the members are documented anyway for the next reader.
library;

import 'dart:math' as math;

/// Maximum number of digits of precision to assume in a `double`.
///
/// JS: `MAX_SIGNIFICANT_DIGITS = 17`.
const int maxSignificantDigits = 17;

/// If a magnitude is *above* this value, it is pushed up a layer.
///
/// 9e15 is close to the largest integer that fits exactly in a `double`.
/// JS: `EXP_LIMIT = 9e15`.
const double expLimit = 9e15;

/// `log10(9e15)`, exactly 15.954242509439325.
///
/// A layer-N (N >= 1) magnitude below this is pulled down a layer.
/// Computed rather than hard-coded, exactly as the reference computes it with
/// `Math.log10(9e15)`; with the [log10] defined below this is the correctly
/// rounded `double` and bit-identical to the JS value.
///
/// (The API contract quotes ~15.954589770191003 for this constant; that figure
/// is wrong — `log10(9e15) = 15 + log10(9)`. The reference value wins.)
final double layerDown = log10(expLimit);

/// At layer 0, non-zero magnitudes smaller than this become layer-1 numbers
/// with a negative magnitude. After that the pattern continues as normal.
///
/// JS: `FIRST_NEG_LAYER = 1 / 9e15`.
const double firstNegLayer = 1 / 9e15;

/// The largest base-10 exponent that can appear in a `double`.
///
/// Not every mantissa is valid at this exponent (1.8e308 overflows).
/// JS: `NUMBER_EXP_MAX = 308`.
const int numberExpMax = 308;

/// The smallest base-10 exponent that can appear in a `double` (subnormal).
///
/// JS: `NUMBER_EXP_MIN = -324`.
const int numberExpMin = -324;

/// How many leading `e`s `toString` will emit before switching to the
/// `(e^N)M` syntax.
///
/// JS: `MAX_ES_IN_A_ROW = 5`.
const int maxEsInARow = 5;

/// `2^54`, the scale factor used to bring a subnormal into the normal range
/// before taking its logarithm. JS/fdlibm: `two54`.
const double _two54 = 1.80143985094819840000e+16;

/// The smallest positive *normal* `double`, `2^-1022`.
const double _minNormal = 2.2250738585072014e-308;

/// Split of `ln(2)`: the leading part, with its low 32 mantissa bits zeroed.
const double _ln2hi = 6.93147180369123816490e-01;

/// Split of `ln(2)`: the trailing part, so `_ln2hi + _ln2lo == ln(2)` to
/// roughly twice `double` precision.
const double _ln2lo = 1.90821492927058770002e-10;

// Minimax polynomial coefficients for `log(1+f)` on the reduced interval.
// fdlibm `Lg1`..`Lg7`.
const double _lg1 = 6.666666666666735130e-01;
const double _lg2 = 3.999999999940941908e-01;
const double _lg3 = 2.857142874366239149e-01;
const double _lg4 = 2.222219843214978396e-01;
const double _lg5 = 1.818357216161805012e-01;
const double _lg6 = 1.531383769920937332e-01;
const double _lg7 = 1.479819860511658591e-01;

/// `1 / ln(10)`, in the low-precision form fdlibm's `log10` multiplies by.
const double _ivln10 = 4.34294481903251816668e-01;

/// Split of `log10(2)`: the leading part.
const double _log102hi = 3.01029995663611771306e-01;

/// Split of `log10(2)`: the trailing part.
const double _log102lo = 3.69423907715893089638e-13;

/// The value of the top 20 mantissa bits at which fdlibm folds `[1, 2)` down
/// to `[sqrt(1/2), sqrt(2))`: `1 + 0x6a09c * 2^-20`, just above `sqrt(2)`.
const double _sqrt2Fold = 1.4142131805419922;

/// `2^20`, used to extract the top 20 mantissa bits arithmetically.
const double _twoPow20 = 1048576.0;

/// Exactly `2^e` for `e` in `[-1074, 1023]`, by binary exponentiation.
///
/// Every intermediate is a power of two and therefore exact, and the final
/// reciprocal is exact because `2^-e` is normal throughout the range this
/// library uses it on.
double _exp2(int e) {
  double result = 1.0;
  double base = 2.0;
  int n = e < 0 ? -e : e;
  while (n > 0) {
    if (n & 1 == 1) result *= base;
    base *= base;
    n >>= 1;
  }
  return e < 0 ? 1.0 / result : result;
}

/// The unbiased binary exponent of a positive, finite, normal [x]: the unique
/// `e` with `x / 2^e` in `[1, 2)`.
///
/// This is `frexp`, which `dart:math` does not provide and which we cannot get
/// at bit-wise without `dart:typed_data`. The seed comes from `math.log`, so it
/// may be off by one on some platforms; the two correction loops (which run at
/// most once) make the answer exact regardless, so the result is *not*
/// platform-dependent.
int _binaryExponent(double x) {
  int e = (math.log(x) * math.log2e).floor();
  if (e > 1023) e = 1023;
  if (e < -1022) e = -1022;
  double m = x / _exp2(e);
  while (m >= 2.0) {
    m /= 2.0;
    e++;
  }
  while (m < 1.0) {
    m *= 2.0;
    e--;
  }
  return e;
}

/// Natural logarithm of [xr], which must already lie in `[0.5, 2)`.
///
/// A direct port of fdlibm's `__ieee754_log` with the argument reduction
/// specialised to the narrow input range (so the exponent is known to be `0`
/// or `-1` and no `frexp` is needed). The bit manipulation in the original is
/// replaced by exact arithmetic: the top 20 mantissa bits of a mantissa `m` in
/// `[1, 2)` are `floor((m - 1) * 2^20)`, and `SET_HIGH_WORD` folding `m` into
/// `[sqrt(1/2), sqrt(2))` is a halving.
double _logReduced(double xr) {
  int k;
  final double m;
  if (xr >= 1.0) {
    k = 0;
    m = xr;
  } else {
    k = -1;
    m = xr * 2.0;
  }

  // Top 20 bits of the mantissa; `m - 1.0` is exact by Sterbenz's lemma and
  // multiplying by a power of two is exact, so this matches fdlibm's
  // `hx & 0x000fffff` bit for bit.
  final int hx = ((m - 1.0) * _twoPow20).floor();

  double x = m;
  if (m >= _sqrt2Fold) {
    x = m / 2.0;
    k += 1;
  }

  final double f = x - 1.0;
  final double dk = k.toDouble();

  // |f| < 2^-20: use the short series instead of the full polynomial.
  if ((0xfffff & (2 + hx)) < 3) {
    if (f == 0.0) {
      if (k == 0) return 0.0;
      return dk * _ln2hi + dk * _ln2lo;
    }
    final double r = f * f * (0.5 - 0.33333333333333333 * f);
    if (k == 0) return f - r;
    return dk * _ln2hi - ((r - dk * _ln2lo) - f);
  }

  final double s = f / (2.0 + f);
  final double z = s * s;
  final double w = z * z;
  final double t1 = w * (_lg2 + w * (_lg4 + w * _lg6));
  final double t2 = z * (_lg1 + w * (_lg3 + w * (_lg5 + w * _lg7)));
  final double r = t1 + t2;

  // fdlibm writes this as `(hx - 0x6147a) | (0x6b851 - hx) > 0`, which is true
  // exactly when both operands are non-negative, i.e. when `x` is near sqrt(2).
  if (hx >= 0x6147a && hx <= 0x6b851) {
    final double hfsq = 0.5 * f * f;
    if (k == 0) return f - (hfsq - s * (hfsq + r));
    return dk * _ln2hi - ((hfsq - (s * (hfsq + r) + dk * _ln2lo)) - f);
  }
  if (k == 0) return f - s * (f - r);
  return dk * _ln2hi - ((s * (f - r) - dk * _ln2lo) - f);
}

/// Base-10 logarithm of [x], the stand-in for JavaScript's `Math.log10`.
///
/// `dart:math` has no `log10`, and neither obvious spelling is good enough.
/// `math.log(x) / math.ln10` returns `99.99999999999999` for `1e100`;
/// `math.log(x) * math.log10e` returns `28.999999999999996` for `1e29`. Both
/// break `floor(log10(...))` on exact powers of ten, which this library relies
/// on constantly — the visible symptom was `Decimal.fromNum(1e30).toString()`
/// printing `9.999999999999918e29`. Worse, both inherit the host C library's
/// `log`, so results differed between the Dart VM and dart2js.
///
/// So this is a self-contained software implementation: fdlibm's
/// `__ieee754_log10` (the Sun original, which is what V8 ships as
/// `Math.log10`) layered over the fdlibm `__ieee754_log` in [_logReduced].
/// Every operation is plain IEEE-754 `double` arithmetic, so the result is
/// identical on every Dart target.
///
/// Verified against V8 (Node 24) over a 109,000-value corpus: bit-identical on
/// **all 6,284** values of the form `Me±N` for `M` in `1..9`, which covers
/// every exact power of ten and is the domain `Decimal.normalize` cares about;
/// bit-identical on 99.2% of the corpus overall, against 78% for the previous
/// `math.log(x) * math.log10e`. The residual is a last-ulp disagreement on
/// arbitrary reals — V8's `Math.log` is not fdlibm's and neither is correctly
/// rounded, so exact agreement everywhere is not achievable.
double log10(double x) {
  if (x.isNaN) return x;
  if (x < 0.0) return double.nan;
  if (x == 0.0) return double.negativeInfinity;
  if (x == double.infinity) return x;

  int k = 0;
  double v = x;
  if (v < _minNormal) {
    // Scale the subnormal up into the normal range; 2^54 is enough that even
    // the smallest subnormal lands above `_minNormal`.
    k -= 54;
    v *= _two54;
  }
  final int e = _binaryExponent(v);
  k += e;
  final double m = v / _exp2(e); // exact; m is in [1, 2)

  // fdlibm reduces to a mantissa in [1, 2) for k >= 0 and [0.5, 1) for k < 0.
  final int i = k < 0 ? 1 : 0;
  final double xr = i == 1 ? m / 2.0 : m;
  final double y = (k + i).toDouble();

  final double z = y * _log102lo + _ivln10 * _logReduced(xr);
  return z + y * _log102hi;
}

/// Index of `10^0` inside [_powersOf10].
///
/// The table starts at `numberExpMin + 1 == -323`, so the offset that maps an
/// exponent to a table index is `323`. JS: `indexOf0InPowersOf10 = 323`.
const int _indexOf0InPowersOf10 = 323;

/// Exact powers of ten for integer exponents in `[-323, 308]`.
///
/// We need this lookup table because `pow(10, exponent)` is slightly
/// inaccurate when `|exponent|` is large. Parsing the literal `"1e<n>"` yields
/// the correctly rounded `double` instead. Built lazily: top-level `final`s in
/// Dart are initialised on first use.
final List<double> _powersOf10 = List<double>.generate(
  numberExpMax - numberExpMin,
  (int i) => double.parse('1e${i + numberExpMin + 1}'),
  growable: false,
);

/// Exactly `10^power` for integer [power], via a lookup table.
///
/// Out-of-range input is clamped explicitly rather than left to array
/// semantics: JavaScript would read past the end of the array, yielding
/// `undefined`, which then poisons any arithmetic into `NaN`. The clamped
/// values here are the *mathematically correct* `double` results anyway —
/// `1e309` overflows to infinity and `1e-324` underflows to zero — so this is
/// a deliberate, strictly-better divergence from the reference on inputs the
/// reference never intends to receive.
double powerOf10(int power) {
  final int index = power + _indexOf0InPowersOf10;
  if (index < 0) {
    // power <= -324: below the smallest subnormal's decade.
    return 0.0;
  }
  if (index >= _powersOf10.length) {
    // power >= 309: beyond double's range.
    return double.infinity;
  }
  return _powersOf10[index];
}
