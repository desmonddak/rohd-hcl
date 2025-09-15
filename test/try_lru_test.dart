import 'package:rohd/rohd.dart';
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

void accessLogicValue(
    List<LogicValue> v, List<LogicValue> outV, int base, LogicValue item,
    {int len = 0}) {
  final ilen = len == 0 ? v.length : len;
  final mid = ilen ~/ 2;
  if (ilen == 1) {
    if (item == base) {
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

Logic leastRecentLogic(List<Logic> v, int base, {int origSz = 0}) {
  final sz = origSz == 0 ? v.length : origSz;
  final mid = v.length ~/ 2;
  return v.length == 1
      ? mux(v[0], Const(base, width: sz), Const(base + 1, width: sz))
      : mux(
          v[mid],
          leastRecentLogic(v.sublist(0, mid), base, origSz: sz),
          leastRecentLogic(v.sublist(mid + 1, v.length), mid + 1 + base,
              origSz: sz));
}

void accessLogic(List<Logic> v, List<Logic> outV, int base, Logic item,
    {int len = 0}) {
  List<Logic> outVV;
  final ilen = len == 0 ? v.length : len;
  final mid = ilen ~/ 2;
  if (ilen == 1) {
    outV[base] = mux(
        item.eq(Const(base, width: 3)), Const(0, width: 3), Const(0, width: 1));
  } else {
    outV <= mux(Const(1), v, v);
    outV[mid + base] = mux(item.lte(Const(mid + base, width: 3)),
        Const(0, width: 1), Const(1, width: 1));
    if (item.toInt() <= mid + base) {
      accessLogicValue(v, outV, base, item, len: mid);
    } else {
      accessLogicValue(v, outV, mid + base + 1, item, len: ilen - mid - 1);
    }
  }
}

void modifyVec(List<int> v, int idx, int val) {
  final x = v.sublist(1, v.length);
  print('x is $x');
  print('v before: $v');
  x[idx] = val;
  print('x is now $x');

  print('v after: $v');
}

// 1) Flip the polarity of the tree for all.  DONE
// 2) access routine: add an outputV.
// 2) access routine:  set all bits in path to follow the access.

void main() {
  tearDown(() async {
    await Simulator.reset();
  });
  final bi = [0, 1, 1, 0, 0, 1, 1];

  test('try int', () async {
    final v = [0, 1, 2, 3, 4, 5, 6, 7];

    print('int2 gets: ${v[leastRecentInt(bi, 0, len: bi.length)]}');
    print('b is:     \t$bi');

    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0]) {
      print('accessing $a');
      accessInt(bi, bi, 0, a);
      print('b is now:\t$bi');
      print('int2 now gets: ${v[leastRecentInt(bi, 0)]}');
    }
  });

  test('try LogicValue', () async {
    final v = [0, 1, 2, 3, 4, 5, 6, 7];
    final bv = [for (final e in bi) e == 1 ? LogicValue.one : LogicValue.zero];
    print('LogicValue gets: ${v[leastRecentLogicValue(bv, 0).toInt()]}');
    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0]) {
      print('accessing $a');
      accessLogicValue(bv, bv, 0, LogicValue.of(a, width: 3));
      print('b is now:\t$bv');
      print('LV now gets: ${v[leastRecentLogicValue(bv, 0).toInt()]}');
    }
  });

  test('try Logic', () async {
    final v = [for (var i = 0; i < 7; i++) Logic()];
    for (var i = 0; i < v.length; i++) {
      v[i].put(bi[i]);
    }
    print('Logic gets: ${leastRecentLogic(v, 0).value.toInt()}');
  });
}
