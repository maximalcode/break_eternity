/// The `.dec` convenience extension on `num`.
library;

import 'decimal.dart';

/// Adds [dec] to every `int` and `double`, for terse [Decimal] literals.
extension DecimalNumExtension on num {
  /// This number as a [Decimal], e.g. `5.dec` or `1.5.dec`.
  ///
  /// Equivalent to `Decimal.fromNum(this)`, including its handling of
  /// `double.nan` and the infinities.
  Decimal get dec => Decimal.fromNum(this);
}
