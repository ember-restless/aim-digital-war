// 吞噬白屏排查 v2：模拟更接近真实对局的 state（基地/指挥部/legalActions/连续更新）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aim/screens/game_screen.dart';
import 'package:aim/net/socket.dart';
import 'package:aim/net/local_socket.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/widgets/hit_fx.dart';

Map<String, dynamic> mkState(List cells, {int mySum = 0, int enSum = 0, List la = const []}) => {
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
  'log': ['吞噬：2+4=6', '回合 3'],
  'hotseat': false,
  'spectator': false,
  'legalActions': la,
};

// 典型开局棋盘：基地8+指挥部9 两端
List<Map<String, dynamic>> fullBoard({int len = 8}) {
  final cells = <Map<String, dynamic>>[];
  for (int i = 0; i < len; i++) {
    cells.add({'v': 0, 'o': null});
  }
  cells[0] = {'v': 8, 'o': 0}; // 我基地
  cells[1] = {'v': 9, 'o': 0}; // 我指挥部
  cells[len - 2] = {'v': 9, 'o': 1};
  cells[len - 1] = {'v': 8, 'o': 1};
  return cells;
}

void main() {
  testWidgets('吞噬：真实棋盘 4吞2→6', (tester) async {
    final sock = AIMSocket('http://x');
    final b = fullBoard();
    b[3] = {'v': 4, 'o': 0};
    b[4] = {'v': 2, 'o': 1};
    final s1 = mkState(b, mySum: 4, enSum: 2);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 等入场动画完成（_animLock 解锁）

    final b2 = fullBoard(len: 7); // 吞噬 splice 后 7 格
    b2[3] = {'v': 6, 'o': 0};
    final s2 = mkState(b2, mySum: 6, enSum: 0)
      ..['lastAction'] = {'type': 'devour', 'i': 3, 'j': 4, 'sum': 6, 'spliced': true, 'collapsed': false, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    // 动画播放中检查：两个格子同时转变（4→6、2→0）
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(HitFx), findsNWidgets(2), reason: '吞噬应有两个转变动画（4→6 和 2→0）');
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '吞噬后渲染异常（白屏根因）');
  });

  testWidgets('吞噬后立刻收到下一 state（动画未结束）', (tester) async {
    final sock = AIMSocket('http://x');
    final b = fullBoard();
    b[3] = {'v': 4, 'o': 0};
    b[4] = {'v': 2, 'o': 1};
    final s1 = mkState(b, mySum: 4, enSum: 2);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 等入场动画完成（_animLock 解锁）

    final b2 = fullBoard(len: 7); // 吞噬 splice 后 7 格
    b2[3] = {'v': 6, 'o': 0};
    final s2 = mkState(b2, mySum: 6, enSum: 0);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 50)); // 动画中
    // 立刻再推一个 state（造兵/移动等）
    final b3 = fullBoard();
    b3[3] = {'v': 6, 'o': 0};
    b3[2] = {'v': 1, 'o': 0};
    final s3 = mkState(b3, mySum: 7, enSum: 0);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s3, packId: 'default', onBack: () {}),
    ));
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '动画中连续 state 更新异常');
  });

  testWidgets('吞噬导致胜利（敌方归零）', (tester) async {
    final sock = AIMSocket('http://x');
    final b = fullBoard();
    b[3] = {'v': 4, 'o': 0};
    b[4] = {'v': 2, 'o': 1};
    final s1 = mkState(b, mySum: 4, enSum: 2);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 等入场动画完成（_animLock 解锁）

    final b2 = fullBoard();
    b2[3] = {'v': 6, 'o': 0};
    b2[4] = {'v': 0, 'o': null};
    final s2 = mkState(b2, mySum: 6, enSum: 0, la: const []);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}, over: {'winner': 0}),
    ));
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '吞噬胜利后渲染异常');
  });

  testWidgets('吞噬超9变拉（10→1+0）', (tester) async {
    final sock = AIMSocket('http://x');
    final b = fullBoard();
    b[3] = {'v': 8, 'o': 0};
    b[4] = {'v': 2, 'o': 1};
    final s1 = mkState(b, mySum: 8, enSum: 2);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 等入场动画完成（_animLock 解锁）

    final b2 = fullBoard(len: 7);
    b2[3] = {'v': 1, 'o': 0}; // 超9：10→1+0，目标格变 0（长度不变）
    b2[4] = {'v': 0, 'o': null};
    // 注意：超9吞噬长度不变（cells[j]={v:0}），不是 splice
    final s2 = mkState(b2, mySum: 1, enSum: 0)
      ..['lastAction'] = {'type': 'devour', 'i': 3, 'j': 4, 'sum': 10, 'spliced': false, 'collapsed': false, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '吞噬超9渲染异常');
  });

  testWidgets('热座：吞噬后行动点用完 turn 切换，yourIdx 翻转', (tester) async {
    final sock = AIMSocket('http://x');
    final b = fullBoard();
    b[3] = {'v': 4, 'o': 0};
    b[4] = {'v': 2, 'o': 1};
    final s1 = mkState(b, mySum: 4, enSum: 2)..['hotseat'] = true;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump();

    // 吞噬结算 + 行动点用完 → 热座视角切到对方（yourIdx 0→1，颜色翻转）
    final b2 = fullBoard(len: 7);
    b2[3] = {'v': 6, 'o': 0};
    final s2 = mkState(b2, mySum: 0, enSum: 6)
      ..['hotseat'] = true
      ..['turn'] = 1
      ..['yourIdx'] = 1
      ..['phase'] = null
      ..['lastAction'] = {'type': 'devour', 'i': 3, 'j': 4, 'sum': 6, 'spliced': true, 'collapsed': false, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '热座视角切换渲染异常');
  });

  testWidgets('桥上吞噬（onBridge 单位）', (tester) async {
    final sock = AIMSocket('http://x');
    final b = fullBoard();
    b[3] = {'v': 4, 'o': 0, 'onBridge': true};
    b[4] = {'v': 2, 'o': 1};
    final s1 = mkState(b, mySum: 4, enSum: 2);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 等入场动画完成（_animLock 解锁）

    final b2 = fullBoard(len: 7);
    b2[3] = {'v': 0, 'o': null}; // 桥毁人亡
    final s2 = mkState(b2, mySum: 0, enSum: 0)
      ..['lastAction'] = {'type': 'devour', 'i': 3, 'j': 4, 'sum': 6, 'spliced': true, 'collapsed': true, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '桥上吞噬渲染异常');
  });

