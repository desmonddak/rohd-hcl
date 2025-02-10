// Copyright (C) 2024-2025 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// floating_point_value.dart
// Implementation of Floating-Point value representations.
//
// 2024 April 1
// Authors:
//  Max Korbel <max.korbel@intel.com>
//  Desmond A Kirkpatrick <desmond.a.kirkpatrick@intel.com

import 'dart:math';
import 'package:meta/meta.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

/// Critical threshold constants
enum FloatingPointConstants {
  /// smallest possible number
  negativeInfinity,

  /// The number zero, negative form
  negativeZero,

  /// The number zero, positive form
  positiveZero,

  /// Smallest possible number, most exponent negative, LSB set in mantissa
  smallestPositiveSubnormal,

  /// Largest possible subnormal, most negative exponent, mantissa all 1s
  largestPositiveSubnormal,

  /// Smallest possible positive number, most negative exponent, mantissa is 0
  smallestPositiveNormal,

  /// Largest number smaller than one
  largestLessThanOne,

  /// The number one
  one,

  /// Smallest number greater than one
  smallestLargerThanOne,

  /// Largest positive number, most positive exponent, full mantissa
  largestNormal,

  /// Largest possible number
  infinity,

  /// Not a Number, demarked by all 1s in exponent and any 1 in mantissa
  nan,
}

/// IEEE Floating Point Rounding Modes
enum FloatingPointRoundingMode {
  /// Truncate the result, no rounding
  truncate,

  /// Round to nearest, ties to even
  roundNearestEven,

  /// Round to nearest, tieas away from zero
  roundNearestTiesAway,

  /// Round toward zero
  roundTowardsZero,

  /// Round toward +infinity
  roundTowardsInfinity,

  /// Round toward -infinity
  roundTowardsNegativeInfinity
}

/// Filler function
typedef FillFPV = (LogicValue sign, LogicValue exponent, LogicValue mantissa)
    Function(FloatingPointValue fpv, int exponentWidth, int mantissaWidth);

/// Filler function
typedef FillFPVOnly = (
  LogicValue sign,
  LogicValue exponent,
  LogicValue mantissa
)
    Function(FloatingPointValue fpv);

/// A flexible representation of floating point values.
/// A [FloatingPointValue] hasa mantissa in [0,2) with
/// 0 <= exponent <= maxExponent();  A normal [isNormal] [FloatingPointValue]
/// has minExponent() <= exponent <= maxExponent() and a mantissa in the
/// range of [1,2).  Subnormal numbers are represented with a zero exponent
/// and leading zeros in the mantissa capture the negative exponent value.
@immutable
class FloatingPointValue implements Comparable<FloatingPointValue> {
  /// The full floating point value bit storage
  late final LogicValue value;

  /// The sign of the value:  1 means a negative value
  late final LogicValue sign;

  /// The exponent of the floating point: this is biased about a midpoint for
  /// positive and negative exponents
  late final LogicValue exponent;

  /// The mantissa of the floating point
  late final LogicValue mantissa;

  /// Return the exponent value representing the true zero exponent 2^0 = 1
  ///   often termed [computeBias] or the offset of the exponent
  static int computeBias(int exponentWidth) =>
      pow(2, exponentWidth - 1).toInt() - 1;

  /// Return the minimum exponent value
  static int computeMinExponent(int exponentWidth) =>
      -pow(2, exponentWidth - 1).toInt() + 2;

  /// Return the maximum exponent value
  static int computeMaxExponent(int exponentWidth) =>
      computeBias(exponentWidth);

  /// Return the bias of this [FloatingPointValue].
  int get bias => _bias;

  /// Return the maximum exponent of this [FloatingPointValue].
  int get maxExponent => _maxExp;

  /// Return the minimum exponent of this [FloatingPointValue].
  int get minExponent => _minExp;

  late final int _bias;
  late final int _maxExp;
  late final int _minExp;

  /// By default, this is populated with available subtypes from ROHD-HCL, but
  /// it can be overridden or extended based on the user's needs.

  /// Basic filling function
  /// Fill FPV with split LogicValues [sign], [exponent], and [mantissa].
  static FillFPV splitLogicFill(
          {required LogicValue sign,
          required LogicValue exponent,
          required LogicValue mantissa}) =>
      (fpv, exponentWidth, mantissaWidth) => (sign, exponent, mantissa);

  /// Fill FPV with split LogicValues [sign], [exponent], and [mantissa].
  /// This version does not require widths to be passed.
  static FillFPVOnly splitLogicFillOnly(
          {required LogicValue sign,
          required LogicValue exponent,
          required LogicValue mantissa}) =>
      (fpv) => (sign, exponent, mantissa);

  /// Fill FPV with a full LogicValue
  static FillFPV logicFill(LogicValue fullFPLogicValue) =>
      (fpv, exponentWidth, mantissaWidth) => (
            fullFPLogicValue[-1],
            fullFPLogicValue.slice(-2, -exponentWidth - 1),
            fullFPLogicValue.slice(mantissaWidth - 1, 0)
          );

