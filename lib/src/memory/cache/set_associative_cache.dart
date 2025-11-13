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
import 'package:rohd_hcl/src/memory/register_file_with_ports.dart';

/// A set-associative cache supporting multiple read and fill ports.
class SetAssociativeCache extends Cache {
  late int _lineAddrWidth;
  late int _tagWidth;
  late int _dataWidth;
  // Expose RF instances so callers can access their ports via the cache
  // instance.
  /// Tag register files, one per way.
  late final List<RegisterFileWithPorts> tagRfs;

  /// Valid bit register files, one per way.
  late final List<RegisterFileWithPorts> validBitRfs;

  /// Data register files, one per way.l
  late final List<RegisterFileWithPorts> dataRfs;
  // Per-line replacement instances created during buildLogic (inherited).
  // The replacement instances themselves retain references to the external
  // AccessInterface objects (extHits/extAllocs/extInvalidates). Helpers
  // will index `replByLine[line].ext*` directly instead of using a holder.

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
    // Number of fill and read ports.
    final numFills = fills.length;
    final numReads = reads.length;
    _lineAddrWidth = log2Ceil(lines);
    _tagWidth = reads.isNotEmpty ? reads[0].addrWidth - _lineAddrWidth : 0;
    _dataWidth = dataWidth;

    final hasEvictions = fills.isNotEmpty && fills[0].eviction != null;

    // Construct tag RFs per-way; build the small per-way interface lists
    // at construction time instead of pre-building 2D arrays.
    tagRfs = List<RegisterFileWithPorts>.generate(ways, (way) {
      // Allocation (write) ports: one per fill port
      final allocPorts = List<DataPortInterface>.generate(numFills, (port) {
        final dpi = DataPortInterface(_tagWidth, _lineAddrWidth);
        dpi.en.named('alloc_port${port}_way${way}_en');
        dpi.addr.named('alloc_port${port}_way${way}_addr');
        dpi.data.named('alloc_port${port}_way${way}_data');
        return dpi;
      });

      // Match (read) ports: fills first, then reads
      final matchReadPorts = <DataPortInterface>[];
      for (var port = 0; port < numFills; port++) {
        final dpi = DataPortInterface(_tagWidth, _lineAddrWidth);
        dpi.en.named('match_fl_port${port}_way${way}_en');
        dpi.addr.named('match_fl_port${port}_way${way}_addr');
        dpi.data.named('match_fl_port${port}_way${way}_data');
        matchReadPorts.add(dpi);
      }
      for (var port = 0; port < numReads; port++) {
        final dpi = DataPortInterface(_tagWidth, _lineAddrWidth);
        dpi.en.named('match_rd_port${port}_way${way}_en');
        dpi.addr.named('match_rd_port${port}_way${way}_addr');
        dpi.data.named('match_rd_port${port}_way${way}_data');
        matchReadPorts.add(dpi);
      }

      // Evict tag read ports come after fill/read ports when evictions are used
      if (hasEvictions) {
        for (var port = 0; port < numFills; port++) {
          final dpi = DataPortInterface(_tagWidth, _lineAddrWidth);
          dpi.en.named('evictTagRd_port${port}_way${way}_en');
          dpi.addr.named('evictTagRd_port${port}_way${way}_addr');
          dpi.data.named('evictTagRd_port${port}_way${way}_data');
          matchReadPorts.add(dpi);
        }
      }

      return RegisterFileWithPorts(clk, reset, allocPorts, matchReadPorts,
          numEntries: lines, name: 'tag_rf_way$way');
    });

    // Construct valid-bit RFs per-way with write/read ports ordered as
    // (fills first, then reads).
    validBitRfs = List<RegisterFileWithPorts>.generate(ways, (way) {
      final wrs = List<DataPortInterface>.generate(numFills + numReads, (port) {
        final dpi = DataPortInterface(1, _lineAddrWidth);
        dpi.en.named('validBitWr_port${port}_way${way}_en');
        dpi.addr.named('validBitWr_port${port}_way${way}_addr');
        dpi.data.named('validBitWr_port${port}_way${way}_data');
        return dpi;
      });
      final rds = List<DataPortInterface>.generate(numFills + numReads, (port) {
        final dpi = DataPortInterface(1, _lineAddrWidth);
        dpi.en.named('validBitRd_port${port}_way${way}_en');
        dpi.addr.named('validBitRd_port${port}_way${way}_addr');
        dpi.data.named('validBitRd_port${port}_way${way}_data');
        return dpi;
      });
      return RegisterFileWithPorts(clk, reset, wrs, rds,
          numEntries: lines, name: 'valid_bit_rf_way$way');
    });

