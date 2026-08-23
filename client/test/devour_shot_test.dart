// 吞噬动画各阶段截图（用 image 工具亲眼看渲染结果）
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:aim/screens/game_screen.dart';
import 'package:aim/net/socket.dart';

// ── 哑平台：测试环境无原生音频插件，替换 audioplayers 平台层（否则事件流订阅抛 MissingPluginException）──
class _FakeAudioPlatform extends AudioplayersPlatformInterface {
  @override
  Future<void> create(String playerId) async {}
  @override
  Future<void> dispose(String playerId) async {}
  @override
  Future<void> pause(String playerId) async {}
  @override
  Future<void> stop(String playerId) async {}
  @override
  Future<void> resume(String playerId) async {}
  @override
  Future<void> release(String playerId) async {}
  @override
  Future<void> seek(String playerId, Duration position) async {}
  @override
  Future<void> setBalance(String playerId, double balance) async {}
  @override
  Future<void> setVolume(String playerId, double volume) async {}
  @override
  Future<void> setReleaseMode(String playerId, ReleaseMode releaseMode) async {}
  @override
  Future<void> setPlaybackRate(String playerId, double playbackRate) async {}
  @override
  Future<void> setSourceUrl(String playerId, String url, {bool? isLocal, String? mimeType}) async {}
  @override
  Future<void> setSourceBytes(String playerId, Uint8List bytes, {String? mimeType}) async {}
  @override
  Future<void> setAudioContext(String playerId, AudioContext ctx) async {}
  @override
  Future<void> setPlayerMode(String playerId, PlayerMode mode) async {}
  @override
  Future<void> emitLog(String playerId, String message) async {}
  @override
  Future<void> emitError(String playerId, String code, String message) async {}
  @override
  Future<int?> getDuration(String playerId) async => 0;
  @override
  Future<int?> getCurrentPosition(String playerId) async => 0;
  @override
  Stream<AudioEvent> getEventStream(String playerId) => const Stream.empty();
}

class _FakeGlobalAudioPlatform extends GlobalAudioplayersPlatformInterface {
  @override
  Future<void> init() async {}
  @override
  Future<void> setGlobalAudioContext(AudioContext ctx) async {}
  @override
  Future<void> emitGlobalLog(String message) async {}
  @override
  Future<void> emitGlobalError(String code, String message) async {}
  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => const Stream.empty();
}

Map<String, dynamic> mkState(List cells, {int mySum = 0, int enSum = 0}) => {
  'cells': cells,
  'turn': 0,
  'yourIdx': 0,
  'phase': 'action',
  'points': 1,
  'produceLeft': 2,
  'mapLen': cells.length,
  'limit': 30,
  'names': ['我', '敌'],
  'mySum': mySum,
  'enemySum': enSum,
  'myBases': 1,
  'myHqs': 1,
  'winner': null,
  'log': [''],
  'hotseat': false,
  'spectator': false,
  'legalActions': const [],
};

Future<void> shot(WidgetTester tester, String name) async {
  // 用测试绑定的截图方法（自动找 RepaintBoundary）
  final element = tester.element(find.byType(GameScreen).first);
  RenderRepaintBoundary repaint;
  RenderObject ro = element.renderObject!;
  while (ro is! RenderRepaintBoundary) {
    ro = ro.parent!;
  }
  repaint = ro as RenderRepaintBoundary;
  final image = await repaint.toImage();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File('/root/.openclaw/workspace/media/devour_shots/$name.png')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
  print('saved $name');
}

void main() {
  testWidgets('吞噬动画截图', (tester) async {
    // 替换平台层（哑实现，构造 AudioPlayer 不再订阅事件流）
    AudioplayersPlatformInterface.instance = _FakeAudioPlatform();
    GlobalAudioplayersPlatformInterface.instance = _FakeGlobalAudioPlatform();
    // 拦截 audioplayers 平台通道（测试环境无原生插件）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (call) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async => null,
    );
    final sock = AIMSocket('http://x');
    final s1 = mkState([
      {'v': 8, 'o': 0}, {'v': 0, 'o': null}, {'v': 1, 'o': 0},
      {'v': 1, 'o': 1}, {'v': 0, 'o': null}, {'v': 8, 'o': 1},
    ], mySum: 1, enSum: 9);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s1, packId: 'default', onBack: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 1000));
    await shot(tester, 't0_initial');

    final s2 = mkState([
      {'v': 8, 'o': 0}, {'v': 0, 'o': null}, {'v': 2, 'o': 0},
      {'v': 0, 'o': null}, {'v': 8, 'o': 1},
    ], mySum: 2, enSum: 8)
      ..['lastAction'] = {'type': 'devour', 'i': 2, 'j': 3, 'sum': 2, 'spliced': true, 'collapsed': false, 'owner': 0}
      ..['lastSeq'] = 1;
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(socket: sock, state: s2, packId: 'default', onBack: () {}),
    ));
    var t = 0;
    for (final ms in [80, 80, 140, 150, 150, 200]) {
      t += ms;
      await tester.pump(Duration(milliseconds: ms));
      await shot(tester, 't${t}');
    }
    expect(tester.takeException(), isNull);
  });
}
