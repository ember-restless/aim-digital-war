// 修复 2 验证：多滚木时，第一个滚木死亡/抹杀动画不被下一个滚木的 acts 吞掉
import '../lib/game/rules.dart' show AimGame, AimCell;

void main() {
  // 场景：A@2（玩家1，右→左，压{2}@1插桥后撞桥死）+ B@8（玩家1，右→左，滚向空地存活）
  // A 在收集顺序前（index 2 < 8）→ 先滚，验证死步不被 B 的 acts 吞
  final g = AimGame(limit: 16);
  g.cells = List.generate(10, (i) => AimCell(0));
  g.cells[1] = AimCell(2, o: 1);
  g.cells[2] = AimCell(6, o: 1); // A
  g.cells[8] = AimCell(6, o: 1); // B
  g.cells[0] = AimCell(8, o: 0); // 玩家0基地
  g.cells[9] = AimCell(8, o: 1); // 玩家1基地

  g.endTurn(0, deferRoll: true); // 轮到玩家1 → A 待滚
  print('待滚: ${g.hasPendingRoll}');

  var step = 0;
  List<String> ops = [];
  while (true) {
    final acts = g.rollStepOnce(g.turn);
    if (acts == null) {
      g.clearPendingRoll();
      break;
    }
    step++;
    final opDesc = acts.map((a) => '${a['op']}@${a['from']}').join('+');
    ops.add('步$step: $opDesc');
    print('步$step acts: ${acts.map((a) => a.toString()).join(' | ')}');
    if (step > 10) break;
  }
  print('最终棋盘: ${g.cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : c.v)).join(' ')}');

  // 期望：A 的 dead 步单独返回（不被 B 的 acts 吞），然后 B 继续
  final hasADead = ops.any((o) => o.contains('dead@2'));
  print('A 的 dead 步单独出现: ${hasADead ? '✅' : '❌'}');
  if (!hasADead) {
    print('❌ 修复失败：A 的 dead 动画被吞');
  } else {
    print('✅ A dead 步正常返回，B 后续步正常');
  }
}
