// 像素画布下 GameScreen 布局/点击回归测试
// 验证：①360 高画布不溢出 ②操作按钮可点击触发 action
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aim/screens/game_screen.dart';
import 'package:aim/net/socket.dart';

class RecordSocket extends AIMSocket {
  final List<List<dynamic>> emits = [];
  RecordSocket() : super('http://x');
  @override
  void emit(String event, [dynamic data]) {
    emits.add([event, data]);
  }
}

Map<String, dynamic> mkState() {
  final cells = <Map<String, dynamic>>[];
  for (int i = 0; i < 8; i++) {
    cells.add({'v': 0, 'o': null, 'id': 100 + i});
  }
  cells[0] = {'v': 8, 'o': 0, 'id': 1};
  cells[1] = {'v': 1, 'o': 0, 'id': 2}; // 我方 1 号（可移动）
  cells[7] = {'v': 8, 'o': 1, 'id': 3};
  return {
    'cells': cells,
    'turn': 0,
    'yourIdx': 0,
    'phase': 'action',
    'points': 2,
    'produceLeft': 1,
    'mapLen': 8,
    'limit': 16,
    'names': ['我', '敌'],
    'mySum': 9,
    'enemySum': 8,
    'myBases': 1,
    'myHqs': 0,
    'winner': null,
    'log': ['回合 1'],
    'hotseat': false,
    'spectator': false,
    'legalActions': [
      {'type': 'move', 'i': 1, 'steps': 1},
      {'type': 'move', 'i': 0, 'steps': 1},
    ],
  };
}

void main() {
  testWidgets('像素画布 640x360 下 GameScreen 不溢出', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(640, 360), padding: EdgeInsets.zero),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: 640,
              height: 360,
              child: MaterialApp(
                home: GameScreen(socket: RecordSocket(), state: mkState(), packId: 'default', onBack: () {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1100)); // 等入场动画
    expect(tester.takeException(), isNull, reason: '画布内 GameScreen 不应布局溢出');
  });

  testWidgets('画布内选中单位后移动按钮可点击并 emit action', (tester) async {
    final sock = RecordSocket();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(640, 360), padding: EdgeInsets.zero),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: 640,
              height: 360,
              child: MaterialApp(
                home: GameScreen(socket: sock, state: mkState(), packId: 'default', onBack: () {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1100)); // 等入场动画解锁

    // 选中格1 的我方 1 号
    final cell1 = find.byKey(const ValueKey('cell2')); // id=2 的格子
    expect(cell1.evaluate().length, greaterThan(0), reason: '格子应存在');
    await tester.tap(cell1.first);
    await tester.pump();

    // 移动按钮应出现
    final moveBtn = find.text('移动');
    expect(moveBtn.evaluate().length, greaterThan(0), reason: '选中可移动单位后应有移动按钮');
    await tester.tap(moveBtn.first);
    await tester.pump();

    // 应 emit 了 move action
    expect(sock.emits.any((e) => e[0] == 'action' && (e[1] as Map)['type'] == 'move'), isTrue,
        reason: '点移动按钮应 emit action move');
  });
}
