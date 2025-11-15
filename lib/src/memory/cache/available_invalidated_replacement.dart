// Copyright (C) 2025 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// available_invalidated_replacement.dart
// A replacement policy that returns an available invalidated way when asked
// via allocs, supports invalidates, and throws on access (hits).
//
// 2025 November 14
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

/// A replacement policy that guarantees that if an invalid way is available,
/// it will be returned for use.
class AvailableInvalidatedReplacement extends ReplacementPolicy {
  /// Construct the policy.
  AvailableInvalidatedReplacement(
      super.clk, super.reset, super._hits, super._allocs, super._invalidates,
      {super.ways,
      super.name = 'available_invalidated',
      super.reserveName,
      super.reserveDefinitionName,
      String? definitionName})
      : super(
            definitionName: definitionName ??
                'available_invalidated_H${_hits.length}_'
                    'A${_allocs.length}_WAYS=$ways') {
    _buildLogic();
  }

  void _buildLogic() {
    // This policy ignores hit/access inputs; callers should not drive them.

    // Per-way valid bit storage (one Logic per way) to simplify bit ops.
    final validBits = List<Logic>.generate(ways, (w) => Logic(name: 'vb_$w'));
    final validBitsNext =
        List<Logic>.generate(ways, (w) => Logic(name: 'vb_next_$w'));

    // Register the bits (reset initializes to 0 = invalid)
    for (var w = 0; w < ways; w++) {
      validBits[w] <= flop(clk, validBitsNext[w], reset: reset);
    }

    // Build expressions for postInvalidate (apply invalidates to current valid
    // bits) Compute postInvalidate expression: current valid bit with
    // invalidates applied.
    final exprPostInv = List<Logic>.generate(ways, (w) {
      var cur = validBits[w];
      for (var i = 0; i < intInvalidates.length; i++) {
        final inval = intInvalidates[i];
        final match = inval.way.eq(Const(w, width: log2Ceil(ways)));
        cur = mux(inval.access & match, Const(0), cur);
      }
      return cur.named('exprPostInv_w$w');
    });

    // Build invalid vector: 1 for each invalid way (available).
    final invalidBits = List<Logic>.generate(
        ways, (w) => (~exprPostInv[w]).named('invalidBit$w'));

    // For each alloc interface, pick the lowest-index invalid way.
    final wayWidth = log2Ceil(ways) == 0 ? 1 : log2Ceil(ways);
    final allocPicks = List<Logic>.generate(
        intAllocs.length, (i) => Logic(width: wayWidth, name: 'alloc_pick_$i'));
    final allocPickNext = List<Logic>.generate(intAllocs.length,
        (i) => Logic(width: wayWidth, name: 'alloc_pick_next_$i'));
    final allocPickLatched = List<Logic>.generate(intAllocs.length,
        (i) => Logic(width: wayWidth, name: 'alloc_pick_latched_$i'));

    // For multi-alloc support, perform greedy allocation in port order by
    // tracking earlier claims as one-hot vectors. For each alloc port we
    // compute available = invalidBits & ~earlierClaims, priority-encode that
    // to choose a way, then add that choice to earlierClaims for the next
    // alloc port.
    final earlierClaims = List<Logic>.generate(ways, (w) => Const(0));
    final allocPickOneHot = <List<Logic>>[];

    for (var i = 0; i < intAllocs.length; i++) {
      final a = intAllocs[i];

      // build available vector: invalidBits & ~earlierClaims.
      final availVec = List<Logic>.generate(ways,
          (w) => (invalidBits[w] & ~earlierClaims[w]).named('avail_${i}_$w'));

      Logic pickWay;
      if (ways == 1) {
        pickWay = Const(0, width: wayWidth);
      } else {
        pickWay = RecursivePriorityEncoder(availVec.rswizzle())
            .out
            .slice(wayWidth - 1, 0);
      }
      allocPicks[i] = pickWay;

      // compute one-hot encoding of pickWay (and gate with access).
      final oneHot = List<Logic>.generate(
          ways,
          (w) => (a.access & allocPicks[i].eq(Const(w, width: wayWidth)))
              .named('pick_${i}_$w'));
      allocPickOneHot.add(oneHot);

      // update earlierClaims for next alloc.
      for (var w = 0; w < ways; w++) {
        earlierClaims[w] =
            (earlierClaims[w] | oneHot[w]).named('earlierClaim_${i}_$w');
      }

      // latch the picked way on the next clock edge when alloc is asserted.
      allocPickLatched[i] <= flop(clk, allocPickNext[i], reset: reset);

      // next value is pickWay when access is asserted, otherwise keep previous.
      allocPickNext[i] <= mux(a.access, pickWay, allocPickLatched[i]);

      // drive the alloc interface `way` from the latched value so reads are
      // stable.
      a.way <= allocPickLatched[i];
    }

    // Compute validBitsNext: set bit if alloc claims it, clear if invalidated,
    // else keep.
    for (var w = 0; w < ways; w++) {
      // detect if any alloc picked this way this cycle by ORing one-hot picks.
      Logic allocClaim = Const(0);
      for (var i = 0; i < allocPickOneHot.length; i++) {
        allocClaim = allocClaim | allocPickOneHot[i][w];
      }
      validBitsNext[w] <= (exprPostInv[w] | allocClaim);
    }
  }
}
