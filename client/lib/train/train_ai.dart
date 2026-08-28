// 训练场 AI：从服务器拉取训练好的权重（MLP），推理决策
// 无权重/加载失败 → 回退到现有 hard 启发式
// 网络约定（与 train/train_bc.py 一致）：
//   输入 53 维 = 8 格 × 6 特征（v/9, o0, o1, bridge, onBridge, auto）+ 5 全局（turn, phaseA, phaseP, points/10, produceLeft/8）
//   输出 49 槽位 = 8 格 × 6 操作（move1, move2, attack, devour, split, produce）+ endTurn
//   权重 JSON：{"version":1,"updatedAt":"...","in":53,"hidden":64,"out":49,
//               "w1":[flat],"b1":[...],"w2":[flat],"b2":[...],"wo":[flat],"bo":[...]}
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../game/ai.dart';
import '../game/rules.dart';

class TrainAi {
  List<double>? _w1, _b1, _w2, _b2, _wo, _bo;
  int _in = 0, _hidden = 0, _out = 0;
  int? _version;
  AimAi? _fallback;
  final math.Random _rand = math.Random();
  final bool explore; // 小概率随机探索（保持训练数据多样性）；测试传 false

  TrainAi({AiLevel fallback = AiLevel.hard, this.explore = true}) {
    _fallback = AimAi(fallback);
  }

  bool get hasModel => _w1 != null;
  int? get version => _version;
  int get outSlots => _out;

  // 从服务器拉权重（失败静默回退 hard）
  Future<void> loadFromUrl(String url) async {
    try {
      final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return;
      loadFromJson(jsonDecode(resp.body) as Map<String, dynamic>);
    } catch (_) {
      _clear();
    }
  }

  // 直接加载权重 JSON（测试/本地用）
  void loadFromJson(Map<String, dynamic> j) {
    _in = (j['in'] as num?)?.toInt() ?? 0;
    _hidden = (j['hidden'] as num?)?.toInt() ?? 0;
    _out = (j['out'] as num?)?.toInt() ?? 0;
    _version = (j['version'] as num?)?.toInt();
    _w1 = _flat(j['w1']);
    _b1 = _flat(j['b1']);
    _w2 = _flat(j['w2']);
    _b2 = _flat(j['b2']);
    _wo = _flat(j['wo']);
    _bo = _flat(j['bo']);
    if (_in <= 0 || _out <= 0 || _w1 == null) _clear();
  }

  void _clear() {
    _w1 = _b1 = _w2 = _b2 = _wo = _bo = null;
    _in = _hidden = _out = 0;
  }

  List<double>? _flat(dynamic v) {
    if (v is! List || v.isEmpty) return null;
    try {
      return v.map((e) => (e as num).toDouble()).toList();
    } catch (_) {
      return null;
    }
  }

