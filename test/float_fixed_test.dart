// Copyright (C) 2024 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// 2024 September 26
// Authors:
//  Soner Yaldiz <soner.yaldiz@intel.com>

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:test/test.dart';

void main() async {
  test('FPtoINT: simple', () async {
    final float = Logic(width: 8);
    final mode = Logic();
    final dut = Float8ToFixedConverter(float, mode, outputWidth: 64);
    await dut.build();

    FloatingPoint8Value fp8;
    FixedPointValue fx8;

    final corners = <double>[];
    mode.put(1);
    corners.addAll([0, 1, -1, 1.625, -74.125]);
    for (var c = 0; c < corners.length; c++) {
      fp8 = FloatingPoint8Value.fromDouble(corners[c], exponentWidth: 4);
      float.put(fp8.value);
      fx8 = FixedPointValue.fromDouble(fp8.toDouble(), m: 54, n: 9);
      expect(dut.fixed.value.bitString, fx8.value.bitString);
    }

    corners.clear();
    mode.put(0);
    corners.addAll([0, 1, -1, 1.25, -74.5]);
    for (var c = 0; c < corners.length; c++) {
      fp8 = FloatingPoint8Value.fromDouble(corners[c], exponentWidth: 5);
      float.put(fp8.value);
      fx8 = FixedPointValue.fromDouble(fp8.toDouble(), m: 47, n: 16);
      expect(dut.fixed.value.bitString, fx8.value.bitString);
    }
  });

  test('FPtoINT: exhaustive', () async {
    final float = Logic(width: 8);
    final mode = Logic();
    final dut = Float8ToFixedConverter(float, mode, outputWidth: 64);
    await dut.build();

    FloatingPoint8Value fp8;
    FixedPointValue fx8;

    // Max normal E4M3 = s1111.110 = 126
    // Max normal E5M2 = s11110.11 = 123
    for (var i = 1; i <= 126; i++) {
      mode.put(1);
      // Positive E4M3
      fp8 = FloatingPoint8Value.fromLogic(LogicValue.ofInt(i, 8), 4);
      float.put(fp8.value);
      fx8 = FixedPointValue.fromDouble(fp8.toDouble(), m: 54, n: 9);
      expect(dut.fixed.value.bitString, fx8.value.bitString);

      // Negative E4M3
      fp8 = FloatingPoint8Value.fromLogic(
          [LogicValue.zero, LogicValue.ofInt(i, 7)].swizzle(), 4);
      float.put(fp8.value);
      fx8 = FixedPointValue.fromDouble(fp8.toDouble(), m: 54, n: 9);
      expect(dut.fixed.value.bitString, fx8.value.bitString);

      if (i <= 123) {
        mode.put(0);
        // Positive E5M2
        fp8 = FloatingPoint8Value.fromLogic(LogicValue.ofInt(i, 8), 5);
        float.put(fp8.value);
        fx8 = FixedPointValue.fromDouble(fp8.toDouble(), m: 47, n: 16);
        expect(dut.fixed.value.bitString, fx8.value.bitString);

        // Negative E5M2
        fp8 = FloatingPoint8Value.fromLogic(
            [LogicValue.zero, LogicValue.ofInt(i, 7)].swizzle(), 5);
        float.put(fp8.value);
        fx8 = FixedPointValue.fromDouble(fp8.toDouble(), m: 47, n: 16);
        expect(dut.fixed.value.bitString, fx8.value.bitString);
      }
    }
  });
}
