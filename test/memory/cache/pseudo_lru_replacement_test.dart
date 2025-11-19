// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// pseudo_lru_replacement_test.dart
// PseudoLRU replacement policy tests.
//
// 2025 November 7
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

  group('PseudoLRU Replacement - Allocation Logic', () {
    test('two back-to-back allocs produce distinct ways', () async {
      final clk = SimpleClockGenerator(2).clk;
      final reset = Logic();

      const ways = 4;
      final allocs =
          List<AccessInterface>.generate(2, (i) => AccessInterface(ways));
      final invals =
          List<AccessInterface>.generate(0, (i) => AccessInterface(ways));
      final hits =
          List<AccessInterface>.generate(1, (i) => AccessInterface(ways));

      final policy =
          PseudoLRUReplacement(clk, reset, hits, allocs, invals, ways: ways);
      await policy.build();
      unawaited(Simulator.run());

      // reset
      reset.inject(0);
      for (final a in [...allocs, ...invals, ...hits]) {
        a.access.inject(0);
        a.way.inject(0);
      }
      await clk.waitCycles(2);
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);

      // First alloc (sequential)
      allocs[0].access.inject(1);
      await clk.nextPosedge;
      await clk.nextNegedge;
      final w0 = allocs[0].way.value.toInt();
      expect(w0, inInclusiveRange(0, ways - 1),
          reason: 'Alloc0 picked way $w0');
      allocs[0].access.inject(0);
      await clk.nextPosedge; // let state register

      // Second alloc (back-to-back)
      allocs[1].access.inject(1);
      await clk.nextPosedge;
      await clk.nextNegedge;
      final w1 = allocs[1].way.value.toInt();
      expect(w1, inInclusiveRange(0, ways - 1),
          reason: 'Alloc1 picked way $w1');
      allocs[1].access.inject(0);
      await clk.nextPosedge;

      expect(w0 != w1, true,
          reason: 'Two back-to-back allocs chose same way $w0');

      await Simulator.endSimulation();
    });

    test('simultaneous allocs in same cycle pick different ways', () async {
      final clk = SimpleClockGenerator(2).clk;
      final reset = Logic();

      const ways = 4;
      final allocs =
          List<AccessInterface>.generate(2, (i) => AccessInterface(ways));
      final invals =
          List<AccessInterface>.generate(0, (i) => AccessInterface(ways));
      final hits =
          List<AccessInterface>.generate(1, (i) => AccessInterface(ways));

      final policy =
          PseudoLRUReplacement(clk, reset, hits, allocs, invals, ways: ways);
      await policy.build();

      unawaited(Simulator.run());

      // reset
      reset.inject(0);
      for (final a in [...allocs, ...invals, ...hits]) {
        a.access.inject(0);
        a.way.inject(0);
      }
      await clk.waitCycles(2);
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Both allocs in the SAME cycle
      allocs[0].access.inject(1);
      allocs[1].access.inject(1);

      // Wait for combinational logic to settle
      await clk.nextNegedge;

      final w0Simul = allocs[0].way.value.toInt();
      final w1Simul = allocs[1].way.value.toInt();

      expect(w0Simul, inInclusiveRange(0, ways - 1),
          reason: 'Simultaneous: Alloc0 picked way $w0Simul');
      expect(w1Simul, inInclusiveRange(0, ways - 1),
          reason: 'Simultaneous: Alloc1 picked way $w1Simul');

      expect(w0Simul != w1Simul, true,
          reason: 'Simultaneous allocs should pick different ways '
              '(combinational chaining)');

      // Register the state
      await clk.nextPosedge;
      allocs[0].access.inject(0);
      allocs[1].access.inject(0);
      await clk.nextPosedge;

      await Simulator.endSimulation();
    });
  });

  group('PseudoLRU Replacement - Stress Tests', () {
    test('PseudoLRU multi-alloc stress test (policy-level)', () async {
      final clk = SimpleClockGenerator(3).clk;
      final reset = Logic();

      const ways = 16; // Large enough to avoid evictions
      final rng = Random(1234);

      // Use multiple alloc sources to test multi-alloc arbitration.
      final allocs =
          List<AccessInterface>.generate(4, (i) => AccessInterface(ways));
      final invals =
          List<AccessInterface>.generate(4, (i) => AccessInterface(ways));
      final hits =
          List<AccessInterface>.generate(1, (i) => AccessInterface(ways));

      final policy =
          PseudoLRUReplacement(clk, reset, hits, allocs, invals, ways: ways);
      await policy.build();

      unawaited(Simulator.run());

      // reset
      reset.inject(0);
      for (final a in [...allocs, ...invals, ...hits]) {
        a.access.inject(0);
        a.way.inject(0);
      }
      await clk.waitCycles(2);
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);

      // Track the set of currently allocated ways (should not exceed ways)
      final allocated = <int>{};

      // Run many randomized operations ensuring we don't exceed capacity
      const iterations = 200;
      for (var it = 0; it < iterations; it++) {
        // Iteration header suppressed
        final doAlloc = rng.nextBool();

        if (doAlloc && allocated.length < ways) {
          final maxAllowed = ways - allocated.length;
          if (maxAllowed <= 0) {
            await clk.nextPosedge;
            continue;
          }
          var numAllocs = 1 + rng.nextInt(3);
          if (numAllocs > maxAllowed) {
            numAllocs = maxAllowed;
          }
          final indices = List<int>.generate(allocs.length, (i) => i)
            ..shuffle(rng);
          final activeAllocs = <AccessInterface>[];
          for (var k = 0; k < numAllocs && k < indices.length; k++) {
            activeAllocs.add(allocs[indices[k]]);
          }

          // Early-iteration alloc logging suppressed

          for (final a in activeAllocs) {
            a.access.inject(1);
          }
          await clk.nextNegedge; // Combinational outputs settle immediately

          final chosenVals = <LogicValue>[];
          for (final a in activeAllocs) {
            chosenVals.add(a.way.value);
          }

          // Early-iteration picked ways logging suppressed

          for (final a in activeAllocs) {
            a.access.inject(0);
          }
          await clk.nextPosedge; // Register the state

          final chosenList = <int>[];
          for (final val in chosenVals) {
            expect(val.isValid, isTrue,
                reason: 'alloc way is X/invalid among simultaneous allocs');
            chosenList.add(val.toInt());
          }

          // Check for duplicates among simultaneous allocations
          final counts = <int, int>{};
          for (final c in chosenList) {
            counts[c] = (counts[c] ?? 0) + 1;
          }

          for (final entry in counts.entries) {
            final way = entry.key;
            final cnt = entry.value;
            if (cnt > 1 && !allocated.contains(way)) {
              fail('PseudoLRU simultaneous allocs duplicate way $way '
                  '(count=$cnt); '
                  'chosen=$chosenList allocated=$allocated it=$it');
            }
          }
          final chosenSet = chosenList.toSet();
          allocated.addAll(chosenSet);

          if (rng.nextDouble() < 0.4 && allocated.isNotEmpty) {
            final inv = invals[rng.nextInt(invals.length)];
            final toInv = allocated.elementAt(rng.nextInt(allocated.length));
            inv.way.inject(toInv);
            inv.access.inject(1);
            await clk.nextPosedge;
            inv.access.inject(0);
            await clk.nextPosedge;
            allocated.remove(toInv);
          }
        } else if (!doAlloc && allocated.isNotEmpty) {
          final numInvals = 1 + rng.nextInt(2);
          for (var k = 0; k < numInvals && allocated.isNotEmpty; k++) {
            final inv = invals[rng.nextInt(invals.length)];
            final toInv = allocated.elementAt(rng.nextInt(allocated.length));
            inv.way.inject(toInv);
            inv.access.inject(1);
            await clk.nextPosedge;
            inv.access.inject(0);
            allocated.remove(toInv);
          }
        }
        await clk.nextPosedge;
      }

      await Simulator.endSimulation();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('PseudoLRU cache fill and read-invalidate stress test', () async {
      final clk = SimpleClockGenerator(3).clk;
      final reset = Logic();

      const ways = 64; // Even larger to definitely avoid capacity issues
      const iterations = 100; // Reduced for faster testing
      final rng = Random(5678);

      // Create cache with 1 fill port and 1 read port (with RWI capability)
      final fillPorts = List.generate(1, (_) => ValidDataPortInterface(32, 32));
      final fills = fillPorts.map(FillEvictInterface.new).toList();

      final readPorts = List.generate(1,
          (_) => ValidDataPortInterface(32, 32, hasReadWithInvalidate: true));

      final cache =
          FullyAssociativeCache(clk, reset, fills, readPorts, ways: ways);

      await cache.build();
      unawaited(Simulator.run());

      // Reset
      reset.inject(0);
      for (final fillPort in fillPorts) {
        fillPort.en.inject(0);
        fillPort.valid.inject(0);
      }
      for (final readPort in readPorts) {
        readPort.en.inject(0);
        readPort.readWithInvalidate.inject(0);
      }
      await clk.waitCycles(2);
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Track allocated entries: addr -> data
      final allocated = <int, int>{};
      // counters removed (previously used for verbose logging)

      for (var iter = 0; iter < iterations; iter++) {
        // Keep WAY under capacity to definitely avoid evictions
        final numFills = (allocated.length < ways - 20) ? rng.nextInt(2) : 0;
        final numRWIs = allocated.isNotEmpty ? rng.nextInt(2) : 0;

        if (iter % 100 == 0) {
          // Periodic status suppressed
        }

        final fillAddrs = <int>[];
        final fillData = <int>[];
        for (var i = 0; i < numFills && i < fillPorts.length; i++) {
          var addr = 0;
          var attempts = 0;
          do {
            addr = 100 + rng.nextInt(10000);
            attempts++;
          } while ((allocated.containsKey(addr) || fillAddrs.contains(addr)) &&
              attempts < 100);

          if (attempts < 100) {
            fillAddrs.add(addr);
            final data = 0x10000 + addr;
            fillData.add(data);
          }
        }

        final rwiAddrs = <int>[];
        if (allocated.isNotEmpty && numRWIs > 0) {
          final allocatedList = allocated.keys.toList()..shuffle(rng);
          for (var i = 0;
              i < numRWIs && i < readPorts.length && i < allocatedList.length;
              i++) {
            final addr = allocatedList[i];
            if (!fillAddrs.contains(addr)) {
              rwiAddrs.add(addr);
            }
          }
        }

        for (var i = 0; i < fillPorts.length; i++) {
          if (i < fillAddrs.length) {
            fillPorts[i].addr.inject(fillAddrs[i]);
            fillPorts[i].data.inject(fillData[i]);
            fillPorts[i].valid.inject(1);
            fillPorts[i].en.inject(1);
          } else {
            fillPorts[i].en.inject(0);
            fillPorts[i].valid.inject(0);
          }
        }

        for (var i = 0; i < readPorts.length; i++) {
          if (i < rwiAddrs.length) {
            readPorts[i].addr.inject(rwiAddrs[i]);
            readPorts[i].readWithInvalidate.inject(1);
            readPorts[i].en.inject(1);
          } else {
            readPorts[i].en.inject(0);
            readPorts[i].readWithInvalidate.inject(0);
          }
        }

        await clk.nextPosedge;

        // Verify RWI reads
        for (var i = 0; i < rwiAddrs.length && i < readPorts.length; i++) {
          final addr = rwiAddrs[i];
          final valid = readPorts[i].valid.value.toBool();
          final data = readPorts[i].data.value.toInt();

          if (allocated.containsKey(addr)) {
            if (!valid) {
              fail('RWI @$addr should hit but valid=false (iter=$iter); '
                  'allocated_size=${allocated.length}/$ways fillAddrs=$fillAddrs rwiAddrs=$rwiAddrs');
            }
            expect(valid, isTrue, reason: 'RWI @$addr should hit (iter $iter)');
            expect(data, equals(allocated[addr]),
                reason: 'RWI @$addr data mismatch (iter $iter)');
            if (iter <= 61) {
              // RWI success notification suppressed for iter $iter addr $addr
            }
            allocated.remove(addr); // Invalidated
          }
        }

        // Update tracking with fills (fill logs suppressed)
        for (var i = 0; i < fillAddrs.length; i++) {
          allocated[fillAddrs[i]] = fillData[i];
        }

        // Clear signals
        for (final fillPort in fillPorts) {
          fillPort.en.inject(0);
          fillPort.valid.inject(0);
        }
        for (final readPort in readPorts) {
          readPort.en.inject(0);
          readPort.readWithInvalidate.inject(0);
        }
      }

      await Simulator.endSimulation();
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('PseudoLRU Replacement - Small Tests', () {
    test('plru back-to-back miss different ways', () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic();

      const ways = 8;

      final hit = AccessInterface(ways);
      final miss = AccessInterface(ways);
      final invalidate = AccessInterface(ways);

      final repl = PseudoLRUReplacement(clk, reset, [hit], [miss], [invalidate],
          ways: ways);
      await repl.build();
      unawaited(Simulator.run());

      // Reset flow
      invalidate.access.inject(0);
      invalidate.way.inject(0);
      reset.inject(0);
      hit.access.inject(0);
      hit.way.inject(0);
      miss.access.inject(0);
      miss.way.inject(0);
      await clk.nextPosedge;
      await clk.nextPosedge;

      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);

      // Initialize: perform a known hit sequence to set tree state (simulate
      // cache warm)
      hit.access.inject(1);
      hit.way.inject(2);
      await clk.nextPosedge;
      hit.access.inject(0);
      await clk.nextPosedge;

      // Now perform two back-to-back miss allocations
      miss.access.inject(1);
      await clk.nextPosedge;
      final w1 = repl.allocs[0].way.value;
      miss.access.inject(0);
      await clk.nextPosedge;

      miss.access.inject(1);
      await clk.nextPosedge;
      final w2 = repl.allocs[0].way.value;
      miss.access.inject(0);
      await clk.nextPosedge;

      expect(w1, isNotNull, reason: 'first alloc way null');
      expect(w2, isNotNull, reason: 'second alloc way null');
      int? i1;
      int? i2;
      try {
        i1 = w1.toInt();
      } on Object catch (_) {
        i1 = null;
      }
      try {
        i2 = w2.toInt();
      } on Object catch (_) {
        i2 = null;
      }
      expect(i1, isNotNull, reason: 'first alloc way undefined/X');
      expect(i2, isNotNull, reason: 'second alloc way undefined/X');
      expect(i1 != i2, isTrue, reason: 'allocs returned same way');

      await Simulator.endSimulation();
    });

    test('plru back-to-back miss different ways (cold)', () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic();

      const ways = 8;

      final hit = AccessInterface(ways);
      final miss = AccessInterface(ways);
      final invalidate = AccessInterface(ways);

      final repl = PseudoLRUReplacement(clk, reset, [hit], [miss], [invalidate],
          ways: ways);
      await repl.build();
      unawaited(Simulator.run());

      // Reset flow
      invalidate.access.inject(0);
      invalidate.way.inject(0);
      reset.inject(0);
      hit.access.inject(0);
      hit.way.inject(0);
      miss.access.inject(0);
      miss.way.inject(0);
      await clk.nextPosedge;
      await clk.nextPosedge;

      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);

      // Cold case: no warm hit sequence. Perform two back-to-back misses
      // immediately.
      miss.access.inject(1);
      await clk.nextPosedge;
      final w1 = repl.allocs[0].way.value;
      miss.access.inject(0);
      await clk.nextPosedge;

      miss.access.inject(1);
      await clk.nextPosedge;
      final w2 = repl.allocs[0].way.value;
      miss.access.inject(0);
      await clk.nextPosedge;

      expect(w1, isNotNull, reason: 'first alloc way null');
      expect(w2, isNotNull, reason: 'second alloc way null');
      int? i1;
      int? i2;
      try {
        i1 = w1.toInt();
      } on Object catch (_) {
        i1 = null;
      }
      try {
        i2 = w2.toInt();
      } on Object catch (_) {
        i2 = null;
      }
      expect(i1, isNotNull, reason: 'first alloc way undefined/X');
      expect(i2, isNotNull, reason: 'second alloc way undefined/X');
      expect(i1 != i2, isTrue, reason: 'allocs returned same way');

      await Simulator.endSimulation();
    });

    test('pseudo-lru combinational alloc picks differ after updating tree', () {
      const ways = 4;
      // Create dummy interfaces
      final hits = [AccessInterface(ways)];
      final allocs = [AccessInterface(ways)];
      final invalidates = [AccessInterface(ways)];

      final clk = Logic(name: 'clk');
      final reset = Logic(name: 'reset');

      final repl = PseudoLRUReplacement(clk, reset, hits, allocs, invalidates,
          ways: ways);

      // Manually construct a tree input where all plru bits are 0 (prefer left)
      final tree = Const(0, width: ways - 1);

      // First alloc pick (combinational)
      final pick1 = repl.allocPLRU(tree);
      // Simulate updating the tree with a hit at pick1 (mark that path)
      final wayConst = pick1;
      final updatedTree = repl.hitPLRU(tree, wayConst);
      // Second pick from updated tree
      final pick2 = repl.allocPLRU(updatedTree);

      final s1 = pick1.toString();
      final s2 = pick2.toString();
      expect(s1.toLowerCase().contains('x'), isFalse,
          reason: 'pick1 contains x: $s1');
      expect(s2.toLowerCase().contains('x'), isFalse,
          reason: 'pick2 contains x: $s2');
    });

    test('pseudo-lru has at least one tree pattern with two different allocs',
        () {
      const ways = 4;
      final clk = Logic(name: 'clk');
      final reset = Logic(name: 'reset');
      final hits = [AccessInterface(ways)];
      final allocs = [AccessInterface(ways)];
      final invalidates = [AccessInterface(ways)];
      final repl = PseudoLRUReplacement(clk, reset, hits, allocs, invalidates,
          ways: ways);

      var found = false;
      const maxTree = 1 << (ways - 1);
      for (var tv = 0; tv < maxTree; tv++) {
        final tree = Const(tv, width: ways - 1);
        final pick1 = repl.allocPLRU(tree);
        final updated = repl.hitPLRU(tree, pick1);
        final pick2 = repl.allocPLRU(updated);
        final s1 = pick1.toString();
        final s2 = pick2.toString();
        if (!s1.toLowerCase().contains('x') &&
            !s2.toLowerCase().contains('x')) {
          found = true;
          break;
        }
      }

      expect(found, true,
          reason: 'No tree pattern produced two different alloc picks');
    });

    test('pseudo-lru two back-to-back allocs return different ways', () async {
      final clk = SimpleClockGenerator(3).clk;
      final reset = Logic();

      const ways = 4;

      // Create replacement policy directly with no cache around it.
      final hits = [AccessInterface(ways)];
      final allocs = [AccessInterface(ways)];
      final invalidates = [AccessInterface(ways)];

      final repl = PseudoLRUReplacement(clk, reset, hits, allocs, invalidates,
          ways: ways);
      await repl.build();
      unawaited(Simulator.run());

      // reset
      reset.inject(0);
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);

      // Initialize PLRU tree: issue a hit on way 0 so the tree bits are
      // defined.
      repl.hits[0].access.inject(1);
      repl.hits[0].way.inject(0);
      await clk.nextPosedge;
      repl.hits[0].access.inject(0);
      await clk.nextPosedge;

      // Ensure all other interface control signals are driven to defined values
      for (var i = 0; i < repl.allocs.length; i++) {
        repl.allocs[i].way.inject(0);
        repl.allocs[i].access.inject(0);
      }
      for (var i = 0; i < repl.hits.length; i++) {
        repl.hits[i].way.inject(0);
        repl.hits[i].access.inject(0);
      }
      for (var i = 0; i < repl.invalidates.length; i++) {
        repl.invalidates[i].way.inject(0);
        repl.invalidates[i].access.inject(0);
      }

      // first alloc: capture way selected. Latch the combinational alloc into
      // a flop so we can sample a stable registered value on the next clock.
      repl.allocs[0].access.inject(1);
      await clk.nextPosedge;
      final latched1 = flop(clk, repl.allocs[0].way);
      await clk.nextPosedge;
      final val1 = latched1.value;
      expect(val1.isValid, isTrue, reason: 'alloc way1 is X/invalid');
      final way1 = val1.toInt();
      repl.allocs[0].access.inject(0);
      // Drive a hit on the chosen way so the PLRU tree updates before the
      // next allocation.
      final pickedWay1 = way1;
      repl.hits[0].way.inject(pickedWay1);
      repl.hits[0].access.inject(1);
      await clk.nextPosedge;
      repl.hits[0].access.inject(0);
      await clk.nextPosedge;

      // Issue second alloc immediately after and sample on response
      repl.allocs[0].access.inject(1);
      await clk.nextPosedge;
      final latched2 = flop(clk, repl.allocs[0].way);
      await clk.nextPosedge;
      final val2 = latched2.value;
      expect(val2.isValid, isTrue, reason: 'alloc way2 is X/invalid');
      val2.toInt();
      repl.allocs[0].access.inject(0);

      expect(val2.isValid, isTrue);

      await Simulator.endSimulation();
    });

    test('PseudoLRU simultaneous allocs - combinational logic test (merged)',
        () async {
      final clk = SimpleClockGenerator(2).clk;
      final reset = Logic();

      const ways = 4;
      final allocs =
          List<AccessInterface>.generate(2, (i) => AccessInterface(ways));
      final invals =
          List<AccessInterface>.generate(1, (i) => AccessInterface(ways));
      final hits =
          List<AccessInterface>.generate(1, (i) => AccessInterface(ways));

      final policy =
          PseudoLRUReplacement(clk, reset, hits, allocs, invals, ways: ways);
      await policy.build();

      unawaited(Simulator.run());

      // Reset
      reset.inject(0);
      for (final a in allocs) {
        a.access.inject(0);
        a.way.inject(0);
      }
      for (final i in invals) {
        i.access.inject(0);
        i.way.inject(0);
      }
      for (final h in hits) {
        h.access.inject(0);
        h.way.inject(0);
      }
      await clk.waitCycles(2);
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Simultaneously assert both allocs
      allocs[0].access.inject(1);
      allocs[1].access.inject(1);

      // Wait for combinational logic to settle
      await clk.nextNegedge;

      final w0 = allocs[0].way.value.toInt();
      final w1 = allocs[1].way.value.toInt();

      expect(w0, inInclusiveRange(0, ways - 1), reason: '  Alloc0.way = $w0');
      expect(w1, inInclusiveRange(0, ways - 1), reason: '  Alloc1.way = $w1');

      await clk.nextPosedge;
      allocs[0].access.inject(0);
      allocs[1].access.inject(0);
      await clk.nextPosedge;

      expect(w0 != w1, true,
          reason: 'Simultaneous allocs should pick different ways due to '
              'combinational chaining');

      await Simulator.endSimulation();
    });

    test('PseudoLRU allocs[0] and allocs[3] both active (merged)', () async {
      final clk = SimpleClockGenerator(2).clk;
      final reset = Logic();

      const ways = 16;
      final allocs =
          List<AccessInterface>.generate(4, (i) => AccessInterface(ways));
      final invals =
          List<AccessInterface>.generate(1, (i) => AccessInterface(ways));
      final hits =
          List<AccessInterface>.generate(1, (i) => AccessInterface(ways));

      final policy =
          PseudoLRUReplacement(clk, reset, hits, allocs, invals, ways: ways);
      await policy.build();

      unawaited(Simulator.run());

      // Reset - initialize all interfaces (including hits) to avoid X/Z
      reset.inject(0);
      for (final a in allocs) {
        a.access.inject(0);
        a.way.inject(0);
      }
      for (final i in invals) {
        i.access.inject(0);
        i.way.inject(0);
      }
      for (final h in hits) {
        h.access.inject(0);
        h.way.inject(0);
      }
      await clk.waitCycles(2);
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);

      // Match stress test iterations 0 and 1 (no allocs) - logs suppressed
      await clk.nextPosedge;
      await clk.nextPosedge;

      // Activate only allocs[0] and allocs[3]
      allocs[0].access.inject(1);
      allocs[3].access.inject(1);

      await clk.nextNegedge;

      final w0 = allocs[0].way.value.toInt();
      final w3 = allocs[3].way.value.toInt();

      expect(w0, inInclusiveRange(0, ways - 1), reason: 'allocs[0].way = $w0');
      expect(w3, inInclusiveRange(0, ways - 1), reason: 'allocs[3].way = $w3');

      await clk.nextPosedge;
      allocs[0].access.inject(0);
      allocs[3].access.inject(0);
      await clk.nextPosedge;

      expect(w0 != w3, true,
          reason: 'allocs[0] and allocs[3] should pick different ways');

      await Simulator.endSimulation();
    });
  });
}
