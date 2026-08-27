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

  TrainAi({AiLevel fallback = AiLevel.hard}) {
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
    if (!hasModel || _fallback == null) return _fallback?.decide(game);
    final owner = game.turn;
    if (game.phase == null) {
      // 阶段选择：用启发式（网络只做行动/造兵内部选择）
      return _fallback!.decide(game);
    }
    final acts = game.getLegalActions(owner);
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
    for (final a in playable) {
      final slot = _actionSlot(a);
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
    if (_rand.nextDouble() < 0.08 && cands.isNotEmpty) {
      return cands[_rand.nextInt(cands.length)];
    }
    return bestAct ?? playable.first;
  }

  // ── 前向传播：relu(relu(x·W1+b1)·W2+b2)·Wo+bo ──
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

  // ── 状态编码：53 维 ──
  List<double> _encode(AimGame game) {
    final x = <double>[];
    for (final c in game.cells) {
      x.add(c.v / 9.0);
      x.add(c.o == 0 ? 1.0 : 0.0);
      x.add(c.o == 1 ? 1.0 : 0.0);
      x.add(c.bridge ? 1.0 : 0.0);
      x.add(c.onBridge ? 1.0 : 0.0);
      x.add(c.auto ? 1.0 : 0.0);
    }
    x.add(game.turn.toDouble());
    x.add(game.phase == 'action' ? 1.0 : 0.0);
    x.add(game.phase == 'produce' ? 1.0 : 0.0);
    x.add(game.points / 10.0);
    x.add(game.produceLeft / 8.0);
    return x;
  }

  // ── 动作 → 槽位（49）──
  int? _actionSlot(Map<String, dynamic> a) {
    final t = a['type'] as String?;
    final i = a['i'] is num ? (a['i'] as num).toInt() : -1;
    if (i < 0 || i >= 8) return null;
    switch (t) {
      case 'move':
        final steps = a['steps'] is num ? (a['steps'] as num).toInt() : 1;
        return i * 6 + (steps >= 2 ? 1 : 0);
      case 'attack':
        return i * 6 + 2;
      case 'devour':
        return i * 6 + 3;
      case 'split':
        return i * 6 + 4;
      case 'produce':
        return i * 6 + 5;
      case 'endTurn':
        return 48;
      default:
        return null;
    }
  }
}
