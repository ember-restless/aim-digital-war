// 通用设置面板：布局 + 边距 + BGM 音量 + 语音音量
// 游戏对局 / 新手教程共用（主菜单设置弹窗保留原有实现，含资源包选择）
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/settings_store.dart';
import '../core/bgm_manager.dart';

const _signal = Color(0xFFFF4E35);
const _paper = Color(0xFFFFF5DC);
const _dim = Color(0xFF77736B);
const _border = Color(0xFF5A554C);
const _panelBg = Color(0xFF1A1916);
const _itemBg = Color(0xFF2A2824);
const _itemOn = Color(0xFF3A2A1C);

String? _captureAction; // 正在改键的动作（设置面板内同时只有一个）

Widget _pt(String s, double size, Color c, {bool bold = false}) {
  return Text(
    s,
    style: TextStyle(color: c, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.w400, height: 1.3),
  );
}

/// 弹出通用设置面板。
/// [onChanged] 在布局/边距/音量变化时回调（调用方刷新界面，如切换布局立即生效）。
void showSettingsPanel(BuildContext context, {VoidCallback? onChanged}) {
  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
      void refresh() {
        setDlg(() {});
        onChanged?.call();
      }

      return Dialog(
        backgroundColor: _panelBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        child: Container(
          width: math.min(300, MediaQuery.sizeOf(ctx).width * 0.92),
          padding: const EdgeInsets.all(16),
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.86),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _pt('设置', 15, _signal),
            const SizedBox(height: 10),
            _pt('界面布局', 13, _paper),
            Row(children: [
              for (final (id, name) in [('classic', '经典'), ('compact', '简洁'), ('side', '侧栏')])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    onTap: () {
                      SettingsStore.layout = id;
                      SettingsStore.save();
                      refresh();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: SettingsStore.layout == id ? _itemOn : _itemBg,
                        border: Border.all(color: SettingsStore.layout == id ? _signal : _border),
                      ),
                      child: _pt(name, 12, SettingsStore.layout == id ? _signal : _paper, bold: SettingsStore.layout == id),
                    ),
                  ),
                ),
            ]),
            _pt('经典：顶信息+底操作；简洁：状态一行地图更大；侧栏：左状态右棋盘', 10, _dim),
            const SizedBox(height: 12),
            _pt('画面边距', 13, _paper),
            Row(children: [
              Expanded(
                child: Slider(
                  value: SettingsStore.margin.clamp(0, 48).toDouble(),
                  min: 0, max: 48, divisions: 24,
                  activeColor: _signal,
                  inactiveColor: _itemBg,
                  onChanged: (d) {
                    SettingsStore.margin = d;
                    SettingsStore.save();
                    refresh();
                  },
                ),
              ),
              SizedBox(width: 64, child: _pt('${SettingsStore.margin.round()}px', 12, _signal, bold: true)),
            ]),
            _pt('游戏棋盘左右留白，防贴边误触', 11, _dim),
            const SizedBox(height: 12),
            _pt('音乐音量（BGM）', 13, _paper),
            Row(children: [
              Expanded(
                child: Slider(
                  value: SettingsStore.bgmVolume.clamp(0, 1).toDouble(),
                  min: 0, max: 1, divisions: 20,
                  activeColor: _signal,
                  inactiveColor: _itemBg,
                  onChanged: (d) {
                    SettingsStore.bgmVolume = d;
                    SettingsStore.save();
                    BgmManager.instance.applyVolume();
                    refresh();
                  },
                ),
              ),
              SizedBox(width: 44, child: _pt('${(SettingsStore.bgmVolume * 100).round()}%', 12, _signal, bold: true)),
            ]),
            _pt('主界面/教程与对战的背景音乐', 11, _dim),
            const SizedBox(height: 12),
            _pt('语音音量（日文配音）', 13, _paper),
            Row(children: [
              Expanded(
                child: Slider(
                  value: SettingsStore.voiceVolume.clamp(0, 1).toDouble(),
                  min: 0, max: 1, divisions: 20,
                  activeColor: _signal,
                  inactiveColor: _itemBg,
                  onChanged: (d) {
                    SettingsStore.voiceVolume = d;
                    SettingsStore.save();
                    refresh();
                  },
                ),
              ),
              SizedBox(width: 44, child: _pt('${(SettingsStore.voiceVolume * 100).round()}%', 12, _signal, bold: true)),
            ]),
            _pt('教程中角色台词配音', 11, _dim),
            const SizedBox(height: 12),
            _pt('音效音量（8-bit 战斗音效）', 13, _paper),
            Row(children: [
              Expanded(
                child: Slider(
                  value: SettingsStore.sfxVolume.clamp(0, 1).toDouble(),
                  min: 0, max: 1, divisions: 20,
                  activeColor: _signal,
                  inactiveColor: _itemBg,
                  onChanged: (d) {
                    SettingsStore.sfxVolume = d;
                    SettingsStore.save();
                    refresh();
                  },
                ),
              ),
              SizedBox(width: 44, child: _pt('${(SettingsStore.sfxVolume * 100).round()}%', 12, _signal, bold: true)),
            ]),
            _pt('选中/移动/攻击/滚木/结算等战斗反馈音', 11, _dim),
            const SizedBox(height: 14),
            _pt('快捷键（对局键盘操作，点击改键）', 13, _paper),
            for (final (act, label) in [
              ('moveLeft', '光标左移'),
              ('moveRight', '光标右移'),
              ('confirm', '确认 / 执行'),
              ('cancel', '取消选中'),
              ('move', '移动'),
              ('attack', '攻击'),
              ('devour', '吞噬'),
              ('split', '拆分'),
              ('produce', '造兵'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: InkWell(
                  onTap: () {
                    _captureAction = act;
                    setDlg(() {});
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _itemBg,
                      border: Border.all(color: _captureAction == act ? _signal : _border),
                    ),
                    child: Row(children: [
                      Expanded(child: _pt(label, 12, _paper)),
                      _pt(_captureAction == act ? '按任意键…' : SettingsStore.keyDisplay(act), 12, _signal, bold: true),
                    ]),
                  ),
                ),
              ),
            _pt('数字键 1-9 / 0 直接选中对应格子（固定）', 10, _dim),
            if (_captureAction != null)
              Focus(
                autofocus: true,
                onKeyEvent: (node, e) {
                  if (e is! KeyDownEvent) return KeyEventResult.ignored;
                  final k = SettingsStore.canonKey(e.logicalKey);
                  if (k != null) {
                    SettingsStore.keybind[_captureAction!] = k;
                    SettingsStore.save();
                    _captureAction = null;
                    refresh();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: const SizedBox(width: 1, height: 1),
              ),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              InkWell(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  decoration: BoxDecoration(color: _itemBg, border: Border.all(color: _border)),
                  child: _pt('关闭', 12, _paper),
                ),
              ),
            ]),
          ]),
          ),
        ),
      );
    }),
  );
}
