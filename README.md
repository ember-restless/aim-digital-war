# AIM — 数字大战

> 牢大 2026-08-11 发明于学校计算器上的游戏，离离实现为联机像素风游戏。
> 当前版本 **v1.0.0**（APK 35.4MB，含日语配音 + 双 BGM + 战斗语音）

## 基本信息
- **游戏名**：AIM（数字大战）
- **规则文档**：`docs/RULES.md`（牢大 2026-08-11 口述，已确认）
- **玩法**：一维地图（上限12~16格偶数，初始一半），数字=兵种+血量+攻击力。两端基地8（造兵点），指挥部9（行动点，只能合出来）。每回合二选一：造兵 or 行动（移动/攻击/拆分/吞噬各1行动点）。伤害溢出在单位前方硬插独木桥（地图+1），吞噬合体超9按十进制字符爆开（变拉）。胜利=敌方数字和为0。
- **核心机制**：地图格子动态增减（插桥+1/拆分+1/吞噬-1/踩桥-2）；骑兵固定走2格；独木桥 1~4 可过、5+ 踩塌同归于尽、小兵1过桥拆桥、滚木克星；滚木自动前进3格。

## 项目结构（/root/aim/）
```
server/          # Node.js + Socket.io 联机服务器
  src/index.js   # 联机服务器入口（Socket.io 游戏服务）
  src/game/rules.js      # 规则引擎（服务端权威，全部判定在这）
  src/game/RoomGame.js   # 房间状态机
  test/          # rules_test.js / rules_extra_test.js
client/          # Flutter 手机端（Android APK）
  lib/tutorial/  # 新手教程：tutorial_engine.dart（本地迷你规则）/ tutorial_script.dart（9章剧本）/ tutorial_audio_map.dart（台词→音频）/ board_anim.dart（入场退场动画）
  lib/widgets/hit_fx.dart # 打击动画公共组件（游戏+教程共用）
  lib/bgm_manager.dart    # 双 BGM 管理器（idle/battle 独立循环播放器）
  lib/settings_store.dart # 设置持久化（布局/边距/BGM音量/语音音量）
  assets/audio/tutorial/  # 129 句日语配音（6 音色，6.5MB）
  assets/audio/bgm/       # bgm_idle.mp3（95s）/ bgm_battle.mp3（125s）
  assets/art/default/     # 像素资源包：units/（0-9/敌版/桥）+ portraits/（7 张角色立绘）
win_client/      # Python/pygame Win 端
docs/            # RULES.md（规则）/ tutorial_story.txt（9章剧本定稿）
```

## 功能特性（v1.0.0）
- **新手教程（9 章剧情）**：Legio Numeri 军团故事，客户端本地实现不依赖服务器；galgame 式对话框（打字机逐字+点击音效）、7 张角色立绘、选项横置中间（明日方舟风）、教学等待时对话框隐藏改用像素风气泡引导（低饱和暗金/暗绿）、章节选择弹窗（菜单→教程）
- **日语配音**：129 句台词 6 角色专属音色（1/2/3/4/5/7 号；前指挥官和主角无 CV），内嵌 APK；语音生命周期绑定字幕——字幕被切走立即停，切句时停旧播新（代次计数器防竞态）
- **双 BGM**：非战斗（主界面+教程循环 bgm_idle）+ 战斗（对局中循环 bgm_battle），独立异步播放器不抢音频焦点（audioFocus none）、不跟语音打架；设置面板分别调 BGM/语音音量
- **逐格动画**：游戏本体多格移动/滚木一格一格走（对比新旧棋盘 diff）；被攻击单位白闪+斜刀光+数字渐变+红边脉冲（600ms，游戏+教程同款）；教程棋盘入场（中间先落对称弹开）/退场（数字朝自家方向飞走淡出）/退出动画
- **滚木绑定模型（2026-08-17 牢大定稿）**：滚木只有在一格一格**滑行时是浮层**，滑完一格就**绑定回棋盘对应格**（脚下压着被压单位，带 id）；绑定期间有其它动画（插桥让位/白闪）时保持绑定、**跟着格子一起位移**——「被推开」=插入动画的推开效果，没有独立 bump 滑行；要再滚时再变回浮层。每规则步 = 1 格滑行 + 绑定。

