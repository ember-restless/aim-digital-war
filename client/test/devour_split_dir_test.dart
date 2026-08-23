// 吞噬超9拆分方向：棋盘从左到右读 = 十进制（十位在左、个位在右）
// 回归：右方(玩家1) 7吞5=12 之前生成"21"，现在必须"12"
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';

void main() {
  test('左方(玩家0) 7吞5=12 → me保留1(十位)，目标位2(个位)：左1右2', () {
    final g = AimGame(limit: 12);
    g.cells = [
      AimCell(8, o: 0),
      AimCell(7, o: 0), // 吞噬者 me（左）
      AimCell(5, o: 0), // 目标（右）
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(8, o: 1),
    ];
    final r = g.doDevour(0, 1, 2);
    expect(r, true);
    expect(g.cells[1].v, 1, reason: 'me（左）应为十位 1');
    expect(g.cells[2].v, 2, reason: '目标位（右）应为个位 2');
    expect(g.cells[1].o, 0);
    expect(g.cells[2].o, 0);
  });

  test('右方(玩家1) 7吞5=12 → me保留2(个位)，目标位1(十位)：仍是左1右2', () {
    final g = AimGame(limit: 12);
    g.cells = [
      AimCell(8, o: 0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(5, o: 1), // 目标（左）
      AimCell(7, o: 1), // 吞噬者 me（右）
      AimCell(8, o: 1),
    ];
    final r = g.doDevour(1, 10, 9);
    expect(r, true);
    expect(g.cells[9].v, 1, reason: '目标位（左）应为十位 1');
    expect(g.cells[10].v, 2, reason: 'me（右）应为个位 2');
    expect(g.cells[9].o, 1);
    expect(g.cells[10].o, 1);
  });

  test('右方(玩家1) 8吞2=10 → me 变空，目标位 1（左1右[空]）', () {
    final g = AimGame(limit: 12);
    g.cells = [
      AimCell(8, o: 0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(2, o: 1),
      AimCell(8, o: 1),
      AimCell(8, o: 1),
    ];
    final r = g.doDevour(1, 10, 9);
    expect(r, true);
    expect(g.cells[9].v, 1, reason: '目标位（左）应为十位 1');
    expect(g.cells[9].o, 1);
    expect(g.cells[10].v, 0, reason: 'me 变空');
    expect(g.cells[10].o, null, reason: '空地不能残留归属');
  });

  test('双端一致的旁证：左右双方拆出结果逐格相同', () {
    final g0 = AimGame(limit: 12);
    g0.cells = [
      AimCell(8, o: 0),
      AimCell(7, o: 0),
      AimCell(5, o: 0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(8, o: 1),
    ];
    g0.doDevour(0, 1, 2);

    final g1 = AimGame(limit: 12);
    g1.cells = [
      AimCell(8, o: 0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(5, o: 1),
      AimCell(7, o: 1),
      AimCell(8, o: 1),
    ];
    g1.doDevour(1, 10, 9);

    // 从左到右读：1、2（1 在前）
    expect([g0.cells[1].v, g0.cells[2].v], [1, 2]);
    expect([g1.cells[9].v, g1.cells[10].v], [1, 2]);
  });
}
