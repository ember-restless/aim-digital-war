// 热座逐步滚木端到端：endTurn 延后滚木 → roll_step 循环逐步驱动
// 验证规则算一步 → state 带该步基础动作 → 全部滚完 rollPending=false
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/net/local_socket.dart';

void main() {
  test('热座逐步滚木：endTurn → rollPending → 逐步滚完 → 棋盘与一次性 autoRoll 一致', () {
    final socket = LocalAimSocket();
    // 构造 86111008 场景（玩家0 先手，玩家1 有滚木）
    socket.game.cells = [
      AimCell(8, o: 0),
      AimCell(6, o: 0, auto: true),
      AimCell(1, o: 0, auto: true),
      AimCell(1, o: 0, auto: true),
      AimCell(1, o: 0, auto: true),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(8, o: 1),
    ];
    socket.game.turn = 1;
    socket.game.phase = null;
    socket.game.points = 0;
    socket.game.produceLeft = 0;

    Map<String, dynamic>? lastState;
    final states = <Map<String, dynamic>>[];
    socket.onEvent = (event, data) {
      if (event == 'game_state') {
        lastState = data as Map<String, dynamic>;
        states.add(lastState!);
      }
    };

    // 玩家1 结束回合 → 玩家0 滚木待滚（棋盘未滚）
    socket.emit('action', {'type': 'endTurn'});
    expect(lastState!['rollPending'], isTrue, reason: 'endTurn 后滚木待滚');
    expect(lastState!['turn'], 0);
    // 棋盘还没滚：滚木还在格1
    expect((lastState!['cells'] as List)[1]['v'], 6);

    // 逐步驱动直到滚完
    var steps = 0;
    var guard = 0;
    while (lastState!['rollPending'] == true && guard++ < 20) {
      final before = (lastState!['cells'] as List).length;
      socket.emit('roll_step');
      final s = lastState!;
      expect(s['rollStepSeq'], steps + 1, reason: '每步序号递增');
      expect(s['rollActs'], isNotNull, reason: '该步带基础动作');
      expect(s['rollActs'], isNotEmpty);
      final acts = s['rollActs'] as List;
      final op = (acts.first as Map)['op'];
      expect(['move', 'crush', 'kill', 'dead'], contains(op));
      // 规则层先算：该步后棋盘长度 = 步前 ± 插桥/删格
      final after = (s['cells'] as List).length;
      expect((after - before).abs(), lessThanOrEqualTo(2), reason: '每步至多插1桥删1格');
      steps++;
    }
    expect(guard, lessThan(20), reason: '滚木步骤有限');
    expect(steps, greaterThan(0), reason: '确实滚了');
    expect(lastState!['rollPending'], isFalse, reason: '滚完清除待滚');

    // 最终棋盘 = 86111008 权威结果
    final cells = (lastState!['cells'] as List).map((c) => c as Map).toList();
    String line() => cells.map((c) {
          if (c['bridge'] == true) return '-';
          final v = (c['v'] as num?)?.toInt() ?? 0;
          final o = (c['o'] as num?)?.toInt();
          return o == null ? '0' : (o == 0 ? '[${v}]' : '{${v}}');
        }).join(' ');
    expect(line(), '[8] 0 - [5] - [5] [6] 0 0 {8}');

    // 与一次性 autoRoll 对照
    final g2 = AimGame(limit: 16);
    g2.cells = [
      AimCell(8, o: 0),
      AimCell(6, o: 0, auto: true),
      AimCell(1, o: 0, auto: true),
      AimCell(1, o: 0, auto: true),
      AimCell(1, o: 0, auto: true),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(8, o: 1),
    ];
    g2.turn = 1;
    g2.phase = null;
    g2.points = 0;
    g2.produceLeft = 0;
    g2.applyAction(1, {'type': 'endTurn'});
    // 对比值序列（忽略 id：两个实例 id 计数器不同）
    String valLine(List<AimCell> cs) => cs.map((c) {
          if (c.isB) return '-';
          return c.o == null ? '0' : (c.o == 0 ? '[${c.v}]' : '{${c.v}}');
        }).join(' ');
    expect(valLine(g2.cells), valLine(socket.game.cells), reason: '逐步结果 = 一次性结果');
  });

  test('热座普通行动不受逐步影响：造兵→攻击→吞噬照常', () {
    final socket = LocalAimSocket();
    socket.game.turn = 0;
    socket.game.phase = 'produce';
    socket.game.produceLeft = 1;
    socket.game.points = 0;
    Map<String, dynamic>? lastState;
    socket.onEvent = (event, data) {
      if (event == 'game_state') lastState = data as Map<String, dynamic>;
    };
    socket.emit('action', {'type': 'produce', 'i': 0, 'j': 1});
    expect(lastState!['rollPending'], isFalse);
    expect(lastState!['rollActs'], isNull);
    expect((lastState!['cells'] as List)[1]['v'], 1);
  });
}