## 技术要点（踩坑记录）
- **规则引擎**：服务端权威计算，客户端只发指令（防作弊+双端一致）。格子结构 `{v, o, bridge?, onBridge?}`；0空地/桥=中立，o=0我方 o=1敌方；onBridge=单位站在桥上（桥地形保留）。
- **插桥方向**：牢大说"默认左边（负数-在左）"，代码实现为插在单位**前方**（朝敌方向，splice(i+dir,0)），硬插不管两边是什么；满员不插。
- **滚木索引坑**：applyDamage 的 splice 会改变数组索引，autoRoll 必须用**对象引用+indexOf**定位滚木，不能存索引；插桥位置<=滚木pos时要pos++修正；已碾单位用 Set 防重复碾。
- **滚木绑定模型实现（2026-08-17）**：`_playRollActs` 每规则步 = 1 格滑行 + 绑定（bindAt：move/kill/crush无桥→to；crush插桥→at+1 桥右）；`_startMoveAnim` 加 `bindAt` 参数，浮层到达后把 6 写回动画棋盘对应格（`{id: rid, v:6, o, pressedV, pressedO}`）并置 `_mv['bound']=true`，渲染层 bound 时不再画浮层；含 dead 动作的步骤（尽头插桥被顶出地图）走旧 bump 逻辑。
- **渲染 key 坑（绑定模型）**：被压单位的原 id 在规则棋盘只存了 v/o 没存 id，清滚木本体时沿用 rid 会跟绑定格撞 `ValueKey('cell$id')` 崩溃 → clearCell 清滚木本体统一用假 id（fakeId--），顺带修掉「cleanup 把刚露出的被压单位误清一帧」的旧 bug。
- **旧回放路径分流（2026-08-18 教训）**：`applyRollStep` 的插桥分支按 `bindAt` 分流——绑定模型（热座/局域网）先绑后挤+置 bound；旧路径（_detectRoll/联机回放，无 bindAt）保持浮层逻辑（单位右移、不写 6 进棋盘、不置 bound）。当初无条件先绑后挤导致 bound 泄漏：浮层被隐藏 + 6 被 placeUnit 清掉 = 6 凭空消失、cleanup 才闪现。
- **插入动画（2026-08-18 平滑推开，真正的根因修复）**：动画期间**步距固定**（cellSize 用规则棋盘长度算，插桥不重排）；偏移公式按**实际居中位移**精确计算——左格跟随 centerDelta（手机棋盘恒溢出=0）、右格 -step*(1-t)，t=0 时每格恰在旧位置、任意屏宽零跳变。原实现 cellSize 随动画棋盘实时重算+补偿写死 ±0.5 格（假设居中），手机窄屏插桥瞬间整盘塌缩（6 被挤得失位，观感「消失后闪现」）。
- **建筑限制**：8/9 不可移动/攻击/吞噬（只能拆分）；吃伤害降级（8受1伤→7可动，9受1伤→8）。
- **拆分满员**：保大保小由拆分方选（action 带 keep: big|small）；拆分产物固定插到保留值右侧（索引+1，不随阵营方向）。
- **盾兵屏障**：盾兵7本体+其身后（朝己方）友方免疫弓兵3/炮兵4远程伤害（0伤害无提示、行动点照扣）。
- **Flutter 构建**：必须用 `/opt/flutter/bin/flutter`（snap 版 3.44.9 有 native_plugin_loader bug 必失败）；`--no-version-check` 防 git fetch 卡死；构建约 70-130s，含音频后 APK 34.5MB。
- **pub 依赖卡死**：pub.dev 主包下载会挂，解法 `timeout 150 env PUB_HOSTED_URL=https://pub.flutter-io.cn /opt/flutter/bin/dart pub get`（清华镜像）。
- **audioplayers 音频焦点坑**：多个 AudioPlayer 默认抢 audio focus，台词一响 BGM 就被暂停且不恢复 → BGM 播放器 `setAudioContext(AudioContext(android: AudioContextAndroid(audioFocus: AndroidAudioFocus.none)))`；注意 6.6.0 没有 handleAudioFocus 参数（旧 API），AudioContextIOS 不是 const 构造。
- **打击动画判定**：diff 新旧棋盘——同位置同方数字减小→受击；单位消失且别处无同 v+o→击杀；排除拆分（原位保留+相邻产物和=原值）；排除移动。
- **CustomPaint 聚光灯在 Impeller 下不显示** → 教程引导用纯 widget（发光边框+浮动箭头）。
- **pygame**：服务器上装 pygame 用清华镜像（pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple pygame python-socketio），需要 --break-system-packages。
- **联机测试**：server/test/net_test.js（Node 双客户端）+ win_client/integration_test.py（Python 双客户端自动对战30回合）均通过。

## 近期更新（2026-08-18 晚 ~ 08-19 凌晨，牢大实测驱动）

### 动画节奏（22:22）
- 滚木每步之间加 400ms 间隔（`_rollStepGapMs`）；压单位停顿 660→1050ms（`_rollCrushPauseMs`）；死亡停顿 400→800ms（`_rollDeadPauseMs`）。滑动本身 260ms/格不变。

### 教程剧本 choice 文案（22:34，tutorial_script.dart）
- 「酒」→「酒？」；第二章玩家问话→「你知道这儿战场的规则吗？」；第九章→「你知道战场约定是什么吗？」（branch key 与选项文本必须一致）。

### 删除动画统一（23:50 牢大定稿：基本动画只写一套）
- **废弃** `_addRemoveAnim`/`_removes` 顶层覆盖层方案（残影遮挡浮层、位移带偏、闪烁帧，牢大嫌突兀）。
- **删除统一用吞噬那一套 `_shiftCtrl`**：removeAt 直接删格（无残影/无白闪）+ 400ms 左右各半格补位。撞桥死停后删桥格（含 6）、重单位走桥塌桥均走这套。
- 插入统一 `_addInsertAnim`（插桥/拆分/滚木插桥共用）；移动统一 `_startMoveAnim`。

