import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:test/test.dart';

int leastRecentInt(List<int> v, int base, {int len = 0}) {
  final ilen = len == 0 ? v.length : len;
  final mid = ilen ~/ 2;
  return ilen == 1
      ? v[base] == 0
          ? base + 1
          : base
      : v[mid + base] == 0
          ? leastRecentInt(v, mid + 1 + base, len: ilen - mid - 1)
          : leastRecentInt(v, base, len: mid);
}

int lruIntRecurse(List<int> v, int base) {
  final mid = v.length ~/ 2;
  return v.length == 1
      ? v[0] == 0
          ? base + 1
          : base
      : v[mid] == 0
          ? lruIntRecurse(v.sublist(mid + 1, v.length), mid + 1 + base)
          : lruIntRecurse(v.sublist(0, mid), base);
}

LogicValue leastRecentLogicValue(List<LogicValue> v, int base,
    {int origSz = 0}) {
  final sz = origSz == 0 ? v.length : origSz;
  final mid = v.length ~/ 2;
  return v.length == 1
      ? v[0] == LogicValue.zero
          ? LogicValue.ofInt(base + 1, sz)
          : LogicValue.ofInt(base, sz)
      : v[mid] == LogicValue.zero
          ? leastRecentLogicValue(v.sublist(mid + 1, v.length), mid + 1 + base,
              origSz: sz)
          : leastRecentLogicValue(v.sublist(0, mid), base, origSz: sz);
}

LogicValue lruLogicValueRecurse(List<LogicValue> v, int base, {int sz = 0}) {
  final lsz = sz == 0 ? log2Ceil(v.length) : sz;
  final mid = v.length ~/ 2;
  return v.length == 1
      ? v[0] == LogicValue.zero
          ? LogicValue.ofInt(base + 1, lsz)
          : LogicValue.ofInt(base, lsz)
      : v[mid] == LogicValue.zero
          ? lruLogicValueRecurse(v.sublist(mid + 1, v.length), mid + 1 + base,
              sz: lsz)
          : lruLogicValueRecurse(v.sublist(0, mid), base, sz: lsz);
}

Logic lruLogicRecurse(List<Logic> v, int base, {int sz = 0}) {
  final lsz = sz == 0 ? log2Ceil(v.length) : sz;
  final mid = v.length ~/ 2;
  return v.length == 1
      ? mux(v[0], Const(base, width: lsz), Const(base + 1, width: lsz))
      : mux(
          v[mid],
          lruLogicRecurse(v.sublist(0, mid), base, sz: lsz),
          lruLogicRecurse(v.sublist(mid + 1, v.length), mid + 1 + base,
              sz: lsz));
}

/// Recursive form of access: purely sequential traversal.
void accessInt(List<int> v, List<int> outV, int base, int item, {int len = 0}) {
  final ilen = len == 0 ? v.length : len;
  final mid = ilen ~/ 2;
  if (ilen == 1) {
    if (item == base) {
      outV[base] = 0; // The least recent is now our neighbor
    } else {
      outV[base] = 1;
    }
  } else {
    if (item <= mid + base) {
      // Go left to find item,but mark right as LRU
      outV[mid + base] = 0;
      accessInt(v, outV, base, item, len: mid);
    } else {
      // Go right to find item, but mark left as LRU
      outV[mid + base] = 1;
      accessInt(v, outV, mid + base + 1, item, len: ilen - mid - 1);
    }
  }
}

/// Recursive form of access: purely sequential traversal.
List<int> accessIntRecurse(List<int> v, int base, int item, {int len = 0}) {
  final ilen = len == 0 ? v.length : len;
  final mid = ilen ~/ 2;
  if (ilen == 1) {
    return [if (item == base) 0 else 1];
  } else {
    if (item <= mid + base) {
      // Go left to find item,but mark right as LRU
      final lower = accessIntRecurse(v, base, item, len: mid);
      final upper = v.sublist(mid + base + 1, base + ilen);
      return [...lower, 0, ...upper];
    } else {
      // Go right to find item, but mark left as LRU
      final lower = v.sublist(base, mid + base);
      final upper =
          accessIntRecurse(v, mid + base + 1, item, len: ilen - mid - 1);
      return [...lower, 1, ...upper];
    }
  }
}

/// Recursive form of access: purely sequential traversal.
List<int> accessIntRecurseNarrowing(List<int> v, int base, int item) {
  if (v.length == 1) {
    return [if (item == base) 0 else 1];
  } else {
    final mid = v.length ~/ 2;
    if (item <= mid + base) {
      // Go left to find item,but mark right as LRU
      final lower = accessIntRecurseNarrowing(v.sublist(0, mid), base, item);
      final upper = v.sublist(mid + 1, v.length);
      return [...lower, 0, ...upper];
    } else {
      // Go right to find item, but mark left as LRU
      final lower = v.sublist(0, mid);
      final upper = accessIntRecurseNarrowing(
          v.sublist(mid + 1, v.length), mid + base + 1, item);
      return [...lower, 1, ...upper];
    }
  }
}