  /// Use this for testing that we really are accessing the subclass methods
  String coolName() => 'baseFPV';

  /// Constructor for a [FloatingPointValue] with a sign, exponent, and
  /// mantissa.
  @protected
  FloatingPointValue(FillFPV fill, int exponentWidth, int mantissaWidth)
      : _bias = computeBias(exponentWidth),
        _minExp = computeMinExponent(exponentWidth),
        _maxExp = computeMaxExponent(exponentWidth) {
    final (a, b, c) = fill(this, exponentWidth, mantissaWidth);
    sign = a;
    if (sign.width != 1) {
      throw RohdHclException('FloatingPointValue: sign width must be 1');
    }
    exponent = b;
    mantissa = c;
    value = [sign, exponent, mantissa].swizzle();
  }

  /// Constructor that uses [fill] only to construct [FloatingPointValue] and
  /// populate its [sign], [exponent], and [mantissa].
  FloatingPointValue._fillOnly(FillFPVOnly fill) {
    final (sign, exponent, mantissa) = fill(this);
    _bias = computeBias(exponent.width);
    _minExp = computeMinExponent(exponent.width);
    _maxExp = computeMaxExponent(exponent.width);

    this.sign = sign;
    if (sign.width != 1) {
      throw RohdHclException('FloatingPointValue: sign width must be 1');
    }
    this.exponent = exponent;
    this.mantissa = mantissa;
    value = [sign, exponent, mantissa].swizzle();
  }

  /// Fill factory that constructs [FloatingPointValue] and calls a given
  /// [filler] to populate its [sign], [exponent], and [mantissa].
  factory FloatingPointValue.fill(
          FillFPV filler, int exponentWidth, int mantissaWidth) =>
      FloatingPointValue(filler, exponentWidth, mantissaWidth);

  /// Fill factory that constructs [FloatingPointValue] and calls a given
  /// [filler] to populate its [sign], [exponent], and [mantissa].  This
  /// type of filler has widths encoded somehow so the constructor
  /// does not need the widths passed directly.
  factory FloatingPointValue.fillOnly(FillFPVOnly filler) =>
      FloatingPointValue._fillOnly(filler);

  /// Construct a FloatingPointValue with a LogicValue
  factory FloatingPointValue.ofLogicValue(
          int exponentWidth, int mantissaWidth, LogicValue val) =>
      FloatingPointValue.fill(
          FloatingPointValue.logicFill(val), exponentWidth, mantissaWidth);

  /// [FloatingPointValue] fill routine from a binary string representation of
  /// individual bitfields
  static FillFPV fillBinaryStrings(
          String sign, String exponent, String mantissa) =>
      (fpv, exponentWidth, mantissaWidth) => (
            LogicValue.of(sign),
            LogicValue.of(exponent),
            LogicValue.of(mantissa)
          );

  /// [FloatingPointValue] fill routine from a binary string representation of
  /// individual bitfields
  static FillFPVOnly fillOnlyBinaryStrings(
          String sign, String exponent, String mantissa) =>
      (fpv) => (
            LogicValue.of(sign),
            LogicValue.of(exponent),
            LogicValue.of(mantissa)
          );

  /// [FloatingPointValue] constructor from a binary string representation of
  /// individual bitfields
  FloatingPointValue.ofBinaryStrings(
      String sign, String exponent, String mantissa)
      : this(
            splitLogicFill(
                sign: LogicValue.of(sign),
                exponent: LogicValue.of(exponent),
                mantissa: LogicValue.of(mantissa)),
            exponent.length,
            mantissa.length);

  /// [FloatingPointValue] fill routine from a single binary string representing
  /// space-separated bitfields
  static FillFPV fillSpacedBinaryString(String fp) =>
      fillBinaryStrings(fp.split(' ')[0], fp.split(' ')[1], fp.split(' ')[2]);

  /// [FloatingPointValue] constructor from a single binary string representing
  /// space-separated bitfields
  FloatingPointValue.ofSpacedBinaryString(String fp)
      : this.ofBinaryStrings(
            fp.split(' ')[0], fp.split(' ')[1], fp.split(' ')[2]);

  /// [FloatingPointValue] fill routine from a radix-encoded string
  /// representation and the size of the exponent and mantissa
  static FillFPV fillString(String fp, {int radix = 2}) {
    (LogicValue sign, LogicValue exponent, LogicValue mantissa) myFunction(
        FloatingPointValue fpv, int exponentWidth, int mantissaWidth) {
      final (sign: s, exponent: e, mantissa: m) =
          _extractBinaryStrings(fp, exponentWidth, mantissaWidth, radix);
      return (LogicValue.of(s), LogicValue.of(e), LogicValue.of(m));
    }

    return myFunction;
  }