### 重单位走桥（00:00）
- 缺移动动画（5 呆原地桥删了人才消失）→ `_startMoveAnim` 加 `holdAtEnd` 参数（cleanup 保留动画棋盘），先播逐格移动走到桥，onDone 里删桥格+补位+`_finishAnim`。
- **桥塌人亡少一格**：doMove 改为单位**原地变空** + 桥格删除（-1），`850-128` 中 5 走两步 → `800128`（旧实现删 2 格变 80128）。双端（rules.dart/rules.js）。

### 幽灵格子（困扰已久的真根因，00:00~00:55）
- **规则层排除**：fuzz 88456 步行动 + 大量滚木轮次，长度零漂移（检测要点：行动前重置 points 防 maybeAutoEnd 自动滚木干扰；滚木阶段 rollSteps 可能残留，只对比 endTurn 前后实际变化）。
- **onBridge 残留修复**（先修）：桥上单位受溢出伤害被新桥挤开，onBridge 残留 → 走开时凭空造桥（1 座桥变 3 座）。applyDamage 溢出插桥后按新位置脚下重判 onBridge（双端）。
- **setState during build 根因（主修复）**：GameScreen didUpdateWidget（build 阶段）里**同步** emit('roll_step') → onEvent → 外层（hotseat）setState 在 build 期间被调用——debug 模式抛 assert 被 try-catch 吞、release 时序脆弱 → state 同步失败时显示层停留在旧动画棋盘（幽灵格子「有时候有」= 帧时序竞争）。修复：条件 2 的 emit 延迟到帧后（`addPostFrameCallback`）。
- 新增 widget 级测试 `test/ghost_cell_test.dart`（HotseatHarness 模拟真实桥接）：80000568 滚木撞桥完整流程，显示层最终格子数与规则棋盘一致。

### 热座撞桥死多一格（08-20，牢大实测反馈）
- **现象**：热座/局域网 80000568，6 往左滚压 5 溢出插桥后撞桥死，滚完后棋盘比规则多一格（牢大：地图最右边多一个 0）。
- **根因**：`_playRollActs`（逐步驱动）的 dead 分支只给 `reason=='fall'` 加 `bridgeCollapse` 标记，但规则层实际只发 `edge/bridge/building`（'fall' 是历史遗留值）→ 撞桥死时 6 不落位桥格，死停期动画棋盘 = 桥 + 露出的 1 两个格子（9 格 vs 规则 8 格）。联机路径（_detectRoll + 服务端全量 rollSteps 含 bridgeCollapse）一直是对的。
- **修复**：`reason=='bridge'` 也带 `bridgeCollapse` → 6 落位桥格（死停期显示桥+6 整体，牢大 08-18 定稿），死停后整格删除回 8 格，与联机一致。
- 新增 `test/dead_bridge_fix_test.dart`（渲染层验证：死停期无 dash 桥图标=6 已落位，结束 8 格）；顺手修了 `devour_anim_test.dart` 的收尾 timer 泄漏。

### 幽灵格子兜底防御（08-20，牢大：删除动画播完后最右边忽然多一格 + 1 操控不了）
- **现象**：牢大实测（热座，先行动自动过回合触发滚木），撞桥删除动画完整播完后，棋盘最右边忽然多一个空位（像 0），一直显示、操作不了、不计入格子上限；且"80000108"里的 1 点不动。widget 测试与 fuzz（60 步随机操作）均无法复现——真实环境某条动画路径漏收尾。
- **根因链**：动画棋盘（_animCells）残留 9 格 → 渲染 9 格 vs 规则 8 格（幽灵格）→ 棋盘总宽按 9 格排布、点击坐标错位 → 点"1"实际点到旁边的空位（操控不了）。两种残留态：`_animLock=false` 漏清、`_animLock=true` 卡死（锁着但无任何动画控制器在播）。
- **防御 v3**（双保险 + 卡死超时，GameScreen）：
  - didUpdateWidget：`_animLock=false` 但 `_animCells` 残留且长度≠规则棋盘 → 强制清理。
  - `_mapArea` 渲染兜底：`_animLock=false` 时 `_animCells` 长度≠规则棋盘 → 回退显示规则棋盘（每次 build 生效）。
  - 卡死解锁：`_animLock=true` 但 `_stepCtrl/_shiftCtrl/_inserts/_hits 全空且非死停` 持续 >2s → 强制解锁+回退（_finishAnim 收尾窗口 ≤1.5s 不误伤，死停期 _rollPaused=true 不误判）。
- 新增测试：`fuzz_ghost_test.dart`（随机操作 fuzz）、`auto_end_roll_test.dart`（行动+自动过回合+滚木）、`dead_bridge_fix_test.dart`（撞桥落位）。

### auto 残留卡行动（08-20 晚，牢大：滚木滚出来的 1 能选中但点不了攻击/吞噬/拆分，之后造兵也没了）
- **根因**：滚木脚下压着的单位被 unpress 转正时硬编码 `auto: true`（滚木激活标记残留）→ `doMove/doAttack/doDevour/doSplit` 的 `if (x.auto) return false` 全部拒绝 → 行动点了没反应（静默）；且点攻击时阶段已隐式锁 action，回头造兵也被规则拒绝。这就是"80000118 里第一个 1 操控不了"。
- **修复**（双端 rules.dart/rules.js）：
  - 执行检查改为 `if (x.auto && x.v == 6)`——只有激活滚木（6）不可操控，非 6 单位带残留标记也能正常行动。
  - unpress 转正 `auto: pressedV == 6`——转出来是 6 才保留激活标记。
