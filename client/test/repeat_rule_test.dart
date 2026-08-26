// 重复操作判负测试（象棋式「三次重复」）：
// 指纹 = 玩家 | 操作签名 | 操作后棋盘快照，同一指纹第 3 次出现 → 制造循环者判负
// 与 server rules.js / pc rules.py 行为一致
// 跑法：cd /root/aim/client && timeout 120 /opt/flutter/bin/flutter test --no-version-check test/repeat_rule_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';

AimGame custom(List<String> spec, {int limit = 16}) {
  final g = AimGame(limit: limit);
  g.cells = spec.map((s) {
    if (s == '-') return AimCell(0, bridge: true);
    if (s == '0') return AimCell(0);
    if (s.startsWith('{')) return AimCell(int.parse(s.substring(1, s.length - 1)), o: 1);
    if (s.startsWith('[')) return AimCell(int.parse(s.substring(1, s.length - 1)), o: 0);
    return AimCell(int.parse(s), o: 0);
  }).toList();
  return g;
}

void main() {
  test('重复攻击同一目标（局面复原）3 次 → 玩家0判负', () {
    // 0 弓手3@4 反复 attack 1 兵@6（2→1）；1 每回合 produce 基地恢复（1→2）
    // 棋盘每轮复原 → 0 的 attack:4:6 指纹第 3 次出现 → 玩家0 负
    final g = custom(['[8]', '0', '0', '0', '[3]', '0', '{2}', '{8}']);
    for (var round = 0; round < 3; round++) {
      final r = g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
      expect(r['ok'], true, reason: '第${round + 1}轮攻击');
      if (round < 2) {
        expect(g.winner, isNull, reason: '前两轮不该判负');
      }
      if (g.winner != null) break;
      final r2 = g.applyAction(1, {'type': 'produce', 'i': 7});
      expect(r2['ok'], true, reason: '第${round + 1}轮恢复');
    }
    expect(g.winner, 1, reason: '玩家0 制造循环应判负');
    expect(g.log.last, contains('重复完全相同操作三次'));
  });

  test('第 2 次重复不判负（累计中）', () {
    final g = custom(['[8]', '0', '0', '0', '[3]', '0', '{2}', '{8}']);
    g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
    g.applyAction(1, {'type': 'produce', 'i': 7});
    g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
    g.applyAction(1, {'type': 'produce', 'i': 7});
    expect(g.winner, isNull);
  });

  test('正常攻防（棋盘在变）不判负', () {
    // 0 交替攻击不同目标，1 每轮恢复 → 指纹棋盘不同 → 不累计
    final g = custom(['[8]', '0', '0', '0', '[3]', '{4}', '{2}', '{8}']);
    g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
    g.applyAction(1, {'type': 'produce', 'i': 7});
    g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 5});
    g.applyAction(1, {'type': 'produce', 'i': 7});
    g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
    expect(g.winner, isNull, reason: '局面一直在变，不该判负');
  });

  test('判负后游戏结束，后续操作被拒', () {
    final g = custom(['[8]', '0', '0', '0', '[3]', '0', '{2}', '{8}']);
    for (var round = 0; round < 3; round++) {
      g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
      if (g.winner != null) break;
      g.applyAction(1, {'type': 'produce', 'i': 7});
    }
    expect(g.winner, 1);
    final r = g.applyAction(0, {'type': 'endTurn'});
    expect(r['ok'], false);
    expect(r['reason'], '游戏已结束');
  });

  test('不同玩家各自指纹独立，不互相干扰', () {
    // 0 和 1 各做 2 次自己的操作，互不累计到对方
    final g = custom(['[8]', '0', '0', '0', '[3]', '0', '{2}', '{8}']);
    g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
    g.applyAction(1, {'type': 'produce', 'i': 7});
    g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
    g.applyAction(1, {'type': 'produce', 'i': 7});
    expect(g.winner, isNull);
    // 0 第三次 attack → 0 负（不是 1 负）
    g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
    expect(g.winner, 1);
  });

  test('第 2 次重复返回 repeatWarn 提示，第 3 次才判负', () {
    final g = custom(['[8]', '0', '0', '0', '[3]', '0', '{2}', '{8}']);
    final r1 = g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
    expect(r1['repeatWarn'], isNot(true), reason: '第 1 次不该警告');
    g.applyAction(1, {'type': 'produce', 'i': 7});
    final r2 = g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
    expect(r2['repeatWarn'], true, reason: '第 2 次应返回警告');
    expect(g.winner, isNull, reason: '第 2 次不该判负');
    expect(g.log.any((l) => l.contains('再重复一次')), true, reason: 'log 应有警告');
    g.applyAction(1, {'type': 'produce', 'i': 7});
    g.applyAction(0, {'type': 'attack', 'i': 4, 'j': 6});
    expect(g.winner, 1, reason: '第 3 次判负');
  });

  test('只剩激活滚木直接判负', () {
    // 玩家0 基地被清掉，只剩激活滚木 6（放 1 号位，远离玩家1基地@7）
    final g = custom(['[8]', '[6]', '0', '0', '0', '0', '0', '{8}']);
    g.cells[0] = AimCell(0); // 清掉玩家0基地
    g.cells[1] = AimCell(6, o: 0, auto: true); // 激活滚木
    g.turn = 1;
    final r = g.applyAction(1, {'type': 'produce', 'i': 7});
    expect(r['ok'], true, reason: r['reason']);
    expect(g.winner, 1, reason: '玩家0 只剩滚木应判负');
    expect(g.log.any((l) => l.contains('只剩滚木')), true);
  });

  test('有可控单位（基地/兵）不判负', () {
    final g = custom(['[8]', '0', '0', '0', '0', '0', '0', '{8}']);
    g.cells[1] = AimCell(6, o: 0, auto: true); // 有滚木也有基地
    g.turn = 1;
    g.applyAction(1, {'type': 'produce', 'i': 7});
    expect(g.winner, isNull);
  });
}
