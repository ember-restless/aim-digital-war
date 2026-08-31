// 热座：主页直开 → 选地图 → 本地规则引擎直接进对局（断网可玩）
// 数据源 = LocalAimSocket（本地引擎），不连任何服务器
// 支持双人（热座）或 玩家 vs AI（aiLevel 非空，AI 为玩家1）
import 'package:flutter/material.dart';

import '../game/ai.dart';
import '../game/rules.dart';
import '../game/tips.dart';
import '../net/local_socket.dart';
import '../core/bgm_manager.dart';
import 'game_screen.dart';

const _ink = Color(0xFF11110F);
const _paper = Color(0xFFFFF5DC);
const _signal = Color(0xFFFF4E35);
const _dim = Color(0xFF77736B);
const _warn = Color(0xFFFFD36A);
const _border = Color(0xFF5A554C);

class HotseatScreen extends StatefulWidget {
  final String playerName;
  final String packId;
  final int limit;
  final bool allowOwnRollerAttack; // 规则开关：己方能否攻击己方滚木
  final AiLevel? aiLevel; // null=双人热座；非 null=玩家 vs AI
  final Map<String, dynamic>? Function(AimGame game)? aiDecider; // αβ 等自定义 AI（优先于 aiLevel）
  final int humanSide; // 人类所在侧（0=左，1=右）；AI 在另一侧
  const HotseatScreen({super.key, required this.playerName, required this.packId, required this.limit, this.allowOwnRollerAttack = true, this.aiLevel, this.aiDecider, this.humanSide = 0});

  @override
  State<HotseatScreen> createState() => _HotseatScreenState();
}

class _HotseatScreenState extends State<HotseatScreen> {
  late LocalAimSocket socket;
  dynamic gameState;
  dynamic gameOver;

  @override
  void initState() {
    super.initState();
    socket = LocalAimSocket(
        limit: widget.limit,
        allowOwnRollerAttack: widget.allowOwnRollerAttack,
        aiLevel: widget.aiLevel,
        aiDecider: widget.aiDecider,
        humanSide: widget.humanSide);
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
    socket.connect();
  }

  void _back() {
    socket.dispose();
    BgmManager.instance.playIdle(); // 对局退出回主页：BGM 切回非战斗
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (gameState != null) {
      return GameScreen(
        socket: socket,
        state: gameState,
        packId: widget.packId,
        over: gameOver,
        onBack: _back,
      );
    }
    return Scaffold(
      body: Container(
        color: _ink,
        child: SafeArea(
          child: Center(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              _pt('🔥 ${(widget.aiLevel == null && widget.aiDecider == null) ? '热座' : '人机对战'}', 22, _signal, bold: true),
              const SizedBox(height: 8),
              _pt('${(widget.aiLevel == null && widget.aiDecider == null) ? '双人轮流 · 地图' : '玩家 vs AI · 地图'} ${widget.limit} 格', 13, _dim),
              if (widget.aiLevel != null || widget.aiDecider != null) ...[
                const SizedBox(height: 4),
                _pt('对手：${widget.aiDecider != null ? 'αβ·剪枝大师' : _aiName(widget.aiLevel!)} · 我执${widget.humanSide == 0 ? '左' : '右'}', 12, _paper),
              ],
              const SizedBox(height: 16),
              const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(color: _signal, strokeWidth: 2)),
              const SizedBox(height: 20),
              // 加载小贴士
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(children: [
                  _pt('Tip:', 11, _warn, bold: true),
                  const SizedBox(height: 4),
                  _pt(randomTip().text, 12, _dim),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _pt(String s, double size, Color c, {bool bold = false}) {
    return Text(s, style: TextStyle(color: c, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal, height: 1.2));
  }

  String _aiName(AiLevel l) {
    switch (l) {
      case AiLevel.easy:
        return 'AI·简单（萌新）';
      case AiLevel.normal:
        return 'AI·普通（老兵）';
      case AiLevel.hard:
        return 'AI·困难（军团）';
    }
  }
}