  // AI 回合决策（训练场用）
  Map<String, dynamic>? decide(AimGame game) {
    final owner = game.turn;
    if (game.phase == null) {
      // 基地没了 / 基地前被桥堵 → 造兵阶段无意义（造兵点=0，选完直接自动过回合=「跳过回合」）
      // 该拦截必须在 hasModel 检查之前：无模型（回退启发式）时同样生效
      if (!_canProduce(game, owner)) {
        return {'type': 'choosePhase', 'phase': 'action'};
      }
    }
    if (!hasModel || _fallback == null) return _fallback?.decide(game);
    if (game.phase == null) {
      // 2026-08-28 阶段选择交给网络（牢大定）：候选 = 行动类 + 造兵类并集，
      // 与训练端一致（phase=null 输入 two-hot 全 0），选出的动作类型隐含阶段选择，
      // 规则层 applyAction 会自动 doChoosePhase。
      final acts = <Map<String, dynamic>>[];
      // 行动类候选：phase=null 时 getLegalActions 返回 choosePhase×2 + 行动类（points 未初始化），
      // 直接过滤掉 choosePhase/endTurn 即可得到行动类
      acts.addAll(game.getLegalActions(owner)
          .where((a) => a['type'] != 'choosePhase' && a['type'] != 'endTurn'));
      // 造兵类候选：phase=null 时 getLegalActions 不含 produce，手动枚举（与规则 produce 分支一致）
      final dir = owner == 0 ? 1 : -1;
      for (var i = 0; i < game.cells.length; i++) {
        final c = game.cells[i];
        if (c.o == owner && c.v == 8) {
          final j = i + dir;
          if (j >= 0 && j < game.cells.length && !game.cells[j].bridge) {
            acts.add({'type': 'produce', 'i': i, 'j': j});
          }
        }
      }
      if (acts.isEmpty) return {'type': 'choosePhase', 'phase': 'action'};
      final x = _encode(game); // phase=null → 编码 two-hot 全 0，与训练一致
      final logits = _forward(x);
      if (logits == null) return _fallback!.decide(game);
      double best = -1e18;
      Map<String, dynamic>? bestAct;
      final cands = <Map<String, dynamic>>[];
      final flip = game.turn == 1;
      for (final a in acts) {
        final slot = _actionSlot(a, flip, game);
        if (slot == null || slot >= logits.length) continue;
        final s = logits[slot];
        if (s > best) {
          best = s;
          bestAct = a;
        }
        cands.add(a);
      }
      if (explore && _rand.nextDouble() < 0.08 && cands.isNotEmpty) {
        return cands[_rand.nextInt(cands.length)];
      }
      return bestAct ?? acts.first;
    }
    final acts = game.getLegalActions(owner);
    // 不做硬性动作过滤——坏习惯（打自己/乱拆）交由学习阶段纠正（RL 奖励惩罚）
    final playable = acts.where((a) => a['type'] != 'endTurn').toList();
    if (playable.isEmpty) return {'type': 'endTurn'};
    final x = _encode(game);
    final logits = _forward(x);
    if (logits == null) return _fallback!.decide(game);
    // 合法动作映射到槽位，取最高分（带温度软化避免死板）
    double best = -1e18;
    Map<String, dynamic>? bestAct;
    final cands = <Map<String, dynamic>>[];
    final temps = <double>[];
    final flip = game.turn == 1; // 我方在右 → 槽位镜像
    for (final a in playable) {
      final slot = _actionSlot(a, flip, game);
      if (slot == null || slot >= logits.length) continue;
      final s = logits[slot];
      if (s > best) {
        best = s;
        bestAct = a;
      }
      cands.add(a);
      temps.add(s);
    }
    // 小概率探索（0.08）随机选合法行动，保持数据多样性
    if (explore && _rand.nextDouble() < 0.08 && cands.isNotEmpty) {
      return cands[_rand.nextInt(cands.length)];
    }
    return bestAct ?? playable.first;
  }

  // 能否造兵：有基地 8 且基地前（朝敌方向）不是桥
  // doProduce 逻辑：基地前空地/己方 → +1；敌方 → 攻击 -1；桥 → 不合法
  bool _canProduce(AimGame game, int owner) {
    final dir = owner == 0 ? 1 : -1;
    for (var i = 0; i < game.cells.length; i++) {
      final c = game.cells[i];
      if (c.o == owner && c.v == 8) {
        final j = i + dir;
        if (j >= 0 && j < game.cells.length) {
          if (!game.cells[j].bridge) return true;
        }
      }
    }
    return false;
  }

