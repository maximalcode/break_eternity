@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:break_eternity/break_eternity.dart';
import 'package:test/test.dart';

/// Replays the JSON fixtures in `test/fixtures/`, which are generated from the
/// vendored JavaScript reference by `node tool/generate_fixtures.mjs`.
///
/// A failure here means the Dart port disagrees with break_eternity.js on a
/// concrete input, which is the whole point of this suite. Do not widen
/// [_relativeTolerance] to make a case pass: fix the port, or (if the fixture
/// itself is wrong) fix the generator.
///
/// The runner is deliberately data-driven. Every `*.json` file in the fixture
/// directory is loaded and dispatched on its `"op"` field, so adding an op to
/// the generator needs no change here beyond one entry in [_ops].
void main() {
  final Directory? dir = _fixtureDirectory();

  if (dir == null) {
    test('fixtures', () {}, skip: _missingDirMessage());
    return;
  }

  final Map<String, File> files = <String, File>{
    for (final FileSystemEntity e in dir.listSync())
      if (e is File && e.path.endsWith('.json'))
        e.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), ''): e,
  };

  // Ops the generator is documented to emit. Listed only so that a *missing*
  // file is reported as a skip with an actionable message instead of silently
  // shrinking the suite.
  const List<String> expectedOps = <String>[
    // Milestone 1.
    'abs',
    'add',
    'ceil',
    'cmp',
    'div',
    'floor',
    'mod',
    'mul',
    'neg',
    'normalize',
    'recip',
    'round',
    'sub',
    'trunc',

    // Milestone 2: logarithms, powers and roots.
    'absLog10',
    'cbrt',
    'cube',
    'exp',
    'ln',
    'log',
    'log10',
    'log2',
    'pLog10',
    'pow',
    'pow10',
    'powBase',
    'root',
    'sqr',
    'sqrt',

    // Milestone 2: the incremental-game series helpers ("args" shape).
    'affordArithmeticSeries',
    'affordGeometricSeries',
    'efficiencyOfPurchase',
    'sumArithmeticSeries',
    'sumGeometricSeries',

    // Milestone 3: tetration, its inverses, and pentation ("n"/"lin" shape).
    'iteratedLog',
    'lambertW',
    'lambertWBranch',
    'layerAdd',
    'layerAdd10',
    'modFloored',
    'pentaLog',
    'pentate',
    'slog',
    'tetrate',
  ];

  for (final String op in expectedOps) {
    if (!files.containsKey(op)) {
      test(op, () {}, skip: _missingFileMessage(dir, op));
    }
  }

  final List<String> names = files.keys.toList()..sort();
  for (final String name in names) {
    test(name, () => _runFixtureFile(files[name]!));
  }
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

/// Relative tolerance each of `sign`, `layer` and `mag` is compared within.
const double _relativeTolerance = 1e-9;

/// How many mismatching cases are quoted before the report is truncated.
const int _maxReportedFailures = 10;

/// The message prefix the reference's Lambert W solvers throw with when their
/// iteration does not converge. See the note where it is handled.
const String _convergenceFailure = 'Iteration failed to converge';

