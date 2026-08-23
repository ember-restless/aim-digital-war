// 教程修复回归测试（2026-08-21 牢大反馈）：
// 1. 第一章 board 敌方单位花括号归属（漏花括号 → 敌方被当己方 → 移动动画清掉己方同数字兵）
// 2. 第四章 {2} 全程不瞬移（攻击后保持格4，Quintus 登场 3/{2} 都不动）
// 3. 第七章滚木溢出插桥：引擎 8→9 格、4 号被顶到桥右侧
// 4. 对话说话人显示『前指挥官』而非『前指挥官号』
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aim/screens/tutorial_screen.dart';
import 'package:aim/tutorial/tutorial_engine.dart';
import 'package:aim/tutorial/tutorial_script.dart';

void main() {
  test('第一章 board：敌方单位用花括号，o=1（不是己方）', () {
    final ch = tutorialChapters[0];
    final boardStep = (ch['steps'] as List).cast<Map<String, dynamic>>().firstWhere(
        (s) => s['board'] != null && ((s['board'] as List).length == 8) &&
            (s['board'] as List)[6] == '{1}');
    final spec = (boardStep['board'] as List).cast<String>();
    expect(spec[6], '{1}', reason: '格6 敌方小兵必须写 {1}');
    expect(spec[7], '{9}', reason: '格7 敌方指挥部必须写 {9}');

    final cells = spec.map(TutCell.fromSpec).toList();
    expect(cells[6].o, 1);
    expect(cells[7].o, 1);
    expect(cells[1].o, 0, reason: '格1 是我方小兵');
  });

  test('第一章移动演示：敌方 {1} 左移后棋盘正确（格1 己方1 保留）', () {
    final e = TutEngine();
    e.load([
      {'board': ['8', '1', '0', '0', '0', '0', '{1}', '{9}']},
      {'end': true},
    ]);
    while (e.boardPending) {
      e.applyPendingBoard();
    }
    expect(e.cells[1].v, 1);
    expect(e.cells[1].o, 0);
    e.doMove(6, 1, owner: 1); // 敌方 {1} 左移
    expect(e.cells[5].o, 1, reason: '{1} 移到格5');
    expect(e.cells[1].o, 0, reason: '己方1 不受影响');
    e.doMove(5, 1, owner: 1);
    expect(e.cells[4].o, 1);
    expect(e.cells[1].v, 1, reason: '己方1 始终保留');
  });

  test('第四章：{2} 走近 3 面前一格，移动前不瞬移', () {
    final ch = tutorialChapters[3];
    final steps = (ch['steps'] as List).cast<Map<String, dynamic>>();
    // 1) 有 {2} 走近的移动演示（i=4 steps=1 owner=1：从格4 走到格3 = 3 面前一格）
    final moveStep = steps.firstWhere((s) => s['auto'] == 'move' && s['i'] == 4);
    expect(moveStep['steps'], 1);
    expect(moveStep['owner'], 1);
    // 2) 8 格 board 里 {2} 只能待在格4（攻击后位置），不得先瞬移到格6（牢大：移动前突然换位置）
    for (final s in steps) {
      if (s['board'] != null && (s['board'] as List).length == 8) {
        final spec = (s['board'] as List).cast<String>();
        if (spec.contains('{2}')) {
          expect(spec.indexOf('{2}'), 4, reason: '8 格 board 里 {2} 只能在格4');
        }
      }
    }
    // 3) 引擎流程：attack 后 {2} 格4 → doMove(4,1,owner:1) 后 {2} 格3（3 面前）
    final e = TutEngine();
    e.load([
      {'board': ['0', '3', '0', '0', '{3}', '0', '0', '0']},
      {'end': true},
    ]);
    while (e.boardPending) {
      e.applyPendingBoard();
    }
    e.doMove(1, 1, owner: 0);
    e.doAttack(2, 4);
    expect(e.cells[4].v, 2, reason: '攻击后 {2} 在格4');
    expect(e.cells[4].o, 1);
    e.doMove(4, 1, owner: 1);
    expect(e.cells[3].v, 2, reason: '{2} 走近到格3（3 面前一格）');
    expect(e.cells[3].o, 1);
    // 4) Quintus 登场 board：3 格2、5 格3、{2} 格4
    final quintus = steps.firstWhere((s) =>
        s['board'] != null && (s['board'] as List).contains('5'));
    final qspec = (quintus['board'] as List).cast<String>();
    expect(qspec[2], '3');
    expect(qspec[3], '5');
    expect(qspec[4], '{2}', reason: '{2} 到 5 面前');
  });

  test('第七章滚木：溢出插桥 8→9 格，2号受6伤变4被顶到桥右侧', () {
    final e = TutEngine();
    e.load([
      {'board': ['6', '0', '2', '0', '0', '0', '0', '7']},
      {'end': true},
    ]);
    while (e.boardPending) {
      e.applyPendingBoard();
    }
    e.rollStep(0, 1);
    expect(e.cells.length, 8);
    e.rollStep(0, 2);
    expect(e.cells.length, 9, reason: '溢出插桥地图 +1');
    expect(e.cells[2].isB, isTrue, reason: '桥在格2');
    // 对齐游戏绑定模型：滚木站到桥右压着变值单位（棋盘显示滚木，4 号藏脚下）
    expect(e.cells[3].v, 6, reason: '格3 是滚木（压着4号）');
    expect(e.cells[3].pressedV, 4, reason: '2号受6伤变4被滚木压着');
    e.rollStep(0, 3);
    expect(e.cells.length, 9);
    expect(e.cells[3].v, 4, reason: '滚木走开，4 号露出');
    expect(e.cells[4].v, 6, reason: '滚木越过桥继续滚');
  });

  testWidgets('第一章对话：说话人显示『前指挥官』（无"号"后缀）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TutorialScreen(onExit: () {}, startChapter: 0),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    // 第一章第一句就是前指挥官台词
    await tester.pump(const Duration(milliseconds: 500));
    // 打字中：『前指挥官』应显示，『前指挥官号』不应出现
    expect(find.textContaining('前指挥官号'), findsNothing, reason: '不能有"号"后缀');
    expect(find.textContaining('前指挥官'), findsWidgets, reason: '说话人名字显示');
    expect(tester.takeException(), isNull);
  });
}
