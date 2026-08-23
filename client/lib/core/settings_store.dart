// AIM 本地设置持久化（边距/布局/音量/名字等），io 与 web 通用（shared_preferences）
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsStore {
  static double margin = 0; // 游戏画面左右边距（逻辑像素）
  static String layout = 'classic'; // 界面布局：classic 经典 | compact 简洁 | side 侧栏
  static double bgmVolume = 0.5; // BGM 音量 0~1（默认比语音小）
  static double voiceVolume = 1.0; // 语音音量 0~1
  static double sfxVolume = 0.35; // 战斗音效音量 0~1（牢大实测太响，默认调小 50%：0.7→0.35）
  static String playerName = '玩家'; // 上次使用的名字（联机/局域网/热座共用）
  static String lastServer = ''; // 上次连接的服务器（手动选过才记）
  static Map<String, String> keybind = {}; // 快捷键绑定（action -> key 名），空用默认
  static bool loaded = false;

  // 快捷键动作默认绑定（规范键名：arrowLeft/arrowRight/space/enter/escape/字母小写）
  static const Map<String, String> defaultKeybind = {
    'moveLeft': 'arrowLeft',
    'moveRight': 'arrowRight',
    'confirm': 'space',
    'cancel': 'escape',
    'move': 'm',
    'attack': 'a',
    'devour': 'd',
    'split': 's',
    'produce': 'p',
  };

  // 取某动作当前绑定的规范键名
  static String keyFor(String action) => keybind[action] ?? defaultKeybind[action]!;

  // 规范键名 → 显示名
  static String keyDisplay(String action) {
    const names = {
      'arrowLeft': '←',
      'arrowRight': '→',
      'space': '空格',
      'enter': '回车',
      'escape': 'Esc',
    };
    final k = keyFor(action);
    return names[k] ?? k.toUpperCase();
  }

  // 把 Flutter 逻辑键转成规范键名；不支持的返回 null（监听到时忽略）
  static String? canonKey(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.arrowLeft) return 'arrowLeft';
    if (k == LogicalKeyboardKey.arrowRight) return 'arrowRight';
    if (k == LogicalKeyboardKey.space) return 'space';
    if (k == LogicalKeyboardKey.enter) return 'enter';
    if (k == LogicalKeyboardKey.escape) return 'escape';
    final label = k.keyLabel;
    if (label != null && label.length == 1 && RegExp(r'[a-zA-Z0-9]').hasMatch(label)) {
      return label.toLowerCase();
    }
    return null;
  }

  static Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      margin = sp.getDouble('margin') ?? 0;
      layout = sp.getString('layout') ?? 'classic';
      bgmVolume = sp.getDouble('bgmVolume') ?? 0.5;
      voiceVolume = sp.getDouble('voiceVolume') ?? 1.0;
      sfxVolume = sp.getDouble('sfxVolume') ?? 0.35;
      // 旧版默认 0.7 迁移：牢大实测太响，新默认 0.35；>=0.6 视为未调过的旧默认（之后手动调整会覆盖）
      if (sfxVolume >= 0.6) sfxVolume = 0.35;
      playerName = sp.getString('playerName') ?? '玩家';
      lastServer = sp.getString('lastServer') ?? '';
      final kb = sp.getString('keybind');
      if (kb != null) {
        keybind = (const JsonDecoder().convert(kb) as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    loaded = true;
  }

  static Future<void> save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setDouble('margin', margin);
      await sp.setString('layout', layout);
      await sp.setDouble('bgmVolume', bgmVolume);
      await sp.setDouble('voiceVolume', voiceVolume);
      await sp.setDouble('sfxVolume', sfxVolume);
      await sp.setString('playerName', playerName);
      await sp.setString('lastServer', lastServer);
      if (keybind.isNotEmpty) {
        await sp.setString('keybind', const JsonEncoder().convert(keybind));
      }
    } catch (_) {}
  }
}
