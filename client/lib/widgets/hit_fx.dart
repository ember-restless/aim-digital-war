// 打击动画公共组件：被攻击时刀光闪过 + 旧数字淡出（渐变到被打后数字）
// 游戏本体（GameScreen）与新手教程（TutorialScreen）共用
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../art/art_manager.dart';

class HitFxData {
  int i;       // 格子索引
  int from;    // 原数字
  int to;      // 被打后数字（0 = 被击杀）
  int id = 0;  // 唯一 id
  HitFxData({required this.i, required this.from, required this.to});
}

class HitFx extends StatefulWidget {
  final String packId;
  final int from;
  final int to;
  final double imgSize;
  final double cellSize;
  final VoidCallback onDone;
  const HitFx({super.key, required this.packId, required this.from, required this.to,
    required this.imgSize, required this.cellSize, required this.onDone});

  @override
  State<HitFx> createState() => _HitFxState();
}

class _HitFxState extends State<HitFx> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..forward().whenComplete(widget.onDone);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.cellSize;
    // 白闪：快速变白（0~15%）→ 慢慢透明（15%~100%）
    // 峰值只到 45% 半透明——模糊遮挡转变瞬间，但数字变化（1→2）依然可见
    final flash = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.45), weight: 15),
      TweenSequenceItem(
        tween: Tween(begin: 0.45, end: 0.0).chain(CurveTween(curve: Curves.easeOut)),
        weight: 85,
      ),
    ]).animate(_c);
    // 刀光：8%~45% 从左往右扫过
    final slash = CurvedAnimation(parent: _c, curve: const Interval(0.08, 0.45, curve: Curves.easeInOut));

    return IgnorePointer(
      child: Stack(alignment: Alignment.center, children: [
        // 白色闪光（数字转变在动画开始时已完成，白闪负责遮挡/吸引注意）
        FadeTransition(
          opacity: flash,
          child: Container(color: const Color(0xFFFFFFFF)),
        ),
        // 刀光：斜向亮条从左上扫到右下
        AnimatedBuilder(
          animation: slash,
          builder: (ctx, _) {
            final t = slash.value;
            return Positioned(
              left: -cs * 0.6 + t * cs * 1.9,
              top: cs * 0.30,
              child: Transform.rotate(
                angle: -0.55,
                child: Container(
                  width: cs * 1.15,
                  height: math.max(3.0, cs * 0.07),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFFFF).withOpacity(0.95 * (1 - t)),
                    boxShadow: [
                      BoxShadow(color: const Color(0xFFFFFFFF).withOpacity(0.7 * (1 - t)), blurRadius: 8),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        // 轻微红边脉冲（受伤感）
        AnimatedBuilder(
          animation: _c,
          builder: (ctx, _) {
            final t = _c.value;
            return Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: const Color(0xFFFF4E35).withOpacity(0.75 * (1 - t)),
                  width: 3,
                ),
              ),
            );
          },
        ),
      ]),
    );
  }
}
