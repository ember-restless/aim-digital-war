import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'core/config.dart';
import 'art/art_manager.dart';
import 'screens/menu_screen.dart';
import 'screens/splash_screen.dart';
import 'core/settings_store.dart';
import 'core/bgm_manager.dart';
import 'widgets/keyboard_insets.dart';

Future<void> main() async {
  // 必须先初始化 Binding，否则 SystemChrome 调用会抛异常（黑屏）
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsStore.load();
  // 强制横屏（牢大要求保留；手表/竖屏靠自适应布局 + 横向滚动兜底）
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  KeyboardInsets.instance.init();
  runApp(const AimApp());
}

class AimApp extends StatelessWidget {
  const AimApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AIM 数字大战',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF11110F),
        fontFamily: 'PixelFont', // 全局像素字体（Ark Pixel 方舟像素 16px）
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF4E35),
          surface: Color(0xFFFFF5DC),
        ),
      ),
      // 像素画布：高度固定 360 基准，宽度跟随屏幕比例（长屏无左右黑边、不变形）
      // 顶部留黑条（状态栏区域）：手机状态栏/刘海不会挡住画布内容
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final barH = mq.padding.top;
        final availH = (mq.size.height - barH).clamp(100.0, 1200.0);
        final ratio = mq.size.width / availH; // 屏幕宽高比
        final cw = (360 * ratio).clamp(320.0, 1200.0); // 画布宽（跟随屏幕比例）
        return MediaQuery(
          data: mq.copyWith(
            size: Size(cw, 360),
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.zero,
            textScaler: TextScaler.noScaling,
          ),
          child: ColoredBox(
            color: const Color(0xFF11110F),
            child: Column(children: [
              // 顶部黑条：状态栏区域（不挡住画布按键）
              Container(height: barH, color: const Color(0xFF11110F)),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.contain, // 画布比例=屏幕比例 → 完全铺满无黑边
                  alignment: Alignment.center,
                  child: SizedBox(width: cw, height: 360, child: child),
                ),
              ),
            ]),
          ),
        );
      },
      home: const SplashGate(),
    );
  }
}

// 启动页 → 主界面（Logo 淡入完再进）
class SplashGate extends StatefulWidget {
  const SplashGate({super.key});
  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _entered = false;

  @override
  Widget build(BuildContext context) {
    if (_entered) return const Home();
    return SplashScreen(onDone: () {
      if (mounted) setState(() => _entered = true);
    });
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String? packId = 'default';
  List<PackInfo> packs = [];
  Map<String, dynamic>? updateInfo;

  @override
  void initState() {
    super.initState();
    ArtManager.listPacks().then((l) {
      if (mounted) setState(() => packs = l);
    });
    _checkUpdate();
  }

  // 自动检查更新（提示不强制：发现新版本横幅提示，老版本仍可玩）
  Future<void> _checkUpdate() async {
    try {
      final res = await http.get(Uri.parse('${AppConfig.serverUrl}/api/version'));
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['version'] != AppConfig.appVersion && mounted) {
        setState(() => updateInfo = data);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return MenuScreen(
      packId: packId!,
      packs: packs,
      updateInfo: updateInfo,
      onPackChange: (id) => setState(() => packId = id),
    );
  }
}