- 验证：滚完的 1 auto=false；auto=true 残留的 1 攻击/移动正常；服务端 rules_test 全过；客户端 65 测试通过（仅 devour_shot_test 因 audioplayers 插件缺失超时，与本次无关）。

### 幽灵格子真根因：动画假 id 撞 key（08-20 晚，牢大给完整复现序列）
- **复现序列**（牢大实测）：81000008 → 81000018 → … → 85000058 → 80050058 → 80050068 → 80000568（13 回合造兵升级+移动），最后 6 往左滚撞桥 → 幽灵格。**只有这个序列触发**（移动 5 走 2 格 + 点数耗尽自动过回合 + 滚木同帧）。
- **根因**：`_startMoveAnim` 的假 id 计数器 `fakeId` 是**局部变量、每次从 -1 重新数**。移动动画给路径格子分配假 id（如 -1）→ 动画结束这些 id 残留在棋盘 → 紧接着滚木动画（`_deferredRoll` 链，base=上一动画棋盘）又从头分配假 id → **两个格子撞同一个 key（Duplicate keys）** → debug 直接 build 崩、release 渲染错乱（牢大看到的"幽灵格/操作不了"）。widget 测试复现：t=500ms 起 `Duplicate keys found: [<'cell-1'>]` 棋盘整个消失。
- **修复**（game_screen.dart）：
  - `fakeId` 改为 State 级全局计数 `_fakeId`（负值向下递增，动画结束存回）——跨动画永不重复。
  - 攻击插桥、拆分产物等动画新建格子统一用 `_fakeId--` 分配 id（原来无 id 会 fallback 索引，也可能撞真实 id）。
- 新增 `test/move_autoend_roll_test.dart`（移动2步+自动过回合+滚木，逐帧验证无幽灵格）。

### 教程四连修（08-21，牢大：第一章消失 / 第四章跳变 / 第七章滚木 / 前指挥官号）
- **第一章「敌方兵移动时我方兵会消失」**：剧本 board `['8','1','0','0','0','0','1','9']` 的格6/格7 **漏写花括号** → `{1}` 写成 `'1'`、`{9}` 写成 `'9'`，被解析成我方单位。演示时"敌方"移动的其实是己方 1，`placeUnit` 按 `v==v && o==o` 清格时把格1 的己方 1 也清掉 → 动画期间消失。修复：`['8','1','0','0','0','0','{1}','{9}']`（敌方必须写 `{x}`）。
- **第四章「敌方移动时地图明显变化」→「{2} 移动前突然换位置」**：原剧本中场 board 把 {2} 从格4 瞬移到格6、再 auto move 走回格4（绕一圈回原点，牢大看着就是"移动前突然换位置"）。修复：**删掉中间 board 和 auto move**，{2} 攻击后一直保持格4；Quintus 登场 board 只插入 5（格3），3/{2} 全程不动，地图 8→9 格只有插入动画。
- **第七章「滚木滚动动画明显问题」**：`_startTutMv` 溢出插桥用**覆盖式**（8 格棋盘里桥盖在格2、4 号塞格3）而引擎真插入（9 格）→ 动画结束地图突然多一格；且滚木浮层滚到被顶开的 4 号格时 `placeUnit` 把 4 号覆盖成滚木 → 4 号短暂消失。修复：bridge 子步改 `anim.insert`（动画棋盘与引擎同步 +1 格）；滚木模式下 from 格若是其他单位保留原内容（浮层掠过）；插桥后白闪移到被顶单位新位置。
- **「前指挥官号」**：`_portraitName()` default 分支 `'$key号'`，`前指挥官`/`旁白` 没匹配命名分支 → 显示"前指挥官号/旁白号"。修复：加 '前指挥官'/'旁白' 直返分支。
- 新增 `test/tutorial_fix_test.dart`（第一章归属/第四章 diff/第七章滚木序列/说话人名字 5 个回归测试）+ `tool/tut_repro.dart`（教程动画复现脚本）。

### 教程动画对齐热座模板（08-21，牢大：教程动画还有问题，别自己独立一套，直接用热座模板）
- **根因**：教程一直维护自己的一套迷你规则（TutEngine）+ 一套动画（_startTutMv 浮层），与热座（rules.dart + GameScreen._startMoveAnim）行为分叉，动画永远修不完。
- **教程规则对齐游戏**：
  - TutCell 增加 `pressedV/pressedO`（滚木脚下压着的单位，对齐 AimCell）——滚木压单位时棋盘只显示滚木，走开才露出。
  - `rollStep` 重写为游戏 `_rollOneStep` 同款语义：每步先露出脚下（_unpress）；撞桥/建筑/越界死；第三格抹杀；一二格压 6 伤，**溢出插桥后滚木站到桥右压着被顶单位（p+1）**（旧逻辑是跳两格 p+2，与游戏不一致）；`_applyDamageAt` 对齐游戏 applyDamage（含 onBridge 死）。
  - `autoRoll` 改为循环 `rollStep`。
