// 全局 BGM 管理器：非战斗（idle）与战斗（battle）两个独立循环播放器
// 异步循环，不阻塞；音量跟随 SettingsStore.bgmVolume
import 'package:audioplayers/audioplayers.dart';
import '../core/settings_store.dart';

class BgmManager {
  BgmManager._();
  static final BgmManager instance = BgmManager._();

  // BGM 不参与 audio focus 竞争：否则台词（voice）一播放就会把 BGM 暂停
  // Android 用 audioFocus none（不请求焦点）；iOS 用 ambient + mixWithOthers 混音共存
  static final AudioContext _bgmContext = AudioContext(
    android: AudioContextAndroid(audioFocus: AndroidAudioFocus.none),
    // iOS：ambient 类别本身可与其他音频混合，无需 mixWithOthers（该组合会触发断言）
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.ambient,
      options: {},
    ),
  );

  final AudioPlayer _idle = AudioPlayer()..setAudioContext(_bgmContext);
  final AudioPlayer _battle = AudioPlayer()..setAudioContext(_bgmContext);
  String _idleState = 'stop'; // stop/play
  String _battleState = 'stop';

  static const _idlePath = 'audio/bgm/bgm_idle.mp3';
  static const _battlePath = 'audio/bgm/bgm_battle.mp3';

  /// 非战斗场景（主界面/教程）：播 idle，停 battle
  Future<void> playIdle() async {
    try {
      if (_idleState == 'play') return;
      await _idle.setReleaseMode(ReleaseMode.loop);
      await _idle.setVolume(SettingsStore.bgmVolume);
      await _idle.play(AssetSource(_idlePath));
      _idleState = 'play';
      if (_battleState == 'play') {
        await _battle.stop();
        _battleState = 'stop';
      }
    } catch (_) {}
  }

  /// 战斗场景：播 battle，停 idle
  Future<void> playBattle() async {
    try {
      if (_battleState == 'play') return;
      await _battle.setReleaseMode(ReleaseMode.loop);
      await _battle.setVolume(SettingsStore.bgmVolume);
      await _battle.play(AssetSource(_battlePath));
      _battleState = 'play';
      if (_idleState == 'play') {
        await _idle.stop();
        _idleState = 'stop';
      }
    } catch (_) {}
  }

  /// 停止所有 BGM
  Future<void> stopAll() async {
    try {
      await _idle.stop();
      await _battle.stop();
    } catch (_) {}
    _idleState = 'stop';
    _battleState = 'stop';
  }

  /// 音量变化时实时应用
  Future<void> applyVolume() async {
    try {
      await _idle.setVolume(SettingsStore.bgmVolume);
      await _battle.setVolume(SettingsStore.bgmVolume);
    } catch (_) {}
  }

  void dispose() {
    _idle.dispose();
    _battle.dispose();
  }
}
