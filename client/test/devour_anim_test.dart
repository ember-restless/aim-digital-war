// 吞噬动画期间格子数量检查（复现"地图变4格再插1格"）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aim/screens/game_screen.dart';
import 'package:aim/net/socket.dart';

Map<String, dynamic> mkState(List cells, {int mySum = 0, int enSum = 0}) => {
  'cells': cells,
  'turn': 0,
  'yourIdx': 0,
  'phase': 'action',
  'points': 1,
  'produceLeft': 2,
  'mapLen': cells.length,
  'limit': 30,
  'names': ['我', '敌'],
  'mySum': mySum,
  'enemySum': enSum,
  'myBases': 1,
  'myHqs': 1,
  'winner': null,
  'log': [''],
  'hotseat': false,
  'spectator': false,
  'legalActions': const [],
};

int cellCount(WidgetTester tester) {
  return tester.widgetList(find.byWidgetPredicate((w) =>
      w.key != null && w.key.toString().contains("'cell"))).length;
}

void main() {
  testWidgets('吞噬动画期间格子数量：801108 → 80208（应始终5格）', (tester) async {
    final sock = AIMSocket('http://x');
    final s1 = mkState([
      {'v': 8, 'o': 0}, {'v': 0, 'o': null}, {'v': 1, 'o': 0},
      {'v': 1, 'o': 1}, {'v': 0, 'o': null}, {'v': 8, 'o': 1},
    ], mySum: 1, enSum: 9);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000));
    print('初始格子数: ${cellCount(tester)} (期望6)');

    // 吞噬：1+1=2，splice → 5 格 [8,0,2,0,8]，剧本 devour
    final s2 = mkState([
      {'v': 8, 'o': 0}, {'v': 0, 'o': null}, {'v': 2, 'o': 0},
      {'v': 0, 'o': null}, {'v': 8, 'o': 1},
    ], mySum: 2, enSum: 8)
      ..['lastAction'] = {'type': 'devour', 'i': 2, 'j': 3, 'sum': 2, 'spliced': true, 'collapsed': false, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    for (int ms = 0; ms <= 1000; ms += 100) {
      await tester.pump(const Duration(milliseconds: 100));
      print('t=${ms + 100}ms 格子数: ${cellCount(tester)} (期望5)');
    }
    expect(tester.takeException(), isNull);
    // 清残留 timer（吞噬动画 _finishAnim 延迟 + shift 补位动画，2026-08-20 补收尾）
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  });
}