- **教程动画对齐游戏绑定模型**：
  - `placeUnit` 改用 **id 精确定位**移动单位（旧逻辑 v/o 匹配，场上同数字单位会被误清）。
  - 压单位（crush）→ 滚木**绑定棋盘格**（显示滚木、压着单位，浮层隐藏）；溢出插桥先绑定再 insert（splice 语义，格子被挤到桥右）；下一步滑行前 placeUnit 清掉滚木露出被压单位。
  - 子步方向 bump 固定 +1；浮层起点按前 step-1 个子步累计（旧公式 oldIdx+dirn*(step-1) 插桥后错位）。
  - 棋盘格宽公式按**规则棋盘长度**算（插桥 8→9 瞬间不整盘重排塌缩）。
- 验证：教程滚木与游戏 rules.dart 同场景最终棋盘一致（00-460007）、中间过程一致（压着4号）；17 个教程测试全过（含更新后的绑定模型断言）。

### 联机大厅规则层对齐热座（08-21，牢大：局域网和联机大厅更新到跟热座一样）
- **背景**：热座/局域网早已用逐步滚木（roll_step 协议：规则算一步 → 动画播一步），但**联机大厅服务端（Node rules.js）还是全量 autoRoll + rollSteps 回放**（客户端走旧的 _detectRoll 全量路径）——规则层/动画层行为跟热座分叉。
- **rules.js 补齐逐步滚木接口**（对齐客户端 rules.dart）：`beginRoll` / `rollStepOnce`（返回该步基础动作序列）/ `hasPendingRoll` / `clearPendingRoll`，内部 `_rollOneStep`（unpress 露出脚下、压 6 伤、溢出插桥站桥右压着、第三格抹杀、撞桥/建筑/滚出死）、`_finishRoll`（rollSeq++/rollSteps 汇总）。
- **endTurn 支持 deferRoll**：手动 endTurn 延后滚木（标记 `_pendingRoll`），由客户端逐步驱动；maybeAutoEnd 自动过回合仍全量滚（与 rules.dart 一致）。
- **RoomGame**：`handleAction` 改 `applyAction(..., true)`；新增 `handleRollStep` / `hasPendingRoll`；`viewFor`/`viewForSpectator` 补 `rollPending`/`rollActs`/`rollStepSeq`（与热座 viewFor 同格式）。
- **index.js**：新增 `roll_step` 事件处理（对齐 lan_server：算一步 → broadcastGame → winner 检查 → game_over）。
- 验证：Node 单测复刻 80000568 场景（滚木压 5 溢出插桥 + 撞桥死），逐步驱动与全量 autoRoll 结果完全一致（`8002010{8}`，8 格无幽灵格）；RoomGame 逐步链路（endTurn → rollPending=true → rollStepOnce×2 → 撞桥死）正常。
- 局域网（lan_server.dart）早已用 rules.dart + roll_step，无需改；客户端 GameScreen 动画层双端通用，联机自动走热座同款绑定模型动画。

### 规则开关：滚木能否被己方攻击（08-21，牢大：进游戏前可选）
- **需求**：进入游戏前可选启用规则「滚木是否能被己方攻击」。当前攻击目标生成是「敌我皆可」，默认保持现状（可攻击己方滚木，用于清理自己阵前的滚木路障）。
- **规则层**（双端对齐）：
  - `rules.dart`：`AimGame({limit, allowOwnRollerAttack = true})`；`genUnitActions` 攻击目标生成时跳过己方滚木（`!allowOwnRollerAttack && t.v == 6 && t.o == owner`）；`doAttack` 同样校验（本地引擎防伪造）。
  - `rules.js`：`createGame({limit, allowOwnRollerAttack})` 存 `state.allowOwnRollerAttack`；`genUnitActions`/`doAttack` 同款校验（联机服务端权威判定，防伪造操作）。
  - 开关**只针对滚木（6）**：己方普通单位仍可被己方攻击（「敌我皆可」不变）；敌方击破己方滚木不受开关限制。
- **UI**：
  - 热座：选地图大小弹窗内加开关（✓ 滚木可被己方攻击，默认开）→ HotseatScreen → LocalAimSocket → AimGame。
  - 联机/局域网：创建房间弹窗内加开关（创建时定死）→ `create_room` 带 `allowOwnRollerAttack`（Node 端存 room 字段，start 时传入 createGame）；局域网 LanServer 构造同参。
  - 房间页：座位下方显示当前规则状态（滚木可被己方攻击 / 己方滚木不可被己方攻击），所有玩家可见。
- 验证：`test/allow_own_roll_test.dart` + `server/test/allow_own_roll_test.js`（默认开可打、关后选项消失+执行拒绝、己方普通单位仍可打、敌方不受限）双端全过；roll_step/rules_local/auto_end/ghost_cell 回归 21 测试全过。

