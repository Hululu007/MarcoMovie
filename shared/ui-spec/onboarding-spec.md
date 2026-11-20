# 跨端故事化新手引导、首次播放提示与自绘示例素材规范（`onboarding-spec.md` · v2 基线对齐修订版）

> **适用里程碑**：Wave 1 · M5a（生成 14 张示例海报脚本 + 独立 `OnboardingScreen` 与 `FirstPlayGestureHint` 组件，不碰壳层与播放器文件）、Wave 2（M5b 路由、设置入口与首次播放提示槽位挂载）。  
> **红线声明**：严格遵守仓库「不内置、不提供、不托管影视资源」边界（`MainActivity.java` 首次地址保持 `""` 空串）；示例卡片严禁出现任何真实影片名、真实剧照、公共影视资料库数据或第三方商标图形。

---

## 1. 独立路由架构与五幕式故事化引导结构

1. **独立路由不侵入首页空状态**：
   - 为避免与 `MobileShell.java` / `AdaptiveShell` 既有首页空状态导入面板冲突，新手引导统一实现为**独立全屏页面/路由**（Android `OnboardingScreen.java`、Flutter `flutter/lib/ui/onboarding/onboarding_screen.dart`），衬底采用 `AuroraSurfaceView` / `AuroraBackground`（Windows 为 `WindowsBackdrop`，Android TV 为静态暗色渐变）；
   - 第 1 幕与第 5 幕的主操作按钮直接回调复用现有的配置导入、剪贴板粘贴与 WebDAV/局域网同步面板；在 iOS 26+ 上主行动按钮统一采用 `IosNativeGlassButton`，保持与全应用一致的原生液态玻璃质感；
   - 任意一幕均可一键「跳过」（电视端按返回键可退回上一幕或跳过），并在「设置 -> 关于与帮助 -> 重新查看新手引导」（含 `ios_settings.dart` 与 `MobileIosSettings.java` / `SettingsScreen.java`）提供常驻重看入口。

| 幕次 | 核心主题 | 展示组件与合规要点 | 三端差异化交互重点 |
| :---: | :--- | :--- | :--- |
| **第 1 幕** | **自有配置与工具边界** | 显著展示「仅作播放与内容管理工具，不内置、不提供任何影视资源」声明；预览空地址导入框（默认 `""`） | **电视**：局域网扫码推送示意 + 遥控输入；**手机/平板/iOS**：剪贴板一键粘贴 + 本地文件选择；**桌面**：地址粘贴 + 备份还原 |
| **第 2 幕** | **海报墙、规格徽章与续播** | 使用 `14` 张程序生成的抽象几何示例海报（右上角强制带 **「示例 / DEMO」** 角标）展示海报网格、纯文字规格徽章（`4K`、`DV · ATMOS`、`HDR10+`、`REMUX`）与继续观看进度条 | **电视**：方向键焦点弹簧缩放体验；**手机/平板/iOS**：横竖屏自适应列数与同心玻璃徽章；**桌面**：悬停规格提示与宽屏多列排版 |
| **第 3 幕** | **多端同步（WebDAV / 局域网）** | 图示 `marco-movie-sync` v2 协议同步观看历史、收藏与公开订阅，明确说明隐私空间与网盘/Emby 登录凭据本机隔离 | 全端统一展示「自配 WebDAV 云盘」与「同一局域网点对点免云盘直连同步」双路径 |
| **第 4 幕** | **进阶播放操控与 HUD** | 动态示意升级后的播放页 HUD（起播规格提示、常驻细进度条、3 秒跳过片头倒计时、分片弹幕）与核心操控手势 | **触控**：长按 `2.0×` 倍速 → 左右滑动调速 → 上滑锁定倍速、两侧双击快进快退、左右半屏亮/音；**电视**：短按左右 `15s`、长按左右加速快进/快退预览松手即播、返回取消；**桌面**：短按/长按 `←`/`→` 快进预览、`Space`、`S` / `[` `]` 倍速、`D` 键开关弹幕、滚轮音量 |
| **第 5 幕** | **个性化外观与立即开始** | 预览减少动态效果、降低透明度、界面缩放（Android `100% / 110% / 120%`、Flutter 动态字号），底部提供「立即导入配置」与「先进入首页」双主按钮 | **电视**：首屏默认聚焦「立即导入配置」；**iPad / 桌面横屏**：采用左右分栏宽屏卡片排版；**iOS 26**：主按钮使用 `IosNativeGlassButton` |

---

## 2. 首次播放手势提示（`FirstPlayGestureHint`）