  // 前向传播：relu(relu(x·W1+b1)·W2+b2)·Wo+bo ──
  List<double>? _forward(List<double> x) {
    final w1 = _w1, b1 = _b1, w2 = _w2, b2 = _b2, wo = _wo, bo = _bo;
    if (w1 == null || b1 == null || w2 == null || b2 == null || wo == null || bo == null) return null;
    if (x.length != _in) return null;
    final h1 = List<double>.filled(_hidden, 0);
    for (var i = 0; i < _hidden; i++) {
      var s = b1[i];
      for (var k = 0; k < _in; k++) {
        s += x[k] * w1[i * _in + k];
      }
      h1[i] = s > 0 ? s : 0; // relu
    }
    final h2 = List<double>.filled(_hidden, 0);
    for (var i = 0; i < _hidden; i++) {
      var s = b2[i];
      for (var k = 0; k < _hidden; k++) {
        s += h1[k] * w2[i * _hidden + k];
      }
      h2[i] = s > 0 ? s : 0;
    }
    final out = List<double>.filled(_out, 0);
    for (var i = 0; i < _out; i++) {
      var s = bo[i];
      for (var k = 0; k < _hidden; k++) {
        s += h2[k] * wo[i * _hidden + k];
      }
      out[i] = s;
    }
    return out;
  }

  // ── 状态编码：53 维（视角归一化——统一为「我方在左」，左右对称）──
  // 我方 = game.turn；若我方在右（turn==1）→ 逆序读格子，让模型看到的永远是「我方在左」的棋盘
  // 格子数可能因插桥/吞噬变化，固定取前 8 格（与训练一致）
  List<double> _encode(AimGame game) {
    final me = game.turn;
    final flip = me == 1; // 我方在右 → 翻成左视角
    final cells = (flip ? game.cells.reversed.toList() : game.cells).take(8).toList();
    final x = <double>[];
    for (final c in cells) {
      x.add(c.v / 9.0);
      x.add(c.o == me ? 1.0 : 0.0);
      x.add(c.o != null && c.o != me ? 1.0 : 0.0);
      x.add(c.bridge ? 1.0 : 0.0);
      x.add(c.onBridge ? 1.0 : 0.0);
      x.add(c.auto ? 1.0 : 0.0);
    }
    while (x.length < 48) {
      x.addAll([0.0, 0.0, 0.0, 0.0, 0.0, 0.0]); // 格子不足 8 格补零
    }
    x.add(0.0); // 归一化视角下我方恒为玩家0（turn）
    x.add(game.phase == 'action' ? 1.0 : 0.0);
    x.add(game.phase == 'produce' ? 1.0 : 0.0);
    x.add(game.points / 10.0);
    x.add(game.produceLeft / 8.0);
    return x;
  }

  // ── 动作 → 槽位（97，视角归一化：翻转时格子索引镜像）──
  // 每格 12 槽：move1, move2, atk敌1..3, atk己1..3, dev敌, dev己, split, produce
  // 攻击/吞噬按「目标敌我 × 距离」细分，AI 能明确指定打谁（此前打谁随机落点→疯狂打己方）
  int? _actionSlot(Map<String, dynamic> a, bool flip, AimGame game) {
    final t = a['type'] as String?;
    var i = a['i'] is num ? (a['i'] as num).toInt() : -1;
    if (i < 0 || i >= 8) return null;
    if (flip) i = 7 - i; // 我方在右：棋盘镜像，格子索引翻转
    switch (t) {
      case 'move':
        final steps = a['steps'] is num ? (a['steps'] as num).toInt() : 1;
        return i * 12 + (steps >= 2 ? 1 : 0);
      case 'attack':
        final j = a['j'] is num ? (a['j'] as num).toInt() : -1;
        final k = (j - (a['i'] as num).toInt()).abs(); // 目标距离 1..3（翻转不变）
        if (k < 1 || k > 3) return null;
        final isEnemy = j >= 0 && j < game.cells.length &&
            game.cells[j].o != null && game.cells[j].o != game.turn;
        return i * 12 + (isEnemy ? 2 + (k - 1) : 5 + (k - 1));
      case 'devour':
        final j = a['j'] is num ? (a['j'] as num).toInt() : -1;
        final isEnemy = j >= 0 && j < game.cells.length &&
            game.cells[j].o != null && game.cells[j].o != game.turn;
        return i * 12 + (isEnemy ? 8 : 9);
      case 'split':
        return i * 12 + 10;
      case 'produce':
        return i * 12 + 11;
      case 'endTurn':
        return 96;
      default:
        return null;
    }
  }
}
