// 移动动画播放验证：检查移动浮层是否出现（逐格平移）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aim/screens/game_screen.dart';
import 'package:aim/net/socket.dart';

Map<String, dynamic> mkState(List cells, {int mySum = 0}) => {
  'cells': cells,
  'turn': 0,
  'yourIdx': 0,
  'phase': 'action',
  'points': 2,
  'produceLeft': 0,
  'mapLen': cells.length,
  'limit': 30,
  'names': ['我', '敌'],
  'mySum': mySum,
  'enemySum': 0,
  'myBases': 1,
  'myHqs': 1,
  'winner': null,
  'log': [''],
  'hotseat': false,
  'spectator': false,
  'legalActions': const [],
};

void main() {
  testWidgets('移动动画：浮层单位出现并逐格移动', (tester) async {
    final sock = AIMSocket('http://x');
    final s0 = mkState([
      {'v': 1, 'o': 0, 'id': 10},
      {'v': 0, 'o': null, 'id': 11},
      {'v': 0, 'o': null, 'id': 12},
    ], mySum: 1);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s0, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 入场

    final s1 = mkState([
      {'v': 0, 'o': null, 'id': 11},
      {'v': 1, 'o': 0, 'id': 10},
      {'v': 0, 'o': null, 'id': 12},
    ], mySum: 1)
      ..['lastAction'] = {'type': 'move', 'i': 0, 'steps': 1, 'bridgeCollapse': null, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 100)); // 动画中
    // 移动浮层 = Positioned 里的单位图
    final floaters = tester.widgetList(
      find.descendant(of: find.byType(Positioned), matching: find.byType(Image)),
    ).length;
    debugPrint('=== 移动动画中浮层 Image 数量: $floaters ===');
    expect(floaters, greaterThan(0), reason: '移动动画中应有浮层单位（逐格平移）');
    // 动画棋盘：单位还在旧位置（格0 有 1）
    await tester.pump(const Duration(milliseconds: 400)); // 动画结束
    expect(tester.takeException(), isNull, reason: '移动动画渲染异常');
  });

  testWidgets('骑兵2格：连续两次平移', (tester) async {
    final sock = AIMSocket('http://x');
    final s0 = mkState([
      {'v': 2, 'o': 0, 'id': 20},
      {'v': 0, 'o': null, 'id': 21},
      {'v': 0, 'o': null, 'id': 22},
    ], mySum: 2);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s0, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000));
    final s1 = mkState([
      {'v': 0, 'o': null, 'id': 21},
      {'v': 0, 'o': null, 'id': 22},
      {'v': 2, 'o': 0, 'id': 20},
    ], mySum: 2)
      ..['lastAction'] = {'type': 'move', 'i': 0, 'steps': 2, 'bridgeCollapse': null, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 第一步动画中
    final floaters = tester.widgetList(
      find.descendant(of: find.byType(Positioned), matching: find.byType(Image)),
    ).length;
    debugPrint('=== 骑兵第一步浮层 Image 数量: $floaters ===');
    expect(floaters, greaterThan(0), reason: '骑兵第一步应有浮层');
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '骑兵移动渲染异常');
  });
}
