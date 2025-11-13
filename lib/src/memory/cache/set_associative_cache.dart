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
    _lineAddrWidth = log2Ceil(lines);
    _tagWidth = reads.isNotEmpty ? reads[0].addrWidth - _lineAddrWidth : 0;
    _dataWidth = dataWidth;

    final tagRFMatchFl = _genTagRFInterfaces(
        [for (final f in fills) f.fill], _tagWidth, _lineAddrWidth,
        prefix: 'match_fl');

    final tagRFMatchRd = _genTagRFInterfaces(reads, _tagWidth, _lineAddrWidth,
        prefix: 'match_rd');

    final tagRFAlloc = _genTagRFInterfaces(
        [for (final f in fills) f.fill], _tagWidth, _lineAddrWidth,
        prefix: 'alloc');

    final hasEvictions = fills.isNotEmpty && fills[0].eviction != null;
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

    final validBitRFWritePorts = List.generate(
        numFills + numReads,
        (port) => List.generate(
            ways,
            (way) => DataPortInterface(1, _lineAddrWidth)
              ..en.named('validBitWr_port${port}_way${way}_en')
              ..addr.named('validBitWr_port${port}_way${way}_addr')
              ..data.named('validBitWr_port${port}_way${way}_data')));

    final validBitRFReadPorts = List.generate(
        numFills + numReads,
        (port) => List.generate(
            ways,
            (way) => DataPortInterface(1, _lineAddrWidth)
              ..en.named('validBitRd_port${port}_way${way}_en')
              ..addr.named('validBitRd_port${port}_way${way}_addr')
              ..data.named('validBitRd_port${port}_way${way}_data')));

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

    for (var flPortIdx = 0; flPortIdx < numFills; flPortIdx++) {
      final flPort = fills[flPortIdx].fill;
      for (var way = 0; way < ways; way++) {
        tagRFMatchFl[flPortIdx][way].addr <= getLine(flPort.addr);
        tagRFMatchFl[flPortIdx][way].en <= flPort.en;

        validBitRFReadPorts[flPortIdx][way].addr <= getLine(flPort.addr);
        validBitRFReadPorts[flPortIdx][way].en <= flPort.en;
      }
    }

    // Per-fill match/encoder/miss are computed inside _FillPortHandler to
    // keep per-RF read-port interfaces local to the RegisterFile instantiation
    // while allowing the handler to encapsulate per-port logic.

    for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++) {
      final rdPort = reads[rdPortIdx];
      for (var way = 0; way < ways; way++) {
        tagRFMatchRd[rdPortIdx][way].addr <= getLine(rdPort.addr);
        tagRFMatchRd[rdPortIdx][way].en <= rdPort.en;

        validBitRFReadPorts[numFills + rdPortIdx][way].addr <=
            getLine(rdPort.addr);
        validBitRFReadPorts[numFills + rdPortIdx][way].en <= rdPort.en;
      }
    }

    // Per-read miss signals are constructed inside each _ReadPortHandler so
    // the handler owns its combinational logic (symmetry with fill handler).

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
      final flPort = fills[flPortIdx].fill;
      final perLinePolicyAllocPorts = policyAllocPorts[flPortIdx];
      final perLinePolicyInvalPorts = policyInvalPorts[flPortIdx];
      final perLinePolicyFlHitPorts = policyFlHitPorts[flPortIdx];

      if (hasEvictions) {
        _FillPortHandler(
                this,
                flPort,
                tagRFMatchFl[flPortIdx],
                validBitRFReadPorts[flPortIdx],
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
                flPortIdx.toString())
            .wire();
      } else {
        _FillPortHandler(
                this,
                flPort,
                tagRFMatchFl[flPortIdx],
                validBitRFReadPorts[flPortIdx],
                fillDataPorts[flPortIdx],
                tagRFAlloc[flPortIdx],
                validBitRFWritePorts[flPortIdx],
                perLinePolicyAllocPorts,
                perLinePolicyFlHitPorts,
                perLinePolicyInvalPorts,
                null,
                null,
                null,
                null,
                null)
            .wire();
      }
    }

    for (var rdPortIdx = 0; rdPortIdx < numReads; rdPortIdx++) {
      final rdPort = reads[rdPortIdx];
      _ReadPortHandler(
              this,
              rdPort,
              tagRFMatchRd[rdPortIdx],
              validBitRFReadPorts[numFills + rdPortIdx],
              readDataPorts[rdPortIdx],
              validBitRFWritePorts[numFills + rdPortIdx],
              policyRdHitPorts[rdPortIdx])
          .wire();
    }
  }

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