/// Recursive form of access: parallel access returning an updated vector.
List<int> accessInt2(List<int> v, int base, int item, {int len = 0}) {
  final ilen = len == 0 ? v.length : len;
  final mid = ilen ~/ 2;
  if (ilen == 1) {
    return [if (item == base) 0 else if (item == (base + 1)) 1 else v[base]];
  } else {
    final lower = accessInt2(v, base, item, len: mid);
    final upper = accessInt2(v, mid + base + 1, item, len: ilen - mid - 1);
    final midVal = [
      if (item < base || item > base + ilen)
        v[mid + base]
      else if (item <= mid + base)
        0
      else
        1
    ];
    return [
      ...lower,
      ...midVal,
      ...upper,
    ];
  }
}

void accessLogicValue(
    List<LogicValue> v, List<LogicValue> outV, int base, LogicValue item,
    {int len = 0}) {
  final ilen = len == 0 ? v.length : len;
  final mid = ilen ~/ 2;
  if (ilen == 1) {
    if (item == LogicValue.of(base, width: item.width)) {
      outV[base] = LogicValue.zero; // The least recent is now our neighbor
    } else {
      outV[base] = LogicValue.one;
    }
  } else {
    if (item.toInt() <= mid + base) {
      // Go left to find item,but mark right as LRU
      outV[mid + base] = LogicValue.zero;
      accessLogicValue(v, outV, base, item, len: mid);
    } else {
      // Go right to find item, but mark left as LRU
      outV[mid + base] = LogicValue.one;
      accessLogicValue(v, outV, mid + base + 1, item, len: ilen - mid - 1);
    }
  }
}

/// Recursive form of access: parallel access returning an updated vector.
List<LogicValue> accessLogicValue2(
    List<LogicValue> v, int base, LogicValue item,
    {int len = 0}) {
  final ilen = len == 0 ? v.length : len;
  final mid = ilen ~/ 2;
  if (ilen == 1) {
    return [
      if (item == LogicValue.of(base, width: item.width))
        LogicValue.zero
      else if (item == LogicValue.of(base + 1, width: item.width))
        LogicValue.one
      else
        v[base]
    ];
  } else {
    final lower = accessLogicValue2(v, base, item, len: mid);
    final upper =
        accessLogicValue2(v, mid + base + 1, item, len: ilen - mid - 1);
    final midVal = [
      if ((item < LogicValue.of(base, width: item.width) == LogicValue.one) ||
          (item > LogicValue.of(base + ilen, width: item.width) ==
              LogicValue.one))
        v[mid + base]
      else if ((item <= LogicValue.of(mid + base, width: item.width)) ==
          LogicValue.one)
        LogicValue.zero
      else
        LogicValue.one
    ];
    return [
      ...lower,
      ...midVal,
      ...upper,
    ];
  }
}

/// Recursive form of access: parallel access returning an updated vector.
List<LogicValue> accessLogicValue3(
    List<LogicValue> v, int base, LogicValue item) {
  if (v.length == 1) {
    return [
      if (item == LogicValue.of(base, width: item.width))
        LogicValue.zero
      else if (item == LogicValue.of(base + 1, width: item.width))
        LogicValue.one
      else
        v[0]
    ];
  } else {
    final mid = v.length ~/ 2;
    final lower = accessLogicValue3(v.sublist(0, mid), base, item);
    final upper =
        accessLogicValue3(v.sublist(mid + 1, v.length), mid + base + 1, item);
    final midVal = [
      if ((item < LogicValue.of(base, width: item.width) == LogicValue.one) ||
          (item > LogicValue.of(base + v.length, width: item.width) ==
              LogicValue.one))
        v[mid]
      else if ((item <= LogicValue.of(mid + base, width: item.width)) ==
          LogicValue.one)
        LogicValue.zero
      else
        LogicValue.one
    ];
    return [
      ...lower,
      ...midVal,
      ...upper,
    ];
  }
}

/// Recursive form of access: parallel access returning an updated vector.
List<Logic> accessLogic(List<Logic> v, int base, Logic item, {int len = 0}) {
  final ilen = len == 0 ? v.length : len;
  final mid = ilen ~/ 2;
  if (ilen == 1) {
    return [
      mux(item.eq(Const(base, width: item.width)), Const(0),
          mux(item.eq(Const(base + 1, width: item.width)), Const(1), v[base]))
    ];
  } else {
    final lower = accessLogic(v, base, item, len: mid);
    final upper = accessLogic(v, mid + base + 1, item, len: ilen - mid - 1);
    final midVal = [
      mux(
          item.lt(Const(base, width: item.width)) |
              item.gt(Const(base + ilen, width: item.width)),
          v[mid + base],
          mux(item.lte(Const(mid + base, width: item.width)), Const(0),
              Const(1)))
    ];
    return [
      ...lower,
      ...midVal,
      ...upper,
    ];
  }
}

