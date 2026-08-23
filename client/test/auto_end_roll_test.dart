// 复现牢大场景：热座 80000568，玩家0 移动 5（points 1→0）→ maybeAutoEnd 自动过回合
// → 6 滚木（autoRoll 全量）→ 行动动画 + 滚木同帧 → _deferredRoll + _detectRoll 回放路径
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/net/local_socket.dart';
import 'package:aim/screens/game_screen.dart';

String imgStr(WidgetTester tester) {
  final imgs = tester
      .widgetList<Image>(find.byType(Image))
      .map((img) => img.image is AssetImage ? (img.image as AssetImage).assetName.split('/').last.replaceAll('.png', '') : '?')
      .toList();
  return imgs.join(' ');
}

int cellCount(WidgetTester tester) {
  return tester.widgetList(find.byWidgetPredicate((w) =>
      w.key != null && w.key.toString().contains("'cell"))).length;
}

class HotseatHarness extends StatefulWidget {
  final LocalAimSocket socket;
  const HotseatHarness({super.key, required this.socket});
  @override
  State<HotseatHarness> createState() => _HotseatHarnessState();
}

class _HotseatHarnessState extends State<HotseatHarness> {
  Map<String, dynamic>? gameState;
  @override
  void initState() {
    super.initState();
    widget.socket.onEvent = (event, data) {
      if (event == 'game_state') {
        setState(() => gameState = data as Map<String, dynamic>);
      }
    };
  }
  @override
  Widget build(BuildContext context) {
    final st = gameState ?? widget.socket.game.viewFor(0);
    return MaterialApp(
      home: GameScreen(
        socket: widget.socket,
        state: st,
        packId: 'default',
        onBack: () {},
      ),
    );
  }
}

void main() {
  testWidgets('行动+自动过回合+滚木：渲染层追踪', (tester) async {
    final socket = LocalAimSocket();
    socket.game.cells = [
      AimCell(8, o: 0),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(5, o: 0),
      AimCell(6, o: 1),
      AimCell(8, o: 1),
    ];
    socket.game.turn = 0;
    socket.game.phase = 'action';
    socket.game.points = 1; // 玩家0 只有1行动点
    socket.game.produceLeft = 0;

    await tester.pumpWidget(HotseatHarness(socket: socket));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    print('=== 玩家0 移动 5（5→4）→ 自动过回合 → 6 滚 ===');
    socket.emit('action', {'type': 'move', 'i': 5, 'steps': 1});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    var lastPrint = '';
    for (var t = 0; t < 300; t++) {
      await tester.pump(const Duration(milliseconds: 100));
      final st = socket.game.viewFor(socket.game.turn);
      final ruleLen = (st['cells'] as List).length;
      final rule = (st['cells'] as List)
          .map((c) => c['bridge'] == true ? '-' : (c['o'] == null ? '0' : '${c['v']}'))
          .join('');
      final sig = 't=${(t + 1) * 100}ms 规则[$ruleLen]=$rule | 格数=${cellCount(tester)} | 图=${imgStr(tester)}';
      if (sig != lastPrint) {
        lastPrint = sig;
        print(sig);
      }
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final st = socket.game.viewFor(socket.game.turn);
    print('最终: 规则=${(st['cells'] as List).map((c) => c['bridge'] == true ? '-' : (c['o'] == null ? '0' : '${c['v']}')).join('')}(${(st['cells'] as List).length}格) 渲染格数=${cellCount(tester)} 图=${imgStr(tester)}');
  });
}
