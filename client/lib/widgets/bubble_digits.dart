// 背景数字气泡：数字缓慢游动（像水里的气泡），靠近指针/手指会避开
// 速度不恒定：每隔几秒随机转向、缓慢漂移；数字带随机倾斜 + 缓慢自转
// 单 ticker + 单 CustomPaint 画布（40 个数字一次绘制，性能好）
//
// ⚠️ 指针追踪不在本组件内部——Stack 底层收不到上层内容短路后的事件！
// 由页面根（SafeArea 内、Stack 外）放 Listener/MouseRegion，用 ValueNotifier 传进来。
// 用法：
//   final ValueNotifier<Offset?> pointer = ValueNotifier(null);
//   Listener(onPointerDown/Move: (e) => pointer.value = e.localPosition, ...
//     child: MouseRegion(onHover: ..., child: Stack(children: [
//       Positioned.fill(child: BubbleDigits(pointer: pointer)),
//       ...
//     ])))
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class BubbleDigits extends StatefulWidget {
  final int count;
  final double minSize;
  final double maxSize;
  final Color color;
  final double baseOpacity;
  final double avoidRadius; // 指针影响半径（px）
  final ValueNotifier<Offset?>? pointer; // 外部指针追踪（页面根 Listener 提供，可空）
  const BubbleDigits({
    super.key,
    this.count = 40,
    this.minSize = 10,
    this.maxSize = 24,
    this.color = const Color(0xFF787060),
    this.baseOpacity = 0.12,
    this.avoidRadius = 70,
    this.pointer,
  });

  @override
  State<BubbleDigits> createState() => _BubbleDigitsState();
}

class _BubbleDigitsState extends State<BubbleDigits>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _lastT = 0;
  Offset? _pointer;
  Size _size = Size.zero; // 画布尺寸（build 时更新）
  late final List<_Bubble> _bubbles;
  final math.Random _rnd = math.Random(20260811);

  @override
  void initState() {
    super.initState();
    _bubbles = List.generate(widget.count, (_) => _Bubble(
      digit: _rnd.nextInt(10),
      nx: _rnd.nextDouble(),
      ny: _rnd.nextDouble(),
      size: widget.minSize + _rnd.nextDouble() * (widget.maxSize - widget.minSize),
      opacity: (widget.baseOpacity + _rnd.nextDouble() * 0.1).clamp(0.0, 1.0),
      color: widget.color,
      rnd: _rnd,
    ));
    widget.pointer?.addListener(_onPointerChanged);
    _ticker = createTicker(_onTick)..start();
  }

  void _onPointerChanged() {
    _pointer = widget.pointer?.value;
  }

  @override
  void dispose() {
    widget.pointer?.removeListener(_onPointerChanged);
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    final dt = (t - _lastT).clamp(0.0, 0.1);
    _lastT = t;
    if (dt <= 0) return;
    final pointer = _pointer;
    final w = _size.width, h = _size.height;
    for (final b in _bubbles) {
      b.avoid(pointer, widget.avoidRadius, w, h, dt);
      b.update(dt);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, cons) {
      _size = Size(cons.maxWidth, cons.maxHeight);
      return CustomPaint(
        size: Size.infinite,
        painter: _BubblePainter(bubbles: _bubbles),
      );
    });
  }
}

// 单个数字气泡（坐标归一化 0-1，与屏幕尺寸解耦，旋转屏幕也不乱）
class _Bubble {
  final int digit;
  double nx, ny; // 归一化中心坐标
  late double vx, vy; // 当前速度（归一化/秒）
  late double tx, ty; // 目标方向（缓慢转向用，速度不恒定）
  double _turnT = 0;
  late double _turnInterval;
  late double rot; // 当前旋转角（rad）
  late double rotV; // 自转速度（rad/s）
  final double size; // 字号（px）
  final double opacity;
  late final TextPainter painter;
  final math.Random _rnd;

  _Bubble({
    required this.digit,
    required this.nx,
    required this.ny,
    required this.size,
    required this.opacity,
    required Color color,
    required math.Random rnd,
  }) : _rnd = rnd {
    painter = TextPainter(
      text: TextSpan(
        text: '$digit',
        style: TextStyle(
          fontSize: size,
          color: color.withOpacity(opacity),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // 每个气泡独立初始速度（方向/快慢都不同）
    final ang = _rnd.nextDouble() * 2 * math.pi;
    final spd = 0.08 + _rnd.nextDouble() * 0.14;
    vx = math.cos(ang) * spd;
    vy = math.sin(ang) * spd;
    tx = vx;
    ty = vy;
    _turnInterval = 2 + _rnd.nextDouble() * 4;
    // 随机初始倾斜 + 缓慢自转（有的正转有的反转，有的几乎不动）
    rot = (_rnd.nextDouble() - 0.5) * 0.7;
    rotV = (_rnd.nextDouble() - 0.5) * 0.5;
  }

  // 游动 + 缓慢转向（速度不恒定）+ 自转 + 边缘反弹
  void update(double dt) {
    // 隔几秒随机换一个目标方向，速度缓缓漂过去——像水流里的气泡
    _turnT += dt;
    if (_turnT > _turnInterval) {
      _turnT = 0;
      _turnInterval = 2 + _rnd.nextDouble() * 4;
      final ang = _rnd.nextDouble() * 2 * math.pi;
      final spd = 0.06 + _rnd.nextDouble() * 0.16;
      tx = math.cos(ang) * spd;
      ty = math.sin(ang) * spd;
    }
    final k = 0.4 * dt; // 转向速率（缓缓转向，不瞬变）
    vx += (tx - vx) * k;
    vy += (ty - vy) * k;
    // 自转
    rot += rotV * dt;
    // 游动
    nx += vx * dt;
    ny += vy * dt;
    if (nx < 0) { nx = 0; vx = vx.abs(); }
    if (nx > 1) { nx = 1; vx = -vx.abs(); }
    if (ny < 0) { ny = 0; vy = vy.abs(); }
    if (ny > 1) { ny = 1; vy = -vy.abs(); }
  }

  // 躲避：指针/手指靠近时加速逃离（越近越用力，平滑不突兀）
  void avoid(Offset? pointer, double avoidRadius, double w, double h, double dt) {
    if (pointer == null || w <= 0 || h <= 0) return;
    final px = nx * w, py = ny * h;
    final dx = px - pointer.dx;
    final dy = py - pointer.dy;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d < avoidRadius && d > 0.5) {
      final force = (avoidRadius - d) / avoidRadius; // 0(边缘)~1(贴着)
      final speed = 0.3 * force * dt; // 归一化位移量
      nx += dx / d * speed;
      ny += dy / d * speed;
      nx = nx.clamp(0.0, 1.0);
      ny = ny.clamp(0.0, 1.0);
    }
  }
}

class _BubblePainter extends CustomPainter {
  final List<_Bubble> bubbles;
  _BubblePainter({required this.bubbles});

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in bubbles) {
      final tp = b.painter;
      final x = b.nx * size.width;
      final y = b.ny * size.height;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(b.rot); // 倾斜/自转（绕数字中心）
      canvas.translate(-tp.width / 2, -tp.height / 2);
      tp.paint(canvas, Offset.zero);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) => true;
}
