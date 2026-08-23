// Android 键盘高度通道
// 系统键盘以 adjustNothing 悬浮在画面上（窗口不 resize），MediaQuery.viewInsets 恒为 0，
// 键盘高度由原生 ViewTreeObserver 监听后经 MethodChannel 'aim/keyboard' 推送过来（逻辑像素）
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class KeyboardInsets {
  KeyboardInsets._();
  static final KeyboardInsets instance = KeyboardInsets._();

  static const _ch = MethodChannel('aim/keyboard');

  /// 键盘高度（逻辑像素，0 = 未弹起）
  final ValueNotifier<double> height = ValueNotifier(0);

  void init() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onKeyboard') {
        final args = call.arguments as Map;
        final visible = args['visible'] == true;
        final h = (args['height'] as num?)?.toDouble() ?? 0;
        double dpr = 1;
        try {
          dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
        } catch (_) {}
        height.value = visible ? h / dpr : 0;
      }
      return null;
    });
  }

  void dispose() {
    _ch.setMethodCallHandler(null);
  }
}
