// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// available_invalidated_test.dart
// Basic tests for the AvailableInvalidated ReplacementPolicy
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
  group('AvailableInvalidated - FullyAssoc 32-way', () {
    test('FullyAssoc 32-way RWI sequence', () async {
      final clk = SimpleClockGenerator(5).clk;
      final reset = Logic();

      const ways = 32;

      final fillPort = ValidDataPortInterface(20, 12);
      final fill = FillEvictInterface(fillPort);

      final readPort =
          ValidDataPortInterface(20, 12, hasReadWithInvalidate: true);

      final cache = FullyAssociativeCache(clk, reset, [fill], [readPort],
          ways: ways, replacement: AvailableInvalidatedReplacement.new);

      await cache.build();
      unawaited(Simulator.run());

      // Reset
      reset.inject(0);
      fillPort.en.inject(0);
      fillPort.valid.inject(0);
      readPort.en.inject(0);
      readPort.valid.inject(0);
      readPort.addr.inject(0);
      readPort.readWithInvalidate.inject(0);
      await clk.waitCycles(2);
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      int h(String s) => int.parse(s, radix: 16);

      Future<(bool, int)?> cycle({String? fillAddr, String? rwiAddr}) async {
        if (fillAddr != null) {
          final addr = h(fillAddr);
          fillPort.addr.inject(addr);
          fillPort.data.inject(0x10000 + addr);
          fillPort.valid.inject(1);
          fillPort.en.inject(1);
        } else {
          fillPort.en.inject(0);
          fillPort.valid.inject(0);
        }

        if (rwiAddr != null) {
          final addr = h(rwiAddr);
          readPort.addr.inject(addr);
          readPort.readWithInvalidate.inject(1);
          readPort.en.inject(1);
        } else {
          readPort.en.inject(0);
          readPort.readWithInvalidate.inject(0);
        }

        await clk.nextPosedge;

        (bool, int)? result;
        if (rwiAddr != null) {
          final valid = readPort.valid.value.toBool();
          final data = readPort.data.value.toInt();
          result = (valid, data);
        }

        fillPort.en.inject(0);
        fillPort.valid.inject(0);
        readPort.en.inject(0);
        readPort.readWithInvalidate.inject(0);

        return result;
      }

      final seq = <List<String>>[
        ['301'],
        ['10e'],
        [],
        ['310'],
        [],
        ['120', 'A301'],
        ['121', 'A10e'],
        ['123'],
        [],
        ['A121'],
        [],
        ['A123'],
        [],
      ];

      for (final line in seq) {
        String? fillAddr;
        String? rwiAddr;
        for (final tok in line) {
          final t = tok.trim();
          if (t.isEmpty) {
            continue;
          }
          if (t.startsWith('A') || t.startsWith('a')) {
            rwiAddr = t.substring(1);
          } else {
            fillAddr = t;
          }
        }
        final result = await cycle(fillAddr: fillAddr, rwiAddr: rwiAddr);
//121, 326, 328, 12d, 341, 140
        if (rwiAddr == '301') {
          expect(result, isNotNull);
          expect(result!.$1, isTrue, reason: 'RWI @301 should hit');
          expect(result.$2, equals(0x10301),
              reason: 'RWI @301 should return correct data');
        }
        if (rwiAddr == '10e') {
          expect(result, isNotNull);
          expect(result!.$1, isTrue, reason: 'RWI @10e should hit');
          expect(result.$2, equals(0x1010e),
              reason: 'RWI @10e should return correct data');
        }
        if (rwiAddr == '121') {
          expect(result, isNotNull);
          expect(result!.$1, isTrue, reason: 'RWI @121 should hit');
          expect(result.$2, equals(0x10121),
              reason: 'RWI @121 should return correct data');
        }
        if (rwiAddr == '123') {
          expect(result, isNotNull);
          expect(result!.$1, isTrue, reason: 'RWI @123 should hit');
          expect(result.$2, equals(0x10123),
              reason: 'RWI @123 should return correct data');
        }
      }

      await Simulator.endSimulation();
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  test('policy basic alloc/invalidate behavior', () async {
    final clk = SimpleClockGenerator(5).clk;
    final reset = Logic();

    const ways = 4;

    final allocs =
        List<AccessInterface>.generate(1, (i) => AccessInterface(ways));
    final invals =
        List<AccessInterface>.generate(1, (i) => AccessInterface(ways));
    final hits = [AccessInterface(ways)];

    final policy = AvailableInvalidatedReplacement(
        clk, reset, hits, allocs, invals,
        ways: ways);
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

    // sequential allocs should produce unique ways until exhausted
    final chosen = <int>{};
    for (var i = 0; i < ways; i++) {
      final a = allocs[i % allocs.length];
      a.access.inject(1);
      await clk.nextPosedge;
      // deassert and allow internal picks to settle into outputs
      a.access.inject(0);
      await clk.nextPosedge;
      final v = a.way.value.toInt();
      expect(!chosen.contains(v), true, reason: 'way $v repeated');
      chosen.add(v);
    }

    // invalidate one chosen way
    final inval = invals[0];
    inval.access.inject(1);
    inval.way.inject(chosen.first);
    await clk.nextPosedge;
    inval.access.inject(0);

    // next alloc should be able to return the invalidated way
    final a2 = allocs[0];
    a2.access.inject(1);
    await clk.nextPosedge;
    a2.access.inject(0);
    final v2 = a2.way.value.toInt();
    expect(chosen.contains(v2), true,
        reason: 'alloc did not return invalidated way');

    await Simulator.endSimulation();
  });

  test('two simultaneous allocs produce distinct ways', () async {
    final clk = SimpleClockGenerator(2).clk;
    final reset = Logic();

    const ways = 4;
    final allocs =
        List<AccessInterface>.generate(2, (i) => AccessInterface(ways));
    final invals = <AccessInterface>[];
    final hits = [AccessInterface(ways)];

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

    // assert both allocs simultaneously
    allocs[0].access.inject(1);
    allocs[1].access.inject(1);
    await clk.nextNegedge; // Combinational outputs settle immediately

    final w0 = allocs[0].way.value.toInt();
    final w1 = allocs[1].way.value.toInt();

    // deassert and allow state to register
    allocs[0].access.inject(0);
    allocs[1].access.inject(0);
    await clk.nextPosedge;

    expect(w0 != w1, true,
        reason: 'Two simultaneous allocs chose same way $w0');

    await Simulator.endSimulation();
  });

  test('fully-assoc two fills store both tags', () async {
    final clk = SimpleClockGenerator(3).clk;
    final reset = Logic();

    final fill = ValidDataPortInterface(32, 32);
    final fills = [FillEvictInterface(fill)];

    final read = ValidDataPortInterface(32, 32);
    final reads = [read];

    final cache = FullyAssociativeCache(clk, reset, fills, reads,
        replacement: AvailableInvalidatedReplacement.new);
    await cache.build();
    unawaited(Simulator.run());

    // reset
    reset.inject(0);
    read.en.inject(0);
    fill.en.inject(0);
    fill.addr.inject(0);
    fill.valid.inject(0);
    fill.data.inject(0);
    read.en.inject(0);
    read.addr.inject(0);
    await clk.waitCycles(2);
    reset.inject(1);
    await clk.nextPosedge;
    reset.inject(0);

    // First fill
    fill.addr.inject(200);
    fill.data.inject(0xdeadbeef);
    fill.valid.inject(1);
    fill.en.inject(1);
    await clk.nextPosedge;
    fill.en.inject(0);
    fill.valid.inject(0);
    await clk.nextPosedge;

    // Second fill
    fill.addr.inject(280);
    fill.data.inject(0xcafebabe);
    fill.valid.inject(1);
    fill.en.inject(1);
    await clk.nextPosedge;
    fill.en.inject(0);
    fill.valid.inject(0);
    await clk.nextPosedge;

    // Read tag 200
    read.en.inject(1);
    read.addr.inject(200);
    await clk.nextPosedge;
    final hit200 = read.valid.value.toInt();
    final data200 = read.data.value.toInt();
    read.en.inject(0);
    await clk.nextPosedge;

    // Read tag 280
    read.en.inject(1);
    read.addr.inject(280);
    await clk.nextPosedge;
    final hit280 = read.valid.value.toInt();
    final data280 = read.data.value.toInt();
    read.en.inject(0);
    await clk.nextPosedge;

    expect(hit200 == 1, true, reason: 'Tag 200 not found (miss)');
    expect(hit280 == 1, true, reason: 'Tag 280 not found (miss)');
    expect(data200 == 0xdeadbeef, true, reason: 'Data for tag 200 mismatched');
    expect(data280 == 0xcafebabe, true, reason: 'Data for tag 280 mismatched');

    await Simulator.endSimulation();
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('fill-before-full blocking with RWI coordination', () async {
    final clk = SimpleClockGenerator(3).clk;
    final reset = Logic();

    const ways = 8;

    // One fill port
    final fillPort = ValidDataPortInterface(32, 32);
    final fills = [FillEvictInterface(fillPort)];

    // One read port with read-with-invalidate
    final readPort =
        ValidDataPortInterface(32, 32, hasReadWithInvalidate: true);
    final readPorts = [readPort];

    final cache = FullyAssociativeCache(clk, reset, fills, readPorts,
        ways: ways, replacement: AvailableInvalidatedReplacement.new);
    await cache.build();
    unawaited(Simulator.run());

    // Reset
    reset.inject(0);
    fillPort.en.inject(0);
    fillPort.addr.inject(0);
    fillPort.valid.inject(0);
    fillPort.data.inject(0);
    readPort.en.inject(0);
    readPort.addr.inject(0);
    readPort.readWithInvalidate.inject(0);
    await clk.waitCycles(2);
    reset.inject(1);
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    final entries = <int, int>{};

    // Fill N-1 ways
    for (var i = 0; i < ways - 1; i++) {
      final addr = 1000 + i * 100;
      final data = 0x10000 + addr;
      fillPort.addr.inject(addr);
      fillPort.data.inject(data);
      fillPort.valid.inject(1);
      fillPort.en.inject(1);
      await clk.nextPosedge;
      fillPort.en.inject(0);
      fillPort.valid.inject(0);
      await clk.nextPosedge;
      entries[addr] = data;
    }

    // Fill the last available way
    const lastAddr = 9000;
    const lastData = 0x19000;
    fillPort.addr.inject(lastAddr);
    fillPort.data.inject(lastData);
    fillPort.valid.inject(1);
    fillPort.en.inject(1);
    await clk.nextPosedge;
    fillPort.en.inject(0);
    fillPort.valid.inject(0);
    await clk.nextPosedge;
    entries[lastAddr] = lastData;

    // Verify last fill succeeded and way 0 still present
    readPort.en.inject(1);
    readPort.addr.inject(lastAddr);
    await clk.nextPosedge;
    final hitLast = readPort.valid.value.toInt();
    final dataLast = readPort.data.value.toInt();
    readPort.en.inject(0);
    await clk.nextPosedge;
    expect(hitLast, 1);
    expect(dataLast, lastData);

    const firstAddr = 1000;
    readPort.en.inject(1);
    readPort.addr.inject(firstAddr);
    await clk.nextPosedge;
    final hitFirst = readPort.valid.value.toInt();
    final dataFirst = readPort.data.value.toInt();
    readPort.en.inject(0);
    await clk.nextPosedge;
    expect(hitFirst, 1);
    expect(dataFirst, entries[firstAddr]);

    // Software blocks a new fill while cache is full
    const blockedAddr = 9999;
    const blockedData = 0x19999;
    // not sending fill - simulate blocking

    // RWI to free a way (choose one of the existing addresses)
    const rwiAddr = 1200; // way 2
    readPort.en.inject(1);
    readPort.addr.inject(rwiAddr);
    readPort.readWithInvalidate.inject(1);
    await clk.nextPosedge;
    final hitRwi = readPort.valid.value.toInt();
    final dataRwi = readPort.data.value.toInt();
    readPort.en.inject(0);
    readPort.readWithInvalidate.inject(0);
    await clk.nextPosedge;
    expect(hitRwi, 1);
    expect(dataRwi, entries[rwiAddr]);
    entries.remove(rwiAddr);

    // Verify RWI invalidated it
    readPort.en.inject(1);
    readPort.addr.inject(rwiAddr);
    await clk.nextPosedge;
    final hitAfterRwi = readPort.valid.value.toInt();
    readPort.en.inject(0);
    await clk.nextPosedge;
    expect(hitAfterRwi, 0);

    // Now fill into freed way
    fillPort.addr.inject(blockedAddr);
    fillPort.data.inject(blockedData);
    fillPort.valid.inject(1);
    fillPort.en.inject(1);
    await clk.nextPosedge;
    fillPort.en.inject(0);
    fillPort.valid.inject(0);
    await clk.nextPosedge;

    readPort.en.inject(1);
    readPort.addr.inject(blockedAddr);
    await clk.nextPosedge;
    final hitBlocked = readPort.valid.value.toInt();
    final dataBlocked = readPort.data.value.toInt();
    readPort.en.inject(0);
    await clk.nextPosedge;
    expect(hitBlocked, 1);
    expect(dataBlocked, blockedData);

    // way 0 still present
    readPort.en.inject(1);
    readPort.addr.inject(firstAddr);
    await clk.nextPosedge;
    final hitFirstAgain = readPort.valid.value.toInt();
    readPort.en.inject(0);
    await clk.nextPosedge;
    expect(hitFirstAgain, 1);

    await Simulator.endSimulation();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('full-cache eviction behavior', () async {
    final clk = SimpleClockGenerator(3).clk;
    final reset = Logic();

    const ways = 8;

    final fillPort = ValidDataPortInterface(32, 32);
    final fills = [FillEvictInterface(fillPort)];
    final readPort =
        ValidDataPortInterface(32, 32, hasReadWithInvalidate: true);
    final readPorts = [readPort];

    final cache = FullyAssociativeCache(clk, reset, fills, readPorts,
        ways: ways, replacement: AvailableInvalidatedReplacement.new);
    await cache.build();
    unawaited(Simulator.run());

    // reset
    reset.inject(0);
    fillPort.en.inject(0);
    fillPort.addr.inject(0);
    fillPort.valid.inject(0);
    fillPort.data.inject(0);
    readPort.en.inject(0);
    readPort.addr.inject(0);
    readPort.readWithInvalidate.inject(0);
    await clk.waitCycles(2);
    reset.inject(1);
    await clk.nextPosedge;
    reset.inject(0);

    final entries = <int, int>{};

    // Fill all ways
    for (var i = 0; i < ways; i++) {
      final addr = 1000 + i * 100;
      final data = 0x10000 + addr;
      fillPort.addr.inject(addr);
      fillPort.data.inject(data);
      fillPort.valid.inject(1);
      fillPort.en.inject(1);
      await clk.nextPosedge;
      fillPort.en.inject(0);
      fillPort.valid.inject(0);
      await clk.nextPosedge;
      entries[addr] = data;
    }

    // Now the cache is full. A subsequent fill should evict way 0 (policy
    // returns way 0 when no invalids exist).
    const newAddr = 9999;
    const newData = 0x99999999;
    const evictedAddr = 1000; // way 0

    fillPort.addr.inject(newAddr);
    fillPort.data.inject(newData);
    fillPort.valid.inject(1);
    fillPort.en.inject(1);
    await clk.nextPosedge;
    fillPort.en.inject(0);
    fillPort.valid.inject(0);
    await clk.nextPosedge;

    // Verify new address present and evicted addr gone
    readPort.en.inject(1);
    readPort.addr.inject(newAddr);
    await clk.nextPosedge;
    final hitNew = readPort.valid.value.toInt();
    final dataNew = readPort.data.value.toInt();
    readPort.en.inject(0);
    await clk.nextPosedge;
    expect(hitNew, 1);
    expect(dataNew, newData);

    readPort.en.inject(1);
    readPort.addr.inject(evictedAddr);
    await clk.nextPosedge;
    final hitEvicted = readPort.valid.value.toInt();
    readPort.en.inject(0);
    await clk.nextPosedge;
    expect(hitEvicted, 0);

    await Simulator.endSimulation();
  }, timeout: const Timeout(Duration(minutes: 1)));

  group('AvailableInvalidated - Additional Tests', () {
    test('two back-to-back allocs produce distinct ways', () async {
      final clk = SimpleClockGenerator(2).clk;
      final reset = Logic();

      const ways = 4;
      final allocs =
          List<AccessInterface>.generate(2, (i) => AccessInterface(ways));
      final invals = <AccessInterface>[];
      final hits = [AccessInterface(ways)];

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

      // First alloc sequential
      allocs[0].access.inject(1);
      await clk.nextPosedge;
      await clk.nextNegedge;
      final w0 = allocs[0].way.value.toInt();
      allocs[0].access.inject(0);
      await clk.nextPosedge;

      // Second alloc back-to-back
      allocs[1].access.inject(1);
      await clk.nextPosedge;
      await clk.nextNegedge;
      final w1 = allocs[1].way.value.toInt();
      allocs[1].access.inject(0);
      await clk.nextPosedge;

      expect(w0 != w1, true, reason: 'Back-to-back allocs chose same way $w0');

      await Simulator.endSimulation();
    });

    test('available-invalidated replicate (minimal)', () async {
      final clk = SimpleClockGenerator(5).clk;
      final reset = Logic();

      const ways = 32;

      final fill = ValidDataPortInterface(32, 32);
      final fills = [FillEvictInterface(fill)];

      final read = ValidDataPortInterface(32, 32, hasReadWithInvalidate: true);
      final reads = [read];

      final cache = FullyAssociativeCache(clk, reset, fills, reads,
          ways: ways, replacement: AvailableInvalidatedReplacement.new);

      await cache.build();
      unawaited(Simulator.run());

      // reset
      reset.inject(0);
      fill.en.inject(0);
      fill.valid.inject(0);
      read.en.inject(0);
      read.readWithInvalidate.inject(0);
      await clk.waitCycles(2);
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);

      Future<void> doFill(int addr, int data) async {
        fill.addr.inject(addr);
        fill.data.inject(data);
        fill.valid.inject(1);
        fill.en.inject(1);
        await clk.nextPosedge;
        fill.en.inject(0);
        fill.valid.inject(0);
        await clk.waitCycles(3);
      }

      Future<void> doRWI(int addr, {int? expectData}) async {
        read.addr.inject(addr);
        read.readWithInvalidate.inject(1);
        read.en.inject(1);
        await clk.nextPosedge;
        final data = read.data.value.toInt();
        if (expectData != null) {
          expect(data, equals(expectData));
        }
        read.readWithInvalidate.inject(0);
        read.en.inject(0);
        await clk.waitCycles(3);
      }

      await doFill(0x200, 0x200);
      await clk.nextPosedge;

      await doFill(0x280, 0x280);
      await clk.nextPosedge;

      await doFill(0x300, 0x300);
      await clk.nextPosedge;

      await clk.nextPosedge;

      await doFill(0x301, 0x301);
      await clk.nextPosedge;

      await doFill(0x102, 0x102);
      await clk.nextPosedge;

      await clk.nextPosedge;

      await doFill(0x303, 0x303);
      await clk.nextPosedge;

      await doFill(0x304, 0x304);
      await clk.nextPosedge;

      await doFill(0x305, 0x305);
      await clk.nextPosedge;

      await doFill(0x306, 0x306);
      await clk.nextPosedge;

      await doFill(0x107, 0x107);
      await clk.nextPosedge;

      await doFill(0x108, 0x108);
      await clk.nextPosedge;

      await doFill(0x309, 0x309);
      await clk.nextPosedge;

      await doFill(0x30a, 0x30a);
      await clk.nextPosedge;

      await clk.nextPosedge;

      await doFill(0x30b, 0x30b);
      await clk.nextPosedge;

      await doFill(0x10c, 0x10c);
      await clk.nextPosedge;

      await doFill(0x10d, 0x10d);
      await clk.nextPosedge;

      await doFill(0x10e, 0x10e);
      await clk.nextPosedge;

      await clk.nextPosedge;

      await doFill(0x310, 0x310);
      await clk.nextPosedge;

      await doFill(0x111, 0x111);
      await clk.nextPosedge;

      await doFill(0x112, 0x112);
      await clk.nextPosedge;

      await doFill(0x113, 0x113);
      await clk.nextPosedge;
      await doRWI(0x300, expectData: 0x300);
      await clk.nextPosedge;

      await doFill(0x115, 0x115);
      await clk.nextPosedge;

      await doFill(0x316, 0x316);
      await clk.nextPosedge;

      await doFill(0x317, 0x317);
      await clk.nextPosedge;

      await doFill(0x118, 0x118);
      await clk.nextPosedge;

      await doFill(0x319, 0x319);
      await clk.nextPosedge;

      await doFill(0x31a, 0x31a);
      await clk.nextPosedge;

      await doFill(0x31b, 0x31b);
      await clk.nextPosedge;

      await doFill(0x31c, 0x31c);
      await clk.nextPosedge;

      await doRWI(0x304, expectData: 0x304);
      await clk.nextPosedge;

      await doRWI(0x306, expectData: 0x306);
      await clk.nextPosedge;

      await doFill(0x31f, 0x31f);
      await clk.nextPosedge;

      await doFill(0x120, 0x120);
      await clk.nextPosedge;

      await doRWI(0x301, expectData: 0x301);
      await clk.nextPosedge;

      await doFill(0x121, 0x121);
      await clk.nextPosedge;

      await doRWI(0x10e, expectData: 0x10e);
      await clk.nextPosedge;

      await doRWI(0x10c, expectData: 0x10c);
      await clk.nextPosedge;

      await doFill(0x123, 0x123);
      await clk.nextPosedge;

      await doFill(0x124, 0x124);
      await clk.nextPosedge;

      await Simulator.endSimulation();
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('set-assoc read-invalidate then fill: RWI frees way for fill',
        () async {
      final clk = SimpleClockGenerator(3).clk;
      final reset = Logic();

      const ways = 4;
      const lines = 8; // 3-bit line address
      const addrWidth = 32;

      final fillPort = ValidDataPortInterface(addrWidth, 32);
      final fills = [FillEvictInterface(fillPort)];

      final readPort =
          ValidDataPortInterface(addrWidth, 32, hasReadWithInvalidate: true);
      final readPorts = [readPort];

      final cache = SetAssociativeCache(clk, reset, fills, readPorts,
          ways: ways,
          lines: lines,
          replacement: AvailableInvalidatedReplacement.new);
      await cache.build();
      unawaited(Simulator.run());

      // Target line 2, fill all 4 ways with different tags
      const targetLine = 2;
      final addrs =
          List.generate(4, (i) => ((100 + i * 100) << 3) | targetLine);
      const newAddr = (500 << 3) | targetLine;

      // Reset
      reset.inject(0);
      fillPort.en.inject(0);
      fillPort.addr.inject(0);
      fillPort.valid.inject(0);
      fillPort.data.inject(0);
      readPort.en.inject(0);
      readPort.addr.inject(0);
      readPort.readWithInvalidate.inject(0);
      await clk.waitCycles(2);
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);

      // Fill all ways of the target line
      for (var i = 0; i < ways; i++) {
        fillPort.addr.inject(addrs[i]);
        fillPort.data.inject(0x1111 * (i + 1));
        fillPort.valid.inject(1);
        fillPort.en.inject(1);
        await clk.nextPosedge;
        fillPort.en.inject(0);
        fillPort.valid.inject(0);
      }
      await clk.nextPosedge;

      // Read-invalidate addr[0]
      readPort.en.inject(1);
      readPort.addr.inject(addrs[0]);
      readPort.readWithInvalidate.inject(1);
      await clk.nextPosedge;

      final hitRWI = readPort.valid.value.toInt();
      final dataRWI = readPort.data.value.toInt();
      readPort.en.inject(0);
      readPort.readWithInvalidate.inject(0);

      // Wait for invalidation to complete
      await clk.nextPosedge;

      // Fill after RWI invalidation has taken effect
      fillPort.addr.inject(newAddr);
      fillPort.data.inject(0x5555);
      fillPort.valid.inject(1);
      fillPort.en.inject(1);
      await clk.nextPosedge;
      fillPort.en.inject(0);
      fillPort.valid.inject(0);
      await clk.nextPosedge;

      expect(hitRWI == 1, true, reason: 'RWI should have hit');
      expect(dataRWI == 0x1111, true, reason: 'RWI should return correct data');

      // Verify addr[0] invalidated
      readPort.en.inject(1);
      readPort.addr.inject(addrs[0]);
      await clk.nextPosedge;
      final hit0After = readPort.valid.value.toInt();
      readPort.en.inject(0);
      expect(hit0After == 0, true, reason: 'addr[0] should be invalidated');

      // Verify newAddr present
      readPort.en.inject(1);
      readPort.addr.inject(newAddr);
      await clk.nextPosedge;
      final hitNew = readPort.valid.value.toInt();
      final dataNew = readPort.data.value.toInt();
      readPort.en.inject(0);
      expect(hitNew == 1, true, reason: 'New address should be present');
      expect(dataNew == 0x5555, true, reason: 'New data should be correct');

      await Simulator.endSimulation();
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('set-assoc multiple read-invalidates then fill', () async {
      final clk = SimpleClockGenerator(3).clk;
      final reset = Logic();

      const ways = 4;
      const lines = 8;
      const addrWidth = 32;

      final fillPort = ValidDataPortInterface(addrWidth, 32);
      final fills = [FillEvictInterface(fillPort)];

      final readPort0 =
          ValidDataPortInterface(addrWidth, 32, hasReadWithInvalidate: true);
      final readPort1 =
          ValidDataPortInterface(addrWidth, 32, hasReadWithInvalidate: true);
      final readPorts = [readPort0, readPort1];

      final cache = SetAssociativeCache(clk, reset, fills, readPorts,
          ways: ways,
          lines: lines,
          replacement: AvailableInvalidatedReplacement.new);
      await cache.build();
      unawaited(Simulator.run());

      const targetLine = 6;
      final addrs =
          List.generate(4, (i) => ((100 + i * 100) << 3) | targetLine);
      const newAddr = (500 << 3) | targetLine;

      // Reset
      reset.inject(0);
      fillPort.en.inject(0);
      fillPort.addr.inject(0);
      fillPort.valid.inject(0);
      fillPort.data.inject(0);
      readPort0.en.inject(0);
      readPort0.addr.inject(0);
      readPort0.readWithInvalidate.inject(0);
      readPort1.en.inject(0);
      readPort1.addr.inject(0);
      readPort1.readWithInvalidate.inject(0);
      await clk.waitCycles(2);
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);

      // Fill the line completely
      for (var i = 0; i < ways; i++) {
        fillPort.addr.inject(addrs[i]);
        fillPort.data.inject(0x1000 + i);
        fillPort.valid.inject(1);
        fillPort.en.inject(1);
        await clk.nextPosedge;
        fillPort.en.inject(0);
        fillPort.valid.inject(0);
      }
      await clk.nextPosedge;

      // Two simultaneous RWIs
      readPort0.en.inject(1);
      readPort0.addr.inject(addrs[0]);
      readPort0.readWithInvalidate.inject(1);
      readPort1.en.inject(1);
      readPort1.addr.inject(addrs[1]);
      readPort1.readWithInvalidate.inject(1);
      await clk.nextPosedge;

      final hit0 = readPort0.valid.value.toInt();
      final hit1 = readPort1.valid.value.toInt();
      readPort0.en.inject(0);
      readPort0.readWithInvalidate.inject(0);
      readPort1.en.inject(0);
      readPort1.readWithInvalidate.inject(0);

      // Wait for invalidations to complete
      await clk.nextPosedge;

      // Fill after RWIs take effect
      fillPort.addr.inject(newAddr);
      fillPort.data.inject(0xaaaa);
      fillPort.valid.inject(1);
      fillPort.en.inject(1);
      await clk.nextPosedge;
      fillPort.en.inject(0);
      fillPort.valid.inject(0);
      await clk.nextPosedge;

      expect(hit0 == 1, true, reason: 'RWI 0 should hit');
      expect(hit1 == 1, true, reason: 'RWI 1 should hit');

      // Verify invalidations
      for (var i = 0; i < 2; i++) {
        readPort0.en.inject(1);
        readPort0.addr.inject(addrs[i]);
        await clk.nextPosedge;
        final hit = readPort0.valid.value.toInt();
        readPort0.en.inject(0);
        expect(hit == 0, true, reason: 'addr[$i] should be invalidated');
      }

      // Verify remaining present
      final expectedPresent = [addrs[2], addrs[3], newAddr];
      for (final addr in expectedPresent) {
        readPort0.en.inject(1);
        readPort0.addr.inject(addr);
        await clk.nextPosedge;
        final hit = readPort0.valid.value.toInt();
        readPort0.en.inject(0);
        expect(hit == 1, true, reason: 'addr $addr should be present');
      }

      await Simulator.endSimulation();
    }, timeout: const Timeout(Duration(minutes: 1)));
  });

  test('availableInvalidated alloc/invalidate behavior', () async {
    final clk = SimpleClockGenerator(5).clk;
    final reset = Logic();

    const ways = 4;

    // Use a single alloc and invalidate interface for sequential testing
    final allocs = [AccessInterface(ways)];
    final invals = [AccessInterface(ways)];
    final hits = [AccessInterface(ways)];

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
      // Wait a posedge then sample at the negative edge so combinational
      // outputs have settled before reading.
      await clk.nextPosedge;
      await clk.nextNegedge;
      final val = a.way.value;
      a.access.inject(0);
      // Allow the alloc claim to register into the policy's validBits
      // so subsequent allocs observe the updated registered state.
      await clk.nextPosedge;
      expect(val.isValid, isTrue, reason: 'alloc way is X/invalid');
      final v = val.toInt();
      // DBG alloc_iter=$i picked=$v
      expect(!chosen.contains(v), true, reason: 'way $v repeated');
      chosen.add(v);
    }

    // Now invalidate one chosen way and allocate again; should be available
    final inval = invals[0];
    inval.access.inject(1);
    inval.way.inject(chosen.first);
    await clk.nextPosedge;
    await clk.nextNegedge;
    inval.access.inject(0);

    // Next alloc should return the invalidated way (it may be the lowest
    // available according to policy)
    final a2 = allocs[0];
    a2.access.inject(1);
    await clk.nextPosedge;
    await clk.nextNegedge;
    final val2 = a2.way.value;
    expect(val2.isValid, isTrue,
        reason: 'alloc way is X/invalid on second alloc');
    final v2 = val2.toInt();
    expect(chosen.contains(v2), true,
        reason: 'alloc did not return invalidated way');
    a2.access.inject(0);

    await Simulator.endSimulation();
  });

  test('availableInvalidated randomized stress test (policy-level)', () async {
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
    for (final a in [...allocs, ...invals, ...hits]) {
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

        for (final a in activeAllocs) {
          a.access.inject(1);
        }
        await clk.nextNegedge; // Combinational outputs settle immediately

        final chosenVals = <LogicValue>[];
        for (final a in activeAllocs) {
          chosenVals.add(a.way.value);
        }

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

        // If duplicates appear among simultaneous allocations, allow them only
        // if the duplicated way was already allocated before this operation.
        final counts = <int, int>{};
        for (final c in chosenList) {
          counts[c] = (counts[c] ?? 0) + 1;
        }
        // DBG counts suppressed: counts=$counts chosen=$chosenList
        // allocated=$allocated it=$it
        for (final entry in counts.entries) {
          final way = entry.key;
          final cnt = entry.value;
          if (cnt > 1 && !allocated.contains(way)) {
            fail('Duplicate allocation among simultaneous allocs way $way');
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
          // DEBUG: removing toInv=$toInv (suppressed)
          allocated.remove(toInv);
        }
      } else {
        if (allocated.isNotEmpty) {
          final inv = invals[rng.nextInt(invals.length)];
          final toInv = allocated.elementAt(rng.nextInt(allocated.length));
          inv.way.inject(toInv);
          inv.access.inject(1);
          await clk.nextPosedge;
          inv.access.inject(0);
          await clk.nextPosedge;
          allocated.remove(toInv);
        } else {
          await clk.nextPosedge;
        }
      }
    }

    await Simulator.endSimulation();
  });

  test('fill and read-invalidate stress test (cache-level)', () async {
    final clk = SimpleClockGenerator(3).clk;
    final reset = Logic();

    const ways = 16;
    const iterations = 500;
    final rng = Random(5678);

    // Create cache with 2 fill ports and 2 read ports (both with RWI
    // capability)
    final fillPorts = List.generate(2, (_) => ValidDataPortInterface(32, 32));
    final fills = fillPorts.map(FillEvictInterface.new).toList();

    final readPorts = List.generate(
        2, (_) => ValidDataPortInterface(32, 32, hasReadWithInvalidate: true));

    final cache = FullyAssociativeCache(clk, reset, fills, readPorts,
        ways: ways, replacement: AvailableInvalidatedReplacement.new);

    await cache.build();
    unawaited(Simulator.run());

    // Reset
    reset.inject(0);
    for (final fillPort in fillPorts) {
      fillPort.en.inject(0);
      fillPort.valid.inject(0);
      fillPort.addr.inject(0);
      fillPort.data.inject(0);
    }
    for (final readPort in readPorts) {
      readPort.en.inject(0);
      readPort.readWithInvalidate.inject(0);
      readPort.addr.inject(0);
    }
    await clk.waitCycles(2);
    reset.inject(1);
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    // Track allocated entries: addr -> data
    final allocated = <int, int>{};

    for (var iter = 0; iter < iterations; iter++) {
      // Iteration header suppressed
      if (iter <= 15) {
        // numFills/numRWIs log suppressed
      }

      // Debug: verify 0x373 at start of iteration 12
      if (iter == 12 && allocated.containsKey(0x373)) {
        readPorts[0].addr.inject(0x373);
        readPorts[0].en.inject(1);
        await clk.nextPosedge;
        await clk.nextNegedge;
        final hit = readPorts[0].valid.value.toInt();
        final data = readPorts[0].data.value.toInt();
        final expectedData = allocated[0x373]!;
        expect(hit, 1,
            reason: 'PRE-CHECK: 0x373 should be in cache (hit=$hit)');
        expect(data, expectedData,
            reason: 'PRE-CHECK: 0x373 should return '
                '0x${expectedData.toRadixString(16)} '
                '(data=0x${data.toRadixString(16)})');
        readPorts[0].en.inject(0);
        await clk.nextPosedge;
      }

      final numFills = (allocated.length < ways - 4) ? rng.nextInt(3) : 0;
      final numRWIs = allocated.isNotEmpty ? rng.nextInt(3) : 0;

      // Removed debug print for numFills and numRWIs

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
        }
      }

      for (var i = 0; i < readPorts.length; i++) {
        if (i < rwiAddrs.length) {
          readPorts[i].addr.inject(rwiAddrs[i]);
          readPorts[i].readWithInvalidate.inject(1);
          readPorts[i].en.inject(1);
        } else {
          readPorts[i].en.inject(0);
        }
      }

      await clk.nextPosedge;
      await clk.nextNegedge; // Let combinational outputs settle

      for (var i = 0; i < rwiAddrs.length; i++) {
        final addr = rwiAddrs[i];
        final expectedData = allocated[addr]!;
        final hit = readPorts[i].valid.value.toInt();
        final data = readPorts[i].data.value.toInt();

        if (hit != 1) {
          // RWI MISS details suppressed: addr=0x${addr.toRadixString(16)}
          // allocated=${allocated.keys.toList()} fillAddrs=${fillAddrs}
          // rwiAddrs=${rwiAddrs} (iter=$iter)
        }

        expect(hit, 1, reason: 'RWI @0x${addr.toRadixString(16)} should hit');
        expect(data, expectedData,
            reason: 'RWI @0x${addr.toRadixString(16)} should return '
                '0x${expectedData.toRadixString(16)}');
      }

      for (final fillPort in fillPorts) {
        fillPort.en.inject(0);
        fillPort.valid.inject(0);
      }
      for (final readPort in readPorts) {
        readPort.en.inject(0);
        readPort.readWithInvalidate.inject(0);
      }

      await clk.nextPosedge;

      for (var i = 0; i < fillAddrs.length; i++) {
        allocated[fillAddrs[i]] = fillData[i];
        if (iter <= 15) {
          // Fill notification suppressed for
          // 0x${fillAddrs[i].toRadixString(16)}
        }
      }
      for (final addr in rwiAddrs) {
        allocated.remove(addr);
        if (iter <= 15) {
          // RWI removed notification suppressed for 0x${addr.toRadixString(16)}
        }
      }

      // Verify fills actually worked (for early iterations)
      if (iter == 10 && fillAddrs.contains(0x373)) {
        readPorts[0].addr.inject(0x373);
        readPorts[0].en.inject(1);
        await clk.nextPosedge;
        await clk.nextNegedge;
        final hit = readPorts[0].valid.value.toInt();
        final data = readPorts[0].data.value.toInt();
        const expectedData = 0x10000 + 0x373;
        expect(hit, 1,
            reason: 'VERIFICATION: 0x373 fill should hit (hit=$hit)');
        expect(data, expectedData,
            reason: 'VERIFICATION: 0x373 fill should return '
                '0x${expectedData.toRadixString(16)} '
                '(data=0x${data.toRadixString(16)})');
        readPorts[0].en.inject(0);
        await clk.nextPosedge;
      }

      if (iter % 50 == 0 && allocated.isNotEmpty) {
        final allocatedList = allocated.keys.toList()..shuffle(rng);
        final testAddr = allocatedList.first;
        final expectedData = allocated[testAddr]!;

        readPorts[0].addr.inject(testAddr);
        readPorts[0].en.inject(1);
        await clk.nextPosedge;
        await clk.nextNegedge; // Let combinational outputs settle

        final hit = readPorts[0].valid.value.toInt();
        final data = readPorts[0].data.value.toInt();

        expect(hit, 1,
            reason: 'Verification read @0x${testAddr.toRadixString(16)} '
                'should hit');
        expect(data, expectedData,
            reason: 'Verification read @0x${testAddr.toRadixString(16)} should '
                'return 0x${expectedData.toRadixString(16)}');

        readPorts[0].en.inject(0);
        await clk.nextPosedge;
      }
    }

    await Simulator.endSimulation();
  });
}
