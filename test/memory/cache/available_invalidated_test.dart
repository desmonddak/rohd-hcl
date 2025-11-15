// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// available_invalidated_test.dart
// Basic tests for the AvailableInvalidatedReplacement ReplacementPolicy
//
// 2025 November 14
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:rohd_vf/rohd_vf.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('availableInvalidated alloc/invalidate behavior', () async {
    final clk = SimpleClockGenerator(5).clk;
    final reset = Logic();

    const ways = 4;

    final allocs =
        List<AccessInterface>.generate(2, (i) => AccessInterface(ways));
    final invals =
        List<AccessInterface>.generate(2, (i) => AccessInterface(ways));
    final hits =
        List<AccessInterface>.generate(1, (i) => AccessInterface(ways));

    final policy = AvailableInvalidatedReplacement(
        clk, reset, hits, allocs, invals,
        ways: ways);
    await policy.build();
    unawaited(Simulator.run());

    // reset
    reset.inject(0);
    for (final a in [...allocs, ...invals]) {
      a.access.inject(0);
      a.way.inject(0);
    }
    await clk.waitCycles(2);
    reset.inject(1);
    await clk.nextPosedge;
    reset.inject(0);

    // At start all ways are invalid/available. Issue sequential allocs and
    // ensure returned ways are unique until ways exhausted.
    final chosen = <int>{};
    for (var i = 0; i < ways; i++) {
      final a = allocs[i % allocs.length];
      a.access.inject(1);
      await clk.nextPosedge;
      a.access.inject(0);
      final v = a.way.value.toInt();
      expect(!chosen.contains(v), true, reason: 'way $v repeated');
      chosen.add(v);
    }

    // Now invalidate one chosen way and allocate again; should be available
    final inval = invals[0];
    inval.access.inject(1);
    inval.way.inject(chosen.first);
    await clk.nextPosedge;
    inval.access.inject(0);

    // Next alloc should return the invalidated way (it may be the lowest
    // available according to policy)
    final a2 = allocs[0];
    a2.access.inject(1);
    await clk.nextPosedge;
    a2.access.inject(0);
    final v2 = a2.way.value.toInt();
    expect(chosen.contains(v2), true,
        reason: 'alloc did not return invalidated way');

    await Simulator.endSimulation();
  });
}
