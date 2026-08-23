// 死局判负（牢大 08-22）：一方无任何可执行行动（无法移动/攻击/吞噬/拆分）→ 直接判负
// 不再"自动过回合"——场上单位全部无法操作时，该方输
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';

void main() {
  test('死局判负：一方只剩锁死滚木（6 auto 不可操控）→ 该方判负', () {
    final g = AimGame(limit: 16);
    g.cells = [
      AimCell(6, o: 0, auto: true), // 玩家0 只剩滚木（已激活不可操控）
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(8, o: 1),
    ];
    g.turn = 0;
    g.points = 1;
    // 选行动阶段 → maybeAutoEnd → 无任何可执行行动 → 判负
    final r = g.applyAction(0, {'type': 'choosePhase', 'phase': 'action'});
    expect(r['ok'], true);
    expect(g.winner, 1, reason: '玩家0 无法行动，玩家1 获胜');
    expect(g.log.any((l) => l.contains('判负')), true);
  });

  test('死局判负不误伤：正常局面选行动阶段 → 不判负', () {
    final g = AimGame(limit: 16);
    g.cells = [
      AimCell(8, o: 0),
      AimCell(1, o: 0), // 玩家0 有可动小兵
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(8, o: 1),
    ];
    g.turn = 0;
    g.points = 1;
    g.applyAction(0, {'type': 'choosePhase', 'phase': 'action'});
    expect(g.winner, isNull, reason: '有可行动单位，不应判负');
  });

  test('死局判负不误伤：只剩基地8（可拆分）→ 不判负', () {
    final g = AimGame(limit: 16);
    g.cells = [
      AimCell(8, o: 0), // 只剩基地
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(0),
      AimCell(8, o: 1),
    ];
    g.turn = 0;
    g.points = 1;
    g.applyAction(0, {'type': 'choosePhase', 'phase': 'action'});
    expect(g.winner, isNull, reason: '基地8 可拆分，不算死局');
  });
}
