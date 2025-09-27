import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/src/memory/plru.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });
  var bi = <int>[0, 1, 1, 0, 0, 1, 1];

  test('integer LRU', () async {
    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      bi = hitPLRUInt(bi, a);
    }
    expect(allocPLRUInt(bi), 5);
  });

  test('integer LRU write invalidate', () async {
    for (final a in [5, 1, 6, 2, 4, 0, 7]) {
      bi = hitPLRUInt(bi, a, invalidate: true);
      expect(a, allocPLRUInt(bi));
    }
  });

  test('LogicValue LRU', () async {
    var bv = [for (final e in bi) e == 1 ? LogicValue.one : LogicValue.zero];
    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      bv = hitPLRULogicValue(bv, LogicValue.of(a, width: 3));
    }
    expect(allocPLRULogicValue(bv).toInt(), 5);
  });

  test('LogicValue LRU write invalidate', () async {
    var bv = [for (final e in bi) e == 1 ? LogicValue.one : LogicValue.zero];
    for (final a in [5, 1, 6, 2, 4, 0, 7]) {
      bv = hitPLRULogicValue(bv, LogicValue.of(a, width: 3),
          invalidate: LogicValue.one);
      expect(a, allocPLRULogicValue(bv).toInt());
    }
  });

  test('Logic LRU', () async {
    var bv = [for (var i = 0; i < 7; i++) Logic()];
    for (var i = 0; i < bv.length; i++) {
      bv[i].put(bi[i]);
    }
    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      bv = hitPLRULogic(bv, Const(a, width: 3));
    }
    expect(allocPLRULogic(bv).value.toInt(), 5);
  });

  test('Logic LRU write invalidate', () async {
    var bv = [for (var i = 0; i < 7; i++) Logic()];
    for (var i = 0; i < bv.length; i++) {
      bv[i].put(bi[i]);
    }
    for (final a in [5, 1, 6, 2, 4, 0, 7]) {
      bv = hitPLRULogic(bv, Const(a, width: 3), invalidate: Const(1));
      expect(a, allocPLRULogic(bv).value.toInt());
    }
  });

  test('LogicVector LRU', () async {
    final v = [for (var i = 0; i < 7; i++) Logic()];
    final bv = [for (var i = 0; i < 7; i++) Logic()];
    for (var i = 0; i < v.length; i++) {
      // v[i].put(bi[i]);
      bv[i].put(bi[i]);
    }
    var brv = bv.rswizzle();

    for (final a in [5, 1, 6, 2, 4, 0, 7, 3, 5, 1, 6, 2, 4, 0, 7, 3]) {
      brv = hitPLRULogicVector(brv, Const(a, width: 3));
    }
    expect(allocPLRULogicVector(brv).value.toInt(), 5);
  });

  test('LogicVector LRU write invalidate', () async {
    final bv = [for (var i = 0; i < 7; i++) Logic()];
    for (var i = 0; i < bv.length; i++) {
      bv[i].put(bi[i]);
    }
    var brv = bv.rswizzle();

    for (final a in [5, 1, 6, 2, 4, 0, 7]) {
      brv = hitPLRULogicVector(brv, Const(a, width: 3), invalidate: Const(1));
      expect(a, allocPLRULogicVector(brv).value.toInt());
    }
  });
}