// 插桥：4攻3溢出 → 桥弹入，3 被顶开，其他格子不应有任何转变动画（误触发检查）
  testWidgets('插桥：4攻3溢出（地图+1）', (tester) async {
    final sock = AIMSocket('http://x');
    final s1 = mkState([
      {'v': 4, 'o': 0},
      {'v': 3, 'o': 1},
    ], mySum: 4, enSum: 3);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 等入场动画完成

    final s2 = mkState([
      {'v': 4, 'o': 0},
      {'bridge': true},
      {'v': 3, 'o': 1},
    ], mySum: 4, enSum: 3)
      ..['lastAction'] = {'type': 'attack', 'i': 0, 'j': 1, 'old': 3, 'newV': 3, 'insertedAt': 1, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    // 插桥：3 保持原样被顶开，转变动画在 j+1（目标右移处）——恰 1 个
    expect(find.byType(HitFx), findsOneWidget, reason: '插桥后目标转变动画（3→3）恰 1 个');
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '插桥后渲染异常');
  });

  testWidgets('移动1格：无转变动画误触发', (tester) async {
    final sock = AIMSocket('http://x');
    final s1 = mkState([
      {'v': 1, 'o': 0},
      {'v': 0, 'o': null},
    ], mySum: 1);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000));
    final s2 = mkState([
      {'v': 0, 'o': null},
      {'v': 1, 'o': 0},
    ], mySum: 1)
      ..['lastAction'] = {'type': 'move', 'i': 0, 'steps': 1, 'bridgeCollapse': null, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(HitFx), findsNothing, reason: '移动不应触发转变动画');
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '移动后渲染异常');
  });

  testWidgets('lastAction 剧本：801108 吞噬 1+1=2 → 80208', (tester) async {
    final sock = AIMSocket('http://x');
    final s1 = mkState([
      {'v': 8, 'o': 0}, {'v': 0, 'o': null}, {'v': 1, 'o': 0},
      {'v': 1, 'o': 1}, {'v': 0, 'o': null}, {'v': 8, 'o': 1},
    ], mySum: 1, enSum: 9);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 等入场

    // 服务端剧本：吞噬 1+1=2，splice 目标格 → 80208
    final s2 = mkState([
      {'v': 8, 'o': 0}, {'v': 0, 'o': null}, {'v': 2, 'o': 0},
      {'v': 0, 'o': null}, {'v': 8, 'o': 1},
    ], mySum: 2, enSum: 8)
      ..['lastAction'] = {'type': 'devour', 'i': 2, 'j': 3, 'sum': 2, 'spliced': true, 'collapsed': false, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    // 剧本驱动：两个转变动画（1→2、1→0），8 不误判移动
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(HitFx), findsNWidgets(2), reason: '吞噬应有两个转变动画（1→2 和 1→0）');
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: 'lastAction 吞噬渲染异常');
  });

  testWidgets('同 lastSeq 不重复播放（回合切换推同一 lastAction）', (tester) async {
    final sock = AIMSocket('http://x');
    // 开局：无 lastAction
    final s0 = mkState([
      {'v': 8, 'o': 0}, {'v': 0, 'o': null}, {'v': 0, 'o': null},
      {'v': 0, 'o': null}, {'v': 0, 'o': null}, {'v': 8, 'o': 1},
    ], mySum: 8, enSum: 8);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s0, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 入场完
    // 第一次行动：produce seq=1 → 应播 1 次
    final s1 = mkState([
      {'v': 8, 'o': 0}, {'v': 1, 'o': 0}, {'v': 0, 'o': null},
      {'v': 0, 'o': null}, {'v': 0, 'o': null}, {'v': 8, 'o': 1},
    ], mySum: 9, enSum: 8)
      ..['lastAction'] = {'type': 'produce', 'j': 1, 'attacked': false, 'newV': 1, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(HitFx), findsOneWidget, reason: '新 seq 应播放一次');
    await tester.pump(const Duration(milliseconds: 700)); // 等动画播完
    // 同 seq 再次推送（回合切换）：不应重复播放
    final s2 = mkState([
      {'v': 8, 'o': 0}, {'v': 1, 'o': 0}, {'v': 0, 'o': null},
      {'v': 0, 'o': null}, {'v': 0, 'o': null}, {'v': 8, 'o': 1},
    ], mySum: 9, enSum: 8)
      ..['lastAction'] = {'type': 'produce', 'j': 1, 'attacked': false, 'newV': 1, 'owner': 0}
      ..['lastSeq'] = 1
      ..['turn'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(HitFx), findsNothing, reason: '同 seq 不应重复播放动画');
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
  });
