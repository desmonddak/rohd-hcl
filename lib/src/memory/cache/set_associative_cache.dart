// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// set_associative_cache.dart
// Set-associative cache implementation.
//
// 2025 September 10
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

/// A set-associative cache supporting multiple read and fill ports.
class SetAssociativeCache extends Cache {
  // Protected width fields derived from constructor parameters and ports.
  // These are initialized at the start of buildLogic().
  late int _lineAddrWidth;
  late int _tagWidth;
  late int _dataWidth;

  /// Constructs a [Cache] supporting multiple read and fill ports.
  ///
  /// Defines a set-associativity of [ways] and a depth or number of [lines].
  /// The total capacity of the cache is [ways]*[lines]. The [replacement]
  /// policy is used to choose which way to evict on a fill miss.
  ///
  /// This cache is a read-cache. It does not track dirty data to implement
  /// write-back. The write policy it would support is a write-around policy.
  SetAssociativeCache(super.clk, super.reset, super.fills, super.reads,
      {super.ways, super.lines, super.replacement});

  @override
  void buildLogic() {
    final numReads = reads.length;
    final numFills = fills.length;
    // Initialize derived widths and mirror into protected instance fields
    _lineAddrWidth = log2Ceil(lines);
    _tagWidth = reads[0].addrWidth - _lineAddrWidth;
    _dataWidth = dataWidth;

    // Create tag RF interfaces (without valid bit)
    final tagRFMatchFl = _genTagRFInterfaces(
        [for (final f in fills) f.fill], _tagWidth, _lineAddrWidth,
        prefix: 'match_fl');
    final tagRFMatchRd = _genTagRFInterfaces(reads, _tagWidth, _lineAddrWidth,
        prefix: 'match_rd');
    final tagRFAlloc = _genTagRFInterfaces(
        [for (final f in fills) f.fill], _tagWidth, _lineAddrWidth,
        prefix: 'alloc');

    // Create eviction tag read ports if needed (one per fill port per way)
    final hasEvictions = fills.isNotEmpty && fills[0].eviction != null;
    final evictTagRfReadPorts = hasEvictions
        ? List.generate(
            ways,
            (way) => List.generate(
                numFills,
                (i) => DataPortInterface(_tagWidth, _lineAddrWidth)
                  ..en.named('evictTagRd_way${way}_port${i}_en')
                  ..addr.named('evictTagRd_way${way}_port${i}_addr')
                  ..data.named('evictTagRd_way${way}_port${i}_data')))
        : <List<DataPortInterface>>[];

    // The Tag `RegisterFile` (without valid bit).
    for (var way = 0; way < ways; way++) {
      // Combine the read and fill match ports for this way.
      final tagRFMatch = [...tagRFMatchFl[way], ...tagRFMatchRd[way]];
      final allTagReadPorts = hasEvictions
          ? [...tagRFMatch, ...evictTagRfReadPorts[way]]
          : tagRFMatch;
      RegisterFile(clk, reset, tagRFAlloc[way], allTagReadPorts,
          numEntries: lines, name: 'tag_rf_way$way');
    }

    // Create valid bit register files (one bit wide, indexed by line address).
    // Each way has its own valid bit RF.
    // validBitRF[way][port] where port includes both reads and fills.
    final validBitRFWritePorts = List.generate(
        ways,
        (way) => List.generate(
            numFills + numReads, // Fills + potential read invalidates
            (i) => DataPortInterface(1, _lineAddrWidth)
              ..en.named('validBitWr_way${way}_port${i}_en')
              ..addr.named('validBitWr_way${way}_port${i}_addr')
              ..data.named('validBitWr_way${way}_port${i}_data')));

    final validBitRFReadPorts = List.generate(
        ways,
        (way) => List.generate(
            numFills + numReads, // For fill and read checks
            (i) => DataPortInterface(1, _lineAddrWidth)
              ..en.named('validBitRd_way${way}_port${i}_en')
              ..addr.named('validBitRd_way${way}_port${i}_addr')
              ..data.named('validBitRd_way${way}_port${i}_data')));

    // Create valid bit register files
    for (var way = 0; way < ways; way++) {
      RegisterFile(
          clk, reset, validBitRFWritePorts[way], validBitRFReadPorts[way],
          numEntries: lines, name: 'valid_bit_rf_way$way');
    }

    // Setup the tag match fill interfaces and valid bit reads for fills.
    // Move the actual wiring into a per-port helper so match ports are
    // prepared before the match one-hot computations below.
    for (var flPortIdx = 0; flPortIdx < numFills; flPortIdx++) {
      final flPort = fills[flPortIdx].fill;
      final perWayTagMatchFl = [
        for (var way = 0; way < ways; way++) tagRFMatchFl[way][flPortIdx]
      ];
      final perWayValidBitRd = [
        for (var way = 0; way < ways; way++) validBitRFReadPorts[way][flPortIdx]
      ];
      _prepareFillPortMatches(flPort, perWayTagMatchFl, perWayValidBitRd);
    }

    final fillPortValidOneHot = [
      for (var flPortIdx = 0; flPortIdx < numFills; flPortIdx++)
        [
          for (var way = 0; way < ways; way++)
            (validBitRFReadPorts[way][flPortIdx].data[0] &
                    tagRFMatchFl[way][flPortIdx]
                        .data
                        .eq(getTag(fills[flPortIdx].fill.addr)))
                .named('match_fl${flPortIdx}_way$way')
        ]
    ];
    final fillPortValidWay = [
      for (var fillPortIdx = 0; fillPortIdx < numFills; fillPortIdx++)
        RecursivePriorityEncoder(fillPortValidOneHot[fillPortIdx].rswizzle())
            .out
            .slice(log2Ceil(ways) - 1, 0)
            .named('fill_port${fillPortIdx}_way')
    ];
    final fillValidPortMiss = [
      for (var fillPortIdx = 0; fillPortIdx < numFills; fillPortIdx++)
        (~[
          for (var way = 0; way < ways; way++)
            fillPortValidOneHot[fillPortIdx][way]
        ].swizzle().or())
            .named('fill_port${fillPortIdx}_miss')
    ];

    // Setup the tag match read interfaces and valid bit reads for reads.
    // Wire the per-way tag match and valid-bit read ports via a helper so
    // the wiring is colocated with other read-port logic.
    for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++) {
      final rdPort = reads[rdPortIdx];
      final perWayTagMatchRd = [
        for (var way = 0; way < ways; way++) tagRFMatchRd[way][rdPortIdx]
      ];
      final perWayValidBitRd = [
        for (var way = 0; way < ways; way++)
          validBitRFReadPorts[way][numFills + rdPortIdx]
      ];
      _prepareReadPortMatches(rdPort, perWayTagMatchRd, perWayValidBitRd);
    }

