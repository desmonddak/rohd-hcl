import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:test/test.dart';

int lruInt(List<int> v, int base) {
  final mid = v.length ~/ 2;
  return v.length == 1
      ? v[0] == 0
          ? base + 1
          : base
      : v[mid] == 0
          ? lruInt(v.sublist(mid + 1, v.length), mid + 1 + base)
          : lruInt(v.sublist(0, mid), base);
}

LogicValue lruLogicValue(List<LogicValue> v, int base, {int sz = 0}) {
  final lsz = sz == 0 ? log2Ceil(v.length) : sz;
  final mid = v.length ~/ 2;
  return v.length == 1
      ? v[0] == LogicValue.zero
          ? LogicValue.ofInt(base + 1, lsz)
          : LogicValue.ofInt(base, lsz)
      : v[mid] == LogicValue.zero
          ? lruLogicValue(v.sublist(mid + 1, v.length), mid + 1 + base, sz: lsz)
          : lruLogicValue(v.sublist(0, mid), base, sz: lsz);
}

Logic lruLogic(List<Logic> v, int base, {int sz = 0}) {
  final lsz = sz == 0 ? log2Ceil(v.length) : sz;
  final mid = v.length ~/ 2;
  return v.length == 1
      ? mux(v[0], Const(base, width: lsz), Const(base + 1, width: lsz))
      : mux(v[mid], lruLogic(v.sublist(0, mid), base, sz: lsz),
          lruLogic(v.sublist(mid + 1, v.length), mid + 1 + base, sz: lsz));
}

/// Recursive form of access: purely sequential traversal.
List<int> accessInt(List<int> v, int base, int item) {
  if (v.length == 1) {
    return [if (item == base) 0 else 1];
  } else {
    final mid = v.length ~/ 2;
    if (item <= mid + base) {
      // Go left to find item,but mark right as LRU
      final lower = accessInt(v.sublist(0, mid), base, item);
      final upper = v.sublist(mid + 1, v.length);
      return [...lower, 0, ...upper];
    } else {
      // Go right to find item, but mark left as LRU
      final lower = v.sublist(0, mid);
      final upper =
          accessInt(v.sublist(mid + 1, v.length), mid + base + 1, item);
      return [...lower, 1, ...upper];
    }
  }
}

/// Recursive form of access: parallel access returning an updated vector.
List<LogicValue> accessLogicValue(
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
    final lower = accessLogicValue(v.sublist(0, mid), base, item);
    final upper =
        accessLogicValue(v.sublist(mid + 1, v.length), mid + base + 1, item);
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
List<Logic> accessLogic(List<Logic> v, int base, Logic item) {
  if (v.length == 1) {
    return [
      mux(item.eq(Const(base, width: item.width)), Const(0),
          mux(item.eq(Const(base + 1, width: item.width)), Const(1), v[0]))
    ];
  } else {
    final mid = v.length ~/ 2;
    final lower = accessLogic(v.sublist(0, mid), base, item);
    final upper =
        accessLogic(v.sublist(mid + 1, v.length), mid + base + 1, item);
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

  test('integer LRU', () async {
    print('int gets: ${v[lruInt(bi, 0)]}');
    print('b is:     \t$bi');

    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      print('accessing $a');
      bi = accessInt(bi, 0, a);
      print('b is now:\t$bi');
      print('int now gets: ${v[lruInt(bi, 0)]}');
    }
    expect(lruInt(bi, 0), 5);
  });

  test('LogicValue LRU', () async {
    var bv = [for (final e in bi) e == 1 ? LogicValue.one : LogicValue.zero];
    print('LogicValue gets: ${v[lruLogicValue(bv, 0).toInt()]}');
    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      print('accessing $a');
      bv = accessLogicValue(bv, 0, LogicValue.of(a, width: 3));
      print('b is now:\t${bv.map((e) => e.toInt()).toList()}');
      print('LV now gets: ${v[lruLogicValue(bv, 0).toInt()]}');
    }
    expect(lruLogicValue(bv, 0).toInt(), 5);
  });

  test('Logic LRU', () async {
    final v = [for (var i = 0; i < 7; i++) Logic()];
    var bv = [for (var i = 0; i < 7; i++) Logic()];
    for (var i = 0; i < v.length; i++) {
      v[i].put(bi[i]);
      bv[i].put(bi[i]);
    }
    print('Logic gets: ${lruLogic(v, 0).value.toInt()}');

    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      print('accessing $a');
      bv = accessLogic(bv, 0, Const(a, width: 3));
      print('b is now:\t${bv.map((e) => e.value.toInt()).toList()}');
      print('Logic gets: ${lruLogic(bv, 0).value.toInt()}');
    }
    expect(lruLogic(bv, 0).value.toInt(), 5);
  });
}
