// 规则开关：滚木能否被己方攻击（allowOwnRollerAttack）
// 默认开（保持「敌我皆可」）；关闭后己方滚木免疫己方攻击，敌方仍可击破
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';

List<AimCell> board8() {
  return [
    AimCell(8, o: 0),
    AimCell(2, o: 0), // 玩家0 的 2（攻击力2）
    AimCell(6, o: 0, auto: true), // 玩家0 的滚木（已激活）
    AimCell(0),
    AimCell(0),
    AimCell(0),
    AimCell(0),
    AimCell(8, o: 1),
  ];
}

void main() {
  test('默认开启：己方可攻击己方滚木（保持敌我皆可）', () {
    final g = AimGame(limit: 16); // allowOwnRollerAttack 默认 true
    g.cells = board8();
    g.turn = 0;
    final acts = <Map<String, dynamic>>[];
    g.genUnitActions(0, acts);
    expect(acts.any((a) => a['type'] == 'attack' && a['i'] == 1 && a['j'] == 2), true,
        reason: '格1 的 2 应有攻击己方滚木的选项');
    final r = g.applyAction(0, {'type': 'attack', 'i': 1, 'j': 2});
    expect(r['ok'], true);
    expect(g.cells[2].v, 4, reason: '2 打 6 → 6-2=4');
    expect(g.cells[2].auto, false, reason: '被打降级后滚木解锁');
  });

  test('关闭后：己方不能攻击己方滚木（选项消失 + 执行被拒）', () {
    final g = AimGame(limit: 16, allowOwnRollerAttack: false);
    g.cells = board8();
    g.turn = 0;
    final acts = <Map<String, dynamic>>[];
    g.genUnitActions(0, acts);
    expect(acts.any((a) => a['type'] == 'attack'), false,
        reason: '己方滚木不应出现在攻击目标里');
    final r = g.applyAction(0, {'type': 'attack', 'i': 1, 'j': 2});
    expect(r['ok'], false, reason: '服务端/本地引擎应拒绝伪造的攻击');
  });

  test('关闭后：己方普通单位仍可攻击（开关只针对滚木）', () {
    final g = AimGame(limit: 16, allowOwnRollerAttack: false);
    g.cells = board8();
    g.cells[2] = AimCell(2, o: 0); // 把己方滚木换成己方普通单位2
    g.turn = 0;
    final acts = <Map<String, dynamic>>[];
    g.genUnitActions(0, acts);
    expect(acts.any((a) => a['type'] == 'attack' && a['i'] == 1 && a['j'] == 2), true,
        reason: '己方普通单位仍可被己方攻击（敌我皆可不变）');
  });

  test('关闭后：敌方仍可攻击己方滚木', () {
    final g = AimGame(limit: 16, allowOwnRollerAttack: false);
    g.cells = [
      AimCell(8, o: 0),
      AimCell(0),
      AimCell(0),
      AimCell(6, o: 0, auto: true), // 玩家0 的滚木
      AimCell(1, o: 1), // 玩家1 的小兵（方向朝左）
      AimCell(0),
      AimCell(0),
      AimCell(8, o: 1),
    ];
    g.turn = 1;
    final acts = <Map<String, dynamic>>[];
    g.genUnitActions(1, acts);
    expect(acts.any((a) => a['type'] == 'attack' && a['i'] == 4 && a['j'] == 3), true,
        reason: '敌方打己方滚木不受开关限制');
    final r = g.applyAction(1, {'type': 'attack', 'i': 4, 'j': 3});
    expect(r['ok'], true);
    expect(g.cells[3].v, 5, reason: '1 打 6 → 5');
  });
}
