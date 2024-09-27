// Copyright (C) 2024 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// fixed_point_logic.dart
// Implementation of Fixed Point objects
//
// 2024 September 25
// Author: Soner Yaldiz <soner.yaldiz@intel.com>

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/src/exceptions.dart';

/// Fixed point logic representation
class FixedPoint extends Logic {
  /// [integerWidth] is the width of bits reserved for integer part
  late final int integerWidth;

  /// [fractionWidth] is the width of bits reserved for fractional part
  late final int fractionWidth;

  static int _fixedPointWidth(int a, int b) => 1 + a + b;

  /// [FixedPoint] Constructor
  FixedPoint(
      {required this.integerWidth, required this.fractionWidth, super.name})
      : super(width: _fixedPointWidth(integerWidth, fractionWidth)) {
    if (integerWidth < 0) {
      throw RohdHclException('integerWidth must be non-negative');
    }
    if (fractionWidth < 0) {
      throw RohdHclException('fractionWidth must be non-negative');
    }
  }
}
