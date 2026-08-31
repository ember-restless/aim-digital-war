// Alpha-Beta 剪枝 AI（Dart 移植版）—— 评估函数 + 搜索逻辑与 Python 端一致
// Python 原型: /root/aim/train/alphabeta_ai.py + mcts_ai.py
// 评估：牢大价值表 V_TABLE（8=30,9=30,7=17...非线性，惩罚乱拆）+ 六特征加权
// 用法：final ai = AlphaBetaAi(depth: 4, timeBudgetMs: 1000);
//       final action = ai.decide(game);
import 'rules.dart';

// ── 牢大价值表：1有1分，2有3分，3有6分，4有10分，5有16分，6没分，7有17分，8有30分，9有30分 ──
const Map<int, int> kVTable = {0: 0, 1: 1, 2: 3, 3: 6, 4: 10, 5: 16, 6: 0, 7: 17, 8: 30, 9: 30};

// ── 评估函数权重（牢大拍板 + 价值表修正）──
const double kWVal = 0.35; // 单位价值差
const double kWMax = 0.20; // 尖峰数字差
const double kWUnits = 0.15; // 兵力差
const double kWAp = 0.15; // 行动点差（9 数+1）
const double kWpp = 0.05; // 造兵点差（8 数=基地）
const double kWDist = 0.10; // 距离差

const double kWinV = 1000.0; // 终局分
const double kEps = 1e-9;

int sideValue(AimGame g, int owner) {
  var s = 0;
  for (final c in g.cells) {
    if (g.isOwnedUnit(c, owner)) {
      s += kVTable[c.v] ?? c.v;
    }
  }
  return s;
}

int? nearestToBase(AimGame g, int owner) {
  final eBase = owner == 0 ? g.cells.length - 1 : 0;
  int? best;
  for (var i = 0; i < g.cells.length; i++) {
    if (g.isOwnedUnit(g.cells[i], owner)) {
      final d = (i - eBase).abs();
      if (best == null || d < best) best = d;
    }
  }
  return best;
}

// 全体单位到对方基地的平均距离（全员推进度：后排不动就拖后腿）
double? avgDistToBase(AimGame g, int owner) {
  final eBase = owner == 0 ? g.cells.length - 1 : 0;
  var sum = 0, n = 0;
  for (var i = 0; i < g.cells.length; i++) {
    if (g.isOwnedUnit(g.cells[i], owner)) {
      sum += (i - eBase).abs();
      n++;
    }
  }
  return n == 0 ? null : sum / n;
}

double evaluate(AimGame g, int me) {
  if (g.winner != null) return g.winner == me ? kWinV : -kWinV;
  final e = 1 - me;
  // 敌方单位价值按 1.5 倍计（牢大定）：消灭敌方收益放大 → 进攻倾向增强
  final dVal = (sideValue(g, me) - 1.5 * sideValue(g, e)) / 100.0;
  var mxMe = 0, mxE = 0;
  for (final c in g.cells) {
    if (g.isOwnedUnit(c, me) && c.v > mxMe) mxMe = c.v;
    if (g.isOwnedUnit(c, e) && c.v > mxE) mxE = c.v;
  }
  final dMax = (mxMe - mxE) / 9.0;
  var uMe = 0, uE = 0;
  for (final c in g.cells) {
    if (g.isOwnedUnit(c, me)) uMe++;
    if (g.isOwnedUnit(c, e)) uE++;
  }
  final dUnits = (uMe - uE) / 8.0;
  final dAp = (g.countOf(me, 9) - g.countOf(e, 9)) / 9.0;
  final dpp = (g.countOf(me, 8) - g.countOf(e, 8)) / 8.0;
  // 距离：前锋最近单位 + 全员平均推进 各一半（前锋敢摸，大部队跟得上）
  var dDist = 0.0;
  final a = nearestToBase(g, me);
  final b = nearestToBase(g, e);
  final am = avgDistToBase(g, me);
  final bm = avgDistToBase(g, e);
  if (a != null && b != null) dDist += ((b - a) / 16.0) * 0.5;
  if (am != null && bm != null) dDist += ((bm - am) / 16.0) * 0.5;
  final power = kWVal * dVal +
      kWMax * dMax +
      kWUnits * dUnits +
      kWAp * dAp +
      kWpp * dpp +
      kWDist * dDist;
  return power.clamp(-kWinV, kWinV);
}

/// 当前局面候选动作（与训练端一致：阶段选择交给动作本身，produce 手动补）
(List<Map<String, dynamic>>, bool) abCandidates(AimGame g) {
  final me = g.turn;
  if (g.winner != null) return (<Map<String, dynamic>>[], true);
  if (g.phase == null) {
    final acts = <Map<String, dynamic>>[];
    for (final a in g.getLegalActions(me)) {
      final t = a['type'];
      if (t != 'choosePhase' && t != 'endTurn') acts.add(a);
    }
    final d = me == 0 ? 1 : -1;
    for (var i = 0; i < g.cells.length; i++) {
      final c = g.cells[i];
      if (c.o == me && c.v == 8) {
        final j = i + d;
        if (j >= 0 && j < g.cells.length && !g.cells[j].bridge) {
          acts.add({'type': 'produce', 'i': i, 'j': j});
        }
      }
    }
    return (acts, false);
  }
  final acts = g.getLegalActions(me);
  final playable = <Map<String, dynamic>>[
    for (final a in acts)
      if (a['type'] != 'endTurn') a,
  ];
  return (playable, playable.isEmpty);
}