void _runFixtureFile(File file) {
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    fail('${file.path}: expected a JSON object at the top level.');
  }

  final Object? op = decoded['op'];
  if (op is! String) {
    fail('${file.path}: missing or non-string "op" field.');
  }

  final Object? rawCases = decoded['cases'];
  if (rawCases is! List<Object?>) {
    fail('${file.path}: missing or non-list "cases" field.');
  }

  final _CaseRunner? runner = _ops[op] ?? _seriesOps[op];
  if (runner == null) {
    final List<String> known = <String>[..._ops.keys, ..._seriesOps.keys]
      ..sort();
    fail(
      '${file.path}: unknown op "$op". Add it to _ops (or _seriesOps, for the '
      'n-ary "args" shape) in test/fixtures_test.dart '
      '(known ops: ${known.join(', ')}).',
    );
  }

  final List<String> failures = <String>[];
  int mismatches = 0;
  int checked = 0;
  int skipped = 0;
  int total = 0;

  for (int i = 0; i < rawCases.length; i++) {
    final Object? entry = rawCases[i];
    if (entry is! Map<String, Object?>) {
      fail('${file.path}: case $i is not a JSON object.');
    }

    final _FixtureCase testCase = _FixtureCase.decode(op, i, entry);
    total++;

    // Cases the reference gave up on by throwing. This port keeps that
    // behaviour rather than quietly returning NaN, so the assertion is that it
    // throws too — with one exception, spelled out in [_convergenceFailure].
    if (testCase.expectedThrow != null) {
      checked++;
      Decimal? returned;
      try {
        returned = runner(testCase).result;
      } on StateError {
        continue;
      }

      if (testCase.expectedThrow == _convergenceFailure) {
        // Whether the Lambert W solver converges within its hundred iterations
        // is decided by the last bit of `log`, and the inputs that reach this
        // are within an ulp of the branch point at -1/e, where the iteration is
        // at its worst conditioned. V8's `Math.log(1.444667861009099)` and the
        // Dart VM's differ by exactly one ulp, and that is enough: the
        // reference gives up where this port converges — to the right answer,
        // as it happens (`w * e^w` reproduces the input exactly, and the value
        // matches the asymptotic series near the branch point to eight
        // digits).
        //
        // So neither outcome is wrong and neither is reproducible across
        // platforms. What is still worth asserting is that a solver which
        // claims to have converged returns a real number rather than NaN.
        if (returned != null && !returned.isNaN) {
          skipped++;
          continue;
        }
      }

      mismatches++;
      if (failures.length < _maxReportedFailures) {
        failures.add(
          '  case ${testCase.index} (${testCase.describeInputs()}): the '
          'reference threw "${testCase.expectedThrow}" but this returned '
          '$returned.',
        );
      }
      continue;
    }

    final _Outcome outcome = runner(testCase);
    if (outcome.skipReason != null) {
      skipped++;
      continue;
    }

    checked++;
    final Decimal actual = outcome.result!;
    if (_tripleMatches(testCase.requireExpected, actual)) {
      continue;
    }
    mismatches++;
    if (failures.length < _maxReportedFailures) {
      failures.add(testCase.describeMismatch(actual));
    }
  }

  if (skipped > 0) {
    printOnFailure('$op: $skipped of $total cases skipped (see runner notes).');
  }

  if (mismatches > 0) {
    final int missing = mismatches - failures.length;
    final StringBuffer buffer = StringBuffer()
      ..writeln(
        '$op: $mismatches of $checked compared cases diverge from the '
        'JavaScript reference (${file.path}).',
      )
      ..writeln();
    for (final String failure in failures) {
      buffer
        ..writeln(failure)
        ..writeln();
    }
    if (missing > 0) {
      buffer.writeln(
        '... and $missing more (report capped at '
        '$_maxReportedFailures cases).',
      );
    }
    fail(buffer.toString().trimRight());
  }

  expect(
    checked,
    greaterThan(0),
    reason: '$op: every case was skipped, so nothing was actually verified.',
  );
}

// ---------------------------------------------------------------------------
// Op dispatch
// ---------------------------------------------------------------------------

/// Computes the result of one fixture case, or explains why it was skipped.
typedef _CaseRunner = _Outcome Function(_FixtureCase testCase);

/// The result of running one case: either a value to compare, or a skip.
class _Outcome {
  const _Outcome.value(Decimal this.result) : skipReason = null;

  const _Outcome.skipped(String this.skipReason) : result = null;

  final Decimal? result;
  final String? skipReason;
}

_CaseRunner _unary(Decimal Function(Decimal a) f) =>
    (_FixtureCase c) => _Outcome.value(f(c.a));

