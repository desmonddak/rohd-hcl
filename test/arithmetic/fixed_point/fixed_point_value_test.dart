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
      ['01111111', 0, pow(2, m) - 1, pow(2, n) - 1],
      ['10000001', 1, pow(2, m) - 1, pow(2, n) - 1],
      ['11101100', 1, 2, 4], // -2.5
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
      ['01000000', 0, pow(2, m - 1), 0],
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
      ['01000', 0, 0, pow(2, n - 1)],
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

  test('FXP: comparison', () {
    final fxp1 = FixedPointValue(
      sign: LogicValue.ofInt(0, 1),
      integer: LogicValue.ofInt(4, 3),
      fraction: LogicValue.ofInt(3, 3),
    );
    expect(
        fxp1.compareTo(FixedPointValue(
          sign: LogicValue.ofInt(0, 1),
          integer: LogicValue.ofInt(4, 3),
          fraction: LogicValue.ofInt(3, 3),
        )),
        0);
    expect(
        fxp1.compareTo(FixedPointValue(
          sign: LogicValue.ofInt(0, 1),
          integer: LogicValue.ofInt(4, 3),
          fraction: LogicValue.ofInt(2, 3),
        )),
        greaterThan(0));
    expect(
        fxp1.compareTo(FixedPointValue(
          sign: LogicValue.ofInt(0, 1),
          integer: LogicValue.ofInt(4, 3),
          fraction: LogicValue.ofInt(4, 3),
        )),
        lessThan(0));

    final fxp2 = FixedPointValue(
      sign: LogicValue.ofInt(1, 1),
      integer: LogicValue.ofInt(4, 3),
      fraction: LogicValue.ofInt(3, 3),
    );
    expect(
        fxp2.compareTo(FixedPointValue(
          sign: LogicValue.ofInt(1, 1),
          integer: LogicValue.ofInt(4, 3),
          fraction: LogicValue.ofInt(3, 3),
        )),
        0);
    expect(
        fxp2.compareTo(FixedPointValue(
          sign: LogicValue.ofInt(1, 1),
          integer: LogicValue.ofInt(4, 3),
          fraction: LogicValue.ofInt(2, 3),
        )),
        lessThan(0));
    expect(
        fxp2.compareTo(FixedPointValue(
          sign: LogicValue.ofInt(1, 1),
          integer: LogicValue.ofInt(4, 3),
          fraction: LogicValue.ofInt(4, 3),
        )),
        greaterThan(0));
  });

  test('FXP: ofDouble toDouble', () {
    final corners = [
      ('00000000', 5, 2, 0.0),
      ('00000000', 4, 3, 0.0),
      ('11111111', 7, 0, -1.0),
      ('00011010', 4, 3, 3.25),
      ('11110010', 4, 3, -1.75),
    ];
    for (var c = 0; c < corners.length; c++) {
      final str = corners[c].$1;
      final m = corners[c].$2;
      final n = corners[c].$3;
      final val = corners[c].$4;
      final fxp = FixedPointValue.fromDouble(val, m: m, n: n);

      expect(str, fxp.value.bitString);
      expect(val, fxp.toDouble());
    }
  });
}
