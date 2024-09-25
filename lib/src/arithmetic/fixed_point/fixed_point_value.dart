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
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

/// A flexible representation of signed fixed-point values following Q notation
/// (Qm.n format) as introduced by
/// (Texas Instruments)[https://www.ti.com/lit/ug/spru565b/spru565b.pdf]
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

  /// TODO: Implement this
  @override
  int compareTo(Object other) => 0;
}