// 800228：第五格2（i=4）吞噬第四格2（j=3）——i > j，splice 后索引左移
  testWidgets('i>j 吞噬：第五格吞第四格（2+2=4 → 80048）', (tester) async {
    final sock = AIMSocket('http://x');
    final s1 = mkState([
      {'v': 8, 'o': 0}, {'v': 0, 'o': null}, {'v': 0, 'o': null},
      {'v': 2, 'o': 1}, {'v': 2, 'o': 0}, {'v': 8, 'o': 1},
    ], mySum: 2, enSum: 10);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000));
    final s2 = mkState([
      {'v': 8, 'o': 0}, {'v': 0, 'o': null}, {'v': 0, 'o': null},
      {'v': 4, 'o': 0}, {'v': 8, 'o': 1},
    ], mySum: 4, enSum: 8)
      ..['lastAction'] = {'type': 'devour', 'i': 4, 'j': 3, 'sum': 4, 'spliced': true, 'collapsed': false, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    // 转变动画 2 个（2→4、2→0），动画棋盘应为 800048（吞噬方在索引4 变 4）
    expect(find.byType(HitFx), findsNWidgets(2), reason: 'i>j 吞噬应有 2 个转变动画');
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: 'i>j 吞噬渲染异常');
  });

  // 联机回放路径（_detectRoll，旧剧本）：crush 子步后 6 必须是浮层继续回放，不消失不闪现
  // （2026-08-18 回归：绑定模型的 bound 泄漏到旧路径会让浮层被隐藏 + 6 被 placeUnit 清掉）
  testWidgets('联机回放：crush 后 6 浮层保持可见', (tester) async {
    final sock = AIMSocket('http://x');
    // 服务端一次算完 + rollSteps 剧本（86500008：crush → bump → move → move）
    final b1 = [
      {'v': 8, 'o': 0, 'id': 1}, {'v': 6, 'o': 0, 'id': 2}, {'v': 5, 'o': 0, 'id': 3},
      {'v': 0, 'o': null, 'id': 4}, {'v': 0, 'o': null, 'id': 5}, {'v': 0, 'o': null, 'id': 6},
      {'v': 0, 'o': null, 'id': 7}, {'v': 8, 'o': 1, 'id': 8},
    ];
    final s1 = mkState(b1, mySum: 19, enSum: 8);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 入场完成

    final b2 = [
      {'v': 8, 'o': 0, 'id': 1}, {'v': 0, 'o': null, 'id': 9},
      {'v': 0, 'o': null, 'bridge': true, 'id': 10},
      {'v': 1, 'o': 0, 'id': 11},
      {'v': 0, 'o': null, 'id': 12}, {'v': 6, 'o': 0, 'id': 2},
      {'v': 0, 'o': null, 'id': 13}, {'v': 0, 'o': null, 'id': 14}, {'v': 8, 'o': 1, 'id': 8},
    ];
    final s2 = mkState(b2, mySum: 15, enSum: 8)
      ..['rollSeq'] = 1
      ..['rollSteps'] = [
        {'crush': true, 'owner': 0, 'oldV': 5, 'newV': 1, 'bridge': true},
        {'bump': true},
        {'crush': false},
        {'crush': false},
      ];
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 500)); // 回放中（crush 已压、未滚完）
    // 9 格棋盘 9 张图 + 6 浮层 1 张 = 10；坏掉时浮层被隐藏只剩 9（6 消失）
    expect(find.byType(Image), findsNWidgets(10), reason: '回放中 6 浮层应可见（不消失）');
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '联机回放渲染异常');
  });

  // 热座全程帧级检查：6 的图标（浮层或绑定格）必须始终可见，0 帧消失
  testWidgets('热座全程：6 永不消失（逐帧检查）', (tester) async {
    final socket = LocalAimSocket();
    socket.game.cells = [
      AimCell(8, o: 0),
      AimCell(6, o: 0, auto: true),
      AimCell(5, o: 0, auto: true),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(8, o: 1),
    ];
    socket.game.turn = 1;
    socket.game.phase = null;
    socket.game.points = 0;
    socket.game.produceLeft = 0;

    final states = <Map<String, dynamic>>[];
    socket.onEvent = (e, d) {
      if (e == 'game_state') states.add(d as Map<String, dynamic>);
    };
    socket.connect();
    var state = states.first;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: socket, state: state, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 入场完成

    bool sixVisible() => find
        .byWidgetPredicate((w) =>
            w is Image &&
            w.image is AssetImage &&
            (w.image as AssetImage).assetName.endsWith('units/6.png'))
        .evaluate()
        .isNotEmpty;

    socket.emit('action', {'type': 'endTurn'});
    var pumped = 1;
    var guard = 0;
    var missingFrames = 0;
    var totalFrames = 0;
    while (socket.game.hasPendingRoll && guard++ < 300) {
      await tester.pump(const Duration(milliseconds: 30)); // 逐帧推进
      if (states.length > pumped) {
        state = states[pumped];
        pumped = states.length;
        await tester.pumpWidget(MaterialApp(
          home: GameScreen(socket: socket, state: state, packId: 'default', onBack: () {}),
        ));
      }
      totalFrames++;
      if (!sixVisible()) missingFrames++;
    }
    expect(missingFrames, 0,
        reason: '6 全程可见（共 $totalFrames 帧，消失 $missingFrames 帧）');
    expect(tester.takeException(), isNull, reason: '热座全程渲染异常');
  });

  // 86500008 绑定模型（2026-08-17）：endTurn 后 6 逐步滚 3 步，每步滑一格→绑定棋盘格
  // →插入动画推开（无独立 bump 滑行）；全程不崩、最终棋盘 = 规则层结果
  // 2026-08-18 补充：crush 暂停期间 6 必须可见（绑定在格子上，不消失不闪现）
  testWidgets('crush 暂停期间 6 绑定在格子上可见', (tester) async {
    final socket = LocalAimSocket();
    socket.game.cells = [
      AimCell(8, o: 0),
      AimCell(6, o: 0, auto: true),
      AimCell(5, o: 0, auto: true),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(8, o: 1),
    ];
    socket.game.turn = 1;
    socket.game.phase = null;
    socket.game.points = 0;
    socket.game.produceLeft = 0;
    final rid = socket.game.cells[1].id; // 滚木 id

    final states = <Map<String, dynamic>>[];
    socket.onEvent = (e, d) {
      if (e == 'game_state') states.add(d as Map<String, dynamic>);
    };
    socket.connect();
    var state = states.first;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: socket, state: state, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 入场动画完成

    socket.emit('action', {'type': 'endTurn'});
    state = states[1]; // endTurn 后（rollPending）
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: socket, state: state, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 50)); // handler → emit roll_step → states[2]
    state = states[2]; // 第1步 crush 后棋盘
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: socket, state: state, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 滑行 260ms + 进入 pause

    // pause 中：6 必须显示在绑定格上（cell$rid 存在且带图标）
    final cellFinder = find.byKey(ValueKey('cell$rid'));
    expect(cellFinder, findsOneWidget, reason: '绑定格存在（id=$rid）');
    final imgs = find.descendant(of: cellFinder, matching: find.byType(Image));
    expect(imgs, findsWidgets, reason: '6 图标显示在绑定格上，不消失');
    // 6 的绑定格应该在桥右侧（棋盘：8 0 - [6] 0 0 0 0 {8}）
    expect(tester.takeException(), isNull, reason: 'crush pause 渲染异常');

    // 等动画全部播完
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: 'crush 后续渲染异常');
  });

  // 86500008 绑定模型端到端：endTurn → 3 步逐步滚完
  testWidgets('86500008 绑定模型端到端：endTurn → 3 步逐步滚完', (tester) async {
    final socket = LocalAimSocket();
    socket.game.cells = [
      AimCell(8, o: 0),
      AimCell(6, o: 0, auto: true),
      AimCell(5, o: 0, auto: true),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(8, o: 1),
    ];
    socket.game.turn = 1;
    socket.game.phase = null;
    socket.game.points = 0;
    socket.game.produceLeft = 0;

    final states = <Map<String, dynamic>>[];
    socket.onEvent = (e, d) {
      if (e == 'game_state') states.add(d as Map<String, dynamic>);
    };
    socket.connect(); // 推初始 state
    expect(states, isNotEmpty);

    var state = states.first;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: socket, state: state, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 入场动画完成

    // 玩家1 endTurn → 玩家0 的 6 待滚（rollPending），动画层逐步驱动：
    // GameScreen 由父组件用新 state 重建（didUpdateWidget），动画播完 emit roll_step
    // → 引擎算下一步 → 新 state 到达 → 继续喂给 GameScreen，直到滚完
    socket.emit('action', {'type': 'endTurn'});
    var pumped = 1;
    var guard = 0;
    while (socket.game.hasPendingRoll && guard++ < 200) {
      await tester.pump(const Duration(milliseconds: 100));
      if (states.length > pumped) {
        state = states[pumped];
        pumped = states.length;
        await tester.pumpWidget(MaterialApp(
          home: GameScreen(socket: socket, state: state, packId: 'default', onBack: () {}),
        ));
      }
    }
    expect(guard, lessThan(200), reason: '逐步滚木应有限步数');
    expect(tester.takeException(), isNull, reason: '86500008 逐步滚木动画异常');

    // 规则层最终棋盘：[8] 0 - [1] 0 [6] 0 0 {8}（9 格）
    final cells = socket.game.cells;
    String line() => cells.map((c) {
          if (c.bridge) return '-';
          final o = c.o;
          return o == null ? '0' : (o == 0 ? '[${c.v}]' : '{${c.v}}');
        }).join(' ');
    expect(line(), '[8] 0 - [1] 0 [6] 0 0 {8}');
  });

  // 逐步滚木（2026-08-16 动画层 pressedV 修复回归）：
  // 规则层每步下发棋盘 + rollActs，动画层重建中间画面时滚木脚下压着的单位必须转正显示；
  // 全序列播放不崩、动画正常解锁（_animLock 复位），最终棋盘 = 规则层棋盘
  testWidgets('逐步滚木：crush 插桥→被压单位露出，序列播放不崩', (tester) async {
    final sock = AIMSocket('http://x');
    // 步前棋盘（endTurn 后未滚）：[8][6][1][1][1]0 0 {8}（idx1 滚木，idx2~4 玩家0 的 1）
    final b1 = [
      {'v': 8, 'o': 0, 'id': 1}, {'v': 6, 'o': 0, 'id': 2}, {'v': 1, 'o': 0, 'id': 3},
      {'v': 1, 'o': 0, 'id': 4}, {'v': 1, 'o': 0, 'id': 5},
      {'v': 0, 'o': null, 'id': 6}, {'v': 0, 'o': null, 'id': 7}, {'v': 8, 'o': 1, 'id': 8},
    ];
    final s1 = mkState(b1, mySum: 15, enSum: 9)
      ..['rollPending'] = true
      ..['rollStepSeq'] = 0
      ..['hotseat'] = true;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 入场完成

    // 第一步 crush 后（规则层）：[8]0[-][6滚压5][1][1]0 0 {8}（9格，滚木在 idx3 脚下压 5）
    final b2 = [
      {'v': 8, 'o': 0, 'id': 1}, {'v': 0, 'o': null, 'id': 9},
      {'v': 0, 'o': null, 'bridge': true, 'id': 10},
      {'v': 6, 'o': 0, 'id': 2, 'pressedV': 5, 'pressedO': 0},
      {'v': 1, 'o': 0, 'id': 4}, {'v': 1, 'o': 0, 'id': 5},
      {'v': 0, 'o': null, 'id': 6}, {'v': 0, 'o': null, 'id': 7}, {'v': 8, 'o': 1, 'id': 8},
    ];
    final s2 = mkState(b2, mySum: 15, enSum: 9)
      ..['rollPending'] = true
      ..['rollStepSeq'] = 1
      ..['hotseat'] = true
      ..['rollActs'] = [
        {'op': 'crush', 'from': 1, 'to': 3, 'at': 2, 'oldV': 1, 'newV': 5, 'bridge': true, 'owner': 0}
      ];
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    // 播放 crush+bump 两步动画（含插桥弹入 + 转变白闪）
    for (int i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '第一步 crush 插桥动画异常');

    // 第二步 crush 后（规则层）：[8]0[-][5][-][6滚压5][1]0 0 {8}（10格，上一步被压的 5 露出）
    final b3 = [
      {'v': 8, 'o': 0, 'id': 1}, {'v': 0, 'o': null, 'id': 9},
      {'v': 0, 'o': null, 'bridge': true, 'id': 10},
      {'v': 5, 'o': 0, 'id': 11},
      {'v': 0, 'o': null, 'bridge': true, 'id': 12},
      {'v': 6, 'o': 0, 'id': 2, 'pressedV': 5, 'pressedO': 0},
      {'v': 1, 'o': 0, 'id': 5}, {'v': 0, 'o': null, 'id': 6}, {'v': 0, 'o': null, 'id': 7},
      {'v': 8, 'o': 1, 'id': 8},
    ];
    final s3 = mkState(b3, mySum: 15, enSum: 9)
      ..['rollPending'] = true
      ..['rollStepSeq'] = 2
      ..['hotseat'] = true
      ..['rollActs'] = [
        {'op': 'crush', 'from': 3, 'to': 5, 'at': 4, 'oldV': 1, 'newV': 5, 'bridge': true, 'owner': 0}
      ];
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s3, packId: 'default', onBack: () {}),
    ));
    for (int i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull, reason: '第二步 crush 插桥动画异常（含被压单位露出）');
  });
}