1. **触发条件与 Wave 1 / Wave 2 零侵入挂载契约**：
   - 用户首次进入点播视频播放且画面成功起播后，避开左上角 `StartSpecOverlay` 区域，在底部主控栏上方居中弹出轻量半透明引导胶囊。
   - **写入边界协同**：Wave 1 中 M2 在 `PlaybackControls` / `PlayerChrome` 与 `player_screen.dart` / `ios_player_chrome.dart` 预留可选浮层构建槽位（默认空），M5a 在独立目录实现 `FirstPlayGestureHint`；Wave 2 再将两者一行代码挂载连通。
   - **三端提示文案（中英双语适配）**：
     - **触控端（Android 手机/平板、iPhone、iPad）**：`长按 2.0× 倍速 · 左右滑调速 · 上滑锁定 · 两侧双击快进快退`
     - **电视端（Android TV）**：`长按左右键加速快进/快退 · 松手即播 · 返回键取消`
     - **桌面端（Windows / macOS）**：`长按 ←/→ 快进预览 · 滚轮音量 · S / [ ] 倍速 · D 弹幕`
2. **频控与永久关闭默认值**：
   - 最多自动展示 **`3` 次**（每次进入新播放会话且停留满 `2s` 计 1 次，展示 `4500ms` 后自动淡出）。
   - 气泡内附带可点击/可聚焦的 `「知道了 / 不再提示」` 按钮，点击后立即置 `dismissed = true`，后续永不自动弹出（除非用户在设置中手动重看引导）。
3. **跨端本机持久化键名约定（不入跨端备份表）**：
   - **Android（本机独立 `SharedPreferences` 读写，严禁加入 `Prefs.KEYS` 备份数组以保持 `ReviewFixChecks.java:191` 长度 `46` 不变）**：
     - `onboarding_done_version`（`int`，默认 `0`，当前引导版本为 `1`）
     - `play_hint_shown_count`（`int`，默认 `0`，上限 `3`）
     - `play_hint_dismissed`（`boolean`，默认 `false`）
   - **Flutter（`onboarding_prefs.dart` 封装 `SharedPreferences`）**：
     - `onboarding_done_version`（`int`，默认 `0`，目标 `1`）
     - `play_hint_shown_count`（`int`，默认 `0`，上限 `3`）
     - `play_hint_dismissed`（`bool`，默认 `false`）

---

## 3. 自绘示例素材生成器（`scripts/generate_demo_art.py`）与合规校验规范

1. **零版权争议程序化生成（Wave 1 · M5a 实现）**：
   - 使用固定随机种子（`seed = 20261120`）纯代码绘制 **`14` 张** `2:3` 竖版抽象艺术海报（几何光影折线 + `motion-tokens.json` 品牌渐变色板 + 胶片颗粒噪点），每张海报画面右上角直接绘制清晰可读的 **`「示例 / DEMO」`** 角标，同时在 UI 卡片层叠加角标双重保险。
   - 配套生成 UTF-8 `manifest.json`（中英双语占位元数据），标题严格限定在虚构占位名集合内（如 `示例 · 远航` / `Sample · Horizon`、`示例 · 城市微光` / `Sample · City Glow`、`示例 · 深空信标` / `Sample · Deep Beacon`、`示例 · 海岸季风` / `Sample · Coastal Wind`）。
   - 所有生成脚本、图像与 JSON 清单均采用与主仓库一致的 **`GPL-3.0-only`** 许可，并在脚本头部注明版权与 SPDX 标识。
2. **唯一权威输出格式与防冲突约定**：
   - 鉴于 `scripts/check_public_content.py:160-163` 原生对 `.png` 豁免二进制解码扫描而拒绝未知二进制格式，**锁定 `scripts/generate_demo_art.py` 唯一输出图像格式为 8-bit 索引调色板量化 `.png`**（分辨率 `360x540` + 抖动压缩，单张 `<= 35 KB`，14 张总计 `< 480 KB`），零守卫脚本改动。
   - Wave 1 中 M5a 生成资源至 `flutter/assets/demo/` 与 `android/src/main/assets/demo/` 并写独立 `android/tests/run_onboarding_checks.py`，**不在 Wave 1 修改 `flutter/pubspec.yaml` 或 `run_checks.py`**（统一留给 Wave 2 注册），确保五线合并零冲突。

---

## 4. 平台边界与不在范围内（Out of Scope）

1. **HarmonyOS NEXT 隔离**：`OhosRuntime.isOhos` 为真时默认跳过首开引导与首次手势提示，保持现有鸿蒙启动流不变；`flutter/ohos/` 与 `flutter/lib/ui/tv/**` 严禁修改。
2. **Android Lite（API 14）与 Apple TV（`tvos/`）**：本轮不引入新手引导。
3. **离线可播放视频样片打包与独立「演示播放器」模式**：不在仓库或安装包内新增任何 `.mp4` / `.mkv` 视频流或演示字幕文件；第 4 幕统一使用轻量矢量/组件级交互动效示意。
4. **首页常驻伪造排行榜、电影票根待看架、拟物书架或虚构评分装饰**（遵守 `docs/COMPATIBILITY.md:36` 原则）。
