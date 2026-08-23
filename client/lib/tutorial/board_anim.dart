// 棋盘入场/退场动画组件（直接驱动现有格子元素，不复制棋盘）
// 入场：中间两格先落 → 对称向两边依次（越靠边越晚）飞入，easeOutBack 弹跳；数字比框晚弹出
// 退场：所有数字先朝自家方向（我方朝左/敌方朝右）移动一小段淡出，空格随后淡
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 入场动画：交错飞入
/// [cell] 格子内容 widget（现有元素）
/// [index] 格子索引（0-based）
/// [count] 格子总数
/// [cellSize] 格子尺寸（用于计算飞入距离）
/// [isUnit] 该格是否有数字单位（决定数字是否后弹）
class BoardEnterCell extends StatefulWidget {
  final Widget cell;
  final int index;
  final int count;
  final double cellSize;
  final bool isUnit;

  const BoardEnterCell({
    super.key,
    required this.cell,
    required this.index,
    required this.count,
    required this.cellSize,
    required this.isUnit,
  });

  @override
  State<BoardEnterCell> createState() => _BoardEnterCellState();
}

class _BoardEnterCellState extends State<BoardEnterCell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _enter;
  late final Animation<double> _numPop;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    // 对称时序：中间两格先落，越靠边越晚（间隔递增 70/100/130...）
    final center = (widget.count - 1) / 2;
    final dist = (widget.index - center).abs();
    final delay = dist * 0.09 + dist * dist * 0.025; // 递增间隔：越远越慢
    _enter = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(delay.clamp(0.0, 0.75), (delay + 0.45).clamp(0.3, 1.0),
          curve: Curves.easeOutBack),
    );
    _numPop = CurvedAnimation(
      parent: _ctrl,
      curve: Interval((delay + 0.28).clamp(0.2, 0.8), (delay + 0.6).clamp(0.5, 1.0),
          curve: Curves.easeOutBack),
    );
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, _) {
        final t = _enter.value;
        // 从上方+侧方飞入：中心格几乎垂直落，边缘格带横向偏移
        final dx = (widget.index - (widget.count - 1) / 2) * -0.4;
        final offset = Offset(dx * (1 - t) * widget.cellSize,
            -(1 - t) * widget.cellSize * 3.2);
        final numT = widget.isUnit ? _numPop.value : 1.0;
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: offset,
            child: widget.isUnit
                ? Transform.scale(
                    scale: 0.6 + 0.4 * numT,
                    child: widget.cell,
                  )
                : widget.cell,
          ),
        );
      },
    );
  }
}

/// 退场动画：数字先一起退（朝自家方向移出淡出），停 100ms 后格子壳再退
class BoardExitCell extends StatefulWidget {
  final Widget box; // 格子壳（背景+边框，不含数字）
  final Widget? icon; // 数字图标（可空）
  final int index;
  final int count;
  final double cellSize;
  final bool isMine; // 我方朝左退，敌方朝右退

  const BoardExitCell({
    super.key,
    required this.box,
    this.icon,
    required this.index,
    required this.count,
    required this.cellSize,
    required this.isMine,
  });

  @override
  State<BoardExitCell> createState() => _BoardExitCellState();
}

class _BoardExitCellState extends State<BoardExitCell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _iconExit; // 数字先退
  late final Animation<double> _boxExit; // 格子壳后退

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
    // 数字退场时序：与入场呼应，中间先走，两边依次跟上
    final center = (widget.count - 1) / 2;
    final dist = (widget.index - center).abs();
    final iconDelay = dist * 0.06 + dist * dist * 0.02;
    _iconExit = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(iconDelay.clamp(0.0, 0.45), (iconDelay + 0.4).clamp(0.35, 0.85),
          curve: Curves.easeIn),
    );
    // 格子壳：等数字退完（约 0.5s）再停 150ms，然后才退
    final boxDelay = 0.6 + dist * 0.04;
    _boxExit = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(boxDelay.clamp(0.5, 0.8), (boxDelay + 0.35).clamp(0.8, 1.0),
          curve: Curves.easeIn),
    );
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, _) {
        final it = _iconExit.value;
        final bt = _boxExit.value;
        // 数字：朝自家方向（我方左/敌方右）移动一小段 + 淡出
        final dir = widget.isMine ? -1.0 : 1.0;
        final dx = (widget.icon != null) ? dir * it * widget.cellSize * 0.9 : 0.0;
        return Opacity(
          opacity: (1 - bt).clamp(0.0, 1.0), // 格子壳：1→0 淡出（曾误写 bt 0→1 淡入，导致壳一开始全透明=瞬间消失）
          child: Stack(alignment: Alignment.center, children: [
            widget.box,
            if (widget.icon != null)
              Opacity(
                opacity: (1 - it).clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(dx, it * widget.cellSize * 0.15),
                  child: widget.icon!,
                ),
              ),
          ]),
        );
      },
    );
  }
}