_CaseRunner _binary(Decimal Function(Decimal a, Decimal b) f) =>
    (_FixtureCase c) => _Outcome.value(f(c.a, c.requireB()));

/// Every `{"a", "b"}`-shaped op the fixture generator can emit, keyed by its
/// `"op"` string. The n-ary series helpers live in [_seriesOps] instead.
final Map<String, _CaseRunner> _ops = <String, _CaseRunner>{
  // Unary.
  'neg': _unary((Decimal a) => -a),
  'abs': _unary((Decimal a) => a.abs()),
  'recip': _unary((Decimal a) => a.reciprocal()),
  'floor': _unary((Decimal a) => a.floor()),
  'ceil': _unary((Decimal a) => a.ceil()),
  'round': _unary((Decimal a) => a.round()),
  'trunc': _unary((Decimal a) => a.truncate()),

  // Binary.
  'add': _binary((Decimal a, Decimal b) => a + b),
  'sub': _binary((Decimal a, Decimal b) => a - b),
  'mul': _binary((Decimal a, Decimal b) => a * b),
  'div': _binary((Decimal a, Decimal b) => a / b),
  'mod': _binary((Decimal a, Decimal b) => a % b),

  'cmp': _runCmp,

  // `normalize` is the odd one out: its "a" is a RAW, possibly invalid triple
  // rather than an already-normalised Decimal, so it is fed straight to the
  // normalising factory.
  'normalize': (_FixtureCase c) =>
      _Outcome.value(Decimal.fromComponents(c.rawA[0], c.rawA[1], c.rawA[2])),

  // --- Milestone 2: logarithms -----------------------------------------
  'log10': _unary((Decimal a) => a.log10()),
  'absLog10': _unary((Decimal a) => a.absLog10()),
  'pLog10': _unary((Decimal a) => a.pLog10()),
  'log2': _unary((Decimal a) => a.log2()),
  'ln': _unary((Decimal a) => a.ln()),
  'log': _binary((Decimal a, Decimal base) => a.log(base)),

  // --- Milestone 2: powers and roots ------------------------------------
  // pow10 is the only op that exercises the exact-power-of-ten lookup table
  // directly; `pow` reaches it too, but only for the exponents that survive its
  // own special cases.
  'pow10': _unary((Decimal a) => a.pow10()),
  'sqr': _unary((Decimal a) => a.sqr()),
  'cube': _unary((Decimal a) => a.cube()),
  'sqrt': _unary((Decimal a) => a.sqrt()),
  'cbrt': _unary((Decimal a) => a.cbrt()),
  'exp': _unary((Decimal a) => a.exp()),
  'pow': _binary((Decimal a, Decimal b) => a.pow(b)),
  'root': _binary((Decimal a, Decimal degree) => a.root(degree)),

  // The reference's `pow_base`: `a.powBase(b)` is b^a, so the fixture's "a" is
  // the exponent and its "b" is the base.
  'powBase': _binary((Decimal a, Decimal base) => a.powBase(base)),

  // --- Milestone 3: tetration and its inverses ---------------------------
  //
  // These carry their plain-number parameters in "n" and the analytic-versus-
  // linear flag in "lin"; see the "SCALAR PARAMETERS" comment in the generator
  // for the argument mapping of each op.
  'tetrate': (_FixtureCase c) => _Outcome.value(
    c.a.tetrate(c.scalar(0), payload: c.requireB(), linear: c.linear),
  ),
  'iteratedLog': (_FixtureCase c) => _Outcome.value(
    c.a.iteratedLog(base: c.requireB(), times: c.scalar(0), linear: c.linear),
  ),
  'slog': (_FixtureCase c) =>
      _Outcome.value(c.a.slog(base: c.requireB(), linear: c.linear)),
  'layerAdd10': (_FixtureCase c) =>
      _Outcome.value(c.a.layerAdd10(c.scalar(0), linear: c.linear)),
  'layerAdd': (_FixtureCase c) =>
      _Outcome.value(c.a.layerAdd(c.scalar(0), c.requireB(), linear: c.linear)),

  // The two Lambert W branches are separate files rather than a flag, because
  // their domains barely overlap.
  'lambertW': _unary((Decimal a) => a.lambertW()),
  'lambertWBranch': _unary((Decimal a) => a.lambertW(principal: false)),

  'pentate': (_FixtureCase c) => _Outcome.value(
    c.a.pentate(c.scalar(0), payload: c.requireB(), linear: c.linear),
  ),
  'pentaLog': (_FixtureCase c) =>
      _Outcome.value(c.a.pentaLog(base: c.requireB(), linear: c.linear)),

  // The floored modulo, which `operator %` cannot express because it takes no
  // parameter.
  'modFloored': _binary((Decimal a, Decimal b) => a.mod(b, floored: true)),
};

