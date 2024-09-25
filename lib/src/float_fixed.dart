// Copyright (C) 2023-2024 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// floating_fixed.dart
// Transform floating point input into fixed point output.
//
// 2024 September 25
// Author: Soner Yaldiz <soner.yaldiz@intel.com>

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

/// [FloatToFixedConverter] converts floating point to fixed point.
class FloatToFixedConverter extends Module {
  /// [integerWidth] is the width of bits reserved for integer part
  late final int integerWidth;

  /// [fractionWidth] is the width of bits reserved for fractional part
  late final int fractionWidth;

  /// Output port [fixed]
  late final FixedPoint fixed =
      FixedPoint(integerWidth: integerWidth, fractionWidth: fractionWidth)
        ..gets(output('fixed'));

  /// Constructor
  FloatToFixedConverter(FloatingPoint float,
      {required this.integerWidth,
      required this.fractionWidth,
      super.name = 'FloatToFixedConverter'}) {
    float = float.clone()..gets(addInput('float', float, width: float.width));
    final fx = addOutput('fixed', width: 1 + integerWidth + fractionWidth);
    fx <= Const(0, width: fixed.width);
  }
}

// Throw away before merge
void main() async {
  final float = FloatingPoint(exponentWidth: 4, mantissaWidth: 3);
  final dut = FloatToFixedConverter(float, integerWidth: 16, fractionWidth: 8);
  await dut.build();
  File('${dut.name}.sv').writeAsStringSync(dut.generateSynth());
}