  /// [FloatingPointValue] constructor from a radix-encoded string
  /// representation and the size of the exponent and mantissa
  FloatingPointValue.ofString(String fp, int exponentWidth, int mantissaWidth,
      {int radix = 2})
      : this.ofBinaryStrings(
            _extractBinaryStrings(fp, exponentWidth, mantissaWidth, radix).sign,
            _extractBinaryStrings(fp, exponentWidth, mantissaWidth, radix)
                .exponent,
            _extractBinaryStrings(fp, exponentWidth, mantissaWidth, radix)
                .mantissa);

  /// Helper function for extracting binary strings from a longer
  /// binary string and the known exponent and mantissa widths.
  static ({String sign, String exponent, String mantissa})
      _extractBinaryStrings(
          String fp, int exponentWidth, int mantissaWidth, int radix) {
    final binaryFp = LogicValue.ofBigInt(
            BigInt.parse(fp, radix: radix), exponentWidth + mantissaWidth + 1)
        .bitString;

    return (
      sign: binaryFp.substring(0, 1),
      exponent: binaryFp.substring(1, 1 + exponentWidth),
      mantissa: binaryFp.substring(
          1 + exponentWidth, 1 + exponentWidth + mantissaWidth)
    );
  }

  // TODO(desmonddak): toRadixString() would be useful, not limited to binary

  /// [FloatingPointValue] fill routine from a set of [BigInt]s of the binary
  /// representation and the size of the exponent and mantissa
  static FillFPV fillBigInts(BigInt exponent, BigInt mantissa,
          {int exponentWidth = 0, int mantissaWidth = 0, bool sign = false}) =>
      splitLogicFill(
          sign: LogicValue.ofBigInt(sign ? BigInt.one : BigInt.zero, 1),
          exponent: LogicValue.ofBigInt(exponent, exponentWidth),
          mantissa: LogicValue.ofBigInt(mantissa, mantissaWidth));

  /// [FloatingPointValue] constructor from a set of [BigInt]s of the binary
  /// representation and the size of the exponent and mantissa
  FloatingPointValue.ofBigInts(BigInt exponent, BigInt mantissa,
      {int exponentWidth = 0, int mantissaWidth = 0, bool sign = false})
      : this(
            splitLogicFill(
                sign: LogicValue.ofBigInt(sign ? BigInt.one : BigInt.zero, 1),
                exponent: LogicValue.ofBigInt(exponent, exponentWidth),
                mantissa: LogicValue.ofBigInt(mantissa, mantissaWidth)),
            exponentWidth,
            mantissaWidth);

  /// [FloatingPointValue] fill routine from a set of [int]s of the binary
  /// representation and the size of the exponent and mantissa
  static FillFPV fillInts(int exponent, int mantissa,
          {int exponentWidth = 0, int mantissaWidth = 0, bool sign = false}) =>
      splitLogicFill(
          sign: LogicValue.ofBigInt(sign ? BigInt.one : BigInt.zero, 1),
          exponent: LogicValue.ofBigInt(BigInt.from(exponent), exponentWidth),
          mantissa: LogicValue.ofBigInt(BigInt.from(mantissa), mantissaWidth));

  /// [FloatingPointValue] constructor from a set of [int]s of the binary
  /// representation and the size of the exponent and mantissa
  FloatingPointValue.ofInts(int exponent, int mantissa,
      {int exponentWidth = 0, int mantissaWidth = 0, bool sign = false})
      : this(
            splitLogicFill(
                sign: LogicValue.ofBigInt(sign ? BigInt.one : BigInt.zero, 1),
                exponent:
                    LogicValue.ofBigInt(BigInt.from(exponent), exponentWidth),
                mantissa:
                    LogicValue.ofBigInt(BigInt.from(mantissa), mantissaWidth)),
            exponentWidth,
            mantissaWidth);

  /// Construct a [FloatingPointValue] from a [LogicValue]
  // factory FloatingPointValue.ofLogicValue(
  //         int exponentWidth, int mantissaWidth, LogicValue val) =>
  //     buildOfLogicValue(
  //         FloatingPointValue.new, exponentWidth, mantissaWidth, val);

  // /// A helper function for [FloatingPointValue.ofLogicValue] and base classes
  // /// which performs some width checks and slicing.
  // @protected
  // static T buildOfLogicValue<T extends FloatingPointValue>(
  //   T Function(FillFullerFPV fn, int exponentWidth, int mantissaWidth)
  //       constructor,
  //   int exponentWidth,
  //   int mantissaWidth,
  //   LogicValue val,
  // ) {
  //   final expectedWidth = 1 + exponentWidth + mantissaWidth;
  //   if (val.width != expectedWidth) {
  //     throw RohdHclException('Width of $val must be $expectedWidth');
  //   }

  //   return constructor(
  //       splitLogicFill(
  //           sign: val[-1],
  //           exponent:
  //               val.slice(exponentWidth + mantissaWidth - 1, mantissaWidth),
  //           mantissa: val.slice(mantissaWidth - 1, 0)),
  //       exponentWidth,
  //       mantissaWidth);
  // }

