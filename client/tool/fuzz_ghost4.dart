// 单步长度变化对比：实际 delta vs lastAction 推导的预期 delta（不累积，定位真正的规则层 bug）
import 'dart:math';
import '../lib/game/rules.dart';

String boardStr(AimGame g) =>
    g.cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : '${c.v}${c.o == 0 ? 'a' : 'b'}')).join(' ');

int expectDelta(Map<String, dynamic>? la) {
  if (la == null) return 0;
  switch (la['type']) {
    case 'move': return la['bridgeCollapse'] != null ? -1 : 0;
    case 'attack': return la['insertedAt'] != null ? 1 : 0;
    case 'split': return la['full'] == true ? 0 : 1;
    case 'devour': return la['spliced'] == true ? -1 : 0;
    default: return 0;
  }
}

void main() {
  final rng = Random(777);
  var bad = 0;
  var checked = 0;

  for (var round = 0; round < 300 && bad < 5; round++) {
    final g = AimGame(limit: 16);
    for (var step = 0; step < 400; step++) {
      if (g.winner != null) break;
      if (g.phase == null) {
        final acts = g.getLegalActions(g.turn);
        final cp = acts.where((a) => a['type'] == 'choosePhase').toList();
        if (cp.isNotEmpty) g.applyAction(g.turn, cp[rng.nextInt(cp.length)]);
        continue;
      }
      final acts = g.getLegalActions(g.turn);
      final playable = acts.where((a) => a['type'] != 'endTurn' && a['type'] != 'choosePhase').toList();
      if (playable.isEmpty) { g.endTurn(g.turn); continue; }
      final a = playable[rng.nextInt(playable.length)];
      final before = g.cells.length;
      final ok = g.applyAction(g.turn, a);
      if (ok['ok'] != true) continue;
      final after = g.cells.length;
      final la = g.lastAction;
      final d = expectDelta(la);
      checked++;
      if (after - before != d) {
        print('❌ 单步不一致: 行动=${a['type']} 实际delta=${after - before} 预期$d');
        print('  lastAction=$la');
        print('  棋盘=${boardStr(g)}');
        bad++;
        break;
      }
      if (g.points <= 0 && g.phase == 'action') {
        g.endTurn(g.turn);
      }
    }
  }
  print('检查 $checked 步，$bad 处不一致');
  print(bad == 0 ? '✅ 规则层单步长度全部一致' : '❌ 规则层单步长度有 bug');
}
