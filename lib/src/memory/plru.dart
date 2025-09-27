// Copyright (C) 2024-2025 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// plru.dart
// Pseudo-LRU algorithm development. A refinement of pLRU from software to
// Logic implementation.
//
// 2025 September 12
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

/// Allocates a way to evict using a binary tree representation of a
/// pseudo-LRU structure using an integer representation of the tree.
///
/// The path of 0s represents the least recently used path.
int allocPLRUInt(List<int> v, {int base = 0}) {
  final mid = v.length ~/ 2;
  return v.length == 1
      ? v[0] == 1
          ? base
          : base + 1
      : v[mid] == 1
          ? allocPLRUInt(v.sublist(0, mid), base: base)
          : allocPLRUInt(v.sublist(mid + 1, v.length), base: mid + 1 + base);
}

/// Access a given way and mark the LRU path in the tree with 0s using an
/// integer representation of the tree.
///
///  - hit way:  node set to 0 to indicate LRU is right.
///  - hit way+1: node set to 1 to indicate LRU is left (current way).
///  - invalidate inverts the 0 or 1 setting:
///     - meaning when we invalidate a hit, we set the node to 1 to indicate
///       left (or current way) is LRU or
///     - if we are hitting way+1, we set to 0 to indicate right (or next way=
///       way+1) is LRU.
List<int> hitPLRUInt(List<int> v, int way,
    {int base = 0, bool invalidate = false}) {
  if (v.length == 1) {
    return [if ((way == base) == invalidate) 1 else 0];
  } else {
    final mid = v.length ~/ 2;
    var lower = v.sublist(0, mid);
    var upper = v.sublist(mid + 1, v.length);
    lower = (way <= mid + base)
        ? hitPLRUInt(lower, way, base: base, invalidate: invalidate)
        : lower;
    upper = (way > mid + base)
        ? hitPLRUInt(upper, way, base: mid + base + 1, invalidate: invalidate)
        : upper;
    final midVal = ((way <= mid + base) == invalidate) ? 1 : 0;
    return [...lower, midVal, ...upper];
  }
}

/// Allocates a way to evict using a binary tree representation of a
/// pseudo-LRU structure using a LogicValue representation of the tree.
///
/// The path of 0s represents the least recently used path.
LogicValue allocPLRULogicValue(List<LogicValue> v, {int base = 0, int sz = 0}) {
  final lsz = sz == 0 ? log2Ceil(v.length) : sz;
  LogicValue convertInt(int i) => LogicValue.ofInt(i, lsz);
  final mid = v.length ~/ 2;
  return v.length == 1
      ? v[0] == LogicValue.one
          ? convertInt(base)
          : convertInt(base + 1)
      : v[mid] == LogicValue.one
          ? allocPLRULogicValue(v.sublist(0, mid), base: base, sz: lsz)
          : allocPLRULogicValue(v.sublist(mid + 1, v.length),
              base: mid + 1 + base, sz: lsz);
}

/// Access a given way and mark the LRU path in the tree with 0s using a
/// LogicValue representation of the tree.
List<LogicValue> hitPLRULogicValue(List<LogicValue> v, LogicValue way,
    {int base = 0, bool invalidate = false}) {
  LogicValue convertInt(int i) => LogicValue.ofInt(i, way.width);
  if (v.length == 1) {
    return [
      if (way == convertInt(base))
        LogicValue.of(invalidate)
      else if (way == convertInt(base + 1))
        LogicValue.of(!invalidate)
      else
        v[0]
    ];
  } else {
    final mid = v.length ~/ 2;
    final lower = hitPLRULogicValue(v.sublist(0, mid), way,
        base: base, invalidate: invalidate);
    final upper = hitPLRULogicValue(v.sublist(mid + 1, v.length), way,
        base: mid + base + 1, invalidate: invalidate);
    final midVal = [
      if ((way < convertInt(base) == LogicValue.one) ||
          (way > convertInt(base + v.length) == LogicValue.one))
        // out of range
        v[mid]
      else if (way <= convertInt(mid + base) == LogicValue.one)
        LogicValue.of(invalidate)
      else
        LogicValue.of(!invalidate)
    ];
    return [...lower, ...midVal, ...upper];
  }
}

