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

/// [Float8ToFixedConverter] converts 8-bit floating point (FP8)
/// to signed fixed-point following Q notation (Qm.n format) as introduced by
/// (Texas Instruments)[https://www.ti.com/lit/ug/spru565b/spru565b.pdf].
/// FP8 input must follow E4M3 or E5M2 as described in
/// (FP8 formats for deep learning)[https://arxiv.org/pdf/2209.05433].
/// Infinities and NaN's are not supported.
/// if `mode` is true:
///   Input is treated as E4M3 and converted to Q9.9
///   `fixed[17:9] contains integer part
///   `fixed[8:0] contains fractional part
/// else:
///    Input is treated as E5M2 and converted to Q16.16
///   `fixed[31:16] contains integer part
///   `fixed[15:0] contains fractional part
class Float8ToFixedConverter extends Module {
  /// Output port [fixed]
  Logic get fixed => output('fixed');

  /// Constructor
  Float8ToFixedConverter(Logic float, Logic mode,
      {required int outputWidth, super.name = 'Float8ToFixedConverter'}) {
    float = addInput('float', float, width: float.width);
    mode = addInput('mode', mode);
    addOutput('fixed', width: outputWidth);

    if (float.width != 8) {
      throw RohdHclException('Input width must be 8');
    }

    if (outputWidth < 33) {
      throw RohdHclException(
          'Output width must be >= 33 for lossless conversion');
    }

    final exponent = Logic(name: 'exponent', width: 5)
      ..gets(mux(
          mode, [Const(0), float.slice(6, 3)].swizzle(), float.slice(6, 2)));

    final jBit = Logic(name: 'jBit')..gets(exponent.or());

    final mantissa = Logic(name: 'mantissa', width: 4)
      ..gets(mux(mode, [jBit, float.slice(2, 0)].swizzle(),
          [Const(0), jBit, float.slice(1, 0)].swizzle()));

    final shift = Logic(name: 'shift', width: exponent.width)
      ..gets(mux(jBit, exponent - 1, Const(0, width: exponent.width)));

    final number = Logic(name: 'number', width: outputWidth)
      ..gets([Const(0, width: outputWidth - 4), mantissa].swizzle() << shift);

    fixed <= mux(float[float.width - 1], ~number + 1, number);
  }
}

// Throw away before merge
void main() async {
  final float = Logic(width: 8);
  final mode = Logic();
  final dut = Float8ToFixedConverter(float, mode, outputWidth: 64);
  await dut.build();
  File('${dut.name}.sv').writeAsStringSync(dut.generateSynth());
}
