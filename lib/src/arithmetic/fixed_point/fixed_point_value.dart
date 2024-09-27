// Copyright (C) 2024 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// fixed_point_value.dart
//
// 2024 September 24
// Authors:
//  Max Korbel <max.korbel@intel.com>
//  Desmond A Kirkpatrick <desmond.a.kirkpatrick@intel.com
//  Soner Yaldiz <soner.yaldiz@intel.com>

import 'dart:math';
import 'package:meta/meta.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

/// A flexible representation of signed fixed-point values following Q notation
/// (Qm.n format) as introduced by
/// (Texas Instruments)[https://www.ti.com/lit/ug/spru565b/spru565b.pdf]
@immutable
class FixedPointValue implements Comparable<FixedPointValue> {
  /// The full fixed point value bit storage in two's complement
  late final LogicValue value;

  /// The sign of the fixed point number
  final LogicValue sign;

  /// The integer part of the fixed point number
  final LogicValue integer;

  /// The fractional part of the fixed point number
  final LogicValue fraction;

  /// Constructor of a [FixedPointValue] from integer and fraction values
  FixedPointValue(
      {required this.sign,
      this.integer = LogicValue.empty,
      this.fraction = LogicValue.empty}) {
    if (sign.width != 1) {
      throw RohdHclException('sign width must be 1');
    }
    if ((integer == LogicValue.empty) & (fraction == LogicValue.empty)) {
      throw RohdHclException('integer or fraction must be non-empty');
    }
    if (sign.isZero) {
      value = [sign, integer, fraction].swizzle();
    } else {
      value = ~[LogicValue.zero, integer, fraction].swizzle() + 1;
    }
  }

  /// Returns a negative integer if `this` less than [other],
  /// a positive integer if `this` greater than [other],
  /// and zero if `this` and [other] are equal.
  @override
  int compareTo(Object other) {
    if (other is! FixedPointValue) {
      throw RohdHclException('Input must be of type FixedPointValue');
    }
    if ((integer.width != other.integer.width) |
        (fraction.width != other.fraction.width)) {
      throw RohdHclException(
          'Integer and fraction widths must match for comparison');
    }
    final signCompare = other.sign.compareTo(sign);
    if (signCompare != 0) {
      return signCompare;
    }
    final flip = sign.isZero ? 1 : -1;
    final integerCompare = integer.compareTo(other.integer);
    if (integerCompare != 0) {
      return flip * integerCompare;
    }
    final fractionCompare = fraction.compareTo(other.fraction);
    return flip * fractionCompare;
  }

  /// Constructor of a [FixedPointValue] from a double rounding away from zero
  factory FixedPointValue.fromDouble(double inDouble,
      {required int m, required int n}) {
    final s = inDouble >= 0 ? LogicValue.zero : LogicValue.one;

    if (inDouble.abs().floor() > pow(2, m) - 1) {
      throw RohdHclException('inDouble exceed integer part');
    }
    final integerPart = inDouble.abs().floor();

    final fractionalPart =
        LogicValue.ofInt((inDouble.abs() * pow(2, n)).round(), n);

    return FixedPointValue(
        sign: s,
        integer: LogicValue.ofInt(integerPart, m),
        fraction: fractionalPart);
  }

  ///
  double toDouble() {
    final value = integer.toInt().toDouble() +
        (fraction.toInt().toDouble() / pow(2, fraction.width));
    return sign.toBool() ? -value : value;
  }
}
