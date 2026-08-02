/// Big numbers for idle and incremental games.
///
/// Ordinary Dart doubles lose integer precision past 2^53 (about 9.0e15) and
/// cannot represent anything above about 1.8e308. Incremental games routinely
/// blow past both limits. [Decimal] stores a number as
/// `sign * 10^10^10^...(layer times)... mag`, which keeps every operation
/// constant-time while reaching values as large as 10^^1e308.
///
/// ```dart
/// final gold = 1e300.dec * 1e300.dec; // 1e600, no overflow
/// print(gold); // 1e600
/// ```
///
/// This is a Dart port of [break_eternity.js](https://github.com/Patashu/break_eternity.js)
/// by Patashu, used under the MIT licence.
library;

export 'src/decimal.dart';
export 'src/num_extension.dart';