  /// Abbreviation Functions for common constants

  /// Return the Infinity value for this FloatingPointValue size.
  FloatingPointValue get infinity =>
      FloatingPointValue.getFloatingPointConstant(
          FloatingPointConstants.infinity, exponent.width, mantissa.width);

  /// Return the Negative Infinity value for this FloatingPointValue size.
  FloatingPointValue get negativeInfinity =>
      FloatingPointValue.getFloatingPointConstant(
          FloatingPointConstants.negativeInfinity,
          exponent.width,
          mantissa.width);

  /// Return the Negative Infinity value for this FloatingPointValue size.
  FloatingPointValue get nan => FloatingPointValue.getFloatingPointConstant(
      FloatingPointConstants.nan, exponent.width, mantissa.width);

  /// Return the value one for this FloatingPointValue size.
  FloatingPointValue get one => FloatingPointValue.getFloatingPointConstant(
      FloatingPointConstants.one, exponent.width, mantissa.width);

  /// Return the Negative Infinity value for this FloatingPointValue size.
  FloatingPointValue get zero => FloatingPointValue.getFloatingPointConstant(
      FloatingPointConstants.positiveZero, exponent.width, mantissa.width);

  /// Fill the [FloatingPointValue] with the constant specified.
  static FillFPV fillConstant(FloatingPointConstants constantFloatingPoint) =>
      (fpv, exponentWidth, mantissaWidth) => unwrapFPV(
          FloatingPointValue.getFloatingPointConstant(
              constantFloatingPoint, exponentWidth, mantissaWidth));

  /// Break a [FloatingPointValue] into [sign], [exponent], [mantissa].
  static (LogicValue, LogicValue, LogicValue) unwrapFPV(
          FloatingPointValue fpv) =>
      (fpv.sign, fpv.exponent, fpv.mantissa);

  /// Return the [FloatingPointValue] representing the constant specified
  factory FloatingPointValue.getFloatingPointConstant(
      FloatingPointConstants constantFloatingPoint,
      int exponentWidth,
      int mantissaWidth) {
    switch (constantFloatingPoint) {
      /// smallest possible number
      case FloatingPointConstants.negativeInfinity:
        return FloatingPointValue.ofBinaryStrings(
            '1', '1' * exponentWidth, '0' * mantissaWidth);

      /// -0.0
      case FloatingPointConstants.negativeZero:
        return FloatingPointValue.ofBinaryStrings(
            '1', '0' * exponentWidth, '0' * mantissaWidth);

      /// 0.0
      case FloatingPointConstants.positiveZero:
        return FloatingPointValue.ofBinaryStrings(
            '0', '0' * exponentWidth, '0' * mantissaWidth);

      /// Smallest possible number, most exponent negative, LSB set in mantissa
      case FloatingPointConstants.smallestPositiveSubnormal:
        return FloatingPointValue.ofBinaryStrings(
            '0', '0' * exponentWidth, '${'0' * (mantissaWidth - 1)}1');

      /// Largest possible subnormal, most negative exponent, mantissa all 1s
      case FloatingPointConstants.largestPositiveSubnormal:
        return FloatingPointValue.ofBinaryStrings(
            '0', '0' * exponentWidth, '1' * mantissaWidth);

      /// Smallest possible positive number, most negative exponent, mantissa 0
      case FloatingPointConstants.smallestPositiveNormal:
        return FloatingPointValue.ofBinaryStrings(
            '0', '${'0' * (exponentWidth - 1)}1', '0' * mantissaWidth);

      /// Largest number smaller than one
      case FloatingPointConstants.largestLessThanOne:
        return FloatingPointValue.ofBinaryStrings(
            '0', '0${'1' * (exponentWidth - 2)}0', '1' * mantissaWidth);

      /// The number '1.0'
      case FloatingPointConstants.one:
        return FloatingPointValue.ofBinaryStrings(
            '0', '0${'1' * (exponentWidth - 1)}', '0' * mantissaWidth);

      /// Smallest number greater than one
      case FloatingPointConstants.smallestLargerThanOne:
        return FloatingPointValue.ofBinaryStrings('0',
            '0${'1' * (exponentWidth - 2)}0', '${'0' * (mantissaWidth - 1)}1');

      /// Largest positive number, most positive exponent, full mantissa
      case FloatingPointConstants.largestNormal:
        return FloatingPointValue.ofBinaryStrings(
            '0', '${'1' * (exponentWidth - 1)}0', '1' * mantissaWidth);

      /// Largest possible number
      case FloatingPointConstants.infinity:
        return FloatingPointValue.ofBinaryStrings(
            '0', '1' * exponentWidth, '0' * mantissaWidth);

      /// Not a Number (NaN)
      case FloatingPointConstants.nan:
        return FloatingPointValue.ofBinaryStrings(
            '0', '1' * exponentWidth, '${'0' * (mantissaWidth - 1)}1');
    }
  }

// TODO(desmonddak): we may have a bug in ofDouble() when
// the FPV is close to the width of the native double:  for LGRS to work
// we need three bits of space to handle the LSB|Guard|Round|Sticky.
// If the FPV is only 2 bits shorter than native, then we know we can round
// with LSB+Guard, but can't fit the round and sticky bits.
// The algorithm needs to extend with zeros and handle.

