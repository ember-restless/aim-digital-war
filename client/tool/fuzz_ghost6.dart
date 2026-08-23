// 滚木阶段长度对比：主动 endTurn 触发滚木，rollSteps 推导预期变化
import 'dart:math';
import '../lib/game/rules.dart';

String boardStr(AimGame g) =>
    g.cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : '${c.v}${c.o == 0 ? 'a' : 'b'}')).join(' ');

void main() {
  final rng = Random(999);
  var bad = 0, rounds = 0;

  for (var round = 0; round < 400 && bad < 5; round++) {
    final g = AimGame(limit: 16);
    for (var step = 0; step < 300; step++) {
      if (g.winner != null) break;
      if (g.phase == null) {
        final acts = g.getLegalActions(g.turn);
        final cp = acts.where((a) => a['type'] == 'choosePhase').toList();
        if (cp.isNotEmpty) g.applyAction(g.turn, cp[rng.nextInt(cp.length)]);
        continue;
      }
      final acts = g.getLegalActions(g.turn);
      final playable = acts.where((a) => a['type'] != 'endTurn' && a['type'] != 'choosePhase').toList();
      // 每 15 步左右主动过回合一次（触发滚木）
      if (step % 15 == 14 || playable.isEmpty) {
        final before = g.cells.length;
        g.endTurn(g.turn);
        final rs = g.rollSteps ?? [];
        var delta = 0;
        for (final r in rs) {
          if (r['bridge'] == true) delta += 1;
          if (r['dead'] == true && r['bridgeCollapse'] == true) delta -= 1;
        }
        final after = g.cells.length;
        rounds++;
        if (after - before != delta) {
          print('❌ 滚木不一致: 实际delta=${after - before} 预期$delta');
          print('  rollSteps=$rs');
          print('  棋盘=${boardStr(g)}');
          bad++;
          break;
        }
        continue;
      }
      g.points = 5; g.produceLeft = 5;
      g.applyAction(g.turn, playable[rng.nextInt(playable.length)]);
    }
  }
  print('滚木 $rounds 轮，$bad 处不一致');
  print(bad == 0 ? '✅ 滚木阶段无长度 bug' : '❌ 滚木阶段长度有 bug');
}
