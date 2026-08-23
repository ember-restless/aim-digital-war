// 对局结束动画（v3）：无彩色，纯白粒子
// 胜利：白色数字从底部向上喷溅（地面烟花/喷泉），循环
// 失败：白色数字雨从顶部下落 + 随机白闪（打雷），循环
// 返回按钮常驻，点击即退出；动画一直播到玩家点返回
// v3 优化：粒子层改 CustomPaint（单 widget + repaint 监听，不再每帧重建数百 Text widget）+ 可滚动布局防按钮溢出
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

const _paper = Color(0xFFFFF5DC);

class GameOverAnim extends StatefulWidget {
  final bool win;
  final String title; // 胜 利 / 败 北 / 左胜 / 右胜
  final String sub; // 副文案
  final VoidCallback onBack;
  final dynamic state; // 最后一个 game_state（含 stats/turnCount/cells/names，结算统计用）
  const GameOverAnim({super.key, required this.win, required this.title, required this.sub, required this.onBack, this.state});

  @override
  State<GameOverAnim> createState() => _GameOverAnimState();
}

class _GameOverAnimState extends State<GameOverAnim> with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 16))
    ..repeat();
  late final AnimationController _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))
    ..forward();
  late final AnimationController _btn = AnimationController(vsync: this, duration: const Duration(milliseconds: 400))
    ..forward();
  final _rnd = math.Random(20260815);
  final List<_Particle> _parts = [];
  double _flash = 0; // 雷闪强度 0~1
  Timer? _flashTimer;
  double _t = 0;
  double _w = 640, _h = 400; // 画布实际尺寸（build 时从 LayoutBuilder 更新）

  @override
  void initState() {
    super.initState();
    _c.addListener(_tick);
    if (!widget.win) {
      _scheduleFlash();
    }
  }

  void _scheduleFlash() {
    _flashTimer?.cancel();
    _flashTimer = Timer(Duration(milliseconds: 1000 + _rnd.nextInt(2200)), () {
      if (!mounted) return;
      // 双闪：亮 → 灭 → 再亮 → 灭
      setState(() => _flash = 0.9);
      _flashTimer = Timer(const Duration(milliseconds: 90), () {
        if (!mounted) return;
        setState(() => _flash = 0);
        _flashTimer = Timer(const Duration(milliseconds: 70), () {
          if (!mounted) return;
          setState(() => _flash = 0.65);
          _flashTimer = Timer(const Duration(milliseconds: 130), () {
            if (!mounted) return;
            setState(() => _flash = 0);
            _scheduleFlash();
          });
        });
      });
    });
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _c.removeListener(_tick);
    _c.dispose();
    _pop.dispose();
    _btn.dispose();
    super.dispose();
  }

  // 只更新粒子数据，不 setState——粒子层由 CustomPainter(repaint: _c) 每帧重绘
  void _tick() {
    _t += 1 / 60;
    if (widget.win) {
      // 胜利：烟花——从底部正中一个点，朝竖直方向 ±30° 锥形内快速射出
      if (_rnd.nextDouble() < 0.6) {
        final n = 2 + _rnd.nextInt(3); // 每帧喷 2~4 个
        for (int k = 0; k < n; k++) {
          final ang = math.pi * 1.5 + (_rnd.nextDouble() - 0.5) * (math.pi / 3); // 竖直向上 ±30°
          final spd = 240 + _rnd.nextDouble() * 280;
          _parts.add(_Particle(
            digit: _rnd.nextInt(10),
            x: _w / 2, // 从画布底部正中喷出
            y: _h - 40,
            vx: math.cos(ang) * spd,
            vy: math.sin(ang) * spd,
            size: 12 + _rnd.nextDouble() * 12,
          ));
        }
      }
      for (final p in _parts) {
        p.vy += 430 * (1 / 60); // 重力（快速射出后回落）
        p.x += p.vx * (1 / 60);
        p.y += p.vy * (1 / 60);
      }
      _parts.removeWhere((p) => p.y > _h + 10 || p.y < -40);
    } else {
      // 失败：数字雨——更快更密、垂直下落、方向统一，带残影
      if (_rnd.nextDouble() < 0.6) {
        _parts.add(_Particle(
          digit: _rnd.nextInt(10),
          x: _rnd.nextDouble() * _w,
          y: -20 - _rnd.nextDouble() * 30,
          vx: 0,
          vy: 460 + _rnd.nextDouble() * 320,
          size: 12 + _rnd.nextDouble() * 10,
        ));
      }
      for (final p in _parts) {
        p.trail.add(Offset(p.x, p.y));
        if (p.trail.length > 3) p.trail.removeAt(0);
        p.y += p.vy * (1 / 60);
      }
      _parts.removeWhere((p) => p.y > 380);
    }
    if (_parts.length > 140) _parts.removeRange(0, _parts.length - 140);
  }

  // 对局统计：回合数 + 双方 击杀/损失/造兵/最大单位 对比
  Widget _statsPanel() {
    final s = widget.state;
    if (s == null) return const SizedBox.shrink();
    final stats = (s['stats'] as Map?) ?? {};
    final List<dynamic> kills = (stats['kills'] as List?) ?? [0, 0];
    final List<dynamic> losses = (stats['losses'] as List?) ?? [0, 0];
    final List<dynamic> produce = (stats['produce'] as List?) ?? [0, 0];
    final names = (s['names'] as List?) ?? ['玩家1', '玩家2'];
    final cells = (s['cells'] as List?) ?? const [];
    final maxUnit = [0, 0];
    for (final c in cells) {
      final o = (c as Map?)?['o'];
      final v = (c as Map?)?['v'];
      if (o is int && o >= 0 && o <= 1 && v is int && v > maxUnit[o]) maxUnit[o] = v;
    }
    final turnCount = (s['turnCount'] as num?)?.toInt() ?? 0;
    final rows = <(String, List<dynamic>)>[
      ('击杀', kills),
      ('损失', losses),
      ('造兵', produce),
      ('最大单位', maxUnit),
    ];
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xCC1E1D1A),
        border: Border.all(color: const Color(0xFF5A554C), width: 1),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('对局统计 · ${turnCount} 回合',
            style: const TextStyle(fontFamily: 'PixelFont', fontSize: 13, color: _paper, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Row(children: [
          const SizedBox(width: 70, child: Text('', style: TextStyle(fontFamily: 'PixelFont'))),
          Expanded(child: Text('${names[0]}', textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'PixelFont', fontSize: 11, color: Color(0xFFFFD36A)))),
          Expanded(child: Text('${names[1]}', textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'PixelFont', fontSize: 11, color: Color(0xFF61D39E)))),
        ]),
        const SizedBox(height: 2),
        for (final (label, vals) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              SizedBox(width: 70, child: Text(label, style: const TextStyle(fontFamily: 'PixelFont', fontSize: 12, color: Color(0xFF77736B)))),
              Expanded(child: Text('${vals[0]}', textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'PixelFont', fontSize: 13, color: _paper))),
              Expanded(child: Text('${vals[1]}', textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'PixelFont', fontSize: 13, color: _paper))),
            ]),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      _w = cons.maxWidth;
      _h = cons.maxHeight;
      return Container(
      color: widget.win ? const Color(0xE611110F) : const Color(0xE60E0B0B),
      child: Stack(children: [
        // 数字粒子（失败带残影）——CustomPaint 单层绘制，repaint 由 _c 驱动，不重建 widget 树
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _ParticlePainter(parts: _parts, win: widget.win, repaint: _c),
              ),
            ),
          ),
        ),
        // 雷闪（失败）
        if (!widget.win && _flash > 0)
          Positioned.fill(
            child: Container(color: Colors.white.withValues(alpha: _flash * 0.55)),
          ),
        // 标题 + 副标题 + 统计 + 返回按钮（可滚动，防按钮被挤出页面）
        Positioned.fill(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                AnimatedBuilder(
                  animation: _pop,
                  builder: (context, _) {
                    final t = Curves.elasticOut.transform(_pop.value);
                    return Opacity(
                      opacity: _pop.value.clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: 0.3 + 0.7 * t,
                        child: Text(
                          widget.title,
                          style: TextStyle(
                            fontFamily: 'PixelFont',
                            fontSize: 52,
                            color: _paper,
                            fontWeight: FontWeight.bold,
                            shadows: const [Shadow(color: Colors.black54, offset: Offset(3, 3))],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                AnimatedBuilder(
                  animation: _btn,
                  builder: (context, _) => Opacity(
                    opacity: _btn.value.clamp(0.0, 1.0),
                    child: Text(
                      widget.sub,
                      style: const TextStyle(fontFamily: 'PixelFont', fontSize: 14, color: _paper),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                // 对局统计面板
                _statsPanel(),
                const SizedBox(height: 16),
                // 返回按钮常驻
                AnimatedBuilder(
                  animation: _btn,
                  builder: (context, _) => Opacity(
                    opacity: _btn.value.clamp(0.0, 1.0),
                    child: GestureDetector(
                      onTap: widget.onBack,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2824),
                          border: Border.all(color: const Color(0xFF5A554C), width: 2),
                          boxShadow: const [BoxShadow(color: Colors.black54, offset: Offset(3, 3))],
                        ),
                        child: const Text(
                          '返回大厅',
                          style: TextStyle(fontFamily: 'PixelFont', fontSize: 16, color: _paper, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
    });
  }
}

// 粒子绘制：单层 canvas 画数字（主体）+ 小方块（失败残影），TextPainter 按 (digit,size) 缓存复用
class _ParticlePainter extends CustomPainter {
  final List<_Particle> parts;
  final bool win;
  final Map<String, TextPainter> _cache = {};

  _ParticlePainter({required this.parts, required this.win, required Listenable repaint}) : super(repaint: repaint);

  TextPainter _tp(int digit, double size, double alpha) {
    final key = '$digit|${size.round()}|${(alpha * 100).round()}';
    return _cache.putIfAbsent(key, () {
      return TextPainter(
        text: TextSpan(
          text: '$digit',
          style: TextStyle(
            fontFamily: 'PixelFont',
            fontSize: size,
            color: Colors.white.withValues(alpha: alpha),
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (win) {
      // 胜利：单个数字
      for (final p in parts) {
        final tp = _tp(p.digit, p.size, 0.75);
        tp.paint(canvas, Offset(p.x, p.y));
      }
    } else {
      // 失败：数字残影（低透明度、略小的数字拖尾）+ 主体数字
      for (final p in parts) {
        for (int i = 0; i < p.trail.length; i++) {
          final tp = _tp(p.digit, p.size * 0.88, 0.12 + 0.2 * i);
          tp.paint(canvas, p.trail[i]);
        }
        final tp = _tp(p.digit, p.size, 1.0);
        tp.paint(canvas, Offset(p.x, p.y));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) => true;
}

class _Particle {
  final int digit;
  double x;
  double y;
  final double vx;
  double vy;
  final double size;
  final List<Offset> trail = []; // 残影（最近几帧位置，失败数字雨用）
  _Particle({required this.digit, required this.x, required this.y, required this.vx, required this.vy, required this.size});
}