/// 应用动作 + 推进滚木；返回是否合法（Python _apply_and_roll 同款）
bool abApplyAndRoll(AimGame g, int owner, Map<String, dynamic> action) {
  final r = g.applyAction(owner, action, deferRoll: true);
  if (r['ok'] != true) return false;
  while (g.hasPendingRoll) {
    if (g.rollStepOnce(g.turn) == null) {
      g.clearPendingRoll();
      break;
    }
  }
  if (g.winner == null) g.checkWin();
  return true;
}

// ── 启发式排序（剪枝友好；与 Python _heuristic_score 对齐）──
double heuristicScore(Map<String, dynamic> a, AimGame g, int me) {
  final t = a['type'] as String;
  double s = 0;
  switch (t) {
    case 'devour':
      s = 100;
      final j = a['j'] as int? ?? -1;
      if (j >= 0 && j < g.cells.length) s += g.cells[j].v * 3;
      break;
    case 'attack':
      s = 30;
      final j = a['j'] as int? ?? -1;
      if (j >= 0 && j < g.cells.length) {
        final tv = g.cells[j].v;
        if (tv == 8) {
          s += 80;
        } else if (tv >= 7) {
          s += 40;
        } else if (tv >= 4) {
          s += 15;
        } else {
          s += 5;
        }
      }
      break;
    case 'produce':
      s = 12;
      break;
    case 'move':
      s = 6;
      final i = a['i'] as int? ?? -1;
      final steps = a['steps'] as int? ?? 1;
      s += steps * 3;
      if (i >= 0 && i < g.cells.length) {
        if (me == 0) {
          s += i * 0.1;
        } else {
          s += (g.cells.length - 1 - i) * 0.1;
        }
      }
      break;
    case 'split':
      s = 1;
      break;
  }
  return s;
}

class AlphaBetaAi {
  final int depth;
  final int timeBudgetMs; // 每步决策预算（毫秒）
  int nodes = 0;
  double lastThinkMs = 0;
  int? _deadlineMs;

  AlphaBetaAi({this.depth = 4, this.timeBudgetMs = 1000});

  /// 当前局面决策，返回一个动作（Map）。
  Map<String, dynamic>? decide(AimGame game) {
    final sw = Stopwatch()..start();
    // 注意：必须用绝对时间做预算（DateTime 基准），不能用 sw.elapsed 跟 now 比较
    _deadlineMs = DateTime.now().millisecondsSinceEpoch + timeBudgetMs;
    nodes = 0;
    final me = game.turn;
    final (acts, mustEnd) = abCandidates(game);
    if (mustEnd || acts.isEmpty) return {'type': 'endTurn'};
    if (acts.length == 1) return acts[0];
    acts.sort((a, b) => heuristicScore(b, game, me).compareTo(heuristicScore(a, game, me)));
    Map<String, dynamic>? bestA;
    var bestV = -1e18;
    for (final a in acts) {
      final g2 = game.clone();
      if (!abApplyAndRoll(g2, me, a)) continue;
      final v = _search(g2, depth - 1, -1e18, 1e18, me);
      if (v > bestV) {
        bestV = v;
        bestA = a;
      }
    }
    lastThinkMs = sw.elapsedMilliseconds.toDouble();
    return bestA ?? acts.first;
  }

  double _search(AimGame game, int depth, double alpha, double beta, int me) {
    nodes++;
    if (game.winner != null) return game.winner == me ? kWinV : -kWinV;
    if (depth <= 0) return evaluate(game, me);
    if (_deadlineMs != null && DateTime.now().millisecondsSinceEpoch > _deadlineMs!) {
      return evaluate(game, me); // 超时截断
    }
    final owner = game.turn;
    final (acts, mustEnd) = abCandidates(game);
    if (mustEnd || acts.isEmpty) {
      final g2 = game.clone();
      if (abApplyAndRoll(g2, owner, {'type': 'endTurn'})) {
        return _search(g2, depth - 1, alpha, beta, me);
      }
      return evaluate(game, me);
    }
    acts.sort((a, b) => heuristicScore(b, game, owner).compareTo(heuristicScore(a, game, owner)));
    final isMax = owner == me;
    if (isMax) {
      var best = -1e18;
      for (final a in acts) {
        final g2 = game.clone();
        if (!abApplyAndRoll(g2, owner, a)) continue;
        final v = _search(g2, depth - 1, alpha, beta, me);
        if (v > best) best = v;
        if (best > alpha) alpha = best;
        if (beta <= alpha) break;
      }
      return best;
    } else {
      var best = 1e18;
      for (final a in acts) {
        final g2 = game.clone();
        if (!abApplyAndRoll(g2, owner, a)) continue;
        final v = _search(g2, depth - 1, alpha, beta, me);
        if (v < best) best = v;
        if (best < beta) beta = best;
        if (beta <= alpha) break;
      }
      return best;
    }
  }
}