  /// Fill from double.
  static FillFPV fillDouble(double inDouble) =>
      (fpv, exponentWidth, mantissaWidth) => unwrapFPV(
          FloatingPointValue.ofDouble(inDouble,
              exponentWidth: exponentWidth, mantissaWidth: mantissaWidth));

  /// Convert from double.
  factory FloatingPointValue.ofDouble(double inDouble,
      {required int exponentWidth,
      required int mantissaWidth,
      FloatingPointRoundingMode roundingMode =
          FloatingPointRoundingMode.roundNearestEven}) {
    if ((exponentWidth == 8) && (mantissaWidth == 23)) {
      // TODO(desmonddak): handle rounding mode for 32 bit?
      return FloatingPoint32Value.ofDouble(inDouble);
    } else if ((exponentWidth == 11) && (mantissaWidth == 52)) {
      return FloatingPoint64Value.ofDouble(inDouble);
    }

    if (inDouble.isNaN) {
      return FloatingPointValue.getFloatingPointConstant(
          FloatingPointConstants.nan, exponentWidth, mantissaWidth);
    }
    if (inDouble.isInfinite) {
      return FloatingPointValue.getFloatingPointConstant(
          inDouble < 0.0
              ? FloatingPointConstants.negativeInfinity
              : FloatingPointConstants.infinity,
          exponentWidth,
          mantissaWidth);
    }

    if (roundingMode != FloatingPointRoundingMode.roundNearestEven &&
        roundingMode != FloatingPointRoundingMode.truncate) {
      throw UnimplementedError(
          'Only roundNearestEven or truncate is supported for this width');
    }

    final fp64 = FloatingPoint64Value.ofDouble(inDouble);
    final exponent64 = fp64.exponent;

    var expVal = (exponent64.toInt() - fp64.bias) +
        FloatingPointValue.computeBias(exponentWidth);
    // Handle subnormal
    final mantissa64 = [
      if (expVal <= 0)
        ([LogicValue.one, fp64.mantissa].swizzle() >>> -expVal).slice(52, 1)
      else
        fp64.mantissa
    ].first;
    var mantissa = mantissa64.slice(51, 51 - mantissaWidth + 1);

    // TODO(desmonddak): this should be in a separate function to use
    // with a FloatingPointValue converter we need.
    if (roundingMode == FloatingPointRoundingMode.roundNearestEven) {
      final sticky = mantissa64.slice(51 - (mantissaWidth + 2), 0).or();

      final roundPos = 51 - (mantissaWidth + 2) + 1;
      final round = mantissa64[roundPos];
      final guard = mantissa64[roundPos + 1];

      // RNE Rounding
      if (guard == LogicValue.one) {
        if ((round == LogicValue.one) |
            (sticky == LogicValue.one) |
            (mantissa[0] == LogicValue.one)) {
          mantissa += 1;
          if (mantissa == LogicValue.zero.zeroExtend(mantissa.width)) {
            expVal += 1;
          }
        }
      }
    }

    // TODO(desmonddak): how to convert to infinity and check that it is
    // supported by the format.
    if ((exponentWidth == 4) && (mantissaWidth == 3)) {
      // TODO(desmonddak): need a better way to detect subclass limitations
      // Here we avoid returning infinity for FP8E4M3
    } else {
      if (expVal >
          FloatingPointValue.computeBias(exponentWidth) +
              FloatingPointValue.computeMaxExponent(exponentWidth)) {
        return (fp64.sign == LogicValue.one)
            ? FloatingPointValue.getFloatingPointConstant(
                FloatingPointConstants.negativeInfinity,
                exponentWidth,
                mantissaWidth)
            : FloatingPointValue.getFloatingPointConstant(
                FloatingPointConstants.infinity, exponentWidth, mantissaWidth);
      }
    }
    final exponent =
        LogicValue.ofBigInt(BigInt.from(max(expVal, 0)), exponentWidth);

    return FloatingPointValue(
        splitLogicFill(sign: fp64.sign, exponent: exponent, mantissa: mantissa),
        exponent.width,
        mantissa.width);
  }

  /// Generate random fill value for [FloatingPointValue],
  /// supplying random seed [rv].
  /// This generates a valid [FloatingPointValue] anywhere in the range
  /// it can represent:a general [FloatingPointValue] has
  /// a mantissa in [0,2) with 0 <= exponent <= maxExponent();
  /// If [normal] is true, This routine will only generate mantissas in the
  /// range of [1,2) and minExponent() <= exponent <= maxExponent().
  static FillFPV fillRandom(Random rv, {bool normal = false}) =>
      (fpv, exponentWidth, mantissaWidth) => unwrapFPV(
          FloatingPointValue.random(rv,
              exponentWidth: exponentWidth, mantissaWidth: mantissaWidth));