    // Instantiate one replacement policy module per cache line using the
    // line-major arrays directly. Initialize replacement instance list.
    replByLine = <ReplacementPolicy>[];
    for (var line = 0; line < lines; line++) {
      final flHits = [
        for (var port = 0; port < numFills; port++)
          (() {
            final ai = AccessInterface(ways);
            ai.access.named('rp_fl_port${port}_line${line}_access');
            ai.way.named('rp_fl_port${port}_line${line}_way');
            return ai;
          })()
      ];
      final rdHits = [
        for (var port = 0; port < numReads; port++)
          (() {
            final ai = AccessInterface(ways);
            ai.access.named('rp_rd_port${port}_line${line}_access');
            ai.way.named('rp_rd_port${port}_line${line}_way');
            return ai;
          })()
      ];
      final allocs = [
        for (var port = 0; port < numFills; port++)
          (() {
            final ai = AccessInterface(ways);
            ai.access.named('rp_alloc_port${port}_line${line}_access');
            ai.way.named('rp_alloc_port${port}_line${line}_way');
            return ai;
          })()
      ];
      final inval = [
        for (var port = 0; port < numFills; port++)
          (() {
            final ai = AccessInterface(ways);
            ai.access.named('rp_inval_port${port}_line${line}_access');
            ai.way.named('rp_inval_port${port}_line${line}_way');
            return ai;
          })()
      ];

      final rp = replacement(clk, reset, flHits..addAll(rdHits), allocs, inval,
          name: 'rp_line$line', ways: ways);
      replByLine.add(rp);
    }

    // Construct data RFs per-way with read ports (reads first, then evicts if
    // present) and fill write ports for fills.
    dataRfs = List<RegisterFileWithPorts>.generate(ways, (way) {
      final allDataReadPorts = <DataPortInterface>[];
      for (var port = 0; port < numReads; port++) {
        final dpi = DataPortInterface(_dataWidth, _lineAddrWidth);
        dpi.en.named('data_rd_port${port}_way${way}_en');
        dpi.addr.named('data_rd_port${port}_way${way}_addr');
        dpi.data.named('data_rd_port${port}_way${way}_data');
        allDataReadPorts.add(dpi);
      }
      if (hasEvictions) {
        for (var port = 0; port < numFills; port++) {
          final dpi = DataPortInterface(_dataWidth, _lineAddrWidth);
          dpi.en.named('evictDataRd_port${port}_way${way}_en');
          dpi.addr.named('evictDataRd_port${port}_way${way}_addr');
          dpi.data.named('evictDataRd_port${port}_way${way}_data');
          allDataReadPorts.add(dpi);
        }
      }

      final fillPortsForWay =
          List<DataPortInterface>.generate(numFills, (port) {
        final dpi = DataPortInterface(_dataWidth, _lineAddrWidth);
        dpi.en.named('data_fl_port${port}_way${way}_en');
        dpi.addr.named('data_fl_port${port}_way${way}_addr');
        dpi.data.named('data_fl_port${port}_way${way}_data');
        return dpi;
      });

      return RegisterFileWithPorts(
          clk, reset, fillPortsForWay, allDataReadPorts,
          numEntries: lines, name: 'data_rf_way$way');
    });

    for (var flPortIdx = 0; flPortIdx < numFills; flPortIdx++) {
      final flPort = fills[flPortIdx].fill;

      // Call helper which will index the class-level policyByLine arrays
      // for the current fill port.
      _wireFillPortHelper(
          flPortIdx,
          flPort,
          hasEvictions ? fills[flPortIdx].eviction : null,
          hasEvictions ? flPortIdx.toString() : null);
    }

