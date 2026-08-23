// AI 对手测试：决策合法性、攻击/吞噬优先级、AI vs AI 完整对局
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/game/ai.dart';

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
  test('easy：随机决策始终返回合法行动', () {
    final g = custom(['[8]', '[2]', '{1}', '0', '0', '0', '0', '{8}']);
    g.turn = 0;
    g.phase = 'action';
    g.points = 1;
    final ai = AimAi(AiLevel.easy);
    for (var k = 0; k < 20; k++) {
      final a = ai.decide(g);
      expect(a, isNotNull);
      expect(g.applyAction(0, a!).isNotEmpty, true, reason: 'easy 决策应能执行: $a');
      // 重置（每次独立决策）
      g.cells = custom(['[8]', '[2]', '{1}', '0', '0', '0', '0', '{8}']).cells;
      g.phase = 'action';
      g.points = 1;
      g.winner = null;
    }
  });

  test('normal：能一击消灭敌方时优先攻击', () {
    final g = custom(['[8]', '[2]', '{1}', '0', '0', '0', '0', '{8}']);
    g.turn = 0;
    g.phase = 'action';
    g.points = 1;
    final a = AimAi(AiLevel.normal).decide(g)!;
    expect(a['type'], 'attack', reason: '2 打 1 能消灭，应选攻击: $a');
    expect(a['i'], 1);
    expect(a['j'], 2);
  });

  test('normal：能合成 8（基地）时优先吞噬', () {
    final g = custom(['[8]', '[4]', '[4]', '0', '0', '0', '0', '{8}']);
    g.turn = 0;
    g.phase = 'action';
    g.points = 1;
    final a = AimAi(AiLevel.normal).decide(g)!;
    expect(a['type'], 'devour', reason: '4+4=8 应优先合体: $a');
    expect(g.applyAction(0, a)['ok'], true);
  });

  test('normal：不主动攻击己方单位', () {
    final g = custom(['[8]', '[2]', '[1]', '0', '0', '0', '0', '{8}']);
    g.turn = 0;
    g.phase = 'action';
    g.points = 1;
    final a = AimAi(AiLevel.normal).decide(g)!;
    expect(a['type'], isNot('attack'), reason: '己方 1 不该被攻击: $a');
  });

  test('normal：选阶段——有高价值行动时选 action，否则 produce', () {
    // 开局：只有基地，选 produce 养兵
    final g = AimGame(limit: 16);
    g.turn = 0;
    final a1 = AimAi(AiLevel.normal).decide(g)!;
    expect(a1['type'], 'choosePhase');
    // 有吞噬合成 8 的机会 → 选 action
    final g2 = custom(['[8]', '[4]', '[4]', '0', '0', '0', '0', '{8}']);
    g2.turn = 0;
    final a2 = AimAi(AiLevel.normal).decide(g2)!;
    expect(a2['phase'], 'action', reason: '有合成机会应选行动: $a2');
  });

  test('AI vs AI 完整对局：不卡死、行动全合法（含滚木逐步）', () {
    final g = AimGame(limit: 16);
    final ai0 = AimAi(AiLevel.normal, seed: 1);
    final ai1 = AimAi(AiLevel.hard, seed: 2);
    var steps = 0;
    while (g.winner == null && steps < 400) {
      steps++;
      final owner = g.turn;
      final ai = owner == 0 ? ai0 : ai1;
      final action = ai.decide(g);
      if (action == null) break;
      final r = g.applyAction(owner, action, deferRoll: true);
      expect(r['ok'], true, reason: 'AI 行动应合法（第$steps步）: $action');
      // 模拟 GameScreen 逐步滚木
      var guard = 0;
      while (g.hasPendingRoll && guard < 100) {
        guard++;
        g.rollStepOnce(g.turn);
      }
      if (guard >= 100) fail('滚木驱动卡死');
      g.clearPendingRoll();
    }
    expect(steps < 400, true, reason: 'AI 对局不应卡死（$steps 步）');
    expect(g.winner != null || steps > 50, true, reason: '对局应有进展');
  });

  test('hard：喂兵链路——滚木路径上的1被碾成5+插桥（规则级，两回合）', () {
    // 1 在格3（滚木+1）：滚木碾过 → 1-6=-5 → 5 + 插桥
    final g = custom(['[8]', '0', '[6]', '[1]', '0', '0', '0', '{8}']);
    g.cells[2].auto = true;
    g.turn = 0;
    g.applyAction(0, {'type': 'endTurn'}, deferRoll: true);
    g.applyAction(1, {'type': 'endTurn'}, deferRoll: true); // 轮到玩家0 → 玩家0滚木待滚
    expect(g.hasPendingRoll, true, reason: '玩家0 滚木应待滚');
    var guard = 0;
    while (g.hasPendingRoll && guard < 50) {
      guard++;
      g.rollStepOnce(g.turn);
    }
    g.clearPendingRoll();
    expect(g.cells.any((c) => c.v == 5 && c.o == 0), true, reason: '1 被碾应变成 5');
    expect(g.cells.any((c) => c.isB), true, reason: '溢出应插桥');
  });

  test('hard：滚木路径上的1不浪费——AI 移动保持升级区不送死', () {
    // 1 在格3（滚木+1）：唯一移动是格4（+2 升级区，+55）或格5（+3 死亡区 -200）
    final g = custom(['[8]', '0', '[6]', '[1]', '0', '0', '0', '{8}']);
    g.cells[2].auto = true;
    g.turn = 0;
    g.phase = 'action';
    g.points = 1;
    final a = AimAi(AiLevel.hard).decide(g)!;
    expect(g.applyAction(0, a)['ok'], true);
    expect(g.cells[4].v, 1, reason: '1 应移到格4（滚木+2 升级区），不送死亡区: $a');
  });

  test('hard：大单位逃离滚木路径（5 骑兵两步跑出+4 安全区）', () {
    // 5 在格4（滚木+2 会被碾成1）：骑兵两步可逃到格6（路径外）
    final g = custom(['[8]', '0', '[6]', '0', '[5]', '0', '0', '{8}']);
    g.cells[2].auto = true;
    g.turn = 0;
    g.phase = 'action';
    g.points = 1;
    final a = AimAi(AiLevel.hard).decide(g)!;
    expect(a['type'], 'move', reason: '5 应移动逃离: $a');
    expect(a['steps'], 2, reason: '5 骑兵两步逃到格6: $a');
    expect(g.applyAction(0, a)['ok'], true);
    expect(g.cells[6].v, 5, reason: '5 应逃到格6（滚木路径外）');
  });

  test('hard：不把单位送进滚木第3格（死亡区）', () {
    // 滚木格1（路径2/3/4），1 在格5：可移格4（+3 抹杀区）或格6（安全）
    final g = custom(['[8]', '[6]', '0', '0', '0', '[1]', '0', '{8}']);
    g.cells[1].auto = true;
    g.turn = 0;
    g.phase = 'action';
    g.points = 1;
    final a = AimAi(AiLevel.hard).decide(g)!;
    expect(a['type'], 'move');
    expect(a['i'], 5);
    expect(a['steps'], 1);
    expect(g.applyAction(0, a)['ok'], true);
    expect(g.cells[6].v, 1, reason: '1 应移到格6（避开滚木第3格死亡区）');
  });

  test('normal：不启用滚木配合（保持普通强度）', () {
    final g = custom(['[8]', '0', '[6]', '0', '[1]', '0', '0', '{8}']);
    g.cells[2].auto = true;
    g.turn = 0;
    g.phase = 'action';
    g.points = 1;
    final a = AimAi(AiLevel.normal).decide(g)!;
    // normal 没有滚木加分：1 只有格3一个移动目标，还是会移，但这不是滚木逻辑（唯一选择）
    // 这里验证 normal 决策不崩 + 合法即可
    expect(g.applyAction(0, a)['ok'], true);
  });
}