  /// Generate a random [FloatingPointValue], supplying random seed [rv].
  /// This generates a valid [FloatingPointValue] anywhere in the range
  /// it can represent:a general [FloatingPointValue] has
  /// a mantissa in [0,2) with 0 <= exponent <= maxExponent();
  /// If [normal] is true, This routine will only generate mantissas in the
  /// range of [1,2) and minExponent() <= exponent <= maxExponent().
  factory FloatingPointValue.random(Random rv,
      {required int exponentWidth,
      required int mantissaWidth,
      bool normal = false}) {
    final largestExponent = FloatingPointValue.computeBias(exponentWidth) +
        FloatingPointValue.computeMaxExponent(exponentWidth);
    final s = rv.nextLogicValue(width: 1).toInt();
    var e = BigInt.one;
    do {
      e = rv
          .nextLogicValue(width: exponentWidth, max: largestExponent)
          .toBigInt();
    } while ((e == BigInt.zero) & normal);
    final m = rv.nextLogicValue(width: mantissaWidth).toBigInt();
    return FloatingPointValue(
        splitLogicFill(
            sign: LogicValue.ofInt(s, 1),
            exponent: LogicValue.ofBigInt(e, exponentWidth),
            mantissa: LogicValue.ofBigInt(m, mantissaWidth)),
        exponentWidth,
        mantissaWidth);
  }

  /// Fill a floating point number into a [FloatingPointValue]
  /// representation. This form performs NO ROUNDING.
  static FillFPV fillDoubleUnrounded(double inDouble) =>
      (fpv, exponentWidth, mantissaWidth) => unwrapFPV(
          FloatingPointValue.ofDoubleUnrounded(inDouble,
              exponentWidth: exponentWidth, mantissaWidth: mantissaWidth));

  /// Convert a floating point number into a [FloatingPointValue]
  /// representation. This form performs NO ROUNDING.
  @internal
  factory FloatingPointValue.ofDoubleUnrounded(double inDouble,
      {required int exponentWidth, required int mantissaWidth}) {
    if ((exponentWidth == 8) && (mantissaWidth == 23)) {
      return FloatingPoint32Value.ofDouble(inDouble);
    } else if ((exponentWidth == 11) && (mantissaWidth == 52)) {
      return FloatingPoint64Value.ofDouble(inDouble);
    }
    if (inDouble.isNaN) {
      return FloatingPointValue.getFloatingPointConstant(
          FloatingPointConstants.nan, exponentWidth, mantissaWidth);
    }

    var doubleVal = inDouble;
    LogicValue sign;
    if (inDouble < 0.0) {
      doubleVal = -doubleVal;
      sign = LogicValue.one;
    } else {
      sign = LogicValue.zero;
    }
    if (inDouble.isInfinite) {
      return FloatingPointValue.getFloatingPointConstant(
          sign.toBool()
              ? FloatingPointConstants.negativeInfinity
              : FloatingPointConstants.infinity,
          exponentWidth,
          mantissaWidth);
    }

    // If we are dealing with a really small number we need to scale it up
    var scaleToWhole = (doubleVal != 0) ? (-log(doubleVal) / log(2)).ceil() : 0;

    if (doubleVal < 1.0) {
      var myCnt = 0;
      var myVal = doubleVal;
      while (myVal % 1 != 0.0) {
        myVal = myVal * 2.0;
        myCnt++;
      }
      if (myCnt < scaleToWhole) {
        scaleToWhole = myCnt;
      }
    }

    // Scale it up to go beyond the mantissa and include the GRS bits
    final scale = mantissaWidth + scaleToWhole;
    var s = scale;

    var sVal = doubleVal;
    if (s > 0) {
      while (s > 0) {
        sVal *= 2.0;
        s = s - 1;
      }
    } else {
      sVal = doubleVal * pow(2.0, scale);
    }

    final scaledValue = BigInt.from(sVal);
    final fullLength = scaledValue.bitLength;

    var fullValue = LogicValue.ofBigInt(scaledValue, fullLength);
    var e = (fullLength > 0)
        ? fullLength - mantissaWidth - scaleToWhole
        : FloatingPointValue.computeMinExponent(exponentWidth);

    if (e > FloatingPointValue.computeMaxExponent(exponentWidth) + 1) {
      return FloatingPointValue.getFloatingPointConstant(
          sign.toBool()
              ? FloatingPointConstants.negativeInfinity
              : FloatingPointConstants.infinity,
          exponentWidth,
          mantissaWidth);
    }

    if (e <= -FloatingPointValue.computeBias(exponentWidth)) {
      fullValue = fullValue >>>
          (scaleToWhole - FloatingPointValue.computeBias(exponentWidth));
      e = -FloatingPointValue.computeBias(exponentWidth);
    } else {
      // Could be just one away from subnormal
      e -= 1;
      if (e > -FloatingPointValue.computeBias(exponentWidth)) {
        fullValue = fullValue << 1; // Chop the first '1'
      }
    }
    // We reverse so that we fit into a shorter BigInt, we keep the MSB.
    // The conversion fills leftward.
    // We reverse again after conversion.
    final exponent = LogicValue.ofInt(
        e + FloatingPointValue.computeBias(exponentWidth), exponentWidth);
    final mantissa =
        LogicValue.ofBigInt(fullValue.reversed.toBigInt(), mantissaWidth)
            .reversed;

    return FloatingPointValue(
        splitLogicFill(exponent: exponent, mantissa: mantissa, sign: sign),
        exponent.width,
        mantissa.width);
  }

