// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// floating_point_value.dart
// Implementation of Floating-Point value representations.
//
// 2025 February 20
// Author:
//  Desmond A Kirkpatrick <desmond.a.kirkpatrick@intel.com

import 'package:meta/meta.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
export 'floating_point_value.dart';

// TODO(desmonddak):  FP constants, convert to FVP and validate,
// unrounded conversion
// what to do about rounding?  rounding adder?

/// A populator for [FloatingPointExplicitJBitValue]s, a utility that can
/// populate various forms of [FloatingPointExplicitJBitValue]s.
class FloatingPointExplicitJBitPopulator
    extends FloatingPointValuePopulator<FloatingPointExplicitJBitValue> {
  /// Creates a [FloatingPointValuePopulator] for the given [_unpopulated]
  /// [FloatingPointExplicitJBitValue].
  FloatingPointExplicitJBitPopulator(super._unpopulated);
}

/// A flexible representation of floating point values. A
/// [FloatingPointExplicitJBitValue]is an explicit j-bit form of
/// [FloatingPointValue] where all numbers are represented with an explicit
/// leading 1 (except for zero).
@immutable
class FloatingPointExplicitJBitValue extends FloatingPointValue {
  /// Creates a [FloatingPointValuePopulator] for the same type as `this` and
  /// with the same widths.
  ///
  /// This must be overridden in subclasses so that the correct type of
  /// [FloatingPointValuePopulator] is returned for generating equivalent types
  /// of [FloatingPointValue]s.
  @override
  FloatingPointExplicitJBitPopulator clonePopulator() =>
      FloatingPointExplicitJBitPopulator(
          FloatingPointExplicitJBitValue.uninitialized());

  /// Constructor for a [FloatingPointValue] with the provided [sign],
  /// [exponent], and [mantissa].
  factory FloatingPointExplicitJBitValue(
          {required LogicValue sign,
          required LogicValue exponent,
          required LogicValue mantissa}) =>
      populator(exponentWidth: exponent.width, mantissaWidth: mantissa.width)
          .populate(sign: sign, exponent: exponent, mantissa: mantissa);

  /// Creates an unpopulated version of a [FloatingPointExplicitJBitValue],
  /// intended to be called with the [populator].
  // @protected
  FloatingPointExplicitJBitValue.uninitialized() : super.uninitialized();

  /// Creates a [FloatingPointExplicitJBitPopulator] with the provided
  /// [exponentWidth] and [mantissaWidth], which can then be used to
  /// complete construction of a [FloatingPointExplicitJBitValue] using
  /// population functions.
  static FloatingPointExplicitJBitPopulator populator(
          {required int exponentWidth, required int mantissaWidth}) =>
      FloatingPointExplicitJBitPopulator(
          FloatingPointExplicitJBitValue.uninitialized()
            ..storedExponentWidth = exponentWidth
            ..storedMantissaWidth = mantissaWidth);

  /// A wrapper around [FloatingPointValuePopulator.ofBinaryStrings] that
  /// computes the widths of the exponent and mantissa from the input string.
  factory FloatingPointExplicitJBitValue.ofBinaryStrings(
          String sign, String exponent, String mantissa) =>
      populator(exponentWidth: exponent.length, mantissaWidth: mantissa.length)
          .ofBinaryStrings(sign, exponent, mantissa);

  /// Return true if the JBit is implicitly represented.
  @override
  bool get implicitJBit => false;

  /// Return the normalized form of [FloatingPointExplicitJBitValue] which has
  /// the leading 1 at the front of the mantissa, or further right if subnormal.
  FloatingPointExplicitJBitValue normalized() {
    var expVal = exponent.toInt();
    var mant = mantissa;
    var sgn = sign;
    if (!isAnInfinity) {
      if (!isNaN) {
        if (mant.or() == LogicValue.one) {
          while ((mant[-1] == LogicValue.zero) & (expVal > 0)) {
            expVal--;
            mant = mant << 1;
          }
        } else {
          expVal = 0;
        }
      } else {
        mant = LogicValue.ofInt(1, exponentWidth);
        sgn = LogicValue.zero;
      }
    }
    return FloatingPointExplicitJBitValue(
        sign: sgn,
        exponent: LogicValue.ofInt(expVal, exponentWidth),
        mantissa: mant);
  }
}