class _ReadPortHandler {
  final SetAssociativeCache cache;
  final ValidDataPortInterface rdPort;
  final List<DataPortInterface>
      tagMatchReadPorts; // per-way tag match read ports
  final List<DataPortInterface>
      validBitReadPorts; // per-way valid-bit read ports
  final List<DataPortInterface> perWayReadDataPorts;
  final List<DataPortInterface> perWayValidBitWrPorts;
  final List<AccessInterface> perLinePolicyRdHitPorts;

  _ReadPortHandler(
      this.cache,
      this.rdPort,
      this.tagMatchReadPorts,
      this.validBitReadPorts,
      this.perWayReadDataPorts,
      this.perWayValidBitWrPorts,
      this.perLinePolicyRdHitPorts);

  void wire() {
    // Create the miss signal inside the handler so the handler fully owns
    // its combinational outputs (matches fill-side behavior).
    final readMiss = Logic(name: 'read_port${rdPort.name}_miss');

    // Construct the per-way match one-hot inside the handler using the
    // passed-in RF read ports.
    final ways = cache.ways;
    final readPortValidOneHot = [
      for (var way = 0; way < ways; way++)
        (validBitReadPorts[way].data[0] &
                tagMatchReadPorts[way].data.eq(cache.getTag(rdPort.addr)))
            .named('match_rd_port${rdPort.name}_way$way')
    ];

    // Encoder output (which way has valid data)
    final readPortValidWay =
        RecursivePriorityEncoder(readPortValidOneHot.rswizzle())
            .out
            .slice(log2Ceil(ways) - 1, 0)
            .named('${rdPort.name}_valid_way');

    // Compute miss by OR-reducing the one-hot
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
        for (var way = 0; way < cache.ways; way++)
          If(readPortValidWay.eq(Const(way, width: log2Ceil(cache.ways))),
              then: [
                perWayReadDataPorts[way].en < rdPort.en,
                perWayReadDataPorts[way].addr < cache.getLine(rdPort.addr),
                rdPort.data < perWayReadDataPorts[way].data,
                rdPort.valid < Const(1),
              ],
              orElse: [
                perWayReadDataPorts[way].en < Const(0)
              ])
      ])
    ]);

    for (var line = 0; line < cache.lines; line++) {
      perLinePolicyRdHitPorts[line].access <=
          rdPort.en &
              ~readMiss &
              cache
                  .getLine(rdPort.addr)
                  .eq(Const(line, width: cache._lineAddrWidth));
      perLinePolicyRdHitPorts[line].way <= readPortValidWay;
    }

    if (rdPort.hasReadWithInvalidate) {
      for (var way = 0; way < cache.ways; way++) {
        final matchWay = Const(way, width: log2Ceil(cache.ways));
        final validBitWrPort = perWayValidBitWrPorts[way];

        final shouldInvalidate = flop(
            cache.clk,
            rdPort.readWithInvalidate &
                hasHit &
                rdPort.en &
                readPortValidWay.eq(matchWay),
            reset: cache.reset);
        final invalidateAddr =
            flop(cache.clk, cache.getLine(rdPort.addr), reset: cache.reset);

        Combinational([
          validBitWrPort.en < shouldInvalidate,
          validBitWrPort.addr < invalidateAddr,
          validBitWrPort.data < Const(0, width: 1),
        ]);
      }
    } else {
      for (var way = 0; way < cache.ways; way++) {
        final validBitWrPort = perWayValidBitWrPorts[way];
        validBitWrPort.en <= Const(0);
        validBitWrPort.addr <= Const(0, width: cache._lineAddrWidth);
        validBitWrPort.data <= Const(0, width: 1);
      }
    }
  }
}