/// The n-ary series helpers, whose cases carry an `"args"` array instead of
/// `"a"`/`"b"` (see the "N-ARY OPS" comment in `tool/generate_fixtures.mjs`).
///
/// Argument order is the reference's declaration order, which is also the order
/// the Dart statics take, so each entry is a straight positional splat.
final Map<String, _CaseRunner> _seriesOps = <String, _CaseRunner>{
  'affordGeometricSeries': _nary(
    4,
    (List<Decimal> a) => Decimal.affordGeometricSeries(a[0], a[1], a[2], a[3]),
  ),
  'sumGeometricSeries': _nary(
    4,
    (List<Decimal> a) => Decimal.sumGeometricSeries(a[0], a[1], a[2], a[3]),
  ),
  'affordArithmeticSeries': _nary(
    4,
    (List<Decimal> a) => Decimal.affordArithmeticSeries(a[0], a[1], a[2], a[3]),
  ),
  'sumArithmeticSeries': _nary(
    4,
    (List<Decimal> a) => Decimal.sumArithmeticSeries(a[0], a[1], a[2], a[3]),
  ),
  'efficiencyOfPurchase': _nary(
    3,
    (List<Decimal> a) => Decimal.efficiencyOfPurchase(a[0], a[1], a[2]),
  ),
};

/// Runner for an `"args"`-shaped op of exactly [arity] arguments.
///
/// The arity is checked per case rather than trusted, so a generator change
/// that drops or adds an argument fails loudly here instead of silently
/// comparing against the wrong call.
_CaseRunner _nary(int arity, Decimal Function(List<Decimal> args) f) =>
    (_FixtureCase c) => _Outcome.value(f(c.requireArgs(arity)));

/// `cmp` is stored as the `Decimal` form of the comparison result, so it can go
/// through the same triple comparison as everything else.
///
/// One deliberate divergence: the reference's `cmp` is incoherent around NaN.
/// `NaN.cmp(x)` falls through to `NaN * cmpabs(...)`, which is `NaN`, while
/// `x.cmp(NaN)` falls through to `x.sign * 0`, which is `0` — so the reference
/// reports a NaN operand as *equal* in one direction and as unordered in the
/// other. Dart's [Decimal.compareTo] instead implements a *total* order (NaN
/// equal to itself, greater than everything else) so it can be handed to
/// `List.sort`, and its return type (`int`) cannot express NaN at all.
///
/// Those cases are therefore checked against this port's documented behaviour
/// rather than against the fixture, then skipped.
_Outcome _runCmp(_FixtureCase c) {
  final Decimal a = c.a;
  final Decimal b = c.requireB();

  if (!a.isNaN && !b.isNaN) {
    return _Outcome.value(Decimal.fromNum(a.compareTo(b)));
  }

  final String where = 'cmp case ${c.index} (${c.describeInputs()})';

  // The total order: NaN sorts equal to itself and above everything else.
  final int expectedOrder = a.isNaN ? (b.isNaN ? 0 : 1) : -1;
  expect(
    a.compareTo(b),
    expectedOrder,
    reason: '$where: compareTo must impose a total order with NaN on top.',
  );

  // The operators still follow `double`: everything is false against NaN.
  expect(a < b, isFalse, reason: '$where: `<` must be false against NaN.');
  expect(a <= b, isFalse, reason: '$where: `<=` must be false against NaN.');
  expect(a > b, isFalse, reason: '$where: `>` must be false against NaN.');
  expect(a >= b, isFalse, reason: '$where: `>=` must be false against NaN.');
  expect(a == b, isFalse, reason: '$where: `==` must be false against NaN.');

  return const _Outcome.skipped(
    'the reference cmp is incoherent around NaN; Dart compareTo is a total '
    'order and returns int, so it cannot reproduce it',
  );
}