  @override
  int get hashCode => sign.hashCode ^ exponent.hashCode ^ mantissa.hashCode;

  /// Floating point comparison to implement Comparable<>
  @override
  int compareTo(Object other) {
    if (other is! FloatingPointValue) {
      throw Exception('Input must be of type FloatingPointValue ');
    }
    if ((exponent.width != other.exponent.width) |
        (mantissa.width != other.mantissa.width)) {
      throw Exception('FloatingPointValue widths must match for comparison');
    }
    final signCompare = sign.compareTo(other.sign);
    final expCompare = exponent.compareTo(other.exponent);
    final mantCompare = mantissa.compareTo(other.mantissa);
    if ((signCompare != 0) && !(exponent.isZero && mantissa.isZero)) {
      return signCompare;
    }
    if (expCompare != 0) {
      return sign.isZero ? expCompare : -expCompare;
    } else if (mantCompare != 0) {
      return sign.isZero ? mantCompare : -mantCompare;
    }
    return 0;
  }

  @override
  bool operator ==(Object other) {
    if (other is! FloatingPointValue) {
      return false;
    }
    if ((exponent.width != other.exponent.width) |
        (mantissa.width != other.mantissa.width)) {
      return false;
    }
    if (isNaN != other.isNaN) {
      return false;
    }
    if (isAnInfinity != other.isAnInfinity) {
      return false;
    }
    if (isAnInfinity) {
      return sign == other.sign;
    }
    // IEEE 754: -0 an +0 are considered equal
    if ((exponent.isZero && mantissa.isZero) &&
        (other.exponent.isZero && other.mantissa.isZero)) {
      return true;
    }
    return (sign == other.sign) &
        (exponent == other.exponent) &
        (mantissa == other.mantissa);
  }

  /// Test if exponent is all '1's.
  bool get isExponentAllOnes => exponent.and() == LogicValue.one;

  /// Test if exponent is all '0's.
  bool get isExponentAllZeros => exponent.or() == LogicValue.zero;

  /// Test if mantissa is all '0's.
  bool get isMantissaAllZeroes => mantissa.or() == LogicValue.zero;

  /// Return true if the represented floating point number is considered
  ///  NaN or 'Not a Number'
  bool get isNaN => isExponentAllOnes && !isMantissaAllZeroes;

  /// Return true if the represented floating point number is considered
  ///  'subnormal', including [isZero].
  bool isSubnormal() => isExponentAllZeros;

  /// Return true if the represented floating point number is considered
  ///  infinity or negative infinity
  bool get isAnInfinity => isExponentAllOnes && isMantissaAllZeroes;

  /// Return true if the represented floating point number is zero. Note
  /// that the equality operator will treat
  /// [FloatingPointConstants.positiveZero]
  /// and [FloatingPointConstants.negativeZero] as equal.
  bool get isZero =>
      this ==
      FloatingPointValue.getFloatingPointConstant(
          FloatingPointConstants.positiveZero, exponent.width, mantissa.width);

  /// Return the value of the floating point number in a Dart [double] type.
  double toDouble() {
    if (isNaN) {
      return double.nan;
    }
    if (isAnInfinity) {
      return sign.isZero ? double.infinity : double.negativeInfinity;
    }
    var doubleVal = double.nan;
    if (value.isValid) {
      if (exponent.toInt() == 0) {
        doubleVal = (sign.toBool() ? -1.0 : 1.0) *
            pow(2.0, computeMinExponent(exponent.width)) *
            mantissa.toBigInt().toDouble() /
            pow(2.0, mantissa.width);
      } else if (!isNaN) {
        doubleVal = (sign.toBool() ? -1.0 : 1.0) *
            (1.0 + mantissa.toBigInt().toDouble() / pow(2.0, mantissa.width)) *
            pow(
                2.0,
                exponent.toInt().toSigned(exponent.width) -
                    computeBias(exponent.width));
        doubleVal = (sign.toBool() ? -1.0 : 1.0) *
            (1.0 + mantissa.toBigInt().toDouble() / pow(2.0, mantissa.width)) *
            pow(2.0, exponent.toInt() - computeBias(exponent.width));
      }
    }
    return doubleVal;
  }

