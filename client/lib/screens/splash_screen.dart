// AIM 启动页：黑屏 → 透明底白字 Logo 淡入（透明度 0→1，1.5s）→ 完全显示后停留 2.5s → 进主界面
// Logo 打包在本地 assets/images/logo.png（离线可用，不依赖网络）
import 'dart:async';
import 'package:flutter/material.dart';

class SplashScreen extends StatefulWidget {
  final VoidCallback onDone;
  const SplashScreen({super.key, required this.onDone});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const _logoAsset = 'assets/images/logo.png';
  static const _fadeInMs = 1500; // 淡入时长
  static const _holdMs = 2500; // 完全显示后停留

  late final AnimationController _ctrl;
  bool _ready = false;
  bool _loadFailed = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: _fadeInMs));
    _loadLogo();
  }

  Future<void> _loadLogo() async {
    try {
      await precacheImage(const AssetImage(_logoAsset), context,
          onError: (e, s) => _onLoadFail());
    } catch (_) {
      _onLoadFail();
    }
    if (!mounted) return;
    setState(() => _ready = true);
    _ctrl.forward().then((_) {
      // 完全显示后停留 2.5s 再进主界面
      _timer = Timer(const Duration(milliseconds: _holdMs), widget.onDone);
    });
  }

  void _onLoadFail() {
    if (mounted && !_loadFailed) {
      setState(() => _loadFailed = true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: FadeTransition(
          opacity: _ctrl,
          child: _ready ? _logo() : const SizedBox.shrink(),
        ),
      ),
    );
  }

  // Logo 图：保持比例，最大占画幅 75%（牢大：logo 大一点）
  Widget _logo() {
    final mq = MediaQuery.sizeOf(context);
    if (_loadFailed) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Text('AIM',
            style: TextStyle(
                color: Colors.white,
                fontSize: mq.width * 0.18,
                fontWeight: FontWeight.w900,
                letterSpacing: 6)),
        const SizedBox(height: 8),
        Text('数字大战',
            style: TextStyle(color: Colors.white70, fontSize: mq.width * 0.045)),
      ]);
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: mq.width * 0.92,
        maxHeight: mq.height * 0.92,
      ),
      child: Image.asset(
        _logoAsset,
        fit: BoxFit.contain, // 保持比例缩放，不拉伸
        gaplessPlayback: true,
        errorBuilder: (c, e, s) => const SizedBox.shrink(),
      ),
    );
  }
}
