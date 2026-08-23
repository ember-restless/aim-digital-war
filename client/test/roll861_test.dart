import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/net/local_socket.dart';
import 'package:aim/screens/game_screen.dart';

void main() {
  testWidgets('86111008 动画层逐步打印', (tester) async {
    final sock = LocalAimSocket(limit: 16);
    sock.game.cells = [
      AimCell(8, o: 0), AimCell(6, o: 0, auto: true), AimCell(1, o: 0, auto: true),
      AimCell(1, o: 0, auto: true), AimCell(1, o: 0, auto: true),
      AimCell(0, o: null), AimCell(0, o: null), AimCell(8, o: 1),
    ];
    sock.game.turn = 1; sock.game.phase = null; sock.game.points = 0; sock.game.produceLeft = 0;
    Map<String, dynamic> init = sock.game.viewFor(1);
    late Map<String, dynamic> current;
    sock.onEvent = (e, d) { if (e == 'game_state') current = (d as Map).cast<String, dynamic>(); };
    Future<void> pumpState(Map<String, dynamic> s) async {
      await tester.pumpWidget(MaterialApp(home: MediaQuery(
        data: const MediaQueryData(size: Size(640, 360), padding: EdgeInsets.zero),
        child: GameScreen(socket: sock, state: s, over: null, packId: 'default', onBack: () {}),
      )));
    }
    await pumpState(init);
    await tester.pump(const Duration(milliseconds: 1000));
    sock.emit('action', {'type': 'endTurn'});
    await tester.pump(const Duration(milliseconds: 50));
    await pumpState(current);
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
    final cells = (current['cells'] as List).map((c) => c as Map).toList();
    String line() => cells.map((c) {
          if (c['bridge'] == true) return '-';
          final v = (c['v'] as num?)?.toInt() ?? 0;
          final o = (c['o'] as num?)?.toInt();
          return o == null ? '0' : (o == 0 ? '[${v}]' : '{${v}}');
        }).join(' ');
    expect(line(), '[8] 0 - [5] - [5] [6] 0 0 {8}');
    expect(tester.takeException(), isNull);
    // 清残留 timer（660ms 停顿 + 400ms 掉桥等）
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  });
}