### 战斗语音：选中/移动/攻击 × 6 角色（08-21 晚，牢大定稿 36 条**日配**）
- **需求**：战斗中选中单位、下达移动、下达攻击三类语音；1/2/3/4/5/7 六个角色（6 滚木、8 基地、9 指挥无语音）；每人 6 句 = 每类 2 句随机轮换。
- **文案**（牢大定稿，`design/battle_voice.md`）：中文内容稿 → **翻成日文 + 语气处理**（牢大：不能直给台词，会生硬——结巴「は、はい！」、促音「へへっ/えいっ」、长音「～/——」、省略号「……」、终助词「ぞ/ぜ/だよ/か」全保留进合成文本）。人设对齐教程：1 新兵紧张结巴（敬语）、2 欢脱少女骑手（活泼だよ/ね）、3 沉默弓手（极简俺）、4 冷淡毒舌炮兵（だが/か）、5 豪爽大汉（俺/だぜ/ぞ）、7 沉稳老兵（郑重）。小兵选中第一句改为「は、はい！し、新兵プリムスです！」（原"到、到！新兵 Primus，报到！"太生硬，牢大要求改）。
- **生成**：音色码 `/tmp/batch_tts.py`（1→S_1FdrG37a2 等 6 个），豆包 TTS（`/opt/speak_volc.py` + `/root/.lili_volc_config.json`）；`tool/gen_battle_voice.py` 批量合成 36 条（中文版误合一次后全删重合成日文版）→ `assets/audio/battle/`（battle_<select|move|attack>_<角色>_<a|b>.mp3）。
- **播放器**（game_screen.dart）：单 AudioPlayer `_battleVoice` + `_voiceBusy` 互斥锁——**播放中新触发直接丢弃**（牢大 08-21：一次必须等一个语音播完才响应下一个）；先订阅 `onPlayerComplete` 再 play；失败 catchError 解锁；随机 a/b。
- **触发点**：选中=3 处 `_clickCell` 选中/切换分支；移动/攻击=统一 `_emitAction`（替换 6 处 `emit('action')`），下令瞬间按 `action['i']` 源单位 v 播对应语音；**归属守卫**（`o == yourIdx` 才播，局域网/联机只播我方语音）；音量走 voiceVolume（0 时跳过）；devour/split/produce 不播。

### v1.0.0 收尾三件套（08-22 凌晨，牢大定）
- **版本号 1.0.0**：客户端 `config.dart`（appVersion/appVersionCode 3）+ 服务端 `config.js`（APP_VERSION/APP_VERSION_CODE 3）+ README；顺手修了 `api/version` 的 `apkUrl` 指向 bug（`/aim.apk` → `/downloads/aim.apk`，之前客户端检查更新会 404）。
- **systemd 常驻**：`/etc/systemd/system/aim-server.service`（Restart=always + 开机自启），替换 nohup 裸跑——**当晚 AIM 服务真的挂了（HTTP 000），systemd 拉起来后稳定**；重启 `systemctl restart aim-server`。
- **死局判负**（牢大：一方无法移动/攻击/吞噬/拆分 → 直接判负）：`maybeAutoEnd` 的"无可用行动自动过回合"改为**判负**（`winner = 1 - turn`），双端 rules.dart/rules.js 同步；点数耗尽自动过回合保留（正常流程）。新增 `test/deadlock_lose_test.dart` + `server/test/deadlock_lose_test.js`（只剩锁死滚木→判负；正常局面/只剩基地8可拆分→不误伤）双端全过。

### 断线重连（08-22 凌晨，牢大：掉线别立刻判负，来个重连）
- **需求**：联机对局掉线不再立即判负，给重连窗口。
- **服务端**（RoomGame.js + index.js）：
  - `removePlayer` 改造：playing 掉线 → 标记 `disconnected + disconnectAt`，**座位保留不判负**（热座/waiting 仍按原逻辑移除）。
  - `tryReconnect(socketId, name, idx)`：playing + 该座位 disconnected + **名字匹配** → 恢复（更新 socketId、清标记）。名字不匹配/对局已结束拒绝。
  - `tick()`：index.js 全局 5s 定时器驱动——掉线 **30s 超时判负**（对方赢）；**当前回合方掉线 15s 自动过回合**（全量滚，游戏不卡死）；返回 changed → `endGameBroadcast`（broadcastGame + game_over 给玩家与观战者）。
  - `join_room` 支持 `reconnectIdx`：重连玩家直接恢复座位 + 立即推 `you_are`/`room_update`/`game_state`（棋盘无缝恢复）；密码仍校验。
  - disconnect 不再解散 playing 房间（全掉线也等 tick 判负）；waiting 无人仍解散。
- **客户端**（lobby_screen.dart）：`you_are` 时记录重连上下文（roomId/playerIdx/名字，观战不参与）；断线 → 「连接断开，正在重连…」遮罩（盖在 GameScreen 上）+ 30s 超时；socket.io 底层自动重连（默认开启、无限重试）→ 重连成功 hello → 自动 `join_room(reconnectIdx)` → 恢复棋盘；重连被拒（对局已结束等）→ 放弃重连回大厅。局域网模式不重连（本地主机，断线=退出）。
- 验证：`server/test/reconnect_test.js`（6 单测：掉线不判负/重连成功/非法拒绝/30s 判负/15s 自动过回合/可循环）+ `server/test/reconnect_e2e_test.js`（连真实服务：建房→掉线 1.5s 不判负→重连恢复座位与棋盘→重连后操作正常）全过。

