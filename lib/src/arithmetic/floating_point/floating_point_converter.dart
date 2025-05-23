// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// floating_point_converter.dart
// A Floating-point to floating-point arbitrary width converter.
//
// 2025 January 28 2025
// Author: Desmond A. Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:math';

import 'package:meta/meta.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

/// A converter module for FloatingPoint values
class FloatingPointConverter extends Module {
  /// Source exponent width
  final int sourceExponentWidth;

  /// Source mantissa width
  final int sourceMantissaWidth;

  /// Destination exponent width
  late final int destExponentWidth;

  /// Destination mantissa width
  late final int destMantissaWidth;

  /// Output [FloatingPoint] computed
  late final FloatingPoint destination = FloatingPoint(
      exponentWidth: destExponentWidth,
      mantissaWidth: destMantissaWidth,
      name: 'dest')
    ..gets(output('destination'));

  /// The result of [FloatingPoint] conversion
  @protected
  late final FloatingPoint _destination = FloatingPoint(
      exponentWidth: destExponentWidth,
      mantissaWidth: destMantissaWidth,
      name: 'dest');

  /// Convert a [FloatingPoint] logic structure from one format to another.
  /// - [source] is the source format [FloatingPoint] logic structure.
  /// - [destination] is the destination format [FloatingPoint] logic
  /// structure.
  /// - [priorityGen] is a [PriorityEncoder] generator to be used in the
  /// leading one detection (default [RecursiveModulePriorityEncoder]).
  /// - [adderGen] can specify the [Adder] to use for exponent calculations.
  FloatingPointConverter(FloatingPoint source, FloatingPoint destination,
      {PriorityEncoder Function(Logic bitVector, {Logic? valid, String name})
          priorityGen = RecursiveModulePriorityEncoder.new,
      Adder Function(Logic a, Logic b, {Logic? carryIn}) adderGen =
          NativeAdder.new,
      super.name})
      : sourceExponentWidth = source.exponent.width,
        sourceMantissaWidth = source.mantissa.width,
        super(
            definitionName: 'FloatingPointConverter_${source.runtimeType}_'
                '${destination.runtimeType}') {
    destExponentWidth = destination.exponent.width;
    destMantissaWidth = destination.mantissa.width;
    source = source.clone(name: 'source')
      ..gets(addInput('source', source, width: source.width));
    addOutput('destination', width: _destination.width) <= _destination;
    destination <= output('destination');

    // maxExpWidth: mantissa +2:
    //     1 for the hidden jbit and 1 for going past with leadingOneDetect
    final maxExpWidth = [
      source.exponent.width,
      destExponentWidth,
      log2Ceil(source.mantissa.width + 2),
      log2Ceil(destMantissaWidth + 2)
    ].reduce(max);
    final sBias = source.bias.zeroExtend(maxExpWidth).named('sourceBias');
    final dBias = destination.bias.zeroExtend(maxExpWidth).named('destBias');
    final se = source.exponent.zeroExtend(maxExpWidth).named('sourceExp');
    final mantissa =
        [source.isNormal, source.mantissa].swizzle().named('mantissa');

    final nan = source.isNaN;
    final Logic infinity;
    final Logic destExponent;
    final Logic destMantissa;
    if (destExponentWidth >= source.exponent.width) {
      // Narrow to Wide
      infinity = source.isAnInfinity;
      final biasDiff = (dBias - sBias).named('biasDiff');
      final predictExp = (se + biasDiff).named('predictExp');

      final leadOneValid = Logic(name: 'leadOne_valid');
      final leadOnePre = priorityGen(mantissa.reversed,
              valid: leadOneValid, name: 'lead_one_encoder')
          .out;
      final leadOne =
          mux(leadOneValid, leadOnePre.zeroExtend(biasDiff.width), biasDiff)
              .named('leadOne');

      final predictSub = mux(
              biasDiff.gte(leadOne) & leadOneValid,
              biasDiff - (leadOne - Const(1, width: leadOne.width)),
              Const(0, width: biasDiff.width))
          .named('predictSubExp');

      final shift =
          mux(biasDiff.gte(leadOne), leadOne, biasDiff).named('shift');

      final newMantissa = (mantissa << shift).named('mantissaShift');

      final Logic roundedMantissa;
      final Logic roundIncExp;
      if (destMantissaWidth < source.mantissa.width) {
        final rounder =
            RoundRNE(newMantissa, source.mantissa.width - destMantissaWidth);

        final roundAdder = adderGen(
            newMantissa.reversed.getRange(1, destMantissaWidth + 1).reversed,
            rounder.doRound.zeroExtend(destMantissaWidth));
        roundedMantissa = roundAdder.sum
            .named('roundedMantissa')
            .getRange(0, destMantissaWidth);
        roundIncExp = roundAdder.sum[-1];
      } else {
        roundedMantissa = newMantissa;
        roundIncExp = Const(0);
      }

      destMantissa = ((destMantissaWidth >= source.mantissa.width)
              ? [
                  newMantissa.slice(-2, 0),
                  Const(0, width: destMantissaWidth - newMantissa.width + 1)
                ].swizzle().named('clippedMantissa')
              : roundedMantissa)
          .named('destMantissa');

      final preExponent =
          mux(shift.gt(Const(0, width: shift.width)), predictSub, predictExp)
                  .named('unRndDestExponent') +
              roundIncExp.zeroExtend(predictSub.width).named('rndIncExp');
      destExponent =
          preExponent.getRange(0, destExponentWidth).named('destExponent');
    } else {
      // Wide to Narrow exponent
      final biasDiff = (sBias - dBias).named('biasDiff');
      final predictE = mux(biasDiff.gte(se), Const(0, width: biasDiff.width),
              (se - biasDiff).named('sourceRebiased'))
          .named('predictExponent');

      final shift = mux(
          biasDiff.gte(se),
          (source.isNormal.zeroExtend(biasDiff.width).named('srcIsNormal') +
                  (biasDiff - se).named('negSourceRebiased'))
              .named('shiftSubnormal'),
          Const(0, width: biasDiff.width));

      final fullMantissa = [mantissa, Const(0, width: destMantissaWidth + 2)]
          .swizzle()
          .named('fullMantissa');

      final shiftMantissa = (fullMantissa >>> shift).named('shiftMantissa');
      final rounder =
          RoundRNE(shiftMantissa, fullMantissa.width - destMantissaWidth - 1);

      final postPredRndMantissa = shiftMantissa
          .slice(-2, shiftMantissa.width - destMantissaWidth - 1)
          .named('preRndMantissa');

      final roundAdder = adderGen(
          postPredRndMantissa,
          [Const(0, width: destMantissaWidth - 1), rounder.doRound]
              .swizzle()
              .named('rndIncrement'));
      final roundIncExp = roundAdder.sum[-1];
      final roundedMantissa = roundAdder.sum.getRange(0, destMantissaWidth);

      destExponent = (predictE + roundIncExp.zeroExtend(predictE.width))
          .named('predictExpRounded')
          .getRange(0, destExponentWidth);
      destMantissa =
          roundedMantissa.getRange(0, destMantissaWidth).named('destMantissa');

      final maxDestExp = Const(
          destination.floatingPointValue.maxExponent +
              destination.floatingPointValue.bias,
          width: maxExpWidth);

      infinity = source.isAnInfinity |
          (se.gt(biasDiff) & (se - biasDiff).gt(maxDestExp));
    }
    Combinational([
      If.block([
        Iff(nan, [
          _destination <
              FloatingPoint(
                      exponentWidth: destExponentWidth,
                      mantissaWidth: destMantissaWidth)
                  .nan,
        ]),
        ElseIf(infinity, [
          _destination <
              FloatingPoint(
                      exponentWidth: destExponentWidth,
                      mantissaWidth: destMantissaWidth)
                  .inf(sign: source.sign),
        ]),
        ElseIf(Const(1), [
          _destination.sign < source.sign,
          _destination.exponent < destExponent,
          _destination.mantissa < destMantissa,
        ]),
      ]),
    ]);
  }
}
