// 教程引擎回归测试：章节内多个 board 指令只展开一次战场
// 历史 bug：applyPendingBoard() 把 _firstBoard 重置回 true，导致第一章
// 每次 board（新增单位）都触发退场+入场动画（战场反复展开）。
// 修复：_firstBoard 只在 load()（章节加载）时置 true，章节内保持 false。
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/tutorial/tutorial_engine.dart';

void main() {
  test('章节内多个 board：只有第一个触发展开（boardPending），后续直接状态更新', () {
    final engine = TutEngine();
    // 模拟第一章：空战场展开 → 兵营出现 → 敌人出现（3 个 board，中间有台词）
    engine.load([
      {'board': ['0', '0', '0', '0', '0', '0', '0', '0']},
      {'say': '前指挥官', 'text': '喏，这就是战场'},
      {'board': ['8', '0', '0', '0', '0', '0', '0', '0']},
      {'say': '前指挥官', 'text': '看，这就是兵营'},
      {'board': ['8', '1', '0', '0', '0', '0', '1', '9']},
      {'end': true},
    ]);

    // ① 第一个 board：触发展开（boardPending = true），棋盘还是空的
    expect(engine.boardPending, isTrue, reason: '章节首个 board 应触发展开动画');
    expect(engine.cells, isEmpty, reason: '展开动画期间棋盘尚未应用');

    // ② UI 播完退场 → applyPendingBoard → 第一个棋盘应用，继续推进
    engine.applyPendingBoard();
    expect(engine.boardPending, isFalse);
    expect(engine.cells.length, 8);
    expect(engine.cells.every((c) => c.v == 0), isTrue);

    // ③ 台词推进后到第二个 board（兵营出现）：必须直接状态更新，不再展开！
    engine.advance(); // 跳过 say → 到第二个 board
    expect(engine.boardPending, isFalse, reason: '章节内 board 不应触发展开动画');
    expect(engine.cells[0].v, 8, reason: '兵营应直接出现在棋盘上');

    // ④ 台词推进后到第三个 board（敌人+指挥部出现）：同样直接更新
    engine.advance();
    expect(engine.boardPending, isFalse, reason: '章节内后续 board 同样不应展开');
    expect(engine.cells[0].v, 8);
    expect(engine.cells[6].v, 1);
    expect(engine.cells[7].v, 9);
  });

  test('新章节 load() 重置 _firstBoard：每章第一个 board 仍会展开', () {
    final engine = TutEngine();
    engine.load([
      {'board': ['8', '0', '0', '0', '0', '0', '0', '0']},
      {'end': true},
    ]);
    expect(engine.boardPending, isTrue, reason: '章节首个 board 触发展开');
    engine.applyPendingBoard();
    expect(engine.boardPending, isFalse);

    // 下一章重新 load：第一个 board 又触发展开
    engine.load([
      {'board': ['7', '1', '0', '0', '0', '0', '0', '{1}']},
      {'end': true},
    ]);
    expect(engine.boardPending, isTrue, reason: '新章节首个 board 应重新触发展开');
  });

  test('lastAction 携带操作前棋盘快照 prevCells（动画基底=旧棋盘，与对战一致）', () {
    final engine = TutEngine();
    // 溢出攻击：5 攻 {1}（格2），伤害溢出 → 桥插格2、目标变4被顶到格3
    engine.load([
      {'board': ['0', '5', '{1}', '0', '0', '0', '0', '0']},
      {'end': true},
    ]);
    engine.applyPendingBoard();

    engine.runAuto({'auto': 'attack', 'i': 1, 'j': 2, 'owner': 0});
    final la = engine.lastAction;
    expect(la, isNotNull);
    expect(la!['type'], 'attack');
    expect(la['insertedAt'], 2, reason: '溢出应插桥');
    final prev = la['prevCells'];
    expect(prev, isA<List<TutCell>>(), reason: '必须带操作前棋盘快照');
    final prevCells = (prev as List).cast<TutCell>();
    expect(prevCells.length, 8);
    expect(prevCells[2].v, 1, reason: '快照中目标格还是操作前的 1');
    expect(prevCells[2].o, 1);
    // 引擎棋盘已是操作后（桥在格2、目标变4在格3）
    expect(engine.cells[2].isB, isTrue);
    expect(engine.cells[3].v, 4);
    // 快照里没有桥（操作前）——UI 用快照做基底就不会重复插桥
    expect(prevCells.any((c) => c.isB), isFalse);
  });

  test('吞噬 lastAction 快照：目标格在快照中仍存在，引擎棋盘已删格', () {
    final engine = TutEngine();
    engine.load([
      {'board': ['0', '4', '2', '0', '0', '0', '0', '0']},
      {'end': true},
    ]);
    engine.applyPendingBoard();

    engine.runAuto({'auto': 'devour', 'i': 1, 'j': 2, 'owner': 0});
    final la = engine.lastAction!;
    expect(la['type'], 'devour');
    final prev = (la['prevCells'] as List).cast<TutCell>();
    expect(prev.length, 8, reason: '快照是操作前 8 格');
    expect(prev[2].v, 2, reason: '快照中目标格还存在（旧值 2）');
    expect(engine.cells.length, 7, reason: '引擎已删格');
    // UI 用快照做基底：两格转变（4→6、2→0）→ 420ms 后 removeAt(2) 删目标格 → 补位
  });

  test('skipTo(practice)：跳到第一个实操步骤，棋盘快进到最近 board，剧情对话被跳过', () {
    final engine = TutEngine();
    engine.load([
      {'board': ['0', '0', '0', '0', '0', '0', '0', '0']},
      {'say': '前指挥官', 'text': '嗯？来了？坐…'},
      {'board': ['8', '0', '0', '0', '0', '0', '0', '0']},
      {'say': '前指挥官', 'text': '看，这就是兵营'},
      {'wait': 'select', 'cell': 0, 'highlight': [0]},
      {'say': '前指挥官', 'text': '简单吧？'},
      {'popup': '造兵', 'lines': ['◆ 基地 8：每回合造兵一次']},
      {'end': true},
    ]);
    // 模拟 UI：首屏展开动画完成后棋盘已应用（当前停在第一句台词）
    engine.applyPendingBoard();
    expect(engine.currentSpeaker, '前指挥官');

    engine.skipTo('practice');

    expect(engine.waiting, isTrue, reason: '应直接进入实操等待');
    expect(engine.waitType, 'select');
    expect(engine.waitCell, 0);
    expect(engine.currentText, isNull, reason: '剧情台词应被跳过');
    expect(engine.cells[0].v, 8, reason: '棋盘应快进到实操前最近一次 board');
    expect(engine.cells[0].o, 0);
    expect(engine.boardPending, isFalse);
    expect(engine.demoQueue, isEmpty);
  });

  test('skipTo(summary)：跳到章末总结 popup，等待状态被清理', () {
    final engine = TutEngine();
    engine.load([
      {'board': ['8', '1', '0', '0', '0', '0', '1', '9']},
      {'say': '前指挥官', 'text': '看，那就是敌人'},
      {'wait': 'tap', 'cell': 0, 'action': 'produce', 'highlight': [0]},
      {'say': '前指挥官', 'text': '好了，我就教到这里了'},
      {'popup': '造兵', 'lines': ['◆ 基地 8', '◆ 指挥部 9']},
      {'end': true},
    ]);
    engine.applyPendingBoard();
    // 先推进到实操等待（模拟玩家进行到一半）
    engine.advance();
    engine.advance(); // 到 wait tap
    expect(engine.waiting, isTrue);

    engine.skipTo('summary');

    expect(engine.popupOpen, isTrue, reason: '应直接显示章末规则总结');
    expect(engine.popupTitle, '造兵');
    expect(engine.popupLines, isNotEmpty);
    expect(engine.waiting, isFalse, reason: '等待状态应被清理');
    expect(engine.cells[0].v, 8, reason: '棋盘快进到 popup 前最近一次 board');
    expect(engine.cells[7].v, 9);
  });

  test('skipTo 找不到目标（无实操/无总结）：状态不变不跳转', () {
    final engine = TutEngine();
    engine.load([
      {'board': ['0', '0', '0', '0', '0', '0', '0', '0']},
      {'say': '前指挥官', 'text': '只有剧情'},
      {'end': true},
    ]);
    engine.applyPendingBoard();
    final before = engine.stepIdx;

    engine.skipTo('practice');
    expect(engine.stepIdx, before, reason: '没有 wait/auto 就不跳');
    engine.skipTo('summary');
    expect(engine.stepIdx, before, reason: '没有 popup 就不跳');
  });

  test('滚木逐子步剧本：压到即记录结果（桥+新值+被顶），不是滚完统一处理', () {
    final engine = TutEngine();
    engine.load([
      {'board': ['6', '0', '2', '0', '0', '0', '0', '7']},
      {'end': true},
    ]);
    engine.applyPendingBoard();

    // 第 1 步：滚到空地（格1）
    engine.rollStep(0, 1);
    expect(engine.lastRollSteps, [{'crush': false}], reason: '空地：无碾压');
    expect(engine.cells[1].v, 6, reason: '滚木应前进到格1');

    // 第 2 步：压到 2 号 → 溢出插桥 + 被顶
    engine.rollStep(0, 2);
    expect(engine.lastRollSteps.length, 2, reason: '压+被顶 = 2 个子步');
    expect(engine.lastRollSteps[0]['crush'], true);
    expect(engine.lastRollSteps[0]['bridge'], true, reason: '溢出应插桥');
    expect(engine.lastRollSteps[0]['newV'], 4, reason: '2 受 6 伤 → 4');
    expect(engine.lastRollSteps[0]['oldV'], 2);
    expect(engine.lastRollSteps[1]['bump'], true, reason: '被顶也是一子步');
    expect(engine.cells[2].isB, isTrue, reason: '被压位置应插入桥');
    // 对齐游戏绑定模型：滚木站到桥右（格3）压着变值单位（棋盘显示滚木 6，4 号藏脚下）
    expect(engine.cells[3].v, 6, reason: '格3 是滚木（压着4号）');
    expect(engine.cells[3].pressedV, 4, reason: '4 号被滚木压着');
    expect(engine.cells[3].pressedO, 0);

    // 第 3 步：滚木走开露出 4 号，继续滚
    engine.rollStep(0, 3);
    expect(engine.lastRollSteps, [{'crush': false}]);
    expect(engine.cells[3].v, 4, reason: '滚木走开，4 号露出');
    expect(engine.cells[4].v, 6, reason: '滚木前进到格4');
  });
}
