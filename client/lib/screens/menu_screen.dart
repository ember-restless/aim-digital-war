// AIM 主菜单：联机大厅 / 局域网 / 热座 三个入口
// 联机大厅：自动选服 → 进大厅；局域网/热座：本地模式（后续接入本地规则引擎）
import 'dart:async';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

import '../art/art_manager.dart';
import '../core/config.dart';
import '../game/ai.dart';
import '../game/tips.dart';
import '../net/server_list.dart';
import '../core/settings_store.dart';
import '../core/bgm_manager.dart';
import '../tutorial/tutorial_script.dart';
import '../widgets/bubble_digits.dart';
import 'tutorial_screen.dart';
import 'lobby_screen.dart';
import 'hotseat_screen.dart';

const _ink = Color(0xFF11110F);
const _paper = Color(0xFFFFF5DC);
const _signal = Color(0xFFFF4E35);
const _dim = Color(0xFF77736B);
const _warn = Color(0xFFFFD36A);
const _orange = Color(0xFFE8A33D);
const _border = Color(0xFF5A554C);
const _green = Color(0xFF61D39E);

// 本地对战对手选择（玩家双人 / AI 三档）
enum _AiOption {
  player('玩家双人', '两人共用一台设备轮流操作', null),
  easy('AI·简单', '随机出招，新手练手', AiLevel.easy),
  normal('AI·普通', '会攻击会合体，有来有回', AiLevel.normal),
  hard('AI·困难', '防守老练，会卡你走位', AiLevel.hard);

  final String label;
  final String desc;
  final AiLevel? ai;
  const _AiOption(this.label, this.desc, this.ai);
}

class MenuScreen extends StatefulWidget {
  final String packId;
  final List<PackInfo> packs;
  final Map<String, dynamic>? updateInfo;
  final void Function(String id) onPackChange;
  const MenuScreen({
    super.key,
    required this.packId,
    required this.packs,
    this.updateInfo,
    required this.onPackChange,
  });

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  double _scale = 1; // 小屏缩放系数（手表/窄屏自动缩小字号与控件）
  // 指针追踪（SafeArea 内、Stack 外：translucent 不挡按钮，又能收到所有触摸/悬停事件）
  final ValueNotifier<Offset?> _pointer = ValueNotifier<Offset?>(null);
  // 主页常驻小贴士：点击换一条，隔 10s 自动换一条
  int _tipIdx = 0;
  Timer? _tipTimer;