class _FillPortHandler {
  final SetAssociativeCache cache;
  final ValidDataPortInterface flPort;
  final List<DataPortInterface> tagMatchReadPorts; // per-way tag read ports
  final List<DataPortInterface>
      validBitReadPorts; // per-way valid-bit read ports
  final List<DataPortInterface> perWayFillDataPorts;
  final List<DataPortInterface> perWayTagAllocPorts;
  final List<DataPortInterface> perWayValidBitWrPorts;
  final List<AccessInterface> perLinePolicyAllocPorts;
  final List<AccessInterface> perLinePolicyFlHitPorts;
  final List<AccessInterface> perLinePolicyInvalPorts;
  final List<DataPortInterface>? perWayEvictTagReadPorts;
  final List<DataPortInterface>? perWayEvictDataReadPorts;
  final List<DataPortInterface>? perWayValidBitRdPorts;
  final ValidDataPortInterface? evictPort;
  final String? nameSuffix;

  _FillPortHandler(
      this.cache,
      this.flPort,
      this.tagMatchReadPorts,
      this.validBitReadPorts,
      this.perWayFillDataPorts,
      this.perWayTagAllocPorts,
      this.perWayValidBitWrPorts,
      this.perLinePolicyAllocPorts,
      this.perLinePolicyFlHitPorts,
      this.perLinePolicyInvalPorts,
      this.perWayEvictTagReadPorts,
      this.perWayEvictDataReadPorts,
      this.perWayValidBitRdPorts,
      this.evictPort,
      this.nameSuffix);