    final readPortValidOneHot = [
      for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++)
        [
          for (var way = 0; way < ways; way++)
            (validBitRFReadPorts[way][numFills + rdPortIdx].data[0] &
                    tagRFMatchRd[way][rdPortIdx]
                        .data
                        .eq(getTag(reads[rdPortIdx].addr)))
                .named('match_rd${rdPortIdx}_way$way')
        ]
    ];
    final readValidPortMiss = [
      for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++)
        (~[
          for (var way = 0; way < ways; way++)
            readPortValidOneHot[rdPortIdx][way]
        ].swizzle().or())
            .named('read_port${rdPortIdx}_miss')
    ];
    final readValidPortWay = [
      for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++)
        RecursivePriorityEncoder(readPortValidOneHot[rdPortIdx].rswizzle())
            .out
            .slice(log2Ceil(ways) - 1, 0)
            .named('read_port${rdPortIdx}_way')
    ];

    // Generate the replacment policy logic. Fills and reads both create
    // hits. A fill miss causes an allocation followed by a hit.

    final policyFlHitPorts = _genReplacementAccesses(
        [for (final f in fills) f.fill],
        prefix: 'rp_fl');
    final policyRdHitPorts = _genReplacementAccesses(reads, prefix: 'rp_rd');
    final policyAllocPorts = _genReplacementAccesses(
        [for (final f in fills) f.fill],
        prefix: 'rp_alloc');
    final policyInvalPorts = _genReplacementAccesses(
        [for (final f in fills) f.fill],
        prefix: 'rp_inval');

    for (var line = 0; line < lines; line++) {
      replacement(
          clk,
          reset,
          policyFlHitPorts[line]..addAll(policyRdHitPorts[line]),
          policyAllocPorts[line],
          policyInvalPorts[line],
          name: 'rp_line$line',
          ways: ways);
    }

    // Eviction and fill helpers implemented as class-level methods below.

    // The per-fill policy wiring and allocation/update helpers are
    // invoked per-fill port later when we build per-port slices and call
    // the per-port helpers. This ensures per-port wiring is colocated and
    // avoids duplicate signal assignments.
    // The Data `RegisterFile`.
    // Each way has its own RF, indexed by line address.

    // Create eviction data read ports if needed (one per fill port per way)
    final evictDataRfReadPorts = hasEvictions
        ? List.generate(
            ways,
            (way) => List.generate(
                numFills,
                (i) => DataPortInterface(_dataWidth, _lineAddrWidth)
                  ..en.named('evictDataRd_way${way}_port${i}_en')
                  ..addr.named('evictDataRd_way${way}_port${i}_addr')
                  ..data.named('evictDataRd_way${way}_port${i}_data')))
        : <List<DataPortInterface>>[];

    final fillDataPorts = _genDataInterfaces(
        [for (final f in fills) f.fill], _dataWidth, _lineAddrWidth,
        prefix: 'data_fl');
    final readDataPorts = _genDataInterfaces(reads, _dataWidth, _lineAddrWidth,
        prefix: 'data_rd');

    for (var way = 0; way < ways; way++) {
      final allDataReadPorts = hasEvictions
          ? [...readDataPorts[way], ...evictDataRfReadPorts[way]]
          : readDataPorts[way];
      RegisterFile(clk, reset, fillDataPorts[way], allDataReadPorts,
          numEntries: lines, name: 'data_rf_way$way');
    }

    for (var flPortIdx = 0; flPortIdx < numFills; flPortIdx++) {
      // Build per-port slices so the class-level helper can operate on a
      // single-port view without indexing into the 2D arrays.
      final flPort = fills[flPortIdx].fill;
      final perWayFillDataPorts = [
        for (var way = 0; way < ways; way++) fillDataPorts[way][flPortIdx]
      ];
      final perWayTagAllocPorts = [
        for (var way = 0; way < ways; way++) tagRFAlloc[way][flPortIdx]
      ];
      final perWayValidBitWrPorts = [
        for (var way = 0; way < ways; way++)
          validBitRFWritePorts[way][flPortIdx]
      ];
      final perLinePolicyAllocPorts = [
        for (var line = 0; line < lines; line++)
          policyAllocPorts[line][flPortIdx]
      ];
      final perLinePolicyInvalPorts = [
        for (var line = 0; line < lines; line++)
          policyInvalPorts[line][flPortIdx]
      ];
      final perLinePolicyFlHitPorts = [
        for (var line = 0; line < lines; line++)
          policyFlHitPorts[line][flPortIdx]
      ];

      if (hasEvictions) {
        final perWayEvictTagReadPorts = [
          for (var way = 0; way < ways; way++)
            evictTagRfReadPorts[way][flPortIdx]
        ];
        final perWayEvictDataReadPorts = [
          for (var way = 0; way < ways; way++)
            evictDataRfReadPorts[way][flPortIdx]
        ];
        final perWayValidBitRdPorts = [
          for (var way = 0; way < ways; way++)
            validBitRFReadPorts[way][flPortIdx]
        ];

        _handleFillPort(
            flPort,
            fillValidPortMiss[flPortIdx],
            fillPortValidWay[flPortIdx],
            perWayFillDataPorts,
            perWayTagAllocPorts,
            perWayValidBitWrPorts,
            perLinePolicyAllocPorts,
            perLinePolicyFlHitPorts,
            perLinePolicyInvalPorts,
            perWayEvictTagReadPorts,
            perWayEvictDataReadPorts,
            perWayValidBitRdPorts,
            fills[flPortIdx].eviction,
            flPortIdx.toString());
      } else {
        _handleFillPort(
            flPort,
            fillValidPortMiss[flPortIdx],
            fillPortValidWay[flPortIdx],
            perWayFillDataPorts,
            perWayTagAllocPorts,
            perWayValidBitWrPorts,
            perLinePolicyAllocPorts,
            perLinePolicyFlHitPorts,
            perLinePolicyInvalPorts);
      }
    }
    // Write after read is:
    //   - We first clear RF enable.
    //   - RF.data is set by the storageBank in the RF on the clock edge.
    //   - We read the RF data below after it is written
    // Fix is to put the RF enable clear in the Else of the If below.

    // Replace per-read inline logic with a per-port helper that receives
    // per-way slices so the helper can operate on a single port view.
    for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++) {
      final rdPort = reads[rdPortIdx];

      final perWayReadDataPorts = [
        for (var way = 0; way < ways; way++) readDataPorts[way][rdPortIdx]
      ];
      final perWayValidBitWrPorts = [
        for (var way = 0; way < ways; way++)
          validBitRFWritePorts[way][numFills + rdPortIdx]
      ];

      final perLinePolicyRdHitPorts = [
        for (var line = 0; line < lines; line++)
          policyRdHitPorts[line][rdPortIdx]
      ];

      _handleReadPort(
          rdPort,
          readValidPortMiss[rdPortIdx],
          readValidPortWay[rdPortIdx],
          perWayReadDataPorts,
          perWayValidBitWrPorts,
          perLinePolicyRdHitPorts);
    }

    // Eviction handling is now invoked from within _handleFillPort when
    // eviction ports are present. The per-port invocation occurs at the
    // time fills are processed above, so there's no separate top-level
    // eviction loop needed here.
  }

  // Class-level eviction helper: perform eviction read/select and drive the
  // eviction output for a single fill/eviction port. Mirrors the previous
  // local helper but exists at class scope.
  void _handleEvictPort(
      ValidDataPortInterface evictPort,
      ValidDataPortInterface fillPort,
      Logic fillMiss,
      Logic fillPortValidWay,
      List<DataPortInterface> perWayEvictTagReadPorts,
      List<DataPortInterface> perWayEvictDataReadPorts,
      List<AccessInterface> perLinePolicyAllocPorts,
      List<DataPortInterface> perWayValidBitRdPorts,
      String nameSuffix) {
    for (var way = 0; way < ways; way++) {
      final evictTagReadPort = perWayEvictTagReadPorts[way];
      final evictDataReadPort = perWayEvictDataReadPorts[way];

      evictTagReadPort.en <= fillPort.en;
      evictTagReadPort.addr <= getLine(fillPort.addr);

      evictDataReadPort.en <= fillPort.en;
      evictDataReadPort.addr <= getLine(fillPort.addr);
    }

    final evictWay =
        Logic(name: 'evict${nameSuffix}Way', width: log2Ceil(ways));
    final fillHasHit = ~fillMiss;

    final allocWay =
        Logic(name: 'evict${nameSuffix}AllocWay', width: log2Ceil(ways));
    final hitWay =
        Logic(name: 'evict${nameSuffix}HitWay', width: log2Ceil(ways));

    if (lines == 1) {
      allocWay <= perLinePolicyAllocPorts[0].way;
      hitWay <= fillPortValidWay;
    } else {
      final allocCases = <CaseItem>[];
      final hitCases = <CaseItem>[];
      for (var line = 0; line < lines; line++) {
        allocCases.add(CaseItem(Const(line, width: _lineAddrWidth),
            [allocWay < perLinePolicyAllocPorts[line].way]));
        hitCases.add(CaseItem(
            Const(line, width: _lineAddrWidth), [hitWay < fillPortValidWay]));
      }
      Combinational([Case(getLine(fillPort.addr), allocCases)]);
      Combinational([Case(getLine(fillPort.addr), hitCases)]);
    }

    Combinational([
      If(fillHasHit, then: [evictWay < hitWay], orElse: [evictWay < allocWay])
    ]);

    final evictTag = Logic(name: 'evict${nameSuffix}Tag', width: _tagWidth);
    final evictData = Logic(name: 'evict${nameSuffix}Data', width: _dataWidth);

    if (ways == 1) {
      evictTag <= perWayEvictTagReadPorts[0].data;
      evictData <= perWayEvictDataReadPorts[0].data;
    } else {
      final tagSelections = <Conditional>[];
      final dataSelections = <Conditional>[];
      for (var way = 0; way < ways; way++) {
        final isThisWay = evictWay.eq(Const(way, width: log2Ceil(ways)));
        tagSelections.add(If(isThisWay,
            then: [evictTag < perWayEvictTagReadPorts[way].data]));
        dataSelections.add(If(isThisWay,
            then: [evictData < perWayEvictDataReadPorts[way].data]));
      }
      Combinational([
        evictTag < Const(0, width: _tagWidth),
        ...tagSelections,
      ]);
      Combinational([
        evictData < Const(0, width: _dataWidth),
        ...dataSelections,
      ]);
    }

    final allocWayValid = Logic(name: 'allocWayValid$nameSuffix');
    if (ways == 1) {
      allocWayValid <= perWayValidBitRdPorts[0].data[0];
    } else {
      final validSelections = <Logic>[];
      for (var way = 0; way < ways; way++) {
        validSelections.add(evictWay.eq(Const(way, width: log2Ceil(ways))) &
            perWayValidBitRdPorts[way].data[0]);
      }
      allocWayValid <=
          validSelections
              .reduce((a, b) => a | b)
              .named('allocWayValidReduction$nameSuffix');
    }

    final allocEvictCond = (fillPort.valid & ~fillHasHit & allocWayValid)
        .named('allocEvictCond$nameSuffix');
    final invalEvictCond =
        (~fillPort.valid & fillHasHit).named('invalEvictCond$nameSuffix');

    final evictAddrComb =
        Logic(name: 'evictAddrComb$nameSuffix', width: fillPort.addrWidth);
    Combinational([
      If(invalEvictCond, then: [
        evictAddrComb < fillPort.addr
      ], orElse: [
        evictAddrComb < [evictTag, getLine(fillPort.addr)].swizzle()
      ])
    ]);

    Combinational([
      evictPort.en < (fillPort.en & (invalEvictCond | allocEvictCond)),
      evictPort.valid < (fillPort.en & (invalEvictCond | allocEvictCond)),
      evictPort.addr < evictAddrComb,
      evictPort.data < evictData,
    ]);
  }

  // Class-level private helper: top-level fill handling for a single fill
  // port. Operates on per-port slices passed in from buildLogic() so it
  // doesn't reference buildLogic() locals directly.
  void _handleFillPort(
      ValidDataPortInterface flPort,
      Logic fillMiss,
      Logic fillPortValidWay,
      List<DataPortInterface> perWayFillDataPorts,
      List<DataPortInterface> perWayTagAllocPorts,
      List<DataPortInterface> perWayValidBitWrPorts,
      List<AccessInterface> perLinePolicyAllocPorts,
      List<AccessInterface> perLinePolicyFlHitPorts,
      List<AccessInterface> perLinePolicyInvalPorts,
      [List<DataPortInterface>? perWayEvictTagReadPorts,
      List<DataPortInterface>? perWayEvictDataReadPorts,
      List<DataPortInterface>? perWayValidBitRdPorts,
      ValidDataPortInterface? evictPort,
      String? nameSuffix]) {
    // Policy: initialize and drive per-line policy ports for this fill
    // port (fl hit, inval, alloc). This was previously in buildLogic().
    Combinational([
      for (var line = 0; line < lines; line++)
        perLinePolicyInvalPorts[line].access < Const(0),
      for (var line = 0; line < lines; line++)
        perLinePolicyFlHitPorts[line].access < Const(0),
      If(flPort.en, then: [
        for (var line = 0; line < lines; line++)
          If(getLine(flPort.addr).eq(Const(line, width: _lineAddrWidth)),
              then: [
                If.block([
                  Iff(flPort.valid & ~fillMiss, [
                    perLinePolicyFlHitPorts[line].access < flPort.en,
                    perLinePolicyFlHitPorts[line].way < fillPortValidWay,
                  ]),
                  ElseIf(~flPort.valid, [
                    perLinePolicyInvalPorts[line].access < flPort.en,
                    perLinePolicyInvalPorts[line].way < fillPortValidWay,
                  ]),
                ])
              ])
      ])
    ]);

    // Policy: Process fill misses (allocations)
    for (var line = 0; line < lines; line++) {
      perLinePolicyAllocPorts[line].access <=
          flPort.en &
              flPort.valid &
              fillMiss &
              getLine(flPort.addr).eq(Const(line, width: _lineAddrWidth));
    }
    // Perform tag allocations and valid-bit updates for this fill port.
    _handleFillAllocAndValidUpdates(
        flPort,
        fillMiss,
        fillPortValidWay,
        perWayTagAllocPorts,
        perLinePolicyAllocPorts,
        perLinePolicyInvalPorts,
        perWayValidBitWrPorts);

    // Data RF writes (per-way)
    for (var way = 0; way < ways; way++) {
      final matchWay = Const(way, width: log2Ceil(ways));
      final fillRFPort = perWayFillDataPorts[way];
      Combinational([
        fillRFPort.en < Const(0),
        fillRFPort.addr < Const(0, width: _lineAddrWidth),
        fillRFPort.data < Const(0, width: _dataWidth),
        If(flPort.en & flPort.valid, then: [
          for (var line = 0; line < lines; line++)
            If(
                fillMiss &
                        perLinePolicyAllocPorts[line].access &
                        perLinePolicyAllocPorts[line].way.eq(matchWay) |
                    ~fillMiss &
                        perLinePolicyFlHitPorts[line].access &
                        fillPortValidWay.eq(matchWay),
                then: [
                  fillRFPort.addr < getLine(flPort.addr),
                  fillRFPort.data < flPort.data,
                  fillRFPort.en < flPort.en,
                ])
        ])
      ]);
    }
    // Optionally perform eviction handling if eviction ports were provided
    // (passed in by buildLogic()).
    if (evictPort != null &&
        perWayEvictTagReadPorts != null &&
        perWayEvictDataReadPorts != null &&
        perWayValidBitRdPorts != null) {
      _handleEvictPort(
          evictPort,
          flPort,
          fillMiss,
          fillPortValidWay,
          perWayEvictTagReadPorts,
          perWayEvictDataReadPorts,
          perLinePolicyAllocPorts,
          perWayValidBitRdPorts,
          nameSuffix ?? '');
    }
  }

  // Helper: process tag allocations and valid-bit updates for a single fill
  // port. This was extracted from buildLogic() to reduce duplication and
  // clarify responsibilities.
  void _handleFillAllocAndValidUpdates(
      ValidDataPortInterface flPort,
      Logic fillMiss,
      Logic fillPortValidWay,
      List<DataPortInterface> perWayTagAllocPorts,
      List<AccessInterface> perLinePolicyAllocPorts,
      List<AccessInterface> perLinePolicyInvalPorts,
      List<DataPortInterface> perWayValidBitWrPorts) {
    // Tag RF (alloc/inval) defaults
    Combinational([
      for (var way = 0; way < ways; way++)
        perWayTagAllocPorts[way].en < Const(0),
      for (var way = 0; way < ways; way++)
        perWayTagAllocPorts[way].addr < Const(0, width: _lineAddrWidth),
      for (var way = 0; way < ways; way++)
        perWayTagAllocPorts[way].data < Const(0, width: _tagWidth),
      If(flPort.en, then: [
        for (var line = 0; line < lines; line++)
          If(getLine(flPort.addr).eq(Const(line, width: _lineAddrWidth)),
              then: [
                for (var way = 0; way < ways; way++)
                  If.block([
                    Iff(
                        // Fill with allocate.
                        flPort.valid &
                            fillMiss &
                            Const(way, width: log2Ceil(ways))
                                .eq(perLinePolicyAllocPorts[line].way),
                        [
                          perWayTagAllocPorts[way].en < flPort.en,
                          perWayTagAllocPorts[way].addr <
                              Const(line, width: _lineAddrWidth),
                          perWayTagAllocPorts[way].data < getTag(flPort.addr),
                        ]),
                    ElseIf(
                        // Fill with invalidate.
                        ~flPort.valid &
                            Const(way, width: log2Ceil(ways))
                                .eq(perLinePolicyInvalPorts[line].way),
                        [
                          perWayTagAllocPorts[way].en < flPort.en,
                          perWayTagAllocPorts[way].addr <
                              Const(line, width: _lineAddrWidth),
                          perWayTagAllocPorts[way].data < getTag(flPort.addr),
                        ]),
                  ])
              ])
      ])
    ]);

    // Valid-bit writes from fills: default to disabled, enable on fill
    for (var way = 0; way < ways; way++) {
      final matchWay = Const(way, width: log2Ceil(ways));
      final validBitWrPort = perWayValidBitWrPorts[way];

      // Check whether allocator chose this way for the given line
      final allocMatches = [
        for (var line = 0; line < lines; line++)
          getLine(flPort.addr).eq(Const(line, width: _lineAddrWidth)) &
              perLinePolicyAllocPorts[line].way.eq(matchWay)
      ];
      final allocMatch = allocMatches.isEmpty
          ? Const(0)
          : allocMatches.reduce((a, b) => a | b);

      Combinational([
        validBitWrPort.en < Const(0),
        validBitWrPort.addr < Const(0, width: _lineAddrWidth),
        validBitWrPort.data < Const(0, width: 1),
        If(flPort.en, then: [
          If.block([
            // Valid fill with hit or miss - set valid bit to 1
            Iff(
                flPort.valid &
                    (~fillMiss & fillPortValidWay.eq(matchWay) |
                        fillMiss & allocMatch),
                [
                  validBitWrPort.en < Const(1),
                  validBitWrPort.addr < getLine(flPort.addr),
                  validBitWrPort.data < Const(1, width: 1),
                ]),
            // Invalid fill (invalidation) - set valid bit to 0
            ElseIf(~flPort.valid & ~fillMiss & fillPortValidWay.eq(matchWay), [
              validBitWrPort.en < Const(1),
              validBitWrPort.addr < getLine(flPort.addr),
              validBitWrPort.data < Const(0, width: 1),
            ]),
          ])
        ])
      ]);
    }
  }

  // Class-level helper: process a single read port. Operates on per-way
  // slices for data read ports and valid-bit write ports so it doesn't
  // index into buildLogic() locals.
  void _handleReadPort(
      ValidDataPortInterface rdPort,
      Logic readMiss,
      Logic readPortValidWay,
      List<DataPortInterface> perWayReadDataPorts,
      List<DataPortInterface> perWayValidBitWrPorts,
      List<AccessInterface> perLinePolicyRdHitPorts) {
    final hasHit = ~readMiss;

    Combinational([
      rdPort.valid < Const(0),
      rdPort.data < Const(0, width: rdPort.dataWidth),
      If(rdPort.en & hasHit, then: [
        for (var way = 0; way < ways; way++)
          If(readPortValidWay.eq(Const(way, width: log2Ceil(ways))), then: [
            perWayReadDataPorts[way].en < rdPort.en,
            perWayReadDataPorts[way].addr < getLine(rdPort.addr),
            rdPort.data < perWayReadDataPorts[way].data,
            rdPort.valid < Const(1),
          ], orElse: [
            perWayReadDataPorts[way].en < Const(0)
          ])
      ])
    ]);

    // Policy: process read hits for the replacement policy. Move this per-
    // port wiring here so the policy access ports are created and driven
    // together with the rest of the read-port wiring.
    for (var line = 0; line < lines; line++) {
      perLinePolicyRdHitPorts[line].access <=
          rdPort.en &
              ~readMiss &
              getLine(rdPort.addr).eq(Const(line, width: _lineAddrWidth));
      perLinePolicyRdHitPorts[line].way <= readPortValidWay;
    }

    // Handle readWithInvalidate functionality - write to valid bit RF
    // on next cycle.
    if (rdPort.hasReadWithInvalidate) {
      for (var way = 0; way < ways; way++) {
        final matchWay = Const(way, width: log2Ceil(ways));
        final validBitWrPort = perWayValidBitWrPorts[way];

        // Register the signals for next cycle write
        final shouldInvalidate = flop(
            clk,
            rdPort.readWithInvalidate &
                hasHit &
                rdPort.en &
                readPortValidWay.eq(matchWay),
            reset: reset);
        final invalidateAddr = flop(clk, getLine(rdPort.addr), reset: reset);

        Combinational([
          validBitWrPort.en < shouldInvalidate,
          validBitWrPort.addr < invalidateAddr,
          validBitWrPort.data < Const(0, width: 1),
        ]);
      }
    } else {
      // No readWithInvalidate, so no valid bit writes from this read port.
      for (var way = 0; way < ways; way++) {
        final validBitWrPort = perWayValidBitWrPorts[way];
        validBitWrPort.en <= Const(0);
        validBitWrPort.addr <= Const(0, width: _lineAddrWidth);
        validBitWrPort.data <= Const(0, width: 1);
      }
    }
  }

  // Prepare tag-match and valid-bit read ports for a single fill port.
  void _prepareFillPortMatches(
      ValidDataPortInterface flPort,
      List<DataPortInterface> perWayTagMatchFl,
      List<DataPortInterface> perWayValidBitRd) {
    for (var way = 0; way < ways; way++) {
      perWayTagMatchFl[way].addr <= getLine(flPort.addr);
      perWayTagMatchFl[way].en <= flPort.en;

      perWayValidBitRd[way].addr <= getLine(flPort.addr);
      perWayValidBitRd[way].en <= flPort.en;
    }
  }

  // Prepare tag-match and valid-bit read ports for a single read port.
  void _prepareReadPortMatches(
      ValidDataPortInterface rdPort,
      List<DataPortInterface> perWayTagMatchRd,
      List<DataPortInterface> perWayValidBitRd) {
    for (var way = 0; way < ways; way++) {
      perWayTagMatchRd[way].addr <= getLine(rdPort.addr);
      perWayTagMatchRd[way].en <= rdPort.en;

      perWayValidBitRd[way].addr <= getLine(rdPort.addr);
      perWayValidBitRd[way].en <= rdPort.en;
    }
  }

  /// Generates a 2D list of [DataPortInterface]s for the tag RF (without valid
  /// bit). The dimensions are [ways][ports].
  List<List<DataPortInterface>> _genTagRFInterfaces(
      List<ValidDataPortInterface> ports, int tagWidth, int addressWidth,
      {String prefix = 'tag'}) {
    final dataPorts = [
      for (var way = 0; way < ways; way++)
        [
          for (var r = 0; r < ports.length; r++)
            DataPortInterface(tagWidth, addressWidth)
        ]
    ];
    for (var way = 0; way < ways; way++) {
      for (var r = 0; r < ports.length; r++) {
        final fullPrefix = '${prefix}_way${way}_port${r}_way$way';
        dataPorts[way][r].en.named('${fullPrefix}_en');
        dataPorts[way][r].addr.named('${fullPrefix}_addr');
        dataPorts[way][r].data.named('${fullPrefix}_data');
      }
    }
    return dataPorts;
  }

  /// Generates a 2D list of [DataPortInterface]s for the data RF.
  /// The dimensions are [ways][ports].
  List<List<DataPortInterface>> _genDataInterfaces(
      List<DataPortInterface> ports, int dataWidth, int addressWidth,
      {String prefix = 'data'}) {
    final dataPorts = [
      for (var way = 0; way < ways; way++)
        [
          for (var r = 0; r < ports.length; r++)
            DataPortInterface(dataWidth, addressWidth)
        ]
    ];
    for (var way = 0; way < ways; way++) {
      for (var r = 0; r < ports.length; r++) {
        dataPorts[way][r].en.named('${prefix}_port${r}_way${way}_en');
        dataPorts[way][r].addr.named('${prefix}_port${r}_way${way}_addr');
        dataPorts[way][r].data.named('${prefix}_port${r}_way${way}_data');
      }
    }
    return dataPorts;
  }

  /// Generate a 2D list of [AccessInterface]s for the replacement policy.
  List<List<AccessInterface>> _genReplacementAccesses(
      List<DataPortInterface> ports,
      {String prefix = 'replace'}) {
    final dataPorts = [
      for (var line = 0; line < lines; line++)
        [for (var i = 0; i < ports.length; i++) AccessInterface(ways)]
    ];

    for (var line = 0; line < lines; line++) {
      for (var r = 0; r < ports.length; r++) {
        dataPorts[line][r]
            .access
            .named('${prefix}_line${line}_port${r}_access');
        dataPorts[line][r].way.named('${prefix}_line${line}_port${r}_way');
      }
    }
    return dataPorts;
  }
}
