// AIM 单位卡片速查表：对战中长按单位查看（玩家忘记单位用途时用）
// 信息与新手教程角色卡同源，额外补齐 6 滚木 / 8 基地 / 9 指挥部

class UnitCard {
  final String name;      // 称呼（拉丁名 / 建筑名）
  final String stat;      // 属性行：伤害 / 生命 / 特性
  final String bio;       // 简介（\n 分行）
  final String? portrait; // 立绘文件名；null = 无立绘（用数字像素图）
  const UnitCard(this.name, this.stat, this.bio, this.portrait);
}

const Map<int, UnitCard> kUnitCards = {
  1: UnitCard('Primus', '伤害 1 · 生命 1',
      '新入伍的步卒，还在学怎么握剑。\n小兵 1 过桥会把桥拆掉；\n也是滚木的优质饲料。', 'primus'),
  2: UnitCard('Secundus', '伤害 2 · 生命 2 · 轻骑',
      '轻骑队的银发女骑手，性子欢脱。\n马背上的风，就是她的信条。\n移动一次走 2 格。', 'secundus'),
  3: UnitCard('Tertius', '伤害 1 · 生命 3 · 弓手',
      '沉默的弓手，箭比话多。\n射程 2 格，攻击恒为 1（远程）。\n打 7 或被 7 掩护的单位：0 伤害。', 'tertius'),
  4: UnitCard('Quartus', '伤害 1 · 生命 4 · 炮手',
      '炮兵，说话带刺，眼里揉不得沙子。\n射程 3 格，攻击恒为 1（远程）。\n重装：上独木桥会桥塌人亡。', 'quartus'),
  5: UnitCard('Quintus', '伤害 5 · 生命 5 · 重骑',
      '五大三粗的重骑，嗓门比马蹄还响。\n移动一次走 2 格。\n重单位：上独木桥会桥塌人亡，千万别走。', 'quintus'),
  6: UnitCard('滚木', '每回合自动前进 3 格',
      '不听命令的石头，碾过什么就是什么。\n前两格压 6 伤（可能砸出独木桥），\n第三格抹杀；撞桥、撞建筑、滚出边界都会死。', null),
  7: UnitCard('Septimus', '伤害 7 · 生命 7 · 盾卫',
      '战场约定的起草人，军团最稳的那面墙。\n本体及其身后（朝己方方向）友军\n免疫远程伤害。', 'septimus'),
  8: UnitCard('基地', '每回合造兵一次',
      '8、9 是建筑：不可移动、不可被吞噬。\n造出的兵落在基地前方一格。\n每回合每个基地各造兵一次。', null),
  9: UnitCard('指挥部', '每回合 +1 行动点',
      '8、9 是建筑：不可移动、不可被吞噬。\n每回合提供额外行动点：\n行动点 = 己方指挥部数 + 1。', null),
};