  void wire() {
    final ways = cache.ways;
    final lines = cache.lines;

    // Build the per-way match one-hot array inside the handler
    final fillPortValidOneHot = [
      for (var way = 0; way < ways; way++)
        (validBitReadPorts[way].data[0] &
                tagMatchReadPorts[way].data.eq(cache.getTag(flPort.addr)))
            .named('match_fl${nameSuffix ?? ''}_way$way')
    ];

    // Encoder for which way is valid
    final fillPortValidWay =
        RecursivePriorityEncoder(fillPortValidOneHot.rswizzle())
            .out
            .slice(log2Ceil(ways) - 1, 0)
            .named('fill_port${nameSuffix ?? ''}_way');

    // Compute miss by OR-reducing the one-hot
    Logic? vsAccum;
    for (var way = 0; way < ways; way++) {
      final b = fillPortValidOneHot[way];
      vsAccum = (vsAccum == null) ? b : (vsAccum | b);
    }
    final fillMiss = Logic(name: 'fill_port${nameSuffix ?? ''}_miss');
    Combinational([fillMiss < ~(vsAccum ?? Const(0))]);

    // Eviction handling (if present)
    if (evictPort != null &&
        perWayEvictTagReadPorts != null &&
        perWayEvictDataReadPorts != null &&
        perWayValidBitRdPorts != null) {
      for (var way = 0; way < cache.ways; way++) {
        final evictTagReadPort = perWayEvictTagReadPorts![way];
        final evictDataReadPort = perWayEvictDataReadPorts![way];
        evictTagReadPort.en <= flPort.en;
        evictTagReadPort.addr <= cache.getLine(flPort.addr);
        evictDataReadPort.en <= flPort.en;
        evictDataReadPort.addr <= cache.getLine(flPort.addr);
      }

      final evictWay = Logic(
          name: 'evict${nameSuffix ?? ''}Way', width: log2Ceil(cache.ways));
      final fillHasHit = ~fillMiss;

      final allocWay = Logic(
          name: 'evict${nameSuffix ?? ''}AllocWay',
          width: log2Ceil(cache.ways));
      final hitWay = Logic(
          name: 'evict${nameSuffix ?? ''}HitWay', width: log2Ceil(cache.ways));

      if (cache.lines == 1) {
        allocWay <= perLinePolicyAllocPorts[0].way;
        hitWay <= fillPortValidWay;
      } else {
        final allocCases = <CaseItem>[];
        for (var line = 0; line < cache.lines; line++) {
          allocCases.add(CaseItem(Const(line, width: cache._lineAddrWidth),
              [allocWay < perLinePolicyAllocPorts[line].way]));
        }
        Combinational([Case(cache.getLine(flPort.addr), allocCases)]);
        Combinational([hitWay < fillPortValidWay]);
      }

      Combinational([
        If(fillHasHit, then: [evictWay < hitWay], orElse: [evictWay < allocWay])
      ]);

      final evictTag =
          Logic(name: 'evict${nameSuffix ?? ''}Tag', width: cache._tagWidth);
      final evictData =
          Logic(name: 'evict${nameSuffix ?? ''}Data', width: cache._dataWidth);

      if (cache.ways == 1) {
        evictTag <= perWayEvictTagReadPorts!.first.data;
        evictData <= perWayEvictDataReadPorts!.first.data;
      } else {
        final tagSelections = <Conditional>[];
        final dataSelections = <Conditional>[];
        for (var way = 0; way < cache.ways; way++) {
          final isThisWay =
              evictWay.eq(Const(way, width: log2Ceil(cache.ways)));
          tagSelections.add(If(isThisWay,
              then: [evictTag < perWayEvictTagReadPorts![way].data]));
          dataSelections.add(If(isThisWay,
              then: [evictData < perWayEvictDataReadPorts![way].data]));
        }
        Combinational(
            [evictTag < Const(0, width: cache._tagWidth), ...tagSelections]);
        Combinational(
            [evictData < Const(0, width: cache._dataWidth), ...dataSelections]);
      }

      final allocWayValid = Logic(name: 'allocWayValid${nameSuffix ?? ''}');
      if (cache.ways == 1) {
        allocWayValid <= perWayValidBitRdPorts![0].data[0];
      } else {
        Logic? vsAccum2;
        for (var way = 0; way < cache.ways; way++) {
          final sel = evictWay.eq(Const(way, width: log2Ceil(cache.ways))) &
              perWayValidBitRdPorts![way].data[0];
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
          evictAddrComb < [evictTag, cache.getLine(flPort.addr)].swizzle()
        ])
      ]);