### AI 对手（08-22 凌晨，牢大拍板：热座弹窗入口 / 三档 / 本地跑）
- **架构**：AI 只做决策层（`client/lib/game/ai.dart`，AimAi），不碰规则引擎——从 `getLegalActions` 结果里按评分选行动；本地跑（热座玩家 vs AI），AI 固定玩家1（后手）。
- **三档**：`easy` 随机行动（新手练手）→ `normal` 启发式评分 → `hard` 加强（防守意识 + 远程威胁规避）。
- **评分**：攻击（目标数字×2、7/8/9 加成、一击消灭 +150、溢出插桥 +40、盾兵屏障拦截、不主动自残）、吞噬（合成 9=+400 / 8=+250 / ≥6=+120、吞敌方威胁×4）、移动（向前推进、1 拆桥 / 5·7 过桥塌 -800、hard 规避远程射程）、拆分（仅拆轻单位过桥）、造兵（基地前有敌方→造兵攻击）。
- **阶段选择**：有高价值行动（评分≥60）→ action；否则普通档偏养兵、困难档偏积极。
- **驱动**（local_socket.dart）：`aiLevel` 非空时玩家1 由 AI 自动决策，每行动延迟 700ms（像在思考）；`_pushState` 后 `_maybeDriveAi` 递归驱动，AI 的 endTurn/滚木走同一套逐步协议。
- **UI**（menu_screen 热座弹窗）：对手选择「玩家双人 / AI·简单 / AI·普通 / AI·困难」+ 原有地图大小/滚木开关；HotseatScreen 加载页显示对手档位。
- 验证：`test/ai_test.dart` 6 测试（easy 决策全合法、消灭优先、合成8优先、不自残、阶段选择、**AI vs AI 完整对局 400 步不卡死行动全合法**）全过；canvas_hotseat/roll_step 回归不受影响。

### 困难 AI 滚木战术（08-22 凌晨，牢大：滚木是刷兵机不是公害）
- **机制确认**：滚木每回合开始方滚 3 格（endTurn 后 `_pendingRoll` 用**新回合方**判断，即"轮到你时你的滚木先滚"）；第1/2格压伤、第3格抹杀、撞桥/建筑死；`beginRoll` 每回合清 `_rsDone` → 可持续喂。
- **hard 新增滚木配合**（`_rollerScore`，ai.dart）：
  - 路径通畅检查（滚木到目标格之间无桥/建筑阻挡，目标本身非桥）——喂兵位置必须滚木滚得到。
  - **喂兵**：把 1 移到滚木前第1/2格 = 被碾升级（1→5 净赚4，+110；2→4 +55；3 白挨；≥4 被碾降级 -160）——1 在路径上不浪费（移动保持升级区）。
  - **逃离**：己方 ≥4 单位在滚木路径上会被碾亏 → 移走加分（5 骑兵两步跑出路径）。
  - **死亡区**：滚木第3格=抹杀 → 绝不送单位进去（-200）。
- 验证：`test/ai_test.dart` 扩到 11 测试——喂兵链路（规则级两回合：1→5+插桥）、1 保持升级区、大单位逃离、死亡区规避、AI vs AI 对局全过。

### 对局统计 + 结算页（08-22 凌晨，牢大：这个好！）
- **引擎统计**（双端 rules.dart/rules.js 对齐）：`state.stats = { kills:[2], losses:[2], produce:[2] }` + `turnCount`。
  - `applyDamage` 加 `byOwner` 参数：攻击/造兵攻击传攻击者 → 致死记 `kills[byOwner]++`；所有死亡（含滚木碾死）记 `losses[阵亡方]++`；**滚木碾死不记击杀**（公害）。
  - 吞噬目标阵亡 → kills/losses；造兵成功 → produce++；endTurn → turnCount++。
  - `viewFor`/`viewForSpectator` 输出 stats + turnCount（热座/局域网/联机通用）。
- **结算页**（game_over_anim.dart）：胜负动画下方加统计面板——回合数 + 双方对比（击杀/损失/造兵/最大单位，最大单位从终局棋盘算），像素风边框；`GameOverAnim` 加 `state` 参数（最后一个 game_state）。
- 验证：`test/stats_test.dart` + `server/test/stats_test.js`（攻击击杀/造兵/吞噬/滚木只记损失/回合数）双端全过；roll_step/AI 回归不受影响。

### 8-bit 战斗音效（08-22 凌晨，牢大拍板：直接 8bit）
- **合成**：`tool/gen_sfx.py` 纯 Python 标准库合成（方波/三角波/噪声 + 滑音 + 脉冲 + 衰减包络），11 个音效共 90KB → `assets/audio/sfx/*.wav`（零版权、像素风契合）：
  - 选中「哔」、移动「嗒嗒」、近战「啪」、远程（3弓/4炮）「嗖」、插桥「咚」、滚木每步「隆隆」、吞噬「咕」、拆分「咔嚓」、造兵「叮」、胜利上行琶音「叮叮叮↑」、失败下行「咚…咚」。
- **播放**（game_screen.dart）：SFX 独立通道（4 AudioPlayer 轮转池，连续音效不互相吞、不与语音互斥）；触发点——选中（3 处）、`_emitAction` 统一发行动（move/attack/shoot/devour/split/produce 全走这里，produce/split 的 emit 也统一收编）、`_playRollActs` 每步、`_playAttack` 插桥、结算胜负。
- **音量**：`SettingsStore.sfxVolume`（默认 0.7，持久化），菜单设置弹窗 + 对局内设置面板都加了「音效音量」滑块。