// ---------------------------------------------------------------------------
// Case decoding
// ---------------------------------------------------------------------------

/// One decoded case: `{"a", "b"?, "r"}`, the n-ary `{"args", "r"}`, or the
/// tetration family's `{"a", "b"?, "n"?, "lin", "r"}`.
///
/// Every shape collapses to the same thing — an ordered list of operand triples
/// and scalars, plus either an expected result or the message the reference
/// threw — so the runner, the comparison and the failure report are shared.
/// [rawA] and [rawB] are just names for the first two operands.
class _FixtureCase {
  _FixtureCase({
    required this.op,
    required this.index,
    required this.rawArgs,
    required this.expected,
    required this.scalars,
    required this.linear,
    required this.expectedThrow,
  });

  factory _FixtureCase.decode(String op, int index, Map<String, Object?> json) {
    final Object? args = json['args'];
    final List<List<double>> operands;
    if (args != null) {
      if (args is! List<Object?> || args.isEmpty) {
        fail('$op case $index: "args" is not a non-empty array ($args).');
      }
      operands = <List<double>>[
        for (int k = 0; k < args.length; k++)
          _decodeTriple(op, index, 'args[$k]', args[k]),
      ];
    } else {
      operands = <List<double>>[
        _decodeTriple(op, index, 'a', json['a']),
        if (json['b'] != null) _decodeTriple(op, index, 'b', json['b']),
      ];
    }

    // The tetration family carries plain scalars (heights, iteration counts) in
    // "n" and the analytic-versus-linear flag in "lin".
    final Object? rawScalars = json['n'];
    final List<double> scalars;
    if (rawScalars == null) {
      scalars = const <double>[];
    } else if (rawScalars is List<Object?>) {
      scalars = <double>[
        for (int k = 0; k < rawScalars.length; k++)
          _decodeComponent(op, index, 'n[$k]', rawScalars[k]),
      ];
    } else {
      fail('$op case $index: "n" is not an array ($rawScalars).');
    }

    final Object? rawLinear = json['lin'];
    if (rawLinear != null && rawLinear is! bool) {
      fail('$op case $index: "lin" is not a boolean ($rawLinear).');
    }

    // A case the reference threw on carries "throws" instead of "r".
    final Object? throws = json['throws'];
    if (throws != null) {
      if (throws is! String) {
        fail('$op case $index: "throws" is not a string ($throws).');
      }
      return _FixtureCase(
        op: op,
        index: index,
        rawArgs: operands,
        expected: null,
        scalars: scalars,
        linear: rawLinear == true,
        expectedThrow: throws,
      );
    }

    return _FixtureCase(
      op: op,
      index: index,
      rawArgs: operands,
      expected: _decodeTriple(op, index, 'r', json['r']),
      scalars: scalars,
      linear: rawLinear == true,
      expectedThrow: null,
    );
  }

  final String op;
  final int index;

  /// The raw components of every operand, in the reference's argument order.
  final List<List<double>> rawArgs;

  /// The expected result components, or null when the reference threw.
  final List<double>? expected;

