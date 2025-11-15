// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// available_invalidated_stress_test.dart
// Stress tests for the AvailableInvalidatedReplacement ReplacementPolicy
//
// 2025 November 14
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:async';
import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:rohd_vf/rohd_vf.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('availableInvalidated randomized stress test', () async {
    final clk = SimpleClockGenerator(3).clk;
    final reset = Logic();

    const ways = 8;
    final rng = Random(1234);

    // Use multiple alloc sources to test multi-alloc arbitration.
    final allocs =
        List<AccessInterface>.generate(4, (i) => AccessInterface(ways));
    final invals =
        List<AccessInterface>.generate(4, (i) => AccessInterface(ways));
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

    // Track the set of currently allocated ways (should not exceed ways-1)
    final allocated = <int>{};

    // We'll run many randomized operations while ensuring the invariant:
    // (#allocations outstanding) - (#invalidates outstanding) < ways
    const iterations = 200;
    for (var it = 0; it < iterations; it++) {
      // Decide whether to do an alloc or invalidate; prefer allocs when
      // allocated set size is small.
      final doAlloc = rng.nextBool();

      if (doAlloc && allocated.length < ways) {
        // Randomly decide how many allocs to assert simultaneously (1..3) limit
        // simultaneous allocs so we never request more than remaining slots
        final maxAllowed = ways - allocated.length;
        if (maxAllowed <= 0) {
          // cannot allocate now
          await clk.nextPosedge;
          continue;
        }
        var numAllocs = 1 + rng.nextInt(3);
        if (numAllocs > maxAllowed) {
          numAllocs = maxAllowed;
        }
        // pick distinct alloc ports (sample without replacement)
        final indices = List<int>.generate(allocs.length, (i) => i)
          ..shuffle(rng);
        final activeAllocs = <AccessInterface>[];
        for (var k = 0; k < numAllocs && k < indices.length; k++) {
          activeAllocs.add(allocs[indices[k]]);
        }

        // Assert access on all selected allocs in the same cycle
        for (final a in activeAllocs) {
          a.access.inject(1);
        }
        await clk.nextPosedge;

        // Deassert accesses and wait for flops to latch
        for (final a in activeAllocs) {
          a.access.inject(0);
        }
        await clk.nextPosedge;
        await clk.nextPosedge; // let combinational outputs and flops settle

        // Collect chosen ways and ensure they are distinct and not already
        // allocated
        final chosenSet = <int>{};
        for (final a in activeAllocs) {
          final chosen = a.way.value.toInt();
          expect(!allocated.contains(chosen), true,
              reason: 'Allocated chosen already-allocated way $chosen');
          expect(!chosenSet.contains(chosen), true,
              reason:
                  'Duplicate allocation among simultaneous allocs way $chosen');
          chosenSet.add(chosen);
        }
        allocated.addAll(chosenSet);

        // Occasionally perform an invalidate to keep invariant
        if (rng.nextDouble() < 0.4 && allocated.isNotEmpty) {
          final inv = invals[rng.nextInt(invals.length)];
          final toInv = allocated.elementAt(rng.nextInt(allocated.length));
          inv.way.inject(toInv);
          inv.access.inject(1);
          await clk.nextPosedge;
          inv.access.inject(0);
          await clk.nextPosedge; // let flops update
          allocated.remove(toInv);
        }
      } else {
        // Perform an invalidate of a random allocated way if any
        if (allocated.isNotEmpty) {
          final inv = invals[rng.nextInt(invals.length)];
          final toInv = allocated.elementAt(rng.nextInt(allocated.length));
          inv.way.inject(toInv);
          inv.access.inject(1);
          await clk.nextPosedge;
          inv.access.inject(0);
          await clk.nextPosedge; // let flops update
          allocated.remove(toInv);
        } else {
          // no allocated ways; do a no-op cycle
          await clk.nextPosedge;
        }
      }
    }

    await Simulator.endSimulation();
  }, timeout: const Timeout(Duration(minutes: 1)));
}
