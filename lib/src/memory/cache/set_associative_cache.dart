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

    // Create tag RF interfaces (without valid bit). Generator now returns
    // port-major arrays ([port][way]) so per-port slices are already easy
    // to pass to helpers and no transpose is required.
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
    // Make eviction read ports port-major: evictTagRfReadPorts[port][way]
    final evictTagRfReadPorts = hasEvictions
        ? List.generate(
            numFills,
            (i) => List.generate(
                ways,
                (way) => DataPortInterface(_tagWidth, _lineAddrWidth)
                  ..en.named('evictTagRd_port${i}_way${way}_en')
                  ..addr.named('evictTagRd_port${i}_way${way}_addr')
                  ..data.named('evictTagRd_port${i}_way${way}_data')))
        : <List<DataPortInterface>>[];

    // The Tag `RegisterFile` (without valid bit). RegisterFile expects
    // way-major lists, so transpose our port-major arrays back into
    // way-major views for construction.
    // RegisterFile expects per-way lists. Build per-way views from the
    // port-major tag RF arrays when instantiating per-way RegisterFiles.
    for (var way = 0; way < ways; way++) {
      final allocPorts = [
        for (var port = 0; port < numFills; port++) tagRFAlloc[port][way]
      ];
      final matchReadPorts = [
            for (var port = 0; port < numFills; port++) tagRFMatchFl[port][way]
          ] +
          [for (var port = 0; port < numReads; port++) tagRFMatchRd[port][way]];
      final allTagReadPorts = hasEvictions
          ? [
              ...matchReadPorts,
              for (var port = 0; port < numFills; port++)
                evictTagRfReadPorts[port][way]
            ]
          : matchReadPorts;
      RegisterFile(clk, reset, allocPorts, allTagReadPorts,
          numEntries: lines, name: 'tag_rf_way$way');
    }

    // Create valid bit register files (one bit wide, indexed by line address).
    // Make these port-major: validBitRF[port][way]
    final validBitRFWritePorts = List.generate(
        numFills + numReads,
        (port) => List.generate(
            ways, // per way
            (way) => DataPortInterface(1, _lineAddrWidth)
              ..en.named('validBitWr_port${port}_way${way}_en')
              ..addr.named('validBitWr_port${port}_way${way}_addr')
              ..data.named('validBitWr_port${port}_way${way}_data')));

    final validBitRFReadPorts = List.generate(
        numFills + numReads,
        (port) => List.generate(
            ways, // per way
            (way) => DataPortInterface(1, _lineAddrWidth)
              ..en.named('validBitRd_port${port}_way${way}_en')
              ..addr.named('validBitRd_port${port}_way${way}_addr')
              ..data.named('validBitRd_port${port}_way${way}_data')));

    // Create valid bit register files
    // Register files expect per-way arrays; transpose our port-major arrays
    // into way-major views for RegisterFile construction.
    for (var way = 0; way < ways; way++) {
      final wrs = [
        for (var port = 0; port < numFills + numReads; port++)
          validBitRFWritePorts[port][way]
      ];
      final rds = [
        for (var port = 0; port < numFills + numReads; port++)
          validBitRFReadPorts[port][way]
      ];
      RegisterFile(clk, reset, wrs, rds,
          numEntries: lines, name: 'valid_bit_rf_way$way');
    }

    // Setup the tag match fill interfaces and valid bit reads for fills.
    // Move the actual wiring into a per-port helper so match ports are
    // prepared before the match one-hot computations below.
    for (var flPortIdx = 0; flPortIdx < numFills; flPortIdx++) {
      final flPort = fills[flPortIdx].fill;
      // Prepare tag-match and valid-bit read ports for this fill port
      for (var way = 0; way < ways; way++) {
        tagRFMatchFl[flPortIdx][way].addr <= getLine(flPort.addr);
        tagRFMatchFl[flPortIdx][way].en <= flPort.en;

        validBitRFReadPorts[flPortIdx][way].addr <= getLine(flPort.addr);
        validBitRFReadPorts[flPortIdx][way].en <= flPort.en;
      }
    }

    final fillPortValidOneHot = [
      for (var flPortIdx = 0; flPortIdx < numFills; flPortIdx++)
        [
          for (var way = 0; way < ways; way++)
            (validBitRFReadPorts[flPortIdx][way].data[0] &
                    tagRFMatchFl[flPortIdx][way]
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
    // Build per-fill-port miss signals without allocating temporary Dart
    // lists; accumulate the OR across ways into a single Logic and then
    // invert it to produce the miss signal.
    final fillValidPortMiss = [
      for (var fillPortIdx = 0; fillPortIdx < numFills; fillPortIdx++)
        Logic(name: 'fill_port${fillPortIdx}_miss')
    ];
    for (var fillPortIdx = 0; fillPortIdx < numFills; fillPortIdx++) {
      Logic? vsAccum;
      for (var way = 0; way < ways; way++) {
        final thisBit = fillPortValidOneHot[fillPortIdx][way];
        vsAccum = (vsAccum == null) ? thisBit : (vsAccum | thisBit);
      }
      Combinational([fillValidPortMiss[fillPortIdx] < ~(vsAccum ?? Const(0))]);
    }

    // Setup the tag match read interfaces and valid bit reads for reads.
    // Wire the per-way tag match and valid-bit read ports via a helper so
    // the wiring is colocated with other read-port logic.
    for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++) {
      final rdPort = reads[rdPortIdx];
      // Prepare tag-match and valid-bit read ports for this read port.
      for (var way = 0; way < ways; way++) {
        tagRFMatchRd[rdPortIdx][way].addr <= getLine(rdPort.addr);
        tagRFMatchRd[rdPortIdx][way].en <= rdPort.en;

        validBitRFReadPorts[numFills + rdPortIdx][way].addr <=
            getLine(rdPort.addr);
        validBitRFReadPorts[numFills + rdPortIdx][way].en <= rdPort.en;
      }
    }

    final readPortValidOneHot = [
      for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++)
        [
          for (var way = 0; way < ways; way++)
            (validBitRFReadPorts[numFills + rdPortIdx][way].data[0] &
                    tagRFMatchRd[rdPortIdx][way]
                        .data
                        .eq(getTag(reads[rdPortIdx].addr)))
                .named('match_rd${rdPortIdx}_way$way')
        ]
    ];
    // Build per-read-port miss signals without temporary list allocations.
    final readValidPortMiss = [
      for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++)
        Logic(name: 'read_port${rdPortIdx}_miss')
    ];
    for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++) {
      Logic? vsAccum;
      for (var way = 0; way < ways; way++) {
        final thisBit = readPortValidOneHot[rdPortIdx][way];
        vsAccum = (vsAccum == null) ? thisBit : (vsAccum | thisBit);
      }
      Combinational([readValidPortMiss[rdPortIdx] < ~(vsAccum ?? Const(0))]);
    }
    final readValidPortWay = [
      for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++)
        RecursivePriorityEncoder(readPortValidOneHot[rdPortIdx].rswizzle())
            .out
            .slice(log2Ceil(ways) - 1, 0)
            .named('read_port${rdPortIdx}_way')
    ];

    // Generate the replacment policy logic. Fills and reads both create
    // hits. A fill miss causes an allocation followed by a hit.

    // Generate replacement policy access ports. _genReplacementAccesses now
    // returns port-major arrays ([port][line]) to make per-port slicing
    // straightforward.
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

    // Instantiate replacement policy modules per-line. Since the
    // replacement generator now returned port-major arrays ([port][line]),
    // we need to build the per-line views when wiring the replacement
    // logic.
    for (var line = 0; line < lines; line++) {
      final flHits = [
        for (var port = 0; port < numFills; port++) policyFlHitPorts[port][line]
      ];
      final rdHits = [
        for (var port = 0; port < numReads; port++) policyRdHitPorts[port][line]
      ];
      final allocs = [
        for (var port = 0; port < numFills; port++) policyAllocPorts[port][line]
      ];
      final inval = [
        for (var port = 0; port < numFills; port++) policyInvalPorts[port][line]
      ];
      replacement(clk, reset, flHits..addAll(rdHits), allocs, inval,
          name: 'rp_line$line', ways: ways);
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
            numFills,
            (i) => List.generate(
                ways,
                (way) => DataPortInterface(_dataWidth, _lineAddrWidth)
                  ..en.named('evictDataRd_port${i}_way${way}_en')
                  ..addr.named('evictDataRd_port${i}_way${way}_addr')
                  ..data.named('evictDataRd_port${i}_way${way}_data')))
        : <List<DataPortInterface>>[];

    // Data interfaces: generator now returns port-major lists ([port][way])
    // so per-port slicing is direct.
    final fillDataPorts = _genDataInterfaces(
        [for (final f in fills) f.fill], _dataWidth, _lineAddrWidth,
        prefix: 'data_fl');
    final readDataPorts = _genDataInterfaces(reads, _dataWidth, _lineAddrWidth,
        prefix: 'data_rd');

    for (var way = 0; way < ways; way++) {
      final allDataReadPorts = hasEvictions
          ? [
                for (var port = 0; port < numReads; port++)
                  readDataPorts[port][way]
              ] +
              [
                for (var port = 0; port < numFills; port++)
                  evictDataRfReadPorts[port][way]
              ]
          : [
              for (var port = 0; port < numReads; port++)
                readDataPorts[port][way]
            ];
      final fillPortsForWay = [
        for (var port = 0; port < numFills; port++) fillDataPorts[port][way]
      ];
      RegisterFile(clk, reset, fillPortsForWay, allDataReadPorts,
          numEntries: lines, name: 'data_rf_way$way');
    }

    for (var flPortIdx = 0; flPortIdx < numFills; flPortIdx++) {
      // Build per-port slices so the class-level helper can operate on a
      // single-port view without indexing into the 2D arrays.
      final flPort = fills[flPortIdx].fill;
      final perLinePolicyAllocPorts = policyAllocPorts[flPortIdx];
      final perLinePolicyInvalPorts = policyInvalPorts[flPortIdx];
      final perLinePolicyFlHitPorts = policyFlHitPorts[flPortIdx];

      if (hasEvictions) {
        _handleFillPort(
            flPort,
            fillValidPortMiss[flPortIdx],
            fillPortValidWay[flPortIdx],
            fillDataPorts[flPortIdx],
            tagRFAlloc[flPortIdx],
            validBitRFWritePorts[flPortIdx],
            perLinePolicyAllocPorts,
            perLinePolicyFlHitPorts,
            perLinePolicyInvalPorts,
            evictTagRfReadPorts[flPortIdx],
            evictDataRfReadPorts[flPortIdx],
            validBitRFReadPorts[flPortIdx],
            fills[flPortIdx].eviction,
            flPortIdx.toString());
      } else {
        _handleFillPort(
            flPort,
            fillValidPortMiss[flPortIdx],
            fillPortValidWay[flPortIdx],
            fillDataPorts[flPortIdx],
            tagRFAlloc[flPortIdx],
            validBitRFWritePorts[flPortIdx],
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

      _handleReadPort(
          rdPort,
          readValidPortMiss[rdPortIdx],
          readValidPortWay[rdPortIdx],
          readDataPorts[rdPortIdx],
          validBitRFWritePorts[numFills + rdPortIdx],
          policyRdHitPorts[rdPortIdx]);
    }

    // Eviction handling is now invoked from within _handleFillPort when
    // eviction ports are present. The per-port invocation occurs at the
    // time fills are processed above, so there's no separate top-level
    // eviction loop needed here.
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
    // Local eviction helper nested here so eviction wiring is colocated
    // with the fill handling for a single port. Care is taken to pass a
    // unique nameSuffix per-call from the caller so created Logic names
    // don't collide across fill ports.
    void handleEvictPort(
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
        for (var line = 0; line < lines; line++) {
          allocCases.add(CaseItem(Const(line, width: _lineAddrWidth),
              [allocWay < perLinePolicyAllocPorts[line].way]));
        }
        Combinational([Case(getLine(fillPort.addr), allocCases)]);
        // hitWay is line-independent; drive it directly from fillPortValidWay.
        Combinational([hitWay < fillPortValidWay]);
      }

      Combinational([
        If(fillHasHit, then: [evictWay < hitWay], orElse: [evictWay < allocWay])
      ]);

      final evictTag = Logic(name: 'evict${nameSuffix}Tag', width: _tagWidth);
      final evictData =
          Logic(name: 'evict${nameSuffix}Data', width: _dataWidth);

      if (ways == 1) {
        evictTag <= perWayEvictTagReadPorts.first.data;
        evictData <= perWayEvictDataReadPorts.first.data;
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
        Logic? vsAccum;
        for (var way = 0; way < ways; way++) {
          final sel = evictWay.eq(Const(way, width: log2Ceil(ways))) &
              perWayValidBitRdPorts[way].data[0];
          vsAccum = (vsAccum == null) ? sel : (vsAccum | sel);
        }
        allocWayValid <=
            (vsAccum ?? Const(0)).named('allocWayValidReduction$nameSuffix');
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

    // Policy: initialize and drive per-line policy ports for this fill
    // port (fl hit, inval, alloc). This was previously in buildLogic().
    // Local helper: perform tag allocations and valid-bit updates for this
    // fill port. Nested so the helper can access _lineAddrWidth, _tagWidth,
    // and _dataWidth directly and remain colocated with the fill logic.
    void handleFillAllocAndValidUpdates(
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

        // Check whether allocator chose this way for the given line.
        // Build the OR of per-line conditions directly to avoid a temporary
        // Dart list allocation.
        Logic allocMatch = Const(0);
        if (lines > 0) {
          Logic? accum;
          for (var line = 0; line < lines; line++) {
            final cond =
                getLine(flPort.addr).eq(Const(line, width: _lineAddrWidth)) &
                    perLinePolicyAllocPorts[line].way.eq(matchWay);
            accum = (accum == null) ? cond : (accum | cond);
          }
          allocMatch = accum ?? Const(0);
        }

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
              ElseIf(
                  ~flPort.valid & ~fillMiss & fillPortValidWay.eq(matchWay), [
                validBitWrPort.en < Const(1),
                validBitWrPort.addr < getLine(flPort.addr),
                validBitWrPort.data < Const(0, width: 1),
              ]),
            ])
          ])
        ]);
      }
    }

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
    handleFillAllocAndValidUpdates(
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
      handleEvictPort(
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

  /// Generates a 2D list of [DataPortInterface]s for the tag RF (without valid
  /// bit). The returned shape is port-major.
  List<List<DataPortInterface>> _genTagRFInterfaces(
      List<ValidDataPortInterface> ports, int tagWidth, int addressWidth,
      {String prefix = 'tag'}) {
    final dataPorts = [
      for (var r = 0; r < ports.length; r++)
        [
          for (var way = 0; way < ways; way++)
            DataPortInterface(tagWidth, addressWidth)
        ]
    ];
    for (var r = 0; r < ports.length; r++) {
      for (var way = 0; way < ways; way++) {
        final fullPrefix = '${prefix}_port${r}_way$way';
        dataPorts[r][way].en.named('${fullPrefix}_en');
        dataPorts[r][way].addr.named('${fullPrefix}_addr');
        dataPorts[r][way].data.named('${fullPrefix}_data');
      }
    }
    return dataPorts;
  }

  /// Generates a 2D list of [DataPortInterface]s for the data RF.
  /// The returned shape is port-major.
  List<List<DataPortInterface>> _genDataInterfaces(
      List<DataPortInterface> ports, int dataWidth, int addressWidth,
      {String prefix = 'data'}) {
    final dataPorts = [
      for (var r = 0; r < ports.length; r++)
        [
          for (var way = 0; way < ways; way++)
            DataPortInterface(dataWidth, addressWidth)
        ]
    ];
    for (var r = 0; r < ports.length; r++) {
      for (var way = 0; way < ways; way++) {
        dataPorts[r][way].en.named('${prefix}_port${r}_way${way}_en');
        dataPorts[r][way].addr.named('${prefix}_port${r}_way${way}_addr');
        dataPorts[r][way].data.named('${prefix}_port${r}_way${way}_data');
      }
    }
    return dataPorts;
  }

  /// Generate a 2D list of [AccessInterface]s for the replacement policy.
  /// The returned shape is port-major.
  List<List<AccessInterface>> _genReplacementAccesses(
      List<DataPortInterface> ports,
      {String prefix = 'replace'}) {
    final dataPorts = [
      for (var r = 0; r < ports.length; r++)
        [for (var line = 0; line < lines; line++) AccessInterface(ways)]
    ];

    for (var r = 0; r < ports.length; r++) {
      for (var line = 0; line < lines; line++) {
        dataPorts[r][line]
            .access
            .named('${prefix}_port${r}_line${line}_access');
        dataPorts[r][line].way.named('${prefix}_port${r}_line${line}_way');
      }
    }
    return dataPorts;
  }
}