    for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++) {
      final rdPort = reads[rdPortIdx];
      _wireReadPortHelper(rdPortIdx, rdPort);
    }
  }

  // Note: interface helper constructors were inlined into per-way loops to
  // ensure interfaces are only created at RegisterFile construction time.

  // Replacement access helper was inlined into the per-line construction
  // above to ensure creation location matches usage.
  // Wire a read port by using the register-file instances directly so the
  // helper can compute per-way ports rather than receiving them as args.
  // Note: interface helper constructors were inlined into per-way loops to
  // ensure interfaces are only created at RegisterFile construction time.

  // Replacement access helper was inlined into the per-line construction
  // above to ensure creation location matches usage.
  // Wire a read port by using the register-file instances directly so the
  // helper can compute per-way ports rather than receiving them as args.
  void _wireReadPortHelper(int rdPortIdx, ValidDataPortInterface rdPort) {
    final numFills = fills.length;
    // Build per-way port arrays from the register-file instances.
    final ways = this.ways;
    final perWayValidBitWrPorts = [
      for (var way = 0; way < ways; way++)
        validBitRfs[way].extWrites[numFills + rdPortIdx]
    ];

    // Drive per-way tag and valid-bit read ports for this read port so the
    // match expressions below observe valid data. These correspond to the
    // read ports created at RegisterFile construction time (fills first,
    // then reads — read ports are offset by numFills).
    for (var way = 0; way < ways; way++) {
      validBitRfs[way].extReads[numFills + rdPortIdx].en <= rdPort.en;
      validBitRfs[way].extReads[numFills + rdPortIdx].addr <=
          getLine(rdPort.addr);
      tagRfs[way].extReads[numFills + rdPortIdx].en <= rdPort.en;
      tagRfs[way].extReads[numFills + rdPortIdx].addr <= getLine(rdPort.addr);
    }

    // Begin logic from former handler
    final readMiss = Logic(name: 'read_port${rdPort.name}_miss');

    final readPortValidOneHot = [
      for (var way = 0; way < ways; way++)
        (validBitRfs[way].extReads[numFills + rdPortIdx].data[0] &
                tagRfs[way]
                    .extReads[numFills + rdPortIdx]
                    .data
                    .eq(getTag(rdPort.addr)))
            .named('match_rd_port${rdPort.name}_way$way')
    ];

    final readPortValidWay =
        RecursivePriorityEncoder(readPortValidOneHot.rswizzle())
            .out
            .slice(log2Ceil(ways) - 1, 0)
            .named('${rdPort.name}_valid_way');

    Logic? vsAccum;
    for (var way = 0; way < ways; way++) {
      final b = readPortValidOneHot[way];
      vsAccum = (vsAccum == null) ? b : (vsAccum | b);
    }
    Combinational([readMiss < ~(vsAccum ?? Const(0))]);

    final hasHit = ~readMiss;

    Combinational([
      rdPort.valid < Const(0),
      rdPort.data < Const(0, width: rdPort.dataWidth),
      If(rdPort.en & hasHit, then: [
        for (var way = 0; way < ways; way++)
          If(readPortValidWay.eq(Const(way, width: log2Ceil(ways))), then: [
            dataRfs[way].extReads[rdPortIdx].en < rdPort.en,
            dataRfs[way].extReads[rdPortIdx].addr < getLine(rdPort.addr),
            rdPort.data < dataRfs[way].extReads[rdPortIdx].data,
            rdPort.valid < Const(1),
          ], orElse: [
            dataRfs[way].extReads[rdPortIdx].en < Const(0)
          ])
      ])
    ]);

    for (var line = 0; line < lines; line++) {
      replByLine[line].extHits[numFills + rdPortIdx].access <=
          rdPort.en &
              ~readMiss &
              getLine(rdPort.addr).eq(Const(line, width: _lineAddrWidth));
      replByLine[line].extHits[numFills + rdPortIdx].way <= readPortValidWay;
    }

    if (rdPort.hasReadWithInvalidate) {
      for (var way = 0; way < ways; way++) {
        final matchWay = Const(way, width: log2Ceil(ways));
        final validBitWrPort = perWayValidBitWrPorts[way];

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
      for (var way = 0; way < ways; way++) {
        final validBitWrPort = perWayValidBitWrPorts[way];
        validBitWrPort.en <= Const(0);
        validBitWrPort.addr <= Const(0, width: _lineAddrWidth);
        validBitWrPort.data <= Const(0, width: 1);
      }
    }
  }

  // Wire a fill port similarly; compute per-way ports from RF instances so
  // callers don't need to pass them.
  void _wireFillPortHelper(int flPortIdx, ValidDataPortInterface flPort,
      ValidDataPortInterface? evictPort, String? nameSuffix) {
    final numFills = fills.length;
    final numReads = reads.length;
    final ways = this.ways;

    // Per-way write ports for data, tag allocations and valid bits.
    // These are accessed directly below via the RF instances to avoid
    // allocating short-lived lists.

    // Drive per-way tag and valid-bit read ports for the fill port so the
    // match expressions below observe valid data. These correspond to the
    // read ports created at RegisterFile construction time (fills first).
    for (var way = 0; way < ways; way++) {
      validBitRfs[way].extReads[flPortIdx].en <= flPort.en;
      validBitRfs[way].extReads[flPortIdx].addr <= getLine(flPort.addr);
      tagRfs[way].extReads[flPortIdx].en <= flPort.en;
      tagRfs[way].extReads[flPortIdx].addr <= getLine(flPort.addr);
    }

    final fillPortValidOneHot = [
      for (var way = 0; way < ways; way++)
        (validBitRfs[way].extReads[flPortIdx].data[0] &
                tagRfs[way].extReads[flPortIdx].data.eq(getTag(flPort.addr)))
            .named('match_fl${nameSuffix ?? ''}_way$way')
    ];

    final fillPortValidWay =
        RecursivePriorityEncoder(fillPortValidOneHot.rswizzle())
            .out
            .slice(log2Ceil(ways) - 1, 0)
            .named('fill_port${nameSuffix ?? ''}_way');

    Logic? vsAccum;
    for (var way = 0; way < ways; way++) {
      final b = fillPortValidOneHot[way];
      vsAccum = (vsAccum == null) ? b : (vsAccum | b);
    }
    final fillMiss = Logic(name: 'fill_port${nameSuffix ?? ''}_miss');
    Combinational([fillMiss < ~(vsAccum ?? Const(0))]);

    // Eviction handling: when an eviction port is present, wire per-way
    // evict read ports directly from the register files and compute
    // allocation/eviction selection signals without temporary lists.
    if (evictPort != null) {
      for (var way = 0; way < ways; way++) {
        tagRfs[way].extReads[numFills + numReads + flPortIdx].en <= flPort.en;
        tagRfs[way].extReads[numFills + numReads + flPortIdx].addr <=
            getLine(flPort.addr);
        dataRfs[way].extReads[numReads + flPortIdx].en <= flPort.en;
        dataRfs[way].extReads[numReads + flPortIdx].addr <=
            getLine(flPort.addr);
      }

      final evictWay =
          Logic(name: 'evict${nameSuffix ?? ''}Way', width: log2Ceil(ways));
      final fillHasHit = ~fillMiss;

      final allocWay = Logic(
          name: 'evict${nameSuffix ?? ''}AllocWay', width: log2Ceil(ways));
      final hitWay =
          Logic(name: 'evict${nameSuffix ?? ''}HitWay', width: log2Ceil(ways));

      if (lines == 1) {
        allocWay <= replByLine[0].extAllocs[flPortIdx].way;
        hitWay <= fillPortValidWay;
      } else {
        final allocCases = <CaseItem>[];
        for (var line = 0; line < lines; line++) {
          allocCases.add(CaseItem(Const(line, width: _lineAddrWidth),
              [allocWay < replByLine[line].extAllocs[flPortIdx].way]));
        }
        Combinational([Case(getLine(flPort.addr), allocCases)]);
        Combinational([hitWay < fillPortValidWay]);
      }

      Combinational([
        If(fillHasHit, then: [evictWay < hitWay], orElse: [evictWay < allocWay])
      ]);

      final evictTag =
          Logic(name: 'evict${nameSuffix ?? ''}Tag', width: _tagWidth);
      final evictData =
          Logic(name: 'evict${nameSuffix ?? ''}Data', width: _dataWidth);

      if (ways == 1) {
        evictTag <= tagRfs[0].extReads[numFills + numReads + flPortIdx].data;
        evictData <= dataRfs[0].extReads[numReads + flPortIdx].data;
      } else {
        final tagSelections = <Conditional>[];
        final dataSelections = <Conditional>[];
        for (var way = 0; way < ways; way++) {
          final isThisWay = evictWay.eq(Const(way, width: log2Ceil(ways)));
          tagSelections.add(If(isThisWay, then: [
            evictTag <
                tagRfs[way].extReads[numFills + numReads + flPortIdx].data
          ]));
          dataSelections.add(If(isThisWay, then: [
            evictData < dataRfs[way].extReads[numReads + flPortIdx].data
          ]));
        }
        Combinational(
            [evictTag < Const(0, width: _tagWidth), ...tagSelections]);
        Combinational(
            [evictData < Const(0, width: _dataWidth), ...dataSelections]);
      }

      final allocWayValid = Logic(name: 'allocWayValid${nameSuffix ?? ''}');
      if (ways == 1) {
        allocWayValid <= validBitRfs[0].extReads[flPortIdx].data[0];
      } else {
        Logic? vsAccum2;
        for (var way = 0; way < ways; way++) {
          final sel = evictWay.eq(Const(way, width: log2Ceil(ways))) &
              validBitRfs[way].extReads[flPortIdx].data[0];
          vsAccum2 = (vsAccum2 == null) ? sel : (vsAccum2 | sel);
        }
        allocWayValid <=
            (vsAccum2 ?? Const(0))
                .named('allocWayValidReduction${nameSuffix ?? ''}');
      }

      final allocEvictCond = (flPort.valid & ~fillHasHit & allocWayValid)
          .named('allocEvictCond${nameSuffix ?? ''}');
      final invalEvictCond = (~flPort.valid & fillHasHit)
          .named('invalEvictCond${nameSuffix ?? ''}');

      final evictAddrComb = Logic(
          name: 'evictAddrComb${nameSuffix ?? ''}', width: flPort.addrWidth);
      Combinational([
        If(invalEvictCond, then: [
          evictAddrComb < flPort.addr
        ], orElse: [
          evictAddrComb < [evictTag, getLine(flPort.addr)].swizzle()
        ])
      ]);

      final evict = evictPort;
      Combinational([
        evict.en < (flPort.en & (invalEvictCond | allocEvictCond)),
        evict.valid < (flPort.en & (invalEvictCond | allocEvictCond)),
        evict.addr < evictAddrComb,
        evict.data < evictData,
      ]);
    }

    // Default combinational setup for policy hit/inval signals and per-line selection
    Combinational([
      for (var line = 0; line < lines; line++)
        replByLine[line].extInvalidates[flPortIdx].access < Const(0),
      for (var line = 0; line < lines; line++)
        replByLine[line].extHits[flPortIdx].access < Const(0),
      If(flPort.en, then: [
        for (var line = 0; line < lines; line++)
          If(getLine(flPort.addr).eq(Const(line, width: _lineAddrWidth)),
              then: [
                If.block([
                  Iff(flPort.valid & ~fillMiss, [
                    replByLine[line].extHits[flPortIdx].access < flPort.en,
                    replByLine[line].extHits[flPortIdx].way < fillPortValidWay,
                  ]),
                  ElseIf(~flPort.valid, [
                    replByLine[line].extInvalidates[flPortIdx].access <
                        flPort.en,
                    replByLine[line].extInvalidates[flPortIdx].way <
                        fillPortValidWay,
                  ]),
                ])
              ])
      ])
    ]);

    // Alloc access signals per-line
    for (var line = 0; line < lines; line++) {
      replByLine[line].extAllocs[flPortIdx].access <=
          flPort.en &
              flPort.valid &
              fillMiss &
              getLine(flPort.addr).eq(Const(
                line,
                width: _lineAddrWidth,
              ));
    }

    // Tag allocations
    Combinational([
      for (var way = 0; way < ways; way++)
        tagRfs[way].extWrites[flPortIdx].en < Const(0),
      for (var way = 0; way < ways; way++)
        tagRfs[way].extWrites[flPortIdx].addr < Const(0, width: _lineAddrWidth),
      for (var way = 0; way < ways; way++)
        tagRfs[way].extWrites[flPortIdx].data < Const(0, width: _tagWidth),
      If(flPort.en, then: [
        for (var line = 0; line < lines; line++)
          If(getLine(flPort.addr).eq(Const(line, width: _lineAddrWidth)),
              then: [
                for (var way = 0; way < ways; way++)
                  If.block([
                    Iff(
                        flPort.valid &
                            fillMiss &
                            Const(way, width: log2Ceil(ways))
                                .eq(replByLine[line].extAllocs[flPortIdx].way),
                        [
                          tagRfs[way].extWrites[flPortIdx].en < flPort.en,
                          tagRfs[way].extWrites[flPortIdx].addr <
                              Const(line, width: _lineAddrWidth),
                          tagRfs[way].extWrites[flPortIdx].data <
                              getTag(flPort.addr),
                        ]),
                    ElseIf(
                        ~flPort.valid &
                            Const(way, width: log2Ceil(ways)).eq(
                                replByLine[line].extInvalidates[flPortIdx].way),
                        [
                          tagRfs[way].extWrites[flPortIdx].en < flPort.en,
                          tagRfs[way].extWrites[flPortIdx].addr <
                              Const(line, width: _lineAddrWidth),
                          tagRfs[way].extWrites[flPortIdx].data <
                              getTag(flPort.addr),
                        ]),
                  ])
              ])
      ])
    ]);

    // Valid-bit updates per-way
    for (var way = 0; way < ways; way++) {
      final matchWay = Const(way, width: log2Ceil(ways));
      final validBitWrPort = validBitRfs[way].extWrites[flPortIdx];

      Logic allocMatch = Const(0);
      if (lines > 0) {
        Logic? accum;
        for (var line = 0; line < lines; line++) {
          final cond =
              getLine(flPort.addr).eq(Const(line, width: _lineAddrWidth)) &
                  replByLine[line].extAllocs[flPortIdx].way.eq(matchWay);
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
            Iff(
                flPort.valid &
                    ((~fillMiss & fillPortValidWay.eq(matchWay)) |
                        (fillMiss & allocMatch)),
                [
                  validBitWrPort.en < Const(1),
                  validBitWrPort.addr < getLine(flPort.addr),
                  validBitWrPort.data < Const(1, width: 1),
                ]),
            ElseIf(~flPort.valid & ~fillMiss & fillPortValidWay.eq(matchWay), [
              validBitWrPort.en < Const(1),
              validBitWrPort.addr < getLine(flPort.addr),
              validBitWrPort.data < Const(0, width: 1),
            ]),
          ])
        ])
      ]);
    }

    // Data RF writes (per-way)
    for (var way = 0; way < ways; way++) {
      final matchWay = Const(way, width: log2Ceil(ways));
      final fillRFPort = dataRfs[way].extWrites[flPortIdx];
      Combinational([
        fillRFPort.en < Const(0),
        fillRFPort.addr < Const(0, width: _lineAddrWidth),
        fillRFPort.data < Const(0, width: _dataWidth),
        If(flPort.en & flPort.valid, then: [
          for (var line = 0; line < lines; line++)
            If(
                (fillMiss &
                        replByLine[line].extAllocs[flPortIdx].access &
                        replByLine[line]
                            .extAllocs[flPortIdx]
                            .way
                            .eq(matchWay)) |
                    (~fillMiss &
                        replByLine[line].extHits[flPortIdx].access &
                        fillPortValidWay.eq(matchWay)),
                then: [
                  fillRFPort.addr < getLine(flPort.addr),
                  fillRFPort.data < flPort.data,
                  fillRFPort.en < flPort.en,
                ])
        ])
      ]);
    }
  }
}