### 加载小贴士 + 投喂小猫咪（08-22 凌晨）
- **tip**：`client/lib/game/tips.dart`，26 条随机展示——牢大投稿 9 条（yhb 赞助人 / 平衡前左边有多强 / awa / 我不要上学…）+ 离离补的角色（8基地 9指挥、3弓射2 4炮射3、2/5骑兵、7盾兵、1饲料）、规则（滚木3格、溢出插桥、过桥塌、吞超9变拉、死局判负）、技巧（喂滚木1→5、留点数、憋大快攻、困难AI特性）各若干；热座加载页 + 联机选服 loading 都显示。
- **投喂**：主菜单顶栏「🐱 投喂」→ 弹窗网络加载微信收款码 `http://your-server:5000/downloads/wechat_qr.png`（8001 上传口：`curl -F "file=@码.png" http://your-server:8001/upload`，网页 `http://your-server:8001/` 直接拖拽上传，systemd `aim-upload.service` 常驻；换码不用重打包）。

### 三连修复（08-22 凌晨，牢大实测反馈）
- **设置弹窗滚动**：主菜单 + 对局内设置弹窗内容超出小屏，加 `maxHeight 86% + SingleChildScrollView` 可滚动。
- **音效吞语音**：sfx 池播放器默认抢音频焦点，一播音效就把正在播的语音暂停（onPlayerComplete 不触发 → `_voiceBusy` 永久卡死 → 语音全哑）。修复：语音 + 音效全部 `AudioContextAndroid(audioFocus: none)` 互不抢焦点（BGM 早已如此），另加 3.5s 看门狗强制解锁 `_voiceBusy` 兜底。
- **吞噬拆分方向**：超 9 拆分时固定 `me 拿十位`，右方(玩家1)吞噬时 me 在右、目标在左 → 棋盘从左读变"21"。修复：按棋盘方位摆放——棋盘从左到右读 = 十进制（十位在左、个位在右），左右双方一致；`ones==0`（10/20…）时吞噬者清成空地。双端同步（rules.dart / rules.js）+ 测试 `devour_split_dir_test`。
- **音效默认音量**：0.7 → 0.35（牢大实测太响，调小 50%），旧存档 ≥0.6 自动迁移。

### PC 版（pygame 重写，08-22 晨，牢大：写 Python+bat+zip，自动装环境）
- **定位**：`/root/aim/pc/`，Python + pygame 重写，**Windows 单机**：双人热座 + AI 三档 + 全部机制对齐手机版（数字单位/滚木逐步/桥/吞噬/拆分/造兵/盾兵/死局判负/统计结算）。
- **结构**：`main.py`（主菜单：模式/地图/规则开关/设置/投喂/tips）· `game_ui.py`（对局：棋盘/轻量动画/滚木逐步驱动/快捷键）· `rules.py`（规则引擎，与 rules.dart 逐行对齐，14 项单测 `test_rules.py` 全过）· `ai.py`（三档评分移植）· `audio.py`（8bit 音效合成 + 复用手机版日配语音 mp3 + BGM）。
- **快捷键**：A/P 选阶段、1-9 选单位、↑↓ 拆分配额、Enter 行动/E 回合、M 设置、ESC 取消/退出。
- **分发**：`start.bat` 自动下载安装 Python + pygame → 运行；zip `aim-pc.zip`（8MB，含文泉驿字体 + 36 句日配语音 + BGM）部署 `downloads/`，下载页已更新；冒烟测试（dummy 驱动）菜单+对局+结算全流程通过。
- **未做**：联机大厅/局域网、教程剧情（第一版单机对齐，联机后续迭代）。

### 开机启动页 Logo（08-22 晨，牢大：透明底白字 logo 淡入）
- **手机版**：`client/lib/screens/splash_screen.dart`——黑屏 → **本地打包** `assets/images/logo.png`（牢大：存在本地，离线可用）→ 1.5s 淡入（透明度 0→1）→ 完全显示停留 2.5s → 进主界面；`main.dart` home 改 `SplashGate`；logo 用 `BoxFit.contain` 保持比例不拉伸，失败兜底文字版「AIM」。
- **PC 版**：`main.py` 的 `_loading` 同流程（pygame alpha 淡入 + smoothscale 按比例 contain），本地 `logo.png` 随包分发。
- **8001 上传页**：`upload_server.js` 双卡片（收款码 + Logo）——`POST /upload_logo` → `downloads/logo.png`，网页 `/` 拖拽/点击自动上传 + 经典表单兜底（`?form=1` 302 跳转），`/preview_upload_logo` 预览；换 logo 需重新打包 APK（本地资源）。

## 待办
- [ ] 残局挑战（牢大：后续再考虑）
- [ ] 牢大实测 AI 手感后调（强度/延迟/策略权重）
- [ ] 牢大实测反馈后再调（教程体验/逐格动画/打击动画手感/BGM 音量/音效音量/音效风格）
- [ ] 联机端逐步滚木已对齐（08-21 done）；旧 _detectRoll 全量回放路径保留兜底，之后可删

## 赞助
如果 AIM 数字大战给你带来了快乐，欢迎请作者喝一杯：

![微信收款码](docs/qr/wechat_qr.png)

> 打赏随缘，你的 star 和反馈就是最好的支持。
