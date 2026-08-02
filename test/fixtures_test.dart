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

  final _CaseRunner? runner = _ops[op];
  if (runner == null) {
    fail(
      '${file.path}: unknown op "$op". Add it to _ops in '
      'test/fixtures_test.dart (known ops: ${(_ops.keys.toList()..sort()).join(', ')}).',
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

    final _Outcome outcome = runner(testCase);
    if (outcome.skipReason != null) {
      skipped++;
      continue;
    }

    checked++;
    final Decimal actual = outcome.result!;
    if (_tripleMatches(testCase.expected, actual)) {
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
      buffer.writeln('... and $missing more (report capped at '
          '$_maxReportedFailures cases).');
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

/// Every op the fixture generator can emit, keyed by its `"op"` string.
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
  'normalize': (_FixtureCase c) => _Outcome.value(
        Decimal.fromComponents(c.rawA[0], c.rawA[1], c.rawA[2]),
      ),
};

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

/// One decoded `{"a": [...], "b": [...], "r": [...]}` entry.
class _FixtureCase {
  _FixtureCase({
    required this.op,
    required this.index,
    required this.rawA,
    required this.rawB,
    required this.expected,
  });

  factory _FixtureCase.decode(String op, int index, Map<String, Object?> json) {
    final List<double> a = _decodeTriple(op, index, 'a', json['a']);
    final List<double>? b =
        json['b'] == null ? null : _decodeTriple(op, index, 'b', json['b']);
    final List<double> r = _decodeTriple(op, index, 'r', json['r']);
    return _FixtureCase(
      op: op,
      index: index,
      rawA: a,
      rawB: b,
      expected: r,
    );
  }

  final String op;
  final int index;

  /// The raw components of the first operand, exactly as stored.
  final List<double> rawA;

  /// The raw components of the second operand, or null for a unary op.
  final List<double>? rawB;

  /// The expected result components.
  final List<double> expected;

  /// The first operand. Fixture inputs are already normalised, so they are
  /// rebuilt verbatim rather than re-normalised (which would hide bugs).
  Decimal get a => Decimal.fromComponentsNoNormalize(rawA[0], rawA[1], rawA[2]);

  /// The second operand, for binary ops.
  Decimal? get b {
    final List<double>? raw = rawB;
    if (raw == null) {
      return null;
    }
    return Decimal.fromComponentsNoNormalize(raw[0], raw[1], raw[2]);
  }

  /// The second operand, failing loudly if the fixture omitted it.
  Decimal requireB() {
    final Decimal? value = b;
    if (value == null) {
      fail('$op case $index: binary op is missing its "b" operand.');
    }
    return value;
  }

  /// The inputs, formatted for a failure message.
  String describeInputs() {
    final List<double>? raw = rawB;
    if (raw == null) {
      return 'a=${_fmtTriple(rawA)}';
    }
    return 'a=${_fmtTriple(rawA)}  b=${_fmtTriple(raw)}';
  }

  /// A full, self-contained description of a mismatching case.
  String describeMismatch(Decimal actual) {
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
List<double> _decodeTriple(
  String op,
  int index,
  String field,
  Object? value,
) {
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
  fail('$op case $index: field "$field" holds an undecodable component '
      '($value). Expected a number or "NaN"/"Infinity"/"-Infinity".');
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
