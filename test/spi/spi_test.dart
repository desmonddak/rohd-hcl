// Copyright (C) 2024 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// spi_test.dart
// Tests for SPI interface
//
// 2024 September 23
// Author: Roberto Torres <roberto.torres@intel.com>

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:test/test.dart';

class SpiMainIntf extends Module {
  SpiMainIntf(SpiInterface intf, {super.name = 'SpiMainIntf'}) {
    intf = SpiInterface.clone(intf)
      ..pairConnectIO(this, intf, PairRole.provider);
  }
}

class SpiSubIntf extends Module {
  SpiSubIntf(SpiInterface intf, {super.name = 'SpiSubIntf'}) {
    intf = SpiInterface.clone(intf)
      ..pairConnectIO(this, intf, PairRole.consumer);
  }
}

class SpiTopIntf extends Module {
  SpiTopIntf({super.name = 'SpiTopIntf'}) {
    final intf = SpiInterface();
    SpiMainIntf(intf);
    SpiSubIntf(intf);
    addOutput('dummy') <= intf.sclk;
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('spi_test', () async {
    final mod = SpiTopIntf();
    await mod.build();
    final genSV = mod.generateSynth();
    expect(genSV, contains('input logic MOSI'));
  });
}
