// AI 训练场：独立对战页面（玩家 vs AI）
// - AI 使用服务器训练权重（TrainAi，无权重回退 hard 启发式）
// - 对局中记录人类每步操作，结束后上传服务器（行为克隆数据）
// - 顶部实时显示训练统计（局数/步数/模型版本）
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/bgm_manager.dart';
import '../core/config.dart';
import '../game/ai.dart';
import '../net/local_socket.dart';
import '../train/train_ai.dart';
import 'game_screen.dart';

const _ink = Color(0xFF11110F);
const _paper = Color(0xFFFFF5DC);
const _signal = Color(0xFFFF4E35);
const _dim = Color(0xFF77736B);
const _warn = Color(0xFFFFD36A);
const _green = Color(0xFF5AC87A);

class TrainScreen extends StatefulWidget {
  const TrainScreen({super.key});

  @override
  State<TrainScreen> createState() => _TrainScreenState();
}

class _TrainScreenState extends State<TrainScreen> {
  late LocalAimSocket socket;
  final TrainAi trainAi = TrainAi();
  dynamic gameState;
  dynamic gameOver;
  bool _aiReady = false;
  bool _uploading = false;
  String _uploadMsg = '';
  int _games = 0;
  int _steps = 0;
  int _modelVersion = 0;
  bool _training = false;
  Timer? _statsTimer;

  @override
  void initState() {
    super.initState();
    _initAi();
    _refreshStats();
    _newGame();
    // 轮询训练统计：新对局/训练完成自动刷新页面
    _statsTimer = Timer.periodic(const Duration(seconds: 12), (_) => _refreshStats());
  }

  Future<void> _initAi() async {
    await trainAi.loadFromUrl('${AppConfig.serverUrl}/downloads/train_weights.json');
    if (mounted) setState(() => _aiReady = true);
  }

  void _newGame() {
    socket = LocalAimSocket(limit: 16, aiLevel: AiLevel.hard);
    socket.recordMode = true;
    socket.aiDecider = trainAi.hasModel ? trainAi.decide : null;
    socket.onEvent = (event, data) {
      if (!mounted) return;
      if (event == 'game_state') {
        setState(() => gameState = data);
      } else if (event == 'game_over') {
        setState(() => gameOver = data);
      }
    };
    socket.onServerError = (msg) {
      // 本地非法操作静默（GameScreen 已限制可执行操作）
    };
    socket.onGameRecorded = _uploadGame;
    socket.connect();
  }

  // 对局结束：上传数据 + 刷新统计
  Future<void> _uploadGame(Map<String, dynamic> data) async {
    if (_uploading) return;
    _uploading = true;
    try {
      final resp = await http
          .post(Uri.parse('${AppConfig.serverUrl}/api/train/upload'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(data))
          .timeout(const Duration(seconds: 10));
      final ok = resp.statusCode == 200;
      if (mounted) {
        setState(() {
          _uploadMsg = ok ? '✓ 第 ${_games + 1} 局已上传' : '上传失败';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _uploadMsg = '上传失败（网络？）');
    }
    _uploading = false;
    _refreshStats();
  }

  Future<void> _refreshStats() async {
    try {
      final resp = await http
          .get(Uri.parse('${AppConfig.serverUrl}/api/train/stats'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final newVer = (j['modelVersion'] as num?)?.toInt() ?? 0;
        if (mounted) {
          setState(() {
            _games = (j['games'] as num?)?.toInt() ?? 0;
            _steps = (j['steps'] as num?)?.toInt() ?? 0;
            _training = j['training'] == true;
            // 模型版本变化 → 拉新权重（对局中 AI 自动切到新模型）
            if (newVer != _modelVersion) {
              _modelVersion = newVer;
              if (newVer > 0) _reloadModel();
            }
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _reloadModel() async {
    await trainAi.loadFromUrl('${AppConfig.serverUrl}/downloads/train_weights.json');
    if (mounted && _modelVersion > 0 && trainAi.hasModel) {
      setState(() => _uploadMsg = '✨ AI 已升级到模型 v$_modelVersion');
      // 提醒一次后清掉（避免常驻）
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _uploadMsg = '');
      });
    }
  }

  void _back() {
    socket.dispose();
    BgmManager.instance.playIdle();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: _ink,
        child: SafeArea(
          child: gameState != null
              ? Stack(children: [
                  Column(children: [
                    _statsBar(),
                    Expanded(
                      child: GameScreen(
                        socket: socket,
                        state: gameState,
                        packId: 'train',
                        over: gameOver,
                        onBack: _newGame, // 结算页「返回」= 再来一局；退出走统计条按钮
                      ),
                    ),
                  ]),
                ])
              : Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(color: _signal, strokeWidth: 2)),
                    const SizedBox(height: 16),
                    _pt('训练场加载中…', 13, _dim),
                    const SizedBox(height: 8),
                    _pt(_aiReady ? (trainAi.hasModel ? 'AI：模型 v${trainAi.version}' : 'AI：启发式（未训练）') : 'AI 模型加载中…', 12, _warn),
                  ]),
                ),
        ),
      ),
    );
  }

  // ── 顶部统计条：训练局数 / 步数 / 模型版本 / 训练状态 ──
  Widget _statsBar() {
    final aiName = trainAi.hasModel ? 'AI·模型 v${trainAi.version}' : 'AI·启发式';
    return Container(
      color: const Color(0xFF1A1916),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        _pt('🧪 训练场', 14, _signal, bold: true),
        const SizedBox(width: 14),
        _pt('局数 $_games', 12, _paper),
        const SizedBox(width: 12),
        _pt('步数 $_steps', 12, _paper),
        const SizedBox(width: 12),
        _pt(aiName, 12, _warn),
        if (_training) ...[
          const SizedBox(width: 10),
          _pt('训练中…', 12, const Color(0xFF7FD8FF)),
        ],
        const Spacer(),
        if (_uploadMsg.isNotEmpty) _pt(_uploadMsg, 11, _green),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _newGame,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2824),
              border: Border.all(color: const Color(0xFF5A554C)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: _pt('再来一局', 12, _paper),
          ),
        ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: _back,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2824),
              border: Border.all(color: const Color(0xFF5A554C)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: _pt('退出', 12, _paper),
          ),
        ),
      ]),
    );
  }

  Widget _pt(String s, double size, Color c, {bool bold = false}) {
    return Text(s,
        style: TextStyle(color: c, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal, height: 1.2));
  }
}
