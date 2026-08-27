import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/train/train_ai.dart';

void main() {
  test('无基地时 AI 阶段选择强制 action（不跳过回合）', () {
    final ai = TrainAi(explore: false); // 无权重 → 走 fallback 但会被 _canProduce 拦截
    // AI（玩家1，右）基地被打掉：只剩兵
    final g = AimGame(limit: 16);
    g.cells[0] = AimCell(0);
    g.cells[1] = AimCell(5, o: 0); // 玩家0 兵
    g.cells[6] = AimCell(3, o: 1); // 玩家1（AI）兵，无基地
    g.cells[7] = AimCell(0);
    g.turn = 1;
    g.phase = null;
    final a = ai.decide(g);
    expect(a, isNotNull);
    expect(a!['type'], 'choosePhase');
    expect(a['phase'], 'action', reason: '无基地必须选行动阶段，实际 $a');
  });

  test('有基地时正常决策', () {
    final ai = TrainAi(explore: false);
    final g = AimGame(limit: 16);
    g.turn = 1;
    g.phase = null;
    final a = ai.decide(g);
    expect(a, isNotNull);
    expect(a!['type'], 'choosePhase');
  });
}
