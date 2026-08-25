// AIM AI 对手：决策层（只从合法行动里选，不碰规则引擎）
// 三档难度：
//   easy   —— 随机行动，偶尔无脑造兵（新手练手）
//   normal —— 启发式评分：攻击消灭优先、吞噬合成 8/9、推进、避桥
//   hard   —— 加强：防守意识（敌方逼近基地优先清除）、远程威胁规避
// 本地跑（热座玩家 vs AI），AI 固定为玩家1（后手）
import 'dart:math' as math;

import 'rules.dart';

enum AiLevel { easy, normal, hard }

class AimAi {
  final AiLevel level;
  final math.Random _rand;

  AimAi(this.level, {int? seed}) : _rand = math.Random(seed);

  // AI 回合决策：返回一个要执行的 action（调用方负责 emit/applyAction）
  Map<String, dynamic>? decide(AimGame game) {
    if (game.winner != null) return null;
    final owner = game.turn;
    if (game.phase == null) {
      // 选阶段：行动 or 造兵
      if (level == AiLevel.easy) {
        return _rand.nextDouble() < 0.5
            ? {'type': 'choosePhase', 'phase': 'action'}
            : {'type': 'choosePhase', 'phase': 'produce'};
      }
      return {'type': 'choosePhase', 'phase': _wantAction(game, owner) ? 'action' : 'produce'};
    }
    if (game.phase == 'produce') {
      final acts = game.getLegalActions(owner);
      final prod = acts.where((a) => a['type'] == 'produce').toList();
      if (prod.isEmpty) return {'type': 'endTurn'};
      if (level == AiLevel.easy) return prod[_rand.nextInt(prod.length)];
      return _pickProduce(game, owner, prod);
    }
    // action 阶段：评分选最优
    final acts = game.getLegalActions(owner);
    final playable = acts.where((a) => a['type'] != 'endTurn').toList();
    if (playable.isEmpty) return {'type': 'endTurn'};
    if (level == AiLevel.easy) return playable[_rand.nextInt(playable.length)];
    playable.sort((a, b) => _score(game, owner, b).compareTo(_score(game, owner, a)));
    return playable.first;
  }

  // ── 阶段选择：有没有值得出手的行动？──
  bool _wantAction(AimGame game, int owner) {
    final acts = game.getLegalActions(owner);
    var best = 0;
    for (final a in acts) {
      final s = _score(game, owner, a);
      if (s > best) best = s;
    }
    if (best >= 60) return true; // 有高价值行动（消灭/合成/大威胁）
    // 没大机会：普通档偏养兵，困难档偏积极
    final p = level == AiLevel.hard ? 0.55 : 0.38;
    return _rand.nextDouble() < p;
  }

  // ── 造兵选择：基地前有敌方 → 造兵攻击；否则随机 ──
  Map<String, dynamic> _pickProduce(AimGame game, int owner, List<Map<String, dynamic>> prod) {
    for (final p in prod) {
      final j = p['j'] as int;
      final c = game.cells[j];
      if (c.o != null && c.o != owner) return p; // 造兵攻击敌方
    }
    return prod[_rand.nextInt(prod.length)];
  }

  // ── 行动评分 ──
  int _score(AimGame game, int owner, Map<String, dynamic> a) {
    switch (a['type']) {
      case 'attack':
        return _scoreAttack(game, owner, a);
      case 'devour':
        return _scoreDevour(game, owner, a);
      case 'move':
        return _scoreMove(game, owner, a);
      case 'split':
        return _scoreSplit(game, owner, a);
      default:
        return 0;
    }
  }

  int _scoreAttack(AimGame game, int owner, Map<String, dynamic> a) {
    final cells = game.cells;
    final i = a['i'] as int, j = a['j'] as int;
    final att = cells[i], t = cells[j];
    if (t.o == owner) return -100; // 不主动自残
    final dmg = kRange.containsKey(att.v) ? 1 : att.v;
    // 远程攻击被盾兵屏障挡下 → 无效
    if (kRange.containsKey(att.v) && game.isShieldCovered(j, i, t)) return -1;
    var score = t.v * 2;
    if (t.v == 7) score += 60;
    if (t.v == 8) score += 120;
    if (t.v == 9) score += 200;
    if (t.v <= dmg) score += 150; // 一击消灭
    if (t.v < dmg) score += 40; // 溢出插桥
    if (level == AiLevel.hard) {
      // 防守分：敌方单位逼近我方基地（3 格内）→ 优先清除
      final myBase = _myBase(game, owner);
      if (myBase != null) {
        final dist = (j - myBase).abs();
        if (dist <= 3) score += (4 - dist) * 25;
      }
    }
    return score;
  }

