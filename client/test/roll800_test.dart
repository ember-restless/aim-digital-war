// 80000568 场景三层对齐验证（牢大 2026-08-16 要求：推理一遍 → 动画层跑一遍 → 规则层跑一遍）
// 场景：[8] 0 0 0 0 [5] {6} {8} —— 格6 的 6 是玩家1 滚木，往左滚（右→左）
// 规则层（牢大语义）：步1 滚木压5 → 溢出插桥 → 滚木被顶到桥右（脚下压1，棋盘只显示6）
//   = `80000-608`；步2 滚木往左撞桥 → 桥塌人亡（滚木掉下去，1 保留）= `80000108`
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/net/local_socket.dart';
import 'package:aim/screens/game_screen.dart';

void main() {
  testWidgets('动画层 80000568：逐步驱动 + 动画棋盘实时打印（AIMDBG）', (tester) async {
    final sock = LocalAimSocket(limit: 16);
    sock.game.cells = [
      AimCell(8, o: 0),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(5, o: 0, auto: true),
      AimCell(6, o: 1, auto: true),
      AimCell(8, o: 1),
    ];
    sock.game.turn = 0;
    sock.game.phase = null;
    sock.game.points = 0;
    sock.game.produceLeft = 0;

    // 手动推初始 state
    Map<String, dynamic> init = sock.game.viewFor(0);
    late Map<String, dynamic> current;
    sock.onEvent = (e, d) {
      if (e == 'game_state') current = (d as Map).cast<String, dynamic>();
    };

    Future<void> pumpState(Map<String, dynamic> s) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(640, 360), padding: EdgeInsets.zero),
            child: GameScreen(
              socket: sock,
              state: s,
              over: null,
              packId: 'default',
              onBack: () {},
            ),
          ),
        ),
      );
    }

    await pumpState(init);
    await tester.pump(const Duration(milliseconds: 1000)); // 入场动画

    // 玩家0 endTurn → 玩家1 回合，滚木待滚
    sock.emit('action', {'type': 'endTurn'});
    await tester.pump(const Duration(milliseconds: 50));
    expect(current['rollPending'], isTrue);
    await pumpState(current); // 喂给 GameScreen
    await tester.pump(const Duration(milliseconds: 50));

    // 逐步驱动：每步喂 state + 多帧推进动画（子步移动 260ms + 停顿 660ms，需多次 pump 驱动帧/timer）
    // 真实 App：onDone 自动 emit roll_step → 调用方监听 game_state 喂 GameScreen。
    // 测试模拟调用方：多帧 pump，current 变化就喂（不手动 emit，防双发跳步）
    var guard = 0;
    Map<String, dynamic>? pumped;
    while (current['rollPending'] == true && guard++ < 30) {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        if (current != pumped) {
          await pumpState(current);
          pumped = current;
        }
      }
    }
    // 最终棋盘
    final cells = (current['cells'] as List).map((c) => c as Map).toList();
    String line() => cells.map((c) {
          if (c['bridge'] == true) return '-';
          final v = (c['v'] as num?)?.toInt() ?? 0;
          final o = (c['o'] as num?)?.toInt();
          return o == null ? '0' : (o == 0 ? '[${v}]' : '{${v}}');
        }).join(' ');
    expect(line(), '[8] 0 0 0 0 [1] 0 {8}');
    expect(tester.takeException(), isNull);
    // 清残留 timer（660ms 停顿 + 400ms 掉桥等）
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  });
}
