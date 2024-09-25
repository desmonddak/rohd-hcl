// Copyright (C) 2024 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// 2024 September 24
// Authors:
//  Max Korbel <max.korbel@intel.com>
//  Desmond A Kirkpatrick <desmond.a.kirkpatrick@intel.com
//  Soner Yaldiz <soner.yaldiz@intel.com>

import 'dart:math';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:test/test.dart';

void main() {
  test('FXP: constructor', () {
    const m = 4;
    const n = 3;
    final corners = [
      // result, sign, integer, fraction
      ['00000000', 0, 0, 0],
      ['01111111', 0, pow(2, m)-1, pow(2, n)-1],
      ['10000001', 1, pow(2, m)-1, pow(2, n)-1],
      ['11101100', 1, 2, 4],  // -2.5
    ];
    for (var c = 0; c < corners.length; c++) {
      final val = LogicValue.ofString(corners[c][0] as String);
      final fxp = FixedPointValue(
        sign: LogicValue.ofInt(corners[c][1] as int, 1),
        integer: LogicValue.ofInt(corners[c][2] as int, m),
        fraction: LogicValue.ofInt(corners[c][3] as int, n),
      );
      expect(val, fxp.value);
    }
  });

  test('FXP: constructor no fraction', () {
    const m = 7;
    const n = 0;
    final corners = [
      // result, sign, integer, fraction
      ['00000000', 0, 0, 0],
      ['00000001', 0, 1, 0],
      ['01000000', 0, pow(2, m-1), 0],
      ['11111111', 1, 1, 0],
    ];
    for (var c = 0; c < corners.length; c++) {
      final val = LogicValue.ofString(corners[c][0] as String);
      final fxp = FixedPointValue(
        sign: LogicValue.ofInt(corners[c][1] as int, 1),
        integer: LogicValue.ofInt(corners[c][2] as int, m),
        fraction: LogicValue.ofInt(corners[c][3] as int, n),
      );
      expect(val, fxp.value);
    }
  });

  test('FXP: constructor no integer', () {
    const m = 0;
    const n = 4;
    final corners = [
      // result, sign, integer, fraction
      ['00000', 0, 0, 0],
      ['00001', 0, 0, 1],
      ['01000', 0, 0, pow(2, n-1)],
      ['11111', 1, 0, 1],
    ];
    for (var c = 0; c < corners.length; c++) {
      final val = LogicValue.ofString(corners[c][0] as String);
      final fxp = FixedPointValue(
        sign: LogicValue.ofInt(corners[c][1] as int, 1),
        integer: LogicValue.ofInt(corners[c][2] as int, m),
        fraction: LogicValue.ofInt(corners[c][3] as int, n),
      );
      expect(val, fxp.value);
    }
  });

}