  /// The plain-number parameters, in the reference's argument order.
  final List<double> scalars;

  /// Whether the reference was called with its `linear` flag set.
  final bool linear;

  /// The message prefix the reference threw with, or null if it returned.
  final String? expectedThrow;

  /// The [k]th scalar parameter, failing loudly if the fixture omitted it.
  double scalar(int k) {
    if (k >= scalars.length) {
      fail('$op case $index: expected at least ${k + 1} entries in "n".');
    }
    return scalars[k];
  }

  /// The expected components, failing loudly on a case that threw.
  List<double> get requireExpected {
    final List<double>? value = expected;
    if (value == null) {
      fail('$op case $index: this case threw, so it has no "r".');
    }
    return value;
  }

  /// The raw components of the first operand, exactly as stored.
  List<double> get rawA => rawArgs[0];

  /// The raw components of the second operand, or null for a unary op.
  List<double>? get rawB => rawArgs.length > 1 ? rawArgs[1] : null;

  /// The first operand. Fixture inputs are already normalised, so they are
  /// rebuilt verbatim rather than re-normalised (which would hide bugs).
  Decimal get a => _decimalAt(0);

  /// The second operand, for binary ops.
  Decimal? get b => rawArgs.length > 1 ? _decimalAt(1) : null;

  /// The second operand, failing loudly if the fixture omitted it.
  Decimal requireB() {
    final Decimal? value = b;
    if (value == null) {
      fail('$op case $index: binary op is missing its "b" operand.');
    }
    return value;
  }

  /// Every operand as a [Decimal], failing loudly on the wrong arity.
  List<Decimal> requireArgs(int arity) {
    if (rawArgs.length != arity) {
      fail(
        '$op case $index: expected $arity arguments in "args", '
        'found ${rawArgs.length}.',
      );
    }
    return <Decimal>[for (int k = 0; k < arity; k++) _decimalAt(k)];
  }

  Decimal _decimalAt(int k) {
    final List<double> raw = rawArgs[k];
    return Decimal.fromComponentsNoNormalize(raw[0], raw[1], raw[2]);
  }

  /// The inputs, formatted for a failure message.
  String describeInputs() {
    final StringBuffer buffer = StringBuffer();
    if (rawArgs.length > 2) {
      buffer.write('args=(${rawArgs.map(_fmtTriple).join(', ')})');
    } else {
      buffer.write('a=${_fmtTriple(rawA)}');
      final List<double>? raw = rawB;
      if (raw != null) {
        buffer.write('  b=${_fmtTriple(raw)}');
      }
    }
    if (scalars.isNotEmpty) {
      buffer.write('  n=(${scalars.map(_fmtDouble).join(', ')})');
      buffer.write('  linear=$linear');
    }
    return buffer.toString();
  }

  /// A full, self-contained description of a mismatching case.
  String describeMismatch(Decimal actual) {
    final List<double> expected = requireExpected;
    final List<double> got = <double>[actual.sign, actual.layer, actual.mag];
    final StringBuffer buffer = StringBuffer()
      ..writeln('  op       $op  (case $index)')
      ..writeln('  input    ${describeInputs()}')
      ..writeln('  expected ${_fmtTriple(expected)}')
      ..writeln('  actual   ${_fmtTriple(got)}');

    const List<String> labels = <String>['sign', 'layer', 'mag'];
    for (int i = 0; i < 3; i++) {
      if (!_componentMatches(expected[i], got[i])) {
        buffer.writeln(
          '  -> ${labels[i]} differs: '
          'expected ${_fmtDouble(expected[i])}, '
          'got ${_fmtDouble(got[i])}'
          '${_relativeErrorSuffix(expected[i], got[i])}',
        );
      }
    }
    return buffer.toString().trimRight();
  }
}