      final evict = evictPort!;
      Combinational([
        evict.en < (flPort.en & (invalEvictCond | allocEvictCond)),
        evict.valid < (flPort.en & (invalEvictCond | allocEvictCond)),
        evict.addr < evictAddrComb,
        evict.data < evictData,
      ]);
    }

    // Default combinational setup for policy hit/inval signals and per-line selection
    Combinational([
      for (var line = 0; line < cache.lines; line++)
        perLinePolicyInvalPorts[line].access < Const(0),
      for (var line = 0; line < cache.lines; line++)
        perLinePolicyFlHitPorts[line].access < Const(0),
      If(flPort.en, then: [
        for (var line = 0; line < cache.lines; line++)
          If(
              cache
                  .getLine(flPort.addr)
                  .eq(Const(line, width: cache._lineAddrWidth)),
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

    // Alloc access signals per-line
    for (var line = 0; line < cache.lines; line++) {
      perLinePolicyAllocPorts[line].access <=
          flPort.en &
              flPort.valid &
              fillMiss &
              cache
                  .getLine(flPort.addr)
                  .eq(Const(line, width: cache._lineAddrWidth));
    }

    // Tag allocations

    Combinational([
      for (var way = 0; way < ways; way++)
        perWayTagAllocPorts[way].en < Const(0),
      for (var way = 0; way < ways; way++)
        perWayTagAllocPorts[way].addr < Const(0, width: cache._lineAddrWidth),
      for (var way = 0; way < ways; way++)
        perWayTagAllocPorts[way].data < Const(0, width: cache._tagWidth),
      If(flPort.en, then: [
        for (var line = 0; line < lines; line++)
          If(
              cache
                  .getLine(flPort.addr)
                  .eq(Const(line, width: cache._lineAddrWidth)),
              then: [
                for (var way = 0; way < ways; way++)
                  If.block([
                    Iff(
                        flPort.valid &
                            fillMiss &
                            Const(way, width: log2Ceil(ways))
                                .eq(perLinePolicyAllocPorts[line].way),
                        [
                          perWayTagAllocPorts[way].en < flPort.en,
                          perWayTagAllocPorts[way].addr <
                              Const(line, width: cache._lineAddrWidth),
                          perWayTagAllocPorts[way].data <
                              cache.getTag(flPort.addr),
                        ]),
                    ElseIf(
                        ~flPort.valid &
                            Const(way, width: log2Ceil(ways))
                                .eq(perLinePolicyInvalPorts[line].way),
                        [
                          perWayTagAllocPorts[way].en < flPort.en,
                          perWayTagAllocPorts[way].addr <
                              Const(line, width: cache._lineAddrWidth),
                          perWayTagAllocPorts[way].data <
                              cache.getTag(flPort.addr),
                        ]),
                  ])
              ])
      ])
    ]);

    // Valid-bit updates per-way
    for (var way = 0; way < ways; way++) {
      final matchWay = Const(way, width: log2Ceil(cache.ways));
      final validBitWrPort = perWayValidBitWrPorts[way];

      // Build allocMatch by OR-reducing per-line conditions without creating a
      // Dart list
      Logic allocMatch = Const(0);
      if (lines > 0) {
        Logic? accum;
        for (var line = 0; line < lines; line++) {
          final cond = cache
                  .getLine(flPort.addr)
                  .eq(Const(line, width: cache._lineAddrWidth)) &
              perLinePolicyAllocPorts[line].way.eq(matchWay);
          accum = (accum == null) ? cond : (accum | cond);
        }
        allocMatch = accum ?? Const(0);
      }

      Combinational([
        validBitWrPort.en < Const(0),
        validBitWrPort.addr < Const(0, width: cache._lineAddrWidth),
        validBitWrPort.data < Const(0, width: 1),
        If(flPort.en, then: [
          If.block([
            Iff(
                flPort.valid &
                    ((~fillMiss & fillPortValidWay.eq(matchWay)) |
                        (fillMiss & allocMatch)),
                [
                  validBitWrPort.en < Const(1),
                  validBitWrPort.addr < cache.getLine(flPort.addr),
                  validBitWrPort.data < Const(1, width: 1),
                ]),
            ElseIf(~flPort.valid & ~fillMiss & fillPortValidWay.eq(matchWay), [
              validBitWrPort.en < Const(1),
              validBitWrPort.addr < cache.getLine(flPort.addr),
              validBitWrPort.data < Const(0, width: 1),
            ]),
          ])
        ])
      ]);
    }

    // Data RF writes (per-way)
    for (var way = 0; way < cache.ways; way++) {
      final matchWay = Const(way, width: log2Ceil(cache.ways));
      final fillRFPort = perWayFillDataPorts[way];
      Combinational([
        fillRFPort.en < Const(0),
        fillRFPort.addr < Const(0, width: cache._lineAddrWidth),
        fillRFPort.data < Const(0, width: cache._dataWidth),
        If(flPort.en & flPort.valid, then: [
          for (var line = 0; line < cache.lines; line++)
            If(
                (fillMiss &
                        perLinePolicyAllocPorts[line].access &
                        perLinePolicyAllocPorts[line].way.eq(matchWay)) |
                    (~fillMiss &
                        perLinePolicyFlHitPorts[line].access &
                        fillPortValidWay.eq(matchWay)),
                then: [
                  fillRFPort.addr < cache.getLine(flPort.addr),
                  fillRFPort.data < flPort.data,
                  fillRFPort.en < flPort.en,
                ])
        ])
      ]);
    }
  }
}
