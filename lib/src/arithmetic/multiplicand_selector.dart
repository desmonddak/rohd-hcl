// Copyright (C) 2024 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// multiplicand_selector.dart
// Selection of muliples of the multiplicand for booth recoding
//
// 2024 May 15
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

/// A class accessing the multiples of the multiplicand at a position
class MultiplicandSelector {
  /// The radix of the selector
  int radix;

  /// The bit shift of the selector (typically overlaps 1)
  int shift;

  /// New width of partial products generated from the multiplicand
  int get width => multiplicand.width + shift - 1;

  /// The base multiplicand from which to generate multiples to select.
  Logic multiplicand = Logic();

  /// Place to store [multiples] of the [multiplicand] (e.g. *1, *2, *-1, *-2..)
  late LogicArray multiples;

  /// Build a [MultiplicandSelector] generationg required [multiples] of
  /// [multiplicand] to [select] using a [RadixEncoder] argument.
  ///
  /// [multiplicand] is base multiplicand multiplied by Booth encodings of
  /// the [RadixEncoder] during [select].
  ///
  /// [signedMultiplicand] generates a fixed signed selector versus using
  /// [selectSignedMultiplicand] which is a runtime sign selection [Logic]
  /// in which case [signedMultiplicand] must be false.
  MultiplicandSelector(this.radix, this.multiplicand,
      {Logic? selectSignedMultiplicand, bool signedMultiplicand = false})
      : shift = log2Ceil(radix) {
    if (signedMultiplicand && (selectSignedMultiplicand != null)) {
      throw RohdHclException('sign reconfiguration requires signed=false');
    }
    if (radix > 16) {
      throw RohdHclException('Radices beyond 16 are not yet supported');
    }
    final width = multiplicand.width + shift;
    final numMultiples = radix ~/ 2;
    multiples = LogicArray([numMultiples], width);
    final Logic extendedMultiplicand;
    if (selectSignedMultiplicand == null) {
      extendedMultiplicand = signedMultiplicand
          ? multiplicand.signExtend(width)
          : multiplicand.zeroExtend(width);
    } else {
      final len = multiplicand.width;
      final sign = multiplicand[len - 1];
      final extension = [
        for (var i = len; i < width; i++)
          mux(selectSignedMultiplicand, sign, Const(0))
      ];
      extendedMultiplicand = (multiplicand.elements + extension).rswizzle();
    }
    for (var pos = 0; pos < numMultiples; pos++) {
      final ratio = pos + 1;
      multiples.elements[pos] <=
          switch (ratio) {
            1 => extendedMultiplicand,
            2 => extendedMultiplicand << 1,
            3 => (extendedMultiplicand << 2) - extendedMultiplicand,
            4 => extendedMultiplicand << 2,
            5 => (extendedMultiplicand << 2) + extendedMultiplicand,
            6 => (extendedMultiplicand << 3) - (extendedMultiplicand << 1),
            7 => (extendedMultiplicand << 3) - extendedMultiplicand,
            8 => extendedMultiplicand << 3,
            _ => throw RohdHclException('Radix is beyond 16')
          };
    }
  }

  /// Retrieve the multiples of the multiplicand at current bit position
  Logic getMultiples(int col) => [
        for (var i = 0; i < multiples.elements.length; i++)
          multiples.elements[i][col]
      ].swizzle().reversed;

  Logic _select(Logic multiples, RadixEncode encode) =>
      (encode.multiples & multiples).or() ^ encode.sign;

  /// Select the partial product term from the multiples using a RadixEncode
  Logic select(int col, RadixEncode encode) =>
      _select(getMultiples(col), encode);
}