/// Allocates a way to evict using a binary tree representation of a
/// pseudo-LRU structure using a Logic representation of the tree.
Logic allocPLRULogic(List<Logic> v, {int base = 0, int sz = 0}) {
  final lsz = sz == 0 ? log2Ceil(v.length) : sz;
  Logic convertInt(int i) => Const(i, width: lsz);

  final mid = v.length ~/ 2;
  return v.length == 1
      ? mux(v[0], convertInt(base), convertInt(base + 1))
      : mux(
          v[mid],
          allocPLRULogic(v.sublist(0, mid), base: base, sz: lsz),
          allocPLRULogic(v.sublist(mid + 1, v.length),
              base: mid + 1 + base, sz: lsz));
}

/// Access a given way and mark the LRU path in the tree with 0s using a
/// Logic representation of the tree.
List<Logic> hitPLRULogic(List<Logic> v, Logic way,
    {int base = 0, Logic? invalidate}) {
  Logic convertInt(int i) => Const(i, width: way.width);
  invalidate ??= Const(0);
  if (v.length == 1) {
    return [
      mux(way.eq(convertInt(base)), invalidate,
          mux(way.eq(convertInt(base + 1)), ~invalidate, v[0]))
    ];
  } else {
    final mid = v.length ~/ 2;
    final lower = hitPLRULogic(v.sublist(0, mid), way,
        base: base, invalidate: invalidate);
    final upper = hitPLRULogic(v.sublist(mid + 1, v.length), way,
        base: mid + base + 1, invalidate: invalidate);
    final midVal = [
      mux(way.lt(convertInt(base)) | way.gt(convertInt(base + v.length)),
          v[mid], mux(way.lte(convertInt(mid + base)), invalidate, ~invalidate))
    ];
    return [...lower, ...midVal, ...upper];
  }
}

/// Allocates a way to evict using a binary tree representation of a
/// pseudo-LRU structure using a Logic Vector representation of the tree.
Logic allocPLRULogicVector(Logic v, {int base = 0, int sz = 0}) {
  final lsz = sz == 0 ? log2Ceil(v.width) : sz;
  Logic convertInt(int i) => Const(i, width: lsz);

  final mid = v.width ~/ 2;
  return v.width == 1
      ? mux(v[0], convertInt(base), convertInt(base + 1))
      : mux(
          v[mid],
          allocPLRULogicVector(v.slice(mid - 1, 0), base: base, sz: lsz),
          allocPLRULogicVector(v.getRange(mid + 1),
              base: mid + 1 + base, sz: lsz));
}

/// Access a given way and mark the LRU path in the tree with 0s using a
/// Logic Vector representation of the tree.
Logic hitPLRULogicVector(Logic v, Logic way,
    {int base = 0, Logic? invalidate}) {
  Logic convertInt(int i) => Const(i, width: way.width);

  invalidate ??= Const(0);
  if (v.width == 1) {
    return mux(way.eq(convertInt(base)), invalidate,
        mux(way.eq(convertInt(base + 1)), ~invalidate, v[0]));
  } else {
    final mid = v.width ~/ 2;
    final lower = hitPLRULogicVector(v.slice(mid - 1, 0), way,
        base: base, invalidate: invalidate);
    final upper = hitPLRULogicVector(v.getRange(mid + 1), way,
        base: mid + base + 1, invalidate: invalidate);
    final midVal = mux(
        way.lt(convertInt(base)) | way.gt(convertInt(base + v.width)),
        v[mid],
        mux(way.lte(convertInt(mid + base)), invalidate, ~invalidate));
    return [lower, midVal, upper].rswizzle();
  }
}
