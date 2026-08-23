// 对局统计测试：kills/losses/produce/turnCount 记录
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
  test('统计：攻击击杀 + 损失', () {
    final g = custom(['[8]', '[1]', '{1}', '0', '0', '0', '0', '{8}']);
    g.turn = 0;
    g.phase = 'action';
    g.points = 1;
    g.applyAction(0, {'type': 'attack', 'i': 1, 'j': 2}); // 1 打 1 → 击杀
    expect((g.stats['kills'] as List)[0], 1, reason: '玩家0 击杀+1');
    expect((g.stats['losses'] as List)[1], 1, reason: '玩家1 损失+1');
  });

  test('统计：造兵数', () {
    final g = AimGame(limit: 16);
    g.turn = 0;
    g.phase = 'produce';
    g.produceLeft = 1;
    g.applyAction(0, {'type': 'produce', 'i': 0, 'j': 1});
    expect((g.stats['produce'] as List)[0], 1);
  });

  test('统计：吞噬记击杀/损失', () {
    final g = custom(['[8]', '[4]', '{2}', '0', '0', '0', '0', '{8}']);
    g.turn = 0;
    g.phase = 'action';
    g.points = 1;
    g.applyAction(0, {'type': 'devour', 'i': 1, 'j': 2});
    expect((g.stats['kills'] as List)[0], 1, reason: '吞噬目标阵亡记击杀');
    expect((g.stats['losses'] as List)[1], 1);
  });

  test('统计：滚木碾死只记损失不记击杀', () {
    final g = AimGame(limit: 16);
    g.cells = [
      AimCell(6, o: 0),
      AimCell(6, o: 1), // 敌方 6 会被碾死
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(8, o: 1),
    ];
    g.applyDamage(1, 6); // 无 byOwner（滚木碾压）
    expect((g.stats['losses'] as List)[1], 1);
    expect((g.stats['kills'] as List)[0], 0, reason: '滚木不记任何方击杀');
    expect((g.stats['kills'] as List)[1], 0);
  });

  test('统计：endTurn 回合数 + viewFor 输出', () {
    final g = AimGame(limit: 16);
    g.turn = 0;
    g.applyAction(0, {'type': 'endTurn'}, deferRoll: true);
    expect(g.turnCount, 1);
    final v = g.viewFor(1);
    expect(v['stats'], isNotNull);
    expect(v['turnCount'], 1);
  });
}
