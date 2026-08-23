// 本地规则引擎对拍测试：与 Node 版 rules.js 的关键场景输出一致
// 跑法：cd /root/aim/client && timeout 120 /opt/flutter/bin/flutter test --no-version-check test/rules_local_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';

String line(AimGame g) {
  return g.cells.map((c) {
    if (c.isB) return '-';
    if (c.o == null) return '0';
    return c.o == 0 ? '[${c.v}]' : '{${c.v}}';
  }).join(' ');
}

AimGame custom(List<String> spec, {int limit = 16}) {
  final g = AimGame(limit: limit);
  g.cells = spec.map((s) {
    if (s == '-') return AimCell(0, bridge: true);
    if (s == '0') return AimCell(0);
    if (s.startsWith('{')) return AimCell(int.parse(s.substring(1, s.length - 1)), o: 1);
    if (s.startsWith('[')) return AimCell(int.parse(s.substring(1, s.length - 1)), o: 0);
    return AimCell(int.parse(s), o: 0);
  }).toList();
  return g;
}

void main() {
  test('createGame：limit=16 → 8格，两端基地', () {
    final g = AimGame(limit: 16);
    expect(g.cells.length, 8);
    expect(g.cells[0].v, 8);
    expect(g.cells[0].o, 0);
    expect(g.cells[7].v, 8);
    expect(g.cells[7].o, 1);
    expect(g.sumOf(0), 8);
    expect(g.sumOf(1), 8);
  });

  test('吞噬：4吞2 → 6，目标格消失（地图-1）', () {
    final g = custom(['0', '[4]', '{2}', '0', '0', '0', '0', '[8]']);
    g.turn = 0;
    final r = g.applyAction(0, {'type': 'devour', 'i': 1, 'j': 2});
    expect(r['ok'], true);
    expect(g.cells[1].v, 6);
    expect(g.cells.length, 7, reason: '目标格应删除');
    expect(g.lastAction?['type'], 'devour');
    expect(g.lastAction?['sum'], 6);
    expect(g.lastAction?['spliced'], true);
  });

  test('吞噬超9：6吞6 → 12 → 1+2（变拉）', () {
    final g = custom(['0', '[6]', '{6}', '0', '0', '0', '0', '[8]']);
    g.turn = 0;
    g.applyAction(0, {'type': 'devour', 'i': 1, 'j': 2});
    expect(g.cells[1].v, 1);
    expect(g.cells[2].v, 2);
    expect(g.cells[2].o, 0);
    expect(g.cells.length, 8, reason: '超9不删格');
  });

  test('插桥：5攻1溢出 → 桥插目标位，1→4顶右', () {
    // 4 是炮兵（攻击恒1）不会溢出；用 5 攻 1 验证溢出插桥
    final g = custom(['0', '[5]', '{1}', '0', '0', '0', '0', '[8]']);
    g.turn = 0;
    g.applyAction(0, {'type': 'attack', 'i': 1, 'j': 2});
    expect(line(g), '0 [5] - {4} 0 0 0 0 [8]');
    expect(g.cells.length, 9, reason: '插桥地图+1');
    expect(g.lastAction?['insertedAt'], 2);
  });

  test('滚木碾压（记忆验证场景）：6压2压1 → 0 - 4 - 5 6 0 0 0 {2} {8}', () {
    final g = custom(['[6]', '[2]', '[1]', '0', '0', '0', '0', '{2}', '{8}'], limit: 16);
    g.turn = 1;
    g.phase = null;
    // 玩家1 endTurn → 玩家0 回合开始 → 玩家0 滚木自动前进
    g.applyAction(1, {'type': 'endTurn'});
    expect(line(g), '0 - [4] - [5] [6] 0 0 0 {2} {8}');
    expect(g.rollSteps, isNotNull);
    expect(g.rollSteps!.length, 5, reason: '压2+被顶+压1+被顶+空地 = 5 子步');
    expect(g.rollSteps![0]['bridge'], true);
    expect(g.rollSteps![0]['newV'], 4);
    expect(g.rollSteps![1]['bump'], true);
    expect(g.rollSteps![2]['bridge'], true);
    expect(g.rollSteps![2]['newV'], 5);
    expect(g.rollSteps![3]['bump'], true);
    expect(g.rollSteps![4]['crush'], false);
  });

  test('移动：正常1格 + 骑兵2格', () {
    final g = custom(['0', '[2]', '0', '0', '0', '0', '0', '[8]']);
    g.turn = 0;
    // 骑兵2号走2格
    g.applyAction(0, {'type': 'move', 'i': 1, 'steps': 2});
    expect(line(g), '0 0 0 [2] 0 0 0 [8]');
  });

  test('拆分：5拆keep=4 → 产物插右侧（i+1），9格', () {
    final g = custom(['0', '[5]', '0', '0', '0', '0', '0', '[8]']);
    g.turn = 0;
    g.applyAction(0, {'type': 'split', 'i': 1, 'keep': 4});
    expect(line(g), '0 [4] [1] 0 0 0 0 0 [8]');
    expect(g.cells.length, 9);
    expect(g.lastAction?['keep'], 4);
    expect(g.lastAction?['other'], 1);
  });

  test('满员拆分：只保留所选', () {
    final g = custom(['0', '[5]', '0', '0', '0', '0', '0', '[8]'], limit: 8);
    g.turn = 0;
    g.applyAction(0, {'type': 'split', 'i': 1, 'keep': 4});
    expect(g.cells[1].v, 4);
    expect(g.cells.length, 8, reason: '满员不插格');
    expect(g.lastAction?['full'], true);
  });

  test('桥上吞噬 ≥5 → 桥毁人亡', () {
    // 桥上 4 吞 2 → 6 ≥ 5 → 桥毁人亡（单位+桥都消失）
    final g = custom(['0', '-', '0', '0', '0', '0', '0', '[8]']);
    g.cells[1] = AimCell(4, o: 0, bridge: true, onBridge: true);
    g.cells[2] = AimCell(2, o: 1);
    g.turn = 0;
    g.applyAction(0, {'type': 'devour', 'i': 1, 'j': 2});
    expect(g.cells[1].v, 0, reason: '单位死亡');
    expect(g.cells[1].isB, isFalse, reason: '桥也消失');
    expect(g.lastAction?['collapsed'], true);
  });

  test('盾兵屏障：弓兵3 打 7 → 0伤害', () {
    // 我方3弓手在格1，敌方7盾兵在格2，敌方1在格3（被7挡住）
    final g = custom(['0', '[3]', '{7}', '{1}', '0', '0', '0', '[8]']);
    g.turn = 0;
    g.applyAction(0, {'type': 'attack', 'i': 1, 'j': 3});
    expect(g.cells[3].v, 1, reason: '被盾兵挡住，0伤害');
    expect(g.lastAction?['shielded'], true);
    // 直接打 7 本身也免疫
    g.turn = 0;
    g.phase = null;
    g.points = 0;
    g.produceLeft = 0;
    g.applyAction(0, {'type': 'attack', 'i': 1, 'j': 2});
    expect(g.cells[2].v, 7, reason: '7本体免疫远程');
  });

  test('造兵：基地前空地+1；攻击敌方-1', () {
    final g = custom(['[8]', '0', '0', '0', '0', '0', '[1]', '{8}']);
    g.turn = 0;
    g.applyAction(0, {'type': 'produce', 'i': 0});
    expect(g.cells[1].v, 1);
    expect(g.cells[1].o, 0);
    // 敌方造兵攻击我方（格6 是我方单位）
    g.applyAction(1, {'type': 'produce', 'i': 7});
    expect(g.cells[6].v, 0, reason: '我方1被敌方造兵攻击减1→0');
  });

  test('热座回合流：造兵→行动→自动过回合→对方滚木', () {
    final g = AimGame(limit: 16);
    // 玩家0：造兵
    var r = g.applyAction(0, {'type': 'produce', 'i': 0});
    expect(r['ok'], true);
    expect(g.cells[1].v, 1);
    // 造兵点用完后自动过回合
    expect(g.turn, 1, reason: '造兵点耗尽自动过回合');
    // 玩家1：造兵
    r = g.applyAction(1, {'type': 'produce', 'i': 7});
    expect(r['ok'], true);
    expect(g.turn, 0);
    // viewFor 视角数据与联机格式一致
    final v = g.viewFor(0);
    expect(v['yourIdx'], 0);
    expect(v['cells'], isA<List>());
    expect(v['lastAction'], isNotNull);
    expect(v['mapLen'], g.cells.length);
  });

  test('viewFor 与联机服务端同格式（含 lastAction/lastSeq/rollSteps）', () {
    final g = custom(['0', '[4]', '{2}', '0', '0', '0', '0', '[8]']);
    g.turn = 0;
    g.applyAction(0, {'type': 'devour', 'i': 1, 'j': 2});
    final v = g.viewFor(0);
    expect(v['cells'][1]['v'], 6);
    expect(v['cells'][1]['id'], isA<int>());
    expect(v['lastAction']?['type'], 'devour');
    expect(v['lastSeq'], 1);
    expect(v['hotseat'], true);
    expect(v['mySum'], 14);
    expect(v['enemySum'], 0);
  });

  test('右→左滚木：压单位溢出插桥后撞桥掉下去（桥塌+滚木消失，单位保留）', () {
    final g = custom(['[8]', '[2]', '[1]', '0', '0', '0', '{2}', '{6}']);
    g.cells[7] = AimCell(6, o: 1, auto: true);
    g.turn = 0;
    // 玩家0 endTurn → 玩家1 回合开始 → 玩家1 滚木自动前进（方向左）
    g.applyAction(0, {'type': 'endTurn'});
    expect(line(g), '[8] [2] [1] 0 0 0 {4} 0', reason: '滚木压2变4，被顶到桥右，下一步撞桥掉下去（桥塌+滚木消失，单位保留）');
    expect(g.rollSteps, isNotNull);
    expect(g.rollSteps!.length, 3);
    expect(g.rollSteps![0]['bridge'], true);
    expect(g.rollSteps![0]['newV'], 4);
    expect(g.rollSteps![1]['bump'], true, reason: '被顶到桥右边');
    expect(g.rollSteps![2]['dead'], true, reason: '撞桥掉下去');
    expect(g.rollSteps![2]['bridgeCollapse'], true);
    expect(g.cells[6].v, 4, reason: '被压单位保留');
    expect(g.cells[7].v, 0, reason: '滚木消失');
  });

  test('右→左滚木：空地正常逐格滚，不瞬移', () {
    final g = custom(['[8]', '0', '0', '0', '0', '0', '0', '{6}']);
    g.cells[7] = AimCell(6, o: 1, auto: true);
    g.turn = 0;
    g.applyAction(0, {'type': 'endTurn'});
    // 滚木从格7 往左滚3格 → 格4
    expect(g.cells[4].v, 6);
    expect(g.cells[4].o, 1);
    expect(g.rollSteps!.length, 3, reason: '三步空地');
    expect(g.rollSteps!.every((s) => s['crush'] == false), isTrue);
  });

  test('rollStepOnce 逐步驱动：86111008 每步动作序列 + 最终棋盘与 autoRoll 一致', () {
    final g = custom(['[8]', '[6]', '[1]', '[1]', '[1]', '0', '0', '{8}']);
    final allActs = <Map<String, dynamic>>[];
    final states = <String>[];
    List<Map<String, dynamic>>? a;
    while ((a = g.rollStepOnce(0)) != null) {
      allActs.addAll(a!);
      states.add(line(g));
    }
    // 最终棋盘 = autoRoll 结果
    expect(line(g), '[8] 0 - [5] - [5] [6] 0 0 {8}');
    expect(g.rollSeq, 1);
    // 动作序列应包含：压单位（插桥）→ 压单位（插桥）→ 抹杀
    final crushes = allActs.where((x) => x['op'] == 'crush').toList();
    expect(crushes.length, 2, reason: '两次压单位（非抹杀）');
    expect(crushes.every((x) => x['bridge'] == true), isTrue, reason: '1 受 6 伤必溢出插桥');
    expect(crushes.every((x) => x['newV'] == 5), isTrue);
    expect(allActs.any((x) => x['op'] == 'kill'), isTrue, reason: '第三格抹杀');
    // 逐步中间态：第一步后棋盘（牢大定稿：滚木被顶到桥右，脚下压着变值单位，棋盘只显示滚木）
    expect(states.first, '[8] 0 - [6] [1] [1] 0 0 {8}', reason: '第一步：桥插格2，滚木被顶到格3（脚下压着5，棋盘显示6）');
  });

  test('deferRoll：endTurn 延后滚木，可逐步驱动', () {
    final g = custom(['[8]', '[6]', '[1]', '[1]', '[1]', '0', '0', '{8}']);
    g.turn = 1;
    // 玩家1 endTurn（deferRoll）→ 玩家0 滚木待滚，但棋盘未变
    final r = g.applyAction(1, {'type': 'endTurn'}, deferRoll: true);
    expect(r['ok'], true);
    expect(g.hasPendingRoll, isTrue, reason: '有滚木待滚');
    expect(line(g), '[8] [6] [1] [1] [1] 0 0 {8}', reason: 'deferRoll 时棋盘不变');
    // 逐步滚完
    var steps = 0;
    List<Map<String, dynamic>>? a;
    while ((a = g.rollStepOnce(0)) != null) {
      steps++;
    }
    expect(steps, greaterThan(0));
    expect(g.hasPendingRoll, isFalse, reason: '滚完清除待滚标记');
    expect(line(g), '[8] 0 - [5] - [5] [6] 0 0 {8}');
  });
}
