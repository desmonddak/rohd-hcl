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

  /// Tag register files, one per way.
  late final List<RegisterFileWithPorts> tagRFs;

  /// Valid bit register files, one per way.
  late final List<RegisterFileWithPorts> validBitRFs;

  /// Data register files, one per way.l
  late final List<RegisterFileWithPorts> dataRFs;

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
    tagRFs = List<RegisterFileWithPorts>.generate(
        ways,
        (way) => RegisterFileWithPorts(
            clk,
            reset,
            [
              for (var port = 0; port < numFills; port++)
                NamedDataPortInterface(_tagWidth, _lineAddrWidth,
                    name: 'alloc_port${port}_way$way')
            ],
            [
              for (var port = 0; port < numFills; port++)
                NamedDataPortInterface(_tagWidth, _lineAddrWidth,
                    name: 'match_fl_port${port}_way$way'),
              for (var port = 0; port < numReads; port++)
                NamedDataPortInterface(_tagWidth, _lineAddrWidth,
                    name: 'match_rd_port${port}_way$way'),
              if (hasEvictions)
                for (var port = 0; port < numFills; port++)
                  NamedDataPortInterface(_tagWidth, _lineAddrWidth,
                      name: 'evictTagRd_port${port}_way$way')
            ],
            numEntries: lines,
            name: 'tag_rf_way$way'));

    // Construct valid-bit RFs per-way with write/read ports ordered as
    // (fills first, then reads).
    validBitRFs = List<RegisterFileWithPorts>.generate(
        ways,
        (way) => RegisterFileWithPorts(
            clk,
            reset,
            [
              for (var port = 0; port < numFills + numReads; port++)
                NamedDataPortInterface(1, _lineAddrWidth,
                    name: 'validBitWr_port${port}_way$way')
            ],
            [
              for (var port = 0; port < numFills + numReads; port++)
                NamedDataPortInterface(1, _lineAddrWidth,
                    name: 'validBitRd_port${port}_way$way')
            ],
            numEntries: lines,
            name: 'valid_bit_rf_way$way'));

    // Instantiate one replacement policy module per cache line using the
    // line-major arrays directly. Initialize replacement instance list.
    replacementPoliciesPerLine = [
      for (var line = 0; line < lines; line++)
        replacement(
            clk,
            reset,
            [
              for (var port = 0; port < numFills; port++)
                NamedAccessInterface(ways, name: 'rp_fl_port${port}_line$line'),
              for (var port = 0; port < numReads; port++)
                NamedAccessInterface(ways, name: 'rp_rd_port${port}_line$line')
            ],
            [
              for (var port = 0; port < numFills; port++)
                NamedAccessInterface(ways,
                    name: 'rp_alloc_port${port}_line$line')
            ],
            [
              for (var port = 0; port < numFills; port++)
                NamedAccessInterface(ways,
                    name: 'rp_inval_port${port}_line$line')
            ],
            name: 'rp_line$line',
            ways: ways)
    ];

    // Construct data RFs per-way with read ports (reads first, then evicts if
    // present) and fill write ports for fills.
    dataRFs = List<RegisterFileWithPorts>.generate(
        ways,
        (way) => RegisterFileWithPorts(
            clk,
            reset,
            [
              for (var port = 0; port < numFills; port++)
                NamedDataPortInterface(_dataWidth, _lineAddrWidth,
                    name: 'data_fl_port${port}_way$way')
            ],
            [
              for (var port = 0; port < numReads; port++)
                NamedDataPortInterface(_dataWidth, _lineAddrWidth,
                    name: 'data_rd_port${port}_way$way'),
              if (hasEvictions)
                for (var port = 0; port < numFills; port++)
                  NamedDataPortInterface(_dataWidth, _lineAddrWidth,
                      name: 'evictDataRd_port${port}_way$way')
            ],
            numEntries: lines,
            name: 'data_rf_way$way'));

    for (var flPortIdx = 0; flPortIdx < numFills; flPortIdx++) {
      // Call helper which will index the class-level policyByLine arrays
      // for the current fill port.
      _fillPortHookup(
          flPortIdx,
          fills[flPortIdx].fill,
          hasEvictions ? fills[flPortIdx].eviction : null,
          hasEvictions ? flPortIdx.toString() : null);
    }

    for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++) {
      _readPortHookup(rdPortIdx, reads[rdPortIdx]);
    }
  }

  void _readPortHookup(int rdPortIdx, ValidDataPortInterface rdPort) {
    final numFills = fills.length;
    for (var way = 0; way < ways; way++) {
      validBitRFs[way].extReads[numFills + rdPortIdx].en <= rdPort.en;
      validBitRFs[way].extReads[numFills + rdPortIdx].addr <=
          getLine(rdPort.addr);
      tagRFs[way].extReads[numFills + rdPortIdx].en <= rdPort.en;
      tagRFs[way].extReads[numFills + rdPortIdx].addr <= getLine(rdPort.addr);
    }

    final readPortValidOneHot = [
      for (var way = 0; way < ways; way++)
        (validBitRFs[way].extReads[numFills + rdPortIdx].data[0] &
                tagRFs[way]
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

    // Combine one-hot hit indicators into a single "any-hit" signal.
    final readPortValidAny = readPortValidOneHot.swizzle().or();

    final readMiss = (~readPortValidAny).named('read_port_${rdPort.name}_miss');
    final hasHit = ~readMiss;

    // Drive read outputs: defaults then per-way gated assignments.
    Combinational([
      rdPort.valid < Const(0),
      rdPort.data < Const(0, width: rdPort.dataWidth),
      for (var way = 0; way < ways; way++)
        If(
            readPortValidWay.eq(Const(way, width: log2Ceil(ways))) &
                rdPort.en &
                hasHit,
            then: [
              dataRFs[way].extReads[rdPortIdx].en < rdPort.en,
              dataRFs[way].extReads[rdPortIdx].addr < getLine(rdPort.addr),
              rdPort.data < dataRFs[way].extReads[rdPortIdx].data,
              rdPort.valid < Const(1),
            ],
            orElse: [
              dataRFs[way].extReads[rdPortIdx].en < Const(0)
            ])
    ]);

    for (var line = 0; line < lines; line++) {
      replacementPoliciesPerLine[line].extHits[numFills + rdPortIdx].access <=
          rdPort.en &
              ~readMiss &
              getLine(rdPort.addr).eq(Const(line, width: _lineAddrWidth));
      replacementPoliciesPerLine[line].extHits[numFills + rdPortIdx].way <=
          readPortValidWay;
    }

    if (rdPort.hasReadWithInvalidate) {
      for (var way = 0; way < ways; way++) {
        final matchWay = Const(way, width: log2Ceil(ways));
        final validBitWrPort = validBitRFs[way].extWrites[numFills + rdPortIdx];

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
        final validBitWrPort = validBitRFs[way].extWrites[numFills + rdPortIdx];
        validBitWrPort.en <= Const(0);
        validBitWrPort.addr <= Const(0, width: _lineAddrWidth);
        validBitWrPort.data <= Const(0, width: 1);
      }
    }
  }

  // Wire a fill port similarly; compute per-way ports from RF instances so
  // callers don't need to pass them.
  void _fillPortHookup(int flPortIdx, ValidDataPortInterface flPort,
      ValidDataPortInterface? evictPort, String? nameSuffix) {
    final numFills = fills.length;
    final numReads = reads.length;
    final ways = this.ways;

    for (var way = 0; way < ways; way++) {
      validBitRFs[way].extReads[flPortIdx].en <= flPort.en;
      validBitRFs[way].extReads[flPortIdx].addr <= getLine(flPort.addr);
      tagRFs[way].extReads[flPortIdx].en <= flPort.en;
      tagRFs[way].extReads[flPortIdx].addr <= getLine(flPort.addr);
    }

    final fillPortValidOneHot = [
      for (var way = 0; way < ways; way++)
        (validBitRFs[way].extReads[flPortIdx].data[0] &
                tagRFs[way].extReads[flPortIdx].data.eq(getTag(flPort.addr)))
            .named('match_fl${nameSuffix ?? ''}_way$way')
    ];
    final fillPortValidWay =
        RecursivePriorityEncoder(fillPortValidOneHot.rswizzle())
            .out
            .slice(log2Ceil(ways) - 1, 0)
            .named('fill_port${nameSuffix ?? ''}_way');

    final fillPortValidAny = fillPortValidOneHot.swizzle().or();
    final fillMiss =
        (~fillPortValidAny).named('fill_port${nameSuffix ?? ''}_miss');

    // Eviction handling: when an eviction port is present, wire per-way
    // evict read ports directly from the register files and compute
    // allocation/eviction selection signals without temporary lists.
    if (evictPort != null) {
      for (var way = 0; way < ways; way++) {
        tagRFs[way].extReads[numFills + numReads + flPortIdx].en <= flPort.en;
        tagRFs[way].extReads[numFills + numReads + flPortIdx].addr <=
            getLine(flPort.addr);
        dataRFs[way].extReads[numReads + flPortIdx].en <= flPort.en;
        dataRFs[way].extReads[numReads + flPortIdx].addr <=
            getLine(flPort.addr);
      }

      final allocWay = Logic(
          name: 'evict${nameSuffix ?? ''}AllocWay', width: log2Ceil(ways));
      final hitWay =
          Logic(name: 'evict${nameSuffix ?? ''}HitWay', width: log2Ceil(ways));

      if (lines == 1) {
        allocWay <= replacementPoliciesPerLine[0].extAllocs[flPortIdx].way;
        hitWay <= fillPortValidWay;
      } else {
        Combinational([
          Case(getLine(flPort.addr), [
            for (var line = 0; line < lines; line++)
              CaseItem(Const(line, width: _lineAddrWidth), [
                allocWay <
                    replacementPoliciesPerLine[line].extAllocs[flPortIdx].way
              ])
          ])
        ]);
        Combinational([hitWay < fillPortValidWay]);
      }

      // Compute whether the fill hit any way and select an eviction way.
      // Place these here so they are in scope for both the single-line and
      // multi-line cases.
      final fillHasHit = (~fillMiss).named('fill_has_hit${nameSuffix ?? ''}');
      final evictWay = mux(fillHasHit, hitWay, allocWay)
          .named('evict${nameSuffix ?? ''}Way');

      final evictTag =
          Logic(name: 'evict${nameSuffix ?? ''}Tag', width: _tagWidth);
      final evictData =
          Logic(name: 'evict${nameSuffix ?? ''}Data', width: _dataWidth);
      final allocWayValid = Logic(name: 'allocWayValid${nameSuffix ?? ''}');

      if (ways == 1) {
        evictTag <= tagRFs[0].extReads[numFills + numReads + flPortIdx].data;
        evictData <= dataRFs[0].extReads[numReads + flPortIdx].data;
        allocWayValid <= validBitRFs[0].extReads[flPortIdx].data[0];
      } else {
        Combinational([
          evictTag < Const(0, width: _tagWidth),
          evictData < Const(0, width: _dataWidth),
          for (var way = 0; way < ways; way++)
            If(evictWay.eq(Const(way, width: log2Ceil(ways))), then: [
              evictTag <
                  tagRFs[way].extReads[numFills + numReads + flPortIdx].data,
              evictData < dataRFs[way].extReads[numReads + flPortIdx].data,
            ])
        ]);

        // Multi-way allocation valid reduction: any selected evict way that
        // has its valid bit set makes the allocation-way-valid true.
        final allocSel = [
          for (var way = 0; way < ways; way++)
            evictWay.eq(Const(way, width: log2Ceil(ways))) &
                validBitRFs[way].extReads[flPortIdx].data[0]
        ];
        allocWayValid <=
            allocSel
                .swizzle()
                .or()
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

      Combinational([
        evictPort.en < (flPort.en & (invalEvictCond | allocEvictCond)),
        evictPort.valid < (flPort.en & (invalEvictCond | allocEvictCond)),
        evictPort.addr < evictAddrComb,
        evictPort.data < evictData,
      ]);
    }

    // Default combinational setup for policy hit/inval signals and per-line selection
    Combinational([
      for (var line = 0; line < lines; line++)
        replacementPoliciesPerLine[line].extInvalidates[flPortIdx].access <
            Const(0),
      for (var line = 0; line < lines; line++)
        replacementPoliciesPerLine[line].extHits[flPortIdx].access < Const(0),
      If(flPort.en, then: [
        for (var line = 0; line < lines; line++)
          If(getLine(flPort.addr).eq(Const(line, width: _lineAddrWidth)),
              then: [
                If.block([
                  Iff(flPort.valid & ~fillMiss, [
                    replacementPoliciesPerLine[line].extHits[flPortIdx].access <
                        flPort.en,
                    replacementPoliciesPerLine[line].extHits[flPortIdx].way <
                        fillPortValidWay,
                  ]),
                  ElseIf(~flPort.valid, [
                    replacementPoliciesPerLine[line]
                            .extInvalidates[flPortIdx]
                            .access <
                        flPort.en,
                    replacementPoliciesPerLine[line]
                            .extInvalidates[flPortIdx]
                            .way <
                        fillPortValidWay,
                  ]),
                ])
              ])
      ])
    ]);

    // Alloc access signals per-line
    for (var line = 0; line < lines; line++) {
      replacementPoliciesPerLine[line].extAllocs[flPortIdx].access <=
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
        tagRFs[way].extWrites[flPortIdx].en < Const(0),
      for (var way = 0; way < ways; way++)
        tagRFs[way].extWrites[flPortIdx].addr < Const(0, width: _lineAddrWidth),
      for (var way = 0; way < ways; way++)
        tagRFs[way].extWrites[flPortIdx].data < Const(0, width: _tagWidth),
      If(flPort.en, then: [
        for (var line = 0; line < lines; line++)
          If(getLine(flPort.addr).eq(Const(line, width: _lineAddrWidth)),
              then: [
                for (var way = 0; way < ways; way++)
                  If.block([
                    Iff(
                        flPort.valid &
                            fillMiss &
                            Const(way, width: log2Ceil(ways)).eq(
                                replacementPoliciesPerLine[line]
                                    .extAllocs[flPortIdx]
                                    .way),
                        [
                          tagRFs[way].extWrites[flPortIdx].en < flPort.en,
                          tagRFs[way].extWrites[flPortIdx].addr <
                              Const(line, width: _lineAddrWidth),
                          tagRFs[way].extWrites[flPortIdx].data <
                              getTag(flPort.addr),
                        ]),
                    ElseIf(
                        ~flPort.valid &
                            Const(way, width: log2Ceil(ways)).eq(
                                replacementPoliciesPerLine[line]
                                    .extInvalidates[flPortIdx]
                                    .way),
                        [
                          tagRFs[way].extWrites[flPortIdx].en < flPort.en,
                          tagRFs[way].extWrites[flPortIdx].addr <
                              Const(line, width: _lineAddrWidth),
                          tagRFs[way].extWrites[flPortIdx].data <
                              getTag(flPort.addr),
                        ]),
                  ])
              ])
      ])
    ]);

    // Valid-bit updates per-way
    for (var way = 0; way < ways; way++) {
      final matchWay = Const(way, width: log2Ceil(ways));
      final validBitWrPort = validBitRFs[way].extWrites[flPortIdx];

      Logic allocMatch = Const(0);
      if (lines > 0) {
        Logic? accum;
        for (var line = 0; line < lines; line++) {
          final cond =
              getLine(flPort.addr).eq(Const(line, width: _lineAddrWidth)) &
                  replacementPoliciesPerLine[line]
                      .extAllocs[flPortIdx]
                      .way
                      .eq(matchWay);
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
      final fillRFPort = dataRFs[way].extWrites[flPortIdx];
      Combinational([
        fillRFPort.en < Const(0),
        fillRFPort.addr < Const(0, width: _lineAddrWidth),
        fillRFPort.data < Const(0, width: _dataWidth),
        If(flPort.en & flPort.valid, then: [
          for (var line = 0; line < lines; line++)
            If(
                (fillMiss &
                        replacementPoliciesPerLine[line]
                            .extAllocs[flPortIdx]
                            .access &
                        replacementPoliciesPerLine[line]
                            .extAllocs[flPortIdx]
                            .way
                            .eq(matchWay)) |
                    (~fillMiss &
                        replacementPoliciesPerLine[line]
                            .extHits[flPortIdx]
                            .access &
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
