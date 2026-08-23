# Contributing

## Branching

`develop` is the integration branch. `main` is for releases only.

```
feature branch  ->  develop  ->  main (release)  ->  tag vX.Y.Z  ->  pub.dev
```

- Branch off `develop` as `<type>/<slug>` — `feat/`, `fix/`, `docs/`, `ci/`,
  `release/`.
- Open the pull request against `develop`. Both branches are protected: every
  status check must pass, the history stays linear, and the rules apply to
  administrators too, so nothing reaches either branch without CI and a review.
- A release is a `develop` -> `main` pull request that bumps the version in
  `pubspec.yaml`, moves the CHANGELOG's `## Unreleased` section under the new
  number, and updates the install snippet in the README. Tag `vX.Y.Z` on `main`
  once it lands, then publish.

**Delete branches when their pull request merges.** GitHub only re-targets a
stacked pull request when the branch beneath it is deleted on merge. Leaving
the branch alive is how a stacked PR quietly merges into its parent instead of
into the integration branch — see #6, which had to be re-landed as #7.

## Before you push

```console
dart format .
dart analyze
dart test
dart test -p node
```

CI runs all four on macOS, Linux and Windows, against both the oldest supported
SDK and current stable, plus the suite compiled to JavaScript. The dart2js run
is not optional: `layer` is a `double` specifically so that results match
between the VM and the web, and only that job proves it.

## Fixtures

`test/fixtures/` is generated from the vendored JavaScript reference, not
hand-written:

```console
node tool/generate_fixtures.mjs
```

Regenerating **must** reproduce every existing file byte for byte. That is the
check which proves the fixtures were derived from break_eternity.js rather than
fitted to whatever this port happens to return. If a file changes, the port's
behaviour changed — find out why before committing it.

## Fidelity comes before correctness

This is a port. Where break_eternity.js is inexact or arguably wrong, the
default is to reproduce its answer and document the wart, not to improve on it
— a silent divergence is worse than a known one. `pow` is not exact on integer
results and `/` is not correctly rounded; both are pinned in
`test/precision_test.dart` precisely so they cannot be "fixed" by accident.

The exceptions are additions with no counterpart in the reference, such as the
`int` conversions and `~/`, which exist because Dart has an integer type and
JavaScript does not.

## Tests that pin numbers

Do not assert an exact value that reaches `math.pow`, `math.exp` or `math.log`.
The host libm is not portable — `7.dec.sqr()` is `48.99999999999999` on
macOS/arm64 and exactly `49` on Linux/x64 — and CI runs on three operating
systems. Assert a bound, a tolerance, or a set of acceptable outcomes. Several
tests have already been lost to this (b2e7c56).