  /// Return a Logic true if this FloatingPointVa;ie contains a normal number,
  /// defined as having mantissa in the range [1,2)
  bool isNormal() => exponent != LogicValue.ofInt(0, exponent.width);

  /// Return a string representation of FloatingPointValue.
  /// if [integer] is true, return sign, exponent, mantissa as integers.
  /// if [integer] is false, return sign, exponent, mantissa as ibinary strings.
  @override
  String toString({bool integer = false}) {
    if (integer) {
      return '(${sign.toInt()}'
          ' ${exponent.toInt()}'
          ' ${mantissa.toInt()})';
    } else {
      return '${sign.toString(includeWidth: false)}'
          ' ${exponent.toString(includeWidth: false)}'
          ' ${mantissa.toString(includeWidth: false)}';
    }
  }

  // TODO(desmonddak): what about floating point representations >> 64 bits?
  FloatingPointValue _performOp(
      FloatingPointValue other, double Function(double a, double b) op) {
    // make sure multiplicand has the same sizes as this
    if (mantissa.width != other.mantissa.width ||
        exponent.width != other.exponent.width) {
      throw RohdHclException('FloatingPointValue: '
          'multiplicand must have the same mantissa and exponent widths');
    }
    if (isNaN | other.isNaN) {
      return FloatingPointValue.getFloatingPointConstant(
          FloatingPointConstants.nan, exponent.width, mantissa.width);
    }

    return FloatingPointValue.ofDouble(op(toDouble(), other.toDouble()),
        mantissaWidth: mantissa.width, exponentWidth: exponent.width);
  }

  /// Multiply operation for [FloatingPointValue]
  FloatingPointValue operator *(FloatingPointValue multiplicand) {
    if (isAnInfinity) {
      if (multiplicand.isAnInfinity) {
        return sign != multiplicand.sign ? negativeInfinity : infinity;
      } else if (multiplicand.isZero) {
        return nan;
      } else {
        return this;
      }
    } else if (multiplicand.isAnInfinity) {
      if (isZero) {
        return nan;
      } else {
        return multiplicand;
      }
    }
    return _performOp(multiplicand, (a, b) => a * b);
  }

  /// Addition operation for [FloatingPointValue]
  FloatingPointValue operator +(FloatingPointValue addend) {
    if (isAnInfinity) {
      if (addend.isAnInfinity) {
        if (sign != addend.sign) {
          return nan;
        } else {
          return sign.toBool() ? negativeInfinity : infinity;
        }
      } else {
        return this;
      }
    } else if (addend.isAnInfinity) {
      return addend;
    }
    return _performOp(addend, (a, b) => a + b);
  }

  /// Divide operation for [FloatingPointValue]
  FloatingPointValue operator /(FloatingPointValue divisor) {
    if (isAnInfinity) {
      if (divisor.isAnInfinity | divisor.isZero) {
        return nan;
      } else {
        return this;
      }
    } else {
      if (divisor.isZero) {
        return sign != divisor.sign ? negativeInfinity : infinity;
      }
    }
    return _performOp(divisor, (a, b) => a / b);
  }

  /// Subtract operation for [FloatingPointValue]
  FloatingPointValue operator -(FloatingPointValue subend) {
    if (isAnInfinity & subend.isAnInfinity) {
      if (sign == subend.sign) {
        return nan;
      } else {
        return this;
      }
    } else if (subend.isAnInfinity) {
      return subend.negate();
    } else if (isAnInfinity) {
      return this;
    }
    return _performOp(subend, (a, b) => a - b);
  }

  /// Negate operation for [FloatingPointValue]
  FloatingPointValue negate() => FloatingPointValue(
      splitLogicFill(
          sign: sign.isZero ? LogicValue.one : LogicValue.zero,
          exponent: exponent,
          mantissa: mantissa),
      exponent.width,
      mantissa.width);

  /// Absolute value operation for [FloatingPointValue]
  FloatingPointValue abs() => FloatingPointValue(
      splitLogicFill(
          sign: LogicValue.zero, exponent: exponent, mantissa: mantissa),
      exponent.width,
      mantissa.width);

  /// Return true if the other [FloatingPointValue] is within a rounding
  /// error of this value.
  bool withinRounding(FloatingPointValue other) {
    if (this != other) {
      final diff = (abs() - other.abs()).abs();
      if (diff.compareTo(ulp()) == 1) {
        return false;
      }
    }
    return true;
  }

  /// Compute the unit in the last place for the given [FloatingPointValue]
  FloatingPointValue ulp() {
    if (exponent.toInt() > mantissa.width) {
      final newExponent =
          LogicValue.ofInt(exponent.toInt() - mantissa.width, exponent.width);
      return FloatingPointValue.ofBinaryStrings(
          sign.bitString, newExponent.bitString, '0' * (mantissa.width));
    } else {
      return FloatingPointValue.ofBinaryStrings(
          sign.bitString, exponent.bitString, '${'0' * (mantissa.width - 1)}1');
    }
  }
}