  @override
  void initState() {
    super.initState();
    // 主界面：播放非战斗 BGM（数码闲时）
    BgmManager.instance.playIdle();
    _tipIdx = Random().nextInt(kGameTips.length);
    _tipTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(_nextTip);
    });
  }

  @override
  void dispose() {
    _tipTimer?.cancel();
    _pointer.dispose();
    super.dispose();
  }

  void _nextTip() => _tipIdx = (_tipIdx + 1) % kGameTips.length;

  @override
  Widget build(BuildContext context) {
    _scale = (MediaQuery.sizeOf(context).shortestSide / 400).clamp(0.72, 1.0);
    final compact = SettingsStore.layout == 'compact';
    // 侧栏排布：左内容 + 右侧竖排入口按钮（仅宽屏启用）
    final side = SettingsStore.layout == 'side' && MediaQuery.sizeOf(context).width >= 600;
    final List<Widget> contentKids = [
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        _seal(),
        const SizedBox(width: 16),
        Expanded(child: _titleBlock(compact)),
      ]),
      if (!compact) ...[const SizedBox(height: 12), _slogan()],
      if (compact) const SizedBox(height: 6),
      // 玩法速览（1/2/3/4）在入口按钮上面
      if (!compact) ...[const SizedBox(height: 10), _rules()],
      // 主页常驻小贴士：点击换一条，10s 自动换一条
      if (compact) const SizedBox(height: 4),
      _tipBar(),
      const SizedBox(height: 12),
    ];
    return Scaffold(
      body: Container(
        color: _ink,
        child: SafeArea(
          // 指针追踪必须在 Stack 外（Stack 底层收不到被上层短路的事件——牢大：手指戳没反应）
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) => _pointer.value = e.localPosition,
            onPointerMove: (e) => _pointer.value = e.localPosition,
            onPointerUp: (_) => _pointer.value = null,
            onPointerCancel: (_) => _pointer.value = null,
            child: MouseRegion(
              onHover: (e) => _pointer.value = e.localPosition,
              onExit: (_) => _pointer.value = null,
              child: Stack(
                children: [
                  // 背景数字气泡：缓慢游动、转向、自转，靠近指针/手指会避开
                  Positioned.fill(child: BubbleDigits(pointer: _pointer)),              if (side)
                Column(children: [
                  Padding(padding: const EdgeInsets.all(16), child: _topBar()),
                  const Divider(color: _border, height: 1),
                  Expanded(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(
                        child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: contentKids)),
                      ),
                      const VerticalDivider(width: 1, color: _border),
                      SizedBox(width: 150, child: _sideEntry()),
                    ]),
                  ),
                  Padding(padding: const EdgeInsets.all(12), child: _bottomBar()),
                ])
              else
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _topBar(),
                      const SizedBox(height: 14),
                      ...contentKids,
                      _entryRow(),
                      const SizedBox(height: 10),
                      _bottomBar(),
                    ],
                  ),
                ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // 经典/紧凑：玩法速览下面，左边说明文字 + 右边一行小按钮（按钮尽量小、靠右）
  Widget _entryRow() {
    final compact = SettingsStore.layout == 'compact';
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      if (!compact)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _pt('联机大厅：自动选择最优服务器，与全网玩家对战\n局域网：同一 WiFi 下开黑，无需外网\n热座：单机双人，一台设备轮流操作', 10, _dim),
          ),
        ),
      Row(mainAxisSize: MainAxisSize.min, children: [
        _miniBtn('联机大厅', _signal, _enterOnline),
        const SizedBox(width: 6),
        _miniBtn('局域网', _green, _enterLan),
        const SizedBox(width: 6),
        _miniBtn('热座', _warn, _enterHotseat),
      ]),
    ]);
  }

  Widget _miniBtn(String title, Color accent, VoidCallback cb) {
    return InkWell(
      onTap: cb,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFF1A1916), border: Border.all(color: accent, width: 1)),
        child: _pt(title, 13, accent, bold: true),
      ),
    );
  }

  // 侧栏排布：右侧竖排三个入口按钮
  Widget _sideEntry() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(children: [
        _sideBtn('联机大厅', '全网对战', _signal, _enterOnline),
        const SizedBox(height: 10),
        _sideBtn('局域网', 'WiFi 开黑', _green, _enterLan),
        const SizedBox(height: 10),
        _sideBtn('热座', '单机双人', _warn, _enterHotseat),
        const Spacer(),
      ]),
    );
  }

  Widget _sideBtn(String title, String sub, Color accent, VoidCallback cb) {
    return InkWell(
      onTap: cb,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFF1A1916), border: Border.all(color: accent, width: 1)),
        child: Column(children: [
          _pt(title, 13, accent, bold: true),
          const SizedBox(height: 2),
          _pt(sub, 9, _dim),
        ]),
      ),
    );
  }

  Widget _topBar() {
    return Row(children: [
      _pt('AIM 数字大战', 13, _paper),
      const Spacer(),
      InkWell(
        onTap: _showFeed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border)),
          child: _pt('投喂小猫', 11, _paper),
        ),
      ),
      const SizedBox(width: 6),
      InkWell(
        onTap: _showChapterSelect,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border)),
          child: _pt('教程', 11, _paper),
        ),
      ),
      const SizedBox(width: 6),
      InkWell(
        onTap: _showSettings,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border)),
          child: _pt('⚙', 13, _paper),
        ),
      ),
    ]);
  }

  // ── 名字输入弹窗（联机/局域网/热座共用，默认上次使用的名字）──
  Future<String?> _askName() async {
    final ctrl = TextEditingController(text: SettingsStore.playerName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1916),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: const Text('你的名字', style: TextStyle(color: _signal, fontSize: 15, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          maxLength: 12,
          autofocus: true,
          style: const TextStyle(color: _paper, fontSize: 15),
          decoration: const InputDecoration(
            counterText: '',
            labelText: '玩家名',
            labelStyle: TextStyle(color: _dim, fontSize: 13),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('取消', style: TextStyle(color: _dim, fontWeight: FontWeight.bold))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isEmpty ? SettingsStore.playerName : ctrl.text.trim()),
            child: const Text('进入', style: TextStyle(color: _signal, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      SettingsStore.playerName = name;
      SettingsStore.save();
    }
    return name;
  }

  // ── 联机大厅：自动选服 → 进大厅 ──
  Future<void> _enterOnline() async {
    final name = await _askName();
    if (name == null || name.isEmpty) return;
    // 自动选服：测延迟 → 排除满员 → 延迟升序，50ms 内选人最少
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: SizedBox(
          width: 260, height: 150,
          child: Card(
            color: const Color(0xFF1A1916),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const CircularProgressIndicator(color: _signal),
                const SizedBox(height: 12),
                const Text('正在选择最优服务器…', style: TextStyle(color: Color(0xFFFFF5DC), fontSize: 13)),
                const SizedBox(height: 8),
                _pt('Tip: ${randomTip().text}', 10, _dim),
              ]),
            ),
          ),
        ),
      ),
    );
    final (server, _) = await autoSelectServer();
    if (!mounted) return;
    Navigator.pop(context); // 关 loading
    if (server == null) {
      _alert('暂无可用服务器', '目录服务无响应或所有服务器都连不上，请检查网络后重试。\n也可以稍后在大厅里手动输入 IP 连接。');
      return;
    }
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => LobbyScreen(server: server, playerName: name, packId: widget.packId)));
  }

  // ── 局域网：UDP 组播发现 + 创建者当主机（本地规则引擎）──
  Future<void> _enterLan() async {
    final name = await _askName();
    if (name == null || name.isEmpty) return;
    final fake = AimServer(
        id: 'lan', name: '局域网', host: 'lan', port: 45679, players: 0, maxPlayers: 99, version: '0.3.0');
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => LobbyScreen(server: fake, playerName: name, packId: widget.packId, lan: true)));
  }

  Future<void> _enterHotseat() async {
    // 本地对战：选地图大小 + 对手（玩家双人 / AI 三档）+ 规则开关（滚木能否被己方攻击）
    var allowOwnRollerAttack = true; // 默认开（保持「敌我皆可」）
    var aiLevel = _AiOption.values.first; // 默认玩家双人
    final pick = await showDialog<(int, bool, _AiOption)>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1916),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          title: const Text('选择地图大小', style: TextStyle(color: _warn, fontSize: 15, fontWeight: FontWeight.bold)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (final l in [12, 14, 16]) ...[
                InkWell(
                  onTap: () => Navigator.pop(ctx, (l, allowOwnRollerAttack, aiLevel)),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border)),
                    child: _pt('$l', 16, _signal, bold: true),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 14),
            // 对手选择：玩家双人 / AI 三档
            _pt('对手', 12, _dim),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final op in _AiOption.values)
                InkWell(
                  onTap: () => setDlg(() => aiLevel = op),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: aiLevel == op ? const Color(0xFF3A2A1C) : const Color(0xFF2A2824),
                      border: Border.all(color: aiLevel == op ? _signal : _border),
                    ),
                    child: _pt(op.label, 12, aiLevel == op ? _signal : _paper, bold: aiLevel == op),
                  ),
                ),
            ]),
            const SizedBox(height: 6),
            _pt(aiLevel.desc, 10, _dim),
            const SizedBox(height: 14),
            // 规则开关：滚木能否被己方攻击
            InkWell(
              onTap: () => setDlg(() => allowOwnRollerAttack = !allowOwnRollerAttack),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: allowOwnRollerAttack ? const Color(0xFF1C2E22) : const Color(0xFF2A2824),
                  border: Border.all(color: allowOwnRollerAttack ? _green : _border),
                ),
                child: Row(children: [
                  _pt(allowOwnRollerAttack ? '✓' : '✗', 14, allowOwnRollerAttack ? _green : _dim, bold: true),
                  const SizedBox(width: 8),
                  Expanded(child: _pt('滚木可被己方攻击', 13, _paper, bold: allowOwnRollerAttack)),
                ]),
              ),
            ),
            const SizedBox(height: 6),
            _pt(allowOwnRollerAttack ? '己方可以打掉自己滚木（清理路障）' : '己方滚木免疫己方攻击，只能由敌方击破', 10, _dim),
          ]),
        );
      }),
    );
    if (pick == null || !mounted) return;
    final (limit, allowOwn, opponent) = pick;
    final name = SettingsStore.playerName.isEmpty ? '玩家1' : SettingsStore.playerName;
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => HotseatScreen(
            playerName: name,
            packId: widget.packId,
            limit: limit,
            allowOwnRollerAttack: allowOwn,
            aiLevel: opponent.ai)));
  }

  void _alert(String title, String msg) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1916),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: Text(title, style: const TextStyle(color: _warn, fontSize: 15, fontWeight: FontWeight.bold)),
        content: Text(msg, style: const TextStyle(color: _paper, fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了', style: TextStyle(color: _signal, fontWeight: FontWeight.bold))),
        ],
      ),
    );
  }

  // ── 投喂小猫咪：微信收款码弹窗（横屏横排布局，不超屏；支持保存付款码到相册）──
  static const String _feedQrUrl = 'http://192.140.166.178:5000/downloads/wechat_qr.png';
  void _showFeed() {
    showDialog(context: context, builder: (ctx) {
      return Dialog(
        backgroundColor: const Color(0xFF1A1916),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        insetPadding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: min(560, MediaQuery.sizeOf(ctx).width * 0.94),
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.88,
          ),
          child: LayoutBuilder(builder: (ctx, box) {
            // 横屏比例：左二维码 + 右信息；图片高度受弹窗高度约束，保持正方形不溢出
            final imgSize = (box.maxHeight - 24).clamp(120.0, 280.0);
            return SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                // 左：收款码（网络加载，失败可重试）
                StatefulBuilder(builder: (ctx, setDlg) {
                  return ClipRect(
                    child: Image.network(
                      _feedQrUrl,
                      width: imgSize, height: imgSize,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      loadingBuilder: (c, child, progress) {
                        if (progress == null) return child;
                        return Container(
                          width: imgSize, height: imgSize,
                          color: const Color(0xFF11110F),
                          alignment: Alignment.center,
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: _orange, strokeWidth: 2)),
                            const SizedBox(height: 8),
                            _pt('正在加载收款码…', 10, _dim),
                          ]),
                        );
                      },
                      errorBuilder: (c, err, st) {
                        return Container(
                          width: imgSize, height: imgSize,
                          color: const Color(0xFF11110F),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.all(12),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            _pt('收款码加载失败（要联网）', 12, _dim),
                            const SizedBox(height: 8),
                            InkWell(
                              onTap: () => setDlg(() {}),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _orange)),
                                child: _pt('重试', 12, _orange, bold: true),
                              ),
                            ),
                          ]),
                        );
                      },
                    ),
                  );
                }),
                const SizedBox(width: 14),
                // 右：标题 + 说明 + 按钮
                Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _pt('🐱 投喂小猫咪', 16, _orange, bold: true),
                    const SizedBox(height: 6),
                    _pt('喵呜～求求啦～给小猫一个小鱼干叭～', 10, _dim),
                    const SizedBox(height: 4),
                    _pt('微信扫码 · 金额随意 · 投喂光荣', 10, _dim),
                    const SizedBox(height: 14),
                    // 保存付款码（下载到相册）
                    StatefulBuilder(builder: (ctx, setDlg) {
                      return InkWell(
                        onTap: () => _saveQr(setDlg),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(color: const Color(0xFF1C2E22), border: Border.all(color: _green)),
                          child: Center(child: _pt('💾 保存付款码到相册', 13, _green, bold: true)),
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () => Navigator.pop(ctx),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border)),
                        child: Center(child: _pt('收下猫的感谢', 13, _paper)),
                      ),
                    ),
                  ]),
                ),
              ]),
            );
          }),
        ),
      );
    });
  }

  // 下载收款码并保存到系统相册（Android 10+ 免权限；旧系统需存储权限已在 Manifest 声明）
  Future<void> _saveQr(StateSetter setDlg) async {
    final done = ScaffoldMessenger.of(context);
    try {
      final res = await http.get(Uri.parse(_feedQrUrl)).timeout(const Duration(seconds: 8));
      final bytes = res.bodyBytes;
      if (bytes.isEmpty) throw Exception('空响应');
      final name = 'aim_wechat_${DateTime.now().millisecondsSinceEpoch}';
      await Gal.putImageBytes(Uint8List.fromList(bytes), name: name);
      if (!mounted) return;
      done.showSnackBar(const SnackBar(
        content: Text('✅ 付款码已保存到相册', style: TextStyle(color: Color(0xFFFFF5DC))),
        backgroundColor: Color(0xFF1C2E22),
        duration: Duration(seconds: 2),
      ));
    } catch (_) {
      if (!mounted) return;
      done.showSnackBar(const SnackBar(
        content: Text('❌ 保存失败（检查网络或存储权限）', style: TextStyle(color: Color(0xFFFFF5DC))),
        backgroundColor: Color(0xFF3A1C1C),
        duration: Duration(seconds: 2),
      ));
    }
  }

  // ── 章节选择：从哪一章开始往后阅读 ──
  void _showChapterSelect() {
    showDialog(context: context, builder: (ctx) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1916),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: const Text('选择章节', style: TextStyle(color: _paper, fontSize: 16, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < tutorialChapters.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(context, MaterialPageRoute(
                          builder: (_) => TutorialScreen(
                              onExit: () => Navigator.of(context).pop(),
                              startChapter: i)));
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2824),
                        border: Border.all(color: _border),
                      ),
                      child: _pt('第${i + 1}章 · ${tutorialChapters[i]['title']}', 14, _paper),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }

  // 设置弹窗：资源包 + 边距
  void _showSettings() {
    showDialog(context: context, builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setDlg) {
        return Dialog(
          backgroundColor: const Color(0xFF1A1916),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          child: Container(
            width: min(300, MediaQuery.sizeOf(ctx).width * 0.92),
            padding: const EdgeInsets.all(16),
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.86),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              _pt('设置 // 资源包', 15, _signal),
              const SizedBox(height: 10),
              for (final p in widget.packs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: InkWell(
                    onTap: () {
                      widget.onPackChange(p.id);
                      Navigator.pop(ctx);
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: widget.packId == p.id ? const Color(0xFF3A2A1C) : const Color(0xFF2A2824),
                        border: Border.all(color: widget.packId == p.id ? _signal : _border),
                      ),
                      child: _pt('${p.name} · ${p.author}', 13, _paper),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              _pt('界面布局', 13, _paper),
              Row(children: [
                for (final (id, name) in [('classic', '经典'), ('compact', '简洁'), ('side', '侧栏')])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InkWell(
                      onTap: () {
                        setDlg(() => SettingsStore.layout = id);
                        SettingsStore.save();
                        setState(() {}); // 主菜单立即刷新（紧凑布局立即可见）
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: SettingsStore.layout == id ? const Color(0xFF3A2A1C) : const Color(0xFF2A2824),
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
                    inactiveColor: const Color(0xFF2A2824),
                    onChanged: (d) {
                      setDlg(() => SettingsStore.margin = d);
                      SettingsStore.save();
                      setState(() {});
                    },
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: _pt('${SettingsStore.margin.round()}px', 12, _orange, bold: true),
                ),
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
                    inactiveColor: const Color(0xFF2A2824),
                    onChanged: (d) {
                      setDlg(() => SettingsStore.bgmVolume = d);
                      SettingsStore.save();
                      BgmManager.instance.applyVolume();
                    },
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: _pt('${(SettingsStore.bgmVolume * 100).round()}%', 12, _orange, bold: true),
                ),
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
                    inactiveColor: const Color(0xFF2A2824),
                    onChanged: (d) {
                      setDlg(() => SettingsStore.voiceVolume = d);
                      SettingsStore.save();
                    },
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: _pt('${(SettingsStore.voiceVolume * 100).round()}%', 12, _orange, bold: true),
                ),
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
                    inactiveColor: const Color(0xFF2A2824),
                    onChanged: (d) {
                      setDlg(() => SettingsStore.sfxVolume = d);
                      SettingsStore.save();
                    },
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: _pt('${(SettingsStore.sfxVolume * 100).round()}%', 12, _orange, bold: true),
                ),
              ]),
              _pt('选中/移动/攻击/滚木/结算等战斗反馈音', 11, _dim),
              const SizedBox(height: 8),
              _pt('电脑端可在 ⚙ 设置里改快捷键', 11, _dim),
            ]),
            ),
          ),
        );
      });
    });
  }

  // 主页常驻小贴士：一行，点击换一条（10s 定时也会换）
  Widget _tipBar() {
    final t = kGameTips[_tipIdx];
    return InkWell(
      onTap: () => setState(_nextTip),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          _pt('Tip: ', 11, _warn, bold: true),
          const SizedBox(width: 6),
          Expanded(child: _pt(t.text, 11, _dim)), // 无分类前缀，直接显示 tip
        ]),
      ),
    );
  }

  Widget _seal() {
    final s = 72 * _scale;
    return Container(
      width: s, height: s,
      decoration: BoxDecoration(border: Border.all(color: _signal, width: 2)),
      child: Stack(children: [
        Positioned.fill(child: Padding(
          padding: const EdgeInsets.all(4),
          child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: _signal, width: 1))),
        )),
        Center(child: _pt('A', 34, _signal, bold: true)),
      ]),
    );
  }

  Widget _titleBlock(bool compact) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _pt('AIM', compact ? 38 : 56, _paper, bold: true),
      _pt('0 1 2 3 4 5 6 7 8 9', compact ? 11 : 13, const Color(0xFF787060)),
      const SizedBox(height: 4),
      _pt('数字即兵力——血与攻，都是数字本身。', compact ? 13 : 15, _paper),
      _pt('一场战争，把敌人的数字减到零。', 11, _dim),
    ]);
  }

  Widget _slogan() {
    if (widget.updateInfo == null) return const SizedBox.shrink();
    final nv = widget.updateInfo?['version'] ?? '?';
    return InkWell(
      onTap: () {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1916),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            title: const Text('新版本下载', style: TextStyle(color: Color(0xFFFFD36A), fontSize: 15, fontWeight: FontWeight.bold)),
            content: Text('下载页：${widget.updateInfo?['downloadPage'] ?? 'http://192.140.166.178:5000/'}',
                style: const TextStyle(color: Color(0xFFFFF5DC), fontSize: 14)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了', style: TextStyle(color: Color(0xFFFF4E35), fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _orange)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _pt('发现新版本 v$nv', 11, _orange),
          const SizedBox(width: 6),
          _pt('点此下载', 11, _signal),
        ]),
      ),
    );
  }

  Widget _rules() {
    const rules = [
      ('01', '数字即兵力', '有多少血，就有多大力'),
      ('02', '回合二选一', '造兵养势，或行动攻伐'),
      ('03', '打穿成桥', '溢出的伤害，长出独木桥'),
      ('04', '吞噬合一', '吞敌吞己，吞出基地与指挥'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _pt('· 玩法速览 ·', 12, _signal),
      const SizedBox(height: 4),
      Wrap(
        spacing: 16, runSpacing: 4,
        children: [for (final (no, t, d) in rules) _ruleItem(no, t, d)],
      ),
    ]);
  }

  Widget _ruleItem(String no, String t, String d) {
    return SizedBox(
      width: 168 * _scale,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _pt(no, 12, _signal),
        const SizedBox(width: 6),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _pt(t, 13, _paper),
          _pt(d, 10, _dim),
        ]),
      ]),
    );
  }

  Widget _bottomBar() {
    return Row(children: [
      _pt('AIM ${AppConfig.appVersion} · 数字大战', 10, _dim),
      const Spacer(),
      _pt('资源包 //', 10, _dim),
      const SizedBox(width: 6),
      if (widget.packs.isNotEmpty)
        InkWell(
          onTap: () {
            final i = widget.packs.indexWhere((p) => p.id == widget.packId);
            final next = widget.packs[(i + 1) % widget.packs.length];
            widget.onPackChange(next.id);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border)),
            child: _pt(widget.packs.firstWhere((p) => p.id == widget.packId,
                orElse: () => widget.packs.first).name, 11, _paper),
          ),
        ),
    ]);
  }

  Widget _pt(String s, double size, Color c, {bool bold = false}) {
    return Text(s,
        style: TextStyle(color: c, fontSize: size * _scale, fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            height: 1.2));
  }
}