/// Recursive form of access: parallel access returning an updated vector.
List<Logic> accessLogicRecurse(List<Logic> v, int base, Logic item) {
  if (v.length == 1) {
    return [
      mux(item.eq(Const(base, width: item.width)), Const(0),
          mux(item.eq(Const(base + 1, width: item.width)), Const(1), v[0]))
    ];
  } else {
    final mid = v.length ~/ 2;
    final lower = accessLogicRecurse(v.sublist(0, mid), base, item);
    final upper =
        accessLogicRecurse(v.sublist(mid + 1, v.length), mid + base + 1, item);
    final midVal = [
      mux(
          item.lt(Const(base, width: item.width)) |
              item.gt(Const(base + v.length, width: item.width)),
          v[mid],
          mux(item.lte(Const(mid + base, width: item.width)), Const(0),
              Const(1)))
    ];
    return [
      ...lower,
      ...midVal,
      ...upper,
    ];
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });
  final v = [0, 1, 2, 3, 4, 5, 6, 7];
  var bi = <int>[0, 1, 1, 0, 0, 1, 1];

  test('try int', () async {
    print('int2 gets: ${v[leastRecentInt(bi, 0, len: bi.length)]}');
    print('b is:     \t$bi');

    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      print('accessing $a');
      accessInt(bi, bi, 0, a);
      print('b is now:\t$bi');
      print('int2 now gets: ${v[leastRecentInt(bi, 0)]}');
    }
    expect(leastRecentInt(bi, 0), 5);
  });

  test('try int recurse', () async {
    print('int2 gets: ${v[leastRecentInt(bi, 0, len: bi.length)]}');
    print('b is:     \t$bi');

    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      print('accessing $a');
      bi = accessIntRecurse(bi, 0, a);
      print('b is now:\t$bi');
      print('int2 now gets: ${v[leastRecentInt(bi, 0)]}');
    }
    expect(leastRecentInt(bi, 0), 5);
  });

  test('try int recurse narrowing', () async {
    print('int2 gets: ${v[lruIntRecurse(bi, 0)]}');
    print('versus: ${v[leastRecentInt(bi, 0, len: bi.length)]}');
    print('b is:     \t$bi');

    // print('b is:     \t$bi');

    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      print('accessing $a');
      bi = accessIntRecurseNarrowing(bi, 0, a);
      print('b is now:\t$bi');
      print('int2 now gets: ${v[lruIntRecurse(bi, 0)]}');
    }
    expect(lruIntRecurse(bi, 0), 5);
  });

  test('try int2', () async {
    print('int2 gets: ${v[leastRecentInt(bi, 0, len: bi.length)]}');
    print('b is:     \t$bi');

    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      print('accessing $a');
      bi = accessInt2(bi, 0, a);
      // accessInt(bi, bi, 0, a);
      print('b is now:\t$bi');
      print('int2 now gets: ${v[leastRecentInt(bi, 0)]}');
    }
    expect(leastRecentInt(bi, 0), 5);
  });

  test('try LogicValue', () async {
    var bv = [for (final e in bi) e == 1 ? LogicValue.one : LogicValue.zero];
    print('LogicValue gets: ${v[lruLogicValueRecurse(bv, 0).toInt()]}');
    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      print('accessing $a');
      // accessLogicValue(bv, bv, 0, LogicValue.of(a, width: 3));
      bv = accessLogicValue3(bv, 0, LogicValue.of(a, width: 3));
      print('b is now:\t${bv.map((e) => e.toInt()).toList()}');
      print('LV now gets: ${v[lruLogicValueRecurse(bv, 0).toInt()]}');
    }
    expect(lruLogicValueRecurse(bv, 0).toInt(), 5);
  });

  test('try Logic', () async {
    final v = [for (var i = 0; i < 7; i++) Logic()];
    var bv = [for (var i = 0; i < 7; i++) Logic()];
    for (var i = 0; i < v.length; i++) {
      v[i].put(bi[i]);
      bv[i].put(bi[i]);
    }
    print('Logic gets: ${lruLogicRecurse(v, 0).value.toInt()}');

    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      print('accessing $a');
      // accessLogicValue(bv, bv, 0, LogicValue.of(a, width: 3));
      bv = accessLogic(bv, 0, Const(a, width: 3));
      print('b is now:\t${bv.map((e) => e.value.toInt()).toList()}');
      print('Logic gets: ${lruLogicRecurse(bv, 0).value.toInt()}');
    }
    expect(lruLogicRecurse(bv, 0).value.toInt(), 5);
  });

  test('try Logic3', () async {
    final v = [for (var i = 0; i < 7; i++) Logic()];
    var bv = [for (var i = 0; i < 7; i++) Logic()];
    for (var i = 0; i < v.length; i++) {
      v[i].put(bi[i]);
      bv[i].put(bi[i]);
    }
    print('Logic gets: ${lruLogicRecurse(v, 0).value.toInt()}');

    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      print('accessing $a');
      // accessLogicValue(bv, bv, 0, LogicValue.of(a, width: 3));
      bv = accessLogicRecurse(bv, 0, Const(a, width: 3));
      print('b is now:\t${bv.map((e) => e.value.toInt()).toList()}');
      print('Logic gets: ${lruLogicRecurse(bv, 0).value.toInt()}');
    }
    expect(lruLogicRecurse(bv, 0).value.toInt(), 5);
  });
}