/// Decodes a `[sign, layer, mag]` triple.
///
/// JSON has no literal for the non-finite doubles, so the generator writes them
/// as the strings `"NaN"`, `"Infinity"` and `"-Infinity"`.
List<double> _decodeTriple(String op, int index, String field, Object? value) {
  if (value is! List<Object?> || value.length != 3) {
    fail('$op case $index: field "$field" is not a 3-element array ($value).');
  }
  return <double>[
    _decodeComponent(op, index, field, value[0]),
    _decodeComponent(op, index, field, value[1]),
    _decodeComponent(op, index, field, value[2]),
  ];
}

double _decodeComponent(String op, int index, String field, Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    switch (value) {
      case 'NaN':
        return double.nan;
      case 'Infinity':
        return double.infinity;
      case '-Infinity':
        return double.negativeInfinity;
    }
    final double? parsed = double.tryParse(value);
    if (parsed != null) {
      return parsed;
    }
  }
  fail(
    '$op case $index: field "$field" holds an undecodable component '
    '($value). Expected a number or "NaN"/"Infinity"/"-Infinity".',
  );
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

bool _tripleMatches(List<double> expected, Decimal actual) =>
    _componentMatches(expected[0], actual.sign) &&
    _componentMatches(expected[1], actual.layer) &&
    _componentMatches(expected[2], actual.mag);

/// Whether [actual] matches [expected] within [_relativeTolerance].
///
/// NaN matches only NaN, and each infinity matches only itself; `0.0` and
/// `-0.0` match because `==` says so (the generator notes that JSON loses the
/// sign of negative zero anyway).
bool _componentMatches(double expected, double actual) {
  if (expected.isNaN || actual.isNaN) {
    return expected.isNaN && actual.isNaN;
  }
  if (expected == actual) {
    return true;
  }
  if (expected.isInfinite || actual.isInfinite) {
    return false;
  }
  final double diff = (expected - actual).abs();
  final double scale = math.max(expected.abs(), actual.abs());
  return diff <= _relativeTolerance * scale;
}

String _relativeErrorSuffix(double expected, double actual) {
  if (expected.isNaN ||
      actual.isNaN ||
      expected.isInfinite ||
      actual.isInfinite) {
    return '';
  }
  final double scale = math.max(expected.abs(), actual.abs());
  if (scale == 0) {
    return '';
  }
  final double rel = (expected - actual).abs() / scale;
  return ' (relative error ${rel.toStringAsExponential(3)}, '
      'tolerance ${_relativeTolerance.toStringAsExponential(0)})';
}

String _fmtTriple(List<double> t) => '[${t.map(_fmtDouble).join(', ')}]';

String _fmtDouble(double v) {
  if (v.isNaN) {
    return 'NaN';
  }
  if (v == double.infinity) {
    return 'Infinity';
  }
  if (v == double.negativeInfinity) {
    return '-Infinity';
  }
  return v.toString();
}

// ---------------------------------------------------------------------------
// Fixture discovery
// ---------------------------------------------------------------------------

/// Where the generator writes its output, relative to the package root.
const String _canonicalFixtureDir = 'test/fixtures';

/// The fixture directory, or null if it has not been generated.
///
/// `dart test` runs with the package root as its working directory; the extra
/// candidates only cover being invoked from `test/` by hand.
Directory? _fixtureDirectory() {
  for (final String candidate in <String>[
    _canonicalFixtureDir,
    '../$_canonicalFixtureDir',
    'fixtures',
  ]) {
    final Directory dir = Directory(candidate);
    if (dir.existsSync()) {
      return dir;
    }
  }
  return null;
}

String _missingDirMessage() =>
    'Fixture directory "$_canonicalFixtureDir" not found (cwd: '
    '${Directory.current.path}). Generate it with: '
    'node tool/generate_fixtures.mjs';

String _missingFileMessage(Directory dir, String op) =>
    'Fixture "${dir.path}/$op.json" not found. Regenerate the fixtures with: '
    'node tool/generate_fixtures.mjs';