  int _scoreDevour(AimGame game, int owner, Map<String, dynamic> a) {
    final cells = game.cells;
    final i = a['i'] as int, j = a['j'] as int;
    final me = cells[i], t = cells[j];
    final sum = me.v + t.v;
    var score = 0;
    if (t.o != owner) score += t.v * 4; // 吞敌方 = 消灭威胁
    if (sum >= 9) score += 400; // 指挥
    else if (sum == 8) score += 250; // 基地
    else if (sum >= 6) score += 120;
    else if (t.o == owner) score += 15; // 己方小合成，低优先
    return score;
  }

  int _scoreMove(AimGame game, int owner, Map<String, dynamic> a) {
    final cells = game.cells;
    final i = a['i'] as int;
    final v = cells[i].v;
    final steps = (a['steps'] as int?) ?? 1;
    final dir = owner == 0 ? 1 : -1;
    final newIdx = i + dir * steps;
    var score = 10;
    // 向前推进：越靠近敌方越好
    score += (owner == 0 ? newIdx : cells.length - 1 - newIdx) * 2;
    // 目标格判断
    if (newIdx >= 0 && newIdx < cells.length && cells[newIdx].isB) {
      if (v == 1) score += 20; // 小兵过桥拆桥
      else if (kBridgeOk.contains(v)) score += 5;
      else score -= 800; // 5/7 过桥塌
    }
    if (a['fatal'] == true) score -= 800; // 重单位过桥（塌）
    if (level == AiLevel.hard) {
      // 远程威胁规避：新位置前方有敌方远程单位在射程内 → 减分
      for (int k = 1; k <= 3; k++) {
        final p = newIdx + dir * k;
        if (p < 0 || p >= cells.length) break;
        final c = cells[p];
        if (c.o != null && c.o != owner && c.v >= 1) {
          final r = kRange[c.v] ?? 1;
          if (r >= k) score -= 12 * (r - k + 1);
        }
      }
      // 滚木配合（牢大 08-22：滚木碾单位会升级/插桥，是战术不是公害）
      score += _rollerScore(game, owner, i, v, newIdx);
    }
    return score;
  }

  // ── 滚木战术评分（hard）──
  // 己方滚木每回合朝敌方向滚 3 格：第1/2格压伤（1→5、2→4 升级+插桥），第3格抹杀；撞桥/建筑死
  // 1) 把己方 1/2 移到滚木前第1/2格 = 喂滚木升级刷兵（1→5 净赚4）
  // 2) 己方 ≥4 单位在滚木路径上会被碾亏 → 移走
  // 3) 第3格是死亡区，绝不送单位进去
  int _rollerScore(AimGame game, int owner, int i, int v, int newIdx) {
    final cells = game.cells;
    final dir = owner == 0 ? 1 : -1;
    int? roller;
    for (int k = 0; k < cells.length; k++) {
      final c = cells[k];
      if (c.o == owner && c.v == 6 && c.auto) {
        roller = k;
        break;
      }
    }
    if (roller == null) return 0;
    // 滚木能否滚到 target（路径上无桥/建筑阻挡，且 target 本身不是桥）
    bool clearTo(int target) {
      for (int q = roller! + dir; q != target; q += dir) {
        if (q < 0 || q >= cells.length) return false;
        final c = cells[q];
        if (c.isB || (c.o != null && c.v >= 8)) return false; // 桥/建筑阻挡
      }
      if (target < 0 || target >= cells.length) return false;
      return !cells[target].isB; // 目标本身不能是桥（站桥=撞桥）
    }
    var score = 0;
    for (int k = 1; k <= 3; k++) {
      final p = roller + dir * k;
      if (p < 0 || p >= cells.length) continue;
      if (p == newIdx) {
        // 单位将移到滚木路径上
        if (!clearTo(p)) continue; // 滚木到不了，无意义
        if (k <= 2) {
          if (v == 1) score += 110; // 1 被碾 → 5（净赚4）
          else if (v == 2) score += 55; // 2 → 4（净赚2）
          else if (v == 3) score -= 10; // 3 → 3 白挨一下
          else score -= 160; // ≥4 被碾降级/死
        } else {
          score -= 200; // 第3格抹杀
        }
      }
      // 己方大单位当前在滚木路径上（会被碾亏）→ 移走
      if (p == i && k <= 2 && v >= 4 && clearTo(p)) {
        score += 90;
      }
    }
    return score;
  }

  int _scoreSplit(AimGame game, int owner, Map<String, dynamic> a) {
    final cells = game.cells;
    final i = a['i'] as int;
    final dir = owner == 0 ? 1 : -1;
    final j = i + dir;
    final keep = (a['keep'] as int?) ?? 1;
    // 拆出轻单位（1-3）过桥 → 有用
    if (j >= 0 && j < cells.length && cells[j].isB && kBridgeOk.contains(keep)) {
      return 60;
    }
    if (cells[i].v >= 8) return -40; // 别拆基地/指挥部
    return 0;
  }

  // 我方基地位置（首个 8）
  int? _myBase(AimGame game, int owner) {
    final cells = game.cells;
    for (int k = 0; k < cells.length; k++) {
      if (cells[k].o == owner && cells[k].v == 8) return k;
    }
    return null;
  }
}
