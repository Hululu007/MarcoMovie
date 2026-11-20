# 基线变更影响清单（`a3cbe546..aa0adb3acd`）

> 本文档记录主仓库 `private/release-0.5.2` 在公共基准点 `a3cbe546`（`android-mobile-v0.5.26`、`android-lite-v0.5.7`、`windows-v0.5.24`、`macos-v0.5.19`、`ios-v0.5.32`）之后，至本项目统一起点 `aa0adb3acd`（`origin/main`，含 `android-tv-v0.5.29`、`ios-v0.5.34`、`appletv-v0.1.1`、`harmonyos-v0.1.1`）之间引入的所有共享代码改动与行为变化，供 M0–M6 设计、实现、门禁及真机 A/B 对照验收使用。

---

## 1. 基线谱系与提交统计

### 1.1 分支与提交范围核验

- **基线起点**：`a3cbe546c3faa803e6be2b06bbe62b6767e503c9`（`a3cbe546`）
- **电视正式版节点**：`940ed5027405e0d673329132128797b876977f56`（`940ed502` / `android-tv-v0.5.29`）
- **iOS 代码节点**：`120cb3fccab350ebbd04aab39cc0ec9a050c9ba7`（`120cb3fc` / `ios-v0.5.34` 代码终点）
- **统一基线终点**：`aa0adb3acd8192127eacb2eab63f21769966b105`（`aa0adb3acd` / `origin/main`，仅追加 `ios-v0.5.34` 发布文档）
- **远端分支包含关系核验**（2026-11-20 实测）：
  - `origin/feat/ios-26-liquid-glass-20261119` 位于 `aa0adb3a`，与 `aa0adb3acd` 差异为 `0 / 0`（已完整包含在基线内）。
  - `origin/feat/appletv-harmonyos-phase2` 位于 `5063b8e9`，为 `aa0adb3acd` 的祖先提交（落后基线 13 个提交、超前 0 个提交，已完整包含在基线内）。

### 1.2 分阶段提交数量

| 阶段范围 | 提交总数 | 说明 |
| :--- | :---: | :--- |
| `a3cbe546..940ed502` | **29** | Apple TV / HarmonyOS NEXT `0.1.0`–`0.1.1`、iOS `0.5.33`、Android TV `0.5.26`–`0.5.29`（含 2 个 merge 提交：`06846085`、`af4d849a`） |
| `940ed502..120cb3fc` | **11** | TV `0.5.29` 文档、iOS 26 Liquid Glass 与 Spider 扩展面板、iOS `0.5.34` 版本号提升、`CompatChecks` 修复（含 1 个 merge 提交：`a7489406`） |
| `120cb3fc..aa0adb3acd` | **1** | `ios-v0.5.34` 发布文档（`CHANGELOG.md`、`docs/platform-releases.md`、`docs/releases/ios-v0.5.34.md`） |
| **合计（`a3cbe546..aa0adb3acd`）** | **41** | 其中 `a3cbe546..120cb3fc` 为 40 个提交；全范围含 38 个非合并提交 + 3 个合并提交；**25 个非合并提交**触及代码/脚本目录（`android/src/`、`shared/`、`flutter/lib/`、`flutter/pubspec.yaml`、`scripts/`；`lite/` 0 改动、`flutter/shaders/` 0 改动） |

### 1.3 共享目录 Diff 汇总（`a3cbe546..aa0adb3acd`）

| 目录 / 范围 | 涉及文件数 | 行数变化 | 说明 |
| :--- | :---: | :---: | :--- |
| `android/src/` | **62** | `+12115 / -1190` | TV V17 详情/首页/直播/搜索/设置、播放器标记与轨道菜单、`Prefs` 键与校验 |
| `lite/` | **0** | `0 / 0` | `lite/` 目录自身无修改 |
| `shared/` | **11** | `+925 / -181` | `shared/catpaw/` 10 个 `.cjs`/`.json` 文件 + `shared/java/com/pilipala/emby/EmbyLibrary.java`（Lite 通过 `shared/java/com/pilipala/emby` 继承） |
| `flutter/lib/` + `flutter/pubspec.yaml` | **32**（`flutter/lib/` **31** + `pubspec.yaml` 1） | `+21605 / -1443` | iOS 26 Liquid Glass、Spider Gateway/扩展面板、HarmonyOS NEXT 适配与 `tv/` 界面、`VideoKernel`、`ios_search_page.dart` |
| `flutter/shaders/` | **0** | `0 / 0` | 基线仍仅有 `glasswork.frag` 与 `GLASSWORK-LICENSE.txt` |

---

## 2. 全量 41 个提交明细与分类

> 顺序按拓扑时间由早到晚排列（`git log --reverse a3cbe546..aa0adb3acd`）。

| # | 提交 | 所属阶段 | 触及范围 | 摘要 |
| :---: | :--- | :--- | :--- | :--- |
| 1 | `f7c0be41` | `a3cbe546..940ed502` | `docs/ci/meta` | 记录已验证的非 TV 正式版（Mobile 0.5.26 / Lite 0.5.7 / Win 0.5.24 / Mac 0.5.19 / iOS 0.5.32） |
| 2 | `02652453` | `a3cbe546..940ed502` | `tvos`、`flutter/ohos`、`flutter/lib`、`flutter/other`、`scripts`、`docs/ci/meta` | 新增原生 tvOS 16+ 客户端、HarmonyOS NEXT 通用 HAP、`OhosRuntime`、`VideoKernel` 与 `flutter/lib/ui/tv/` |
| 3 | `ffb8bfdd` | `a3cbe546..940ed502` | `tvos`、`flutter/lib`、`docs/ci/meta` | 修复 Swift C 指针转换、OHOS Flutter 版本标签与智慧屏 4K 网盘 UI |
| 4 | `b5b72c34` | `a3cbe546..940ed502` | `tvos`、`flutter/ohos`、`flutter/other`、`docs/ci/meta` | 修复 CI 中 tvOS 16 `Menu` 可用性与 OHOS `flutter-hvigor-plugin` 覆盖 |
| 5 | `a3bf593d` | `a3cbe546..940ed502` | `flutter/other`、`docs/ci/meta` | `prepare_ohos.py` 支持单引号与无引号 JSON5 |
| 6 | `1f7675ae` | `a3cbe546..940ed502` | `flutter/other`、`docs/ci/meta` | `prepare_ohos.py` 规范化 `targetSdkVersion` 并合并 `module.json5` |
| 7 | `26239b3f` | `a3cbe546..940ed502` | `flutter/ohos`、`docs/ci/meta` | 对齐 DevEco SDK 26.0.0.821 与 ArkTS preferences/throw 类型 |
| 8 | `a5bb5ada` | `a3cbe546..940ed502` | `docs/ci/meta` | CI 允许无签名配置时产出未签名 HarmonyOS HAP |
| 9 | `45ca4d6d` | `a3cbe546..940ed502` | `docs/ci/meta` | 恢复 `main` 分支完整多端 CI 矩阵 |
| 10 | `4d4f946f` | `a3cbe546..940ed502` | `tvos`、`flutter/ohos`、`flutter/lib`、`flutter/other` | Phase 2 4K 网盘扫码授权、6 路并发 Range 代理、HDR 与音轨/字幕控制 |
| 11 | `511f5b2d` | `a3cbe546..940ed502` | `tvos` | `NetdiskSessionValidator` 检查 CRLF 控制字节 |
| 12 | `c701ab53` | `a3cbe546..940ed502` | `scripts`、`docs/ci/meta` | 发布 Apple TV 0.1.0 与 HarmonyOS NEXT 0.1.0 文档及镜像同步 |
| 13 | `f89f0da0` | `a3cbe546..940ed502` | `flutter/lib`、`flutter/other`、`shared`、`scripts`、`docs/ci/meta` | iOS `0.5.33`：iPad 沉浸式播放、宽松设置页、首页缓存瞬开、3 行搜索日志、WEX/DoH 容错与封面精度 |
| 14 | `1342e4c9` | `a3cbe546..940ed502` | `flutter/lib` | 退出隐私空间时绕过首页快照缓存 |
| 15 | `f90fef9c` | `a3cbe546..940ed502` | `android/src`、`android/tests`、`scripts`、`docs/ci/meta` | Android TV V17 候选：引入 `TvV17*`、`TvDetailHost`、`TvMarkerHost`、隔离拼音学习与 `TvSubtitleSource` |
| 16 | `15784b3b` | `a3cbe546..940ed502` | `docs/ci/meta` | 记录已验证的 iOS / iPadOS `0.5.33` 发布 |
| 17 | `06846085` | `a3cbe546..940ed502` | *Merge* | 合并 iOS `0.5.33` 发布记录到 TV 候选分支 |
| 18 | `9f08f638` | `a3cbe546..940ed502` | `android/src`、`android/tests`、`docs/ci/meta` | 格式化 V17 Java 代码并记录 TV 验证 |
| 19 | `080d5231` | `a3cbe546..940ed502` | `docs/ci/meta` | 绑定 TV 0.5.26 至已格式化签名候选 |
| 20 | `daffd3eb` | `a3cbe546..940ed502` | `android/src`、`android/tests`、`scripts` | 离线清理片头片尾标记存储并编译 API23 probe 依赖 |
| 21 | `6a6db2aa` | `a3cbe546..940ed502` | `android/src`、`android/tests` | 首页自动翻页前等待当前窗口渲染完成 |
| 22 | `093595df` | `a3cbe546..940ed502` | `android/src`、`android/tests` | 翻页目标就绪前保持「更早」按钮焦点 |
| 23 | `ba588a95` | `a3cbe546..940ed502` | `docs/ci/meta` | 绑定 TV 0.5.26 至 R6 验证范围 |
| 24 | `d2469bb3` | `a3cbe546..940ed502` | `flutter/lib`、`flutter/other`、`docs/ci/meta` | 引入 `ios_liquid_glass.dart`：原生 iOS 26 底部栏、详情操作条、分段控件、设置外观与弹窗桥接 |
| 25 | `2ef5f027` | `a3cbe546..940ed502` | `flutter/lib`、`flutter/other`、`tvos` | 沉浸式影院详情页、选集器与嵌入式 QuickJS DRPY/Guard 运行时（`catpaw_embedded_engine.dart`、`catpaw_crypto.dart`） |
| 26 | `a0181360` | `a3cbe546..940ed502` | `flutter/lib` | 鸿蒙 TV 优先聚焦继续观看行以避免分类胶囊裁剪 |
| 27 | `af4d849a` | `a3cbe546..940ed502` | *Merge* | 合并 `origin/main`（TV 0.5.26）至 `feat/appletv-harmonyos-phase2` |
| 28 | `c7209f17` | `a3cbe546..940ed502` | `flutter/lib`、`flutter/other` | 对齐 iOS 26 Dock 高度、滚动收起品牌 Logo 菜单、原生顶栏 `UIMenu` 与 `UISheet` 筛选面板 |
| 29 | `7b723932` | `a3cbe546..940ed502` | `flutter/lib`、`flutter/ohos`、`flutter/other`、`tvos`、`docs/ci/meta` | 鸿蒙智慧屏 UI 对齐 Apple TV（`tv_ambient_theme.dart` 等），提升 Apple TV / HarmonyOS NEXT 至 `0.1.1` |
| 30 | `37251b42` | `a3cbe546..940ed502` | `flutter/lib`、`flutter/other` | 原生 iOS 26 隐私 PIN 弹窗、62pt Liquid Glass Dock、解除源/仓菜单上限并修复网盘浮层 |
| 31 | `5063b8e9` | `a3cbe546..940ed502` | `docs/ci/meta` | 发布 Apple TV 0.1.1 与 HarmonyOS NEXT 0.1.1 说明与校验和 |
| 32 | `aa7d232e` | `a3cbe546..940ed502` | `flutter/lib`、`flutter/other` | 居中原生隐私 PIN 模态框、跨路由门控 `UiKitView` 消除黑屏遮挡、优化历史滚动与过滤 `.so` 线路 |
| 33 | `0f9f6d1b` | `a3cbe546..940ed502` | `flutter/lib`、`flutter/other`、`docs/ci/meta` | 消除转场跳闪、重构原生 iOS 26 设置页、新增脚本适配包与 BYO Spider Gateway（`spider_gateway.dart`、`spider_plugin_registry.dart`、`spider_extensions_panel.dart`） |
| 34 | `f4dc4489` | `a3cbe546..940ed502` | `flutter/lib`、`flutter/other` | 消除图标缩放弹跳与深浅切换闪烁，补充中文 Spider 扩展指南 |
| 35 | `940ed502` | `a3cbe546..940ed502` | `android/src`、`android/tests`、`shared`、`docs/ci/meta` | **Android TV `0.5.29`**：直播高清策略（`LiveQualityPolicy`）、EPG（`LiveEpgService`）、统一首页库与动态氛围光、Apple TV 风格详情/墙纸上传（`WallpaperUploadServer`）、`EmbyLibrary` 直播频道与关闭流扩展 |
| 36 | `8a0e90d8` | `940ed502..120cb3fc` | `docs/ci/meta` | 发布 Android TV 0.5.29 说明与校验和 |
| 37 | `dc030801` | `940ed502..120cb3fc` | `flutter/lib`、`flutter/other` | 全局搜索重构为全屏 Liquid Glass 影院体验（新增 `ios_search_page.dart`） |
| 38 | `a7489406` | `940ed502..120cb3fc` | *Merge* | 合并 `origin/main`（TV 0.5.29）至 `feat/ios-26-liquid-glass-20261119` |
| 39 | `1637e9d3` | `940ed502..120cb3fc` | `flutter/other`、`docs/ci/meta` | 提升 iOS / iPadOS 版本号至 `0.5.34`（build 84） |
| 40 | `120cb3fc` | `940ed502..120cb3fc` | `android/tests` | 将 `LiveQualityPolicy.java` 加入 `CompatChecks` Module B 编译清单 |
| 41 | `aa0adb3a` | `120cb3fc..aa0adb3acd` | `docs/ci/meta` | 记录已验证的 iOS / iPadOS `0.5.34` 发布 |

---

## 3. 各端在基线中「已继承」的变更（A/B 对照必读）

> 以下变化在基线 `aa0adb3acd` 中**已经存在**。在以 GitHub Releases 上已发布安装包（Android Mobile `0.5.26`、Lite `0.5.7`、Windows `0.5.24`、macOS `0.5.19`）作为对照组做 A/B 验收时，这些变化**不属于本项目引入的回归**。

### 3.1 Android 手机 / 平板（相对 `android-mobile-v0.5.26 @ a3cbe546`）

1. **共享运行时与设置项（`Prefs.java`、`MainActivity.java`、`SettingsScreen.java`）**
   - 新增多项直播与 TV 背景/导航偏好键及备份白名单/校验：`TV_NAVIGATION_MODE`、`TV_AMBIENT_PERCENT`、`TV_BG_MODE`、`TV_GLOW_PRESET`、`TV_GLOW_COLOR_LEFT`、`TV_GLOW_COLOR_RIGHT`、`LIVE_UDPXY_URL`、`LIVE_EPG_URL`、`LIVE_URL`、`LIVE_NAME`、`LIVE_SOURCES_JSON`、`LIVE_STREAM_METRICS`。
   - `MainActivity` 拼音词库加载拆分为 `initializePhonetic()`（隔离学习索引，避免污染静态字典），保留手机/平板专属 `DownloadManager.get(this)`；新增 `markerHost` 字段（主要服务 TV 端标记点）。
   - `DetailScreen.show(...)` 入口对 `a.isTvDevice()` 分流至 `TvDetailHost`；手机/平板仍走 `MainActivity` 中 `!isTvDevice()` 分支调用 `MobileDetailScreen.show(...)`，**但** `DetailScreen` 中的公共方法（如 `toggleFavorite`、`renderEpisodes` 与按钮样式辅助）已随 TV 0.5.29 更新。
2. **播放器（`PlaybackControls.java`、`PlaybackController.java`、`MoviePlayer.java`）**
   - `PlaybackControls` 选源/菜单弹窗（`showMenu` 等）新增**视频子轨选择**（`player.trackLabels(2)` > 1 时显示「视频子轨 · 自动优选画质」与各子轨）和**直播 EPG 节目单入口**（`"live".equals(site.key)` 且 `liveSession.index >= 0` 时显示「📅 节目单与回看 (EPG)」）。
   - `PlaybackControls` 的 `ICON_SKIP_INTRO` / `ICON_SKIP_OUTRO` 高亮判定增加了 `!a.isTvDevice()` 守卫，电视端改由 `TvMarkerHost` / `TvMarkerTailGate` 处理。
   - `PlaybackController` 在直播起播成功回调中调用 `LiveQualityPolicy.recordStreamSuccess(...)` 记录分辨率与首帧耗时到 `Prefs.LIVE_STREAM_METRICS`。
3. **直播与 Emby（`LiveController.java`、`LiveEpgService.java`、`LiveQualityPolicy.java`、`EmbyLibrary.java`）**
   - 引入直播清晰度优选策略、EPG 回看服务以及 `EmbyLibrary` 直播频道枚举（`mmemby://live-catalog` / `mmemby://live`）和 `LiveTv/LiveStreams/Close` 关闭请求。
   - `shared/catpaw/` 下 10 个 `.cjs`/`.json` 文件随 iOS `0.5.33` 更新（WEX/DoH 容错、adapter 规则、HTTP 辅助）。

### 3.2 Android Lite（相对 `android-lite-v0.5.7 @ a3cbe546`）

- `lite/` 目录自身 **0 修改**。
- `scripts/build_lite.py` 会编译 `shared/java/com/pilipala/{emby,source,glass}/**/*.java`，因此 Lite 仅间接继承了 `shared/java/com/pilipala/emby/EmbyLibrary.java` 的扩展（直播频道 API、LiveStreamId 关闭逻辑与 `accountId()` 等公开方法），点播解析、UI 与单 DEX 约束未受影响。

### 3.3 Flutter Windows / macOS（相对 `windows-v0.5.24` / `macos-v0.5.19 @ a3cbe546`）

1. **入口与平台分流（`flutter/lib/main.dart`、`ohos_runtime.dart`、`ios_liquid_glass.dart`）**
   - 启动时新增 `await OhosRuntime.ensureInitialized()` 与 `await IosLiquidGlassBridge.ensureInitialized()`；非鸿蒙平台仍正常初始化 `MediaKit.ensureInitialized()`。
   - `MarcoMovieApp.home` 改为通过 `ValueListenableBuilder(OhosRuntime.uiModeRevision)` 判断 `OhosRuntime.shouldUseTvUi(storage.tvUiMode)`；Windows/macOS 默认 `tvUiMode` 为 `'auto'` 且 `isSmartScreenHardware == false`，正常进入 `AdaptiveShell`。
   - `IosLiquidGlassBridge.isAvailable` 在非 iOS 平台（含 Windows/macOS）固定返回 `false`，所有 `IosNativeGlass*` / `showAppleNative*` 调用自动回退到 Flutter 实现（但需注意 `apple_theme.dart`、`adaptive_shell.dart`、`ios_settings.dart` 中与 fallback 相关的结构变化已一并合入）。
2. **外观、路由与搜索/设置/扩展能力**
   - `apple_theme.dart` 引入 `WindowsSmoothPageTransitionsBuilder` 与 `buildApplePageRoute`（Windows 使用 185ms 单层 `RepaintBoundary` + 淡入位移，规避 ANGLE/D3D11 下 `CupertinoPageRoute` 500ms 双层视差开销；macOS/iOS 仍用 `CupertinoPageRoute`）。
   - `adaptive_shell.dart`、`ios_search_page.dart`、`ios_settings.dart`、`spider_gateway.dart`、`spider_plugin_registry.dart`、`spider_extensions_panel.dart`、退出隐私空间绕过首页缓存（`1342e4c9`）以及 WEX/DoH 容错与封面精度修复（`f89f0da0`）均已合并到 Windows/macOS 共用的 `flutter/lib/`。
3. **详情页与播放器（`detail_screen.dart`、`player_screen.dart`、`mobile_player_chrome.dart`、`video_kernel.dart`）**
   - `player_screen.dart` 视频表面由直接构造 `Video(...)` 改为 `_videoKernel.buildVideoSurface(...)`（非 OHOS 平台仍走 `media_kit_video` 的 `Video`），且已包含 `4d4f946f` / `f89f0da0` 中的多画质切换与 iPad 沉浸式系统栏逻辑（`MobilePlayerChrome.setImmersive`，桌面端仅系统 chrome 逻辑不触发 iOS channel）。
   - `detail_screen.dart` 错误弹窗改为 `showAppleNativeAlert`（桌面走 Cupertino/Material fallback）、浮动返回按钮使用 `IosNativeGlassButton`（桌面走 `LiquidGlass` fallback）。
   - `shared/catpaw/` 10 个文件更新同步被桌面 CatPaw Node 宿主继承。

---

## 4. 对 M0–M6 规范与实现的直接影响与约束

1. **Flutter 目录结构已彻底迁移至 `flutter/lib/`**
   - 仓库中**不存在 `flutter/src/`**。M0/M1/M2/M3/M4/M5/M6 所有 Flutter 规格与实现均直接面向 `flutter/lib/` 与 `flutter/test/`；`flutter/prepare_platform.py` 当前职责为同步品牌资源与配置 Apple/Windows 原生壳层，不再承担 `src -> lib` 复制。
2. **M1 规格徽章接线点明确**
   - **Android 手机/平板**：接线点在 `MobileDetailScreen.java`（而非 `DetailScreen.java` 单独覆盖全部）。
   - **Android TV**：接线点仅限 `TvV17DetailScreen.java` 与 `DetailScreen.java`（`renderEpisodes` 选集弹窗线路胶囊）；`TvDetailHost.java` 在 §4.1 中为只读，不得修改。注意 `TvV17DetailScreen.java:456` 的 `extractFilenameFromUrl` 使用了会把字面量 `'+'` 转为空格的 `URLDecoder.decode`，M1 提取规格徽章时必须直接对原始 `episode.url` / `episode.name` 调用 `badge-rules.json` 定义的保 `'+'` 百分号归一化逻辑。
   - **Android Lite**：接线点在 `lite/src/main/java/com/pilipala/marcomovie/lite/LiteActivity.java`（详情页元数据行 `:3977` 与线路胶囊 `:4114`，需在 Wave 1 启动前纳入 M1 允许最小接线白名单）。
   - **Flutter**：接线点在 `flutter/lib/ui/detail_screen.dart` 与 `flutter/lib/ui/windows_detail.dart`（仅线路胶囊处），且严禁修改 `flutter/lib/ui/tv/**`（只读）。
3. **HarmonyOS 共享 `flutter/lib/` 带来的硬性隔离约束**
   - `flutter/ohos/` 与 `flutter/lib/ui/tv/**` 为只读目录；本机未安装 HarmonyOS 工具链（无 `hvigorw` / `ohpm` / `hdc`），无法在本地执行 `.hap` 编译。
   - **M1–M6 新增 Flutter 功能不得引入不支持 `ohos` 的新插件/原生通道**，且必须在运行时通过 `OhosRuntime.isOhos` 隔离或默认关闭（尤其 M2 触控/键鼠 HUD、M3 弹幕层、M4 `FragmentProgram` 着色器转场与极光背景、M5 引导），保证现有 `VideoKernel` / `OhosPlatformPlayer` 与 `TvLivingRoomShell` 行为不受影响。
4. **M2 播放页 HUD、M3 弹幕与 M5 引导的 §4.1 写入边界协同约束（已锁定）**
   - **Android 播放器核心只读边界**：`MoviePlayer.java`、`SystemPlayer.java`、`PlaybackController.java`、`SeekGesture.java` 与 `TvDetailHost.java` 全部严格保持只读、零修改！M2 起播规格提示直接消费现有的 `a.player.mediaBadges()` 纯文本列表并经 `MediaBadges` 做双通道分组融合；电视端长按左右方向键沿用 `PlaybackController.dispatchPlaybackKey`（`:2067-2083`）-> `SeekGesture`（`:62-101`）加速快进/快退预览管线（与 `InteractionProbe.java:96-147` 100% 兼容，且与 `:2026` `TvMarkerHost` 上键零冲突），S22 仅在 `PlaybackControls.java`、`PlayerChrome.java` 与 `hud/*.java` 中升级预览浮层与 3 秒跳过倒计时（利用 `dialogOpen` 将按键路由至聚焦按钮）。
   - **Android `PlaybackControls.java`**：已被 `TvMarkerHost` / `TvMarkerTailGate`（TV 跳过片头片尾标记）、视频子轨菜单、EPG 入口触及；M2 在独立新类（`PlayerGestureStateMachine`、`hud/*.java`）实现全部状态机与视图，只在 `TouchPlayerGesture.java`、`PlaybackControls.java`、`PlayerChrome.java` 做最小挂载，并预留一个可选的首次播放提示浮层槽位（供 M5 注入 `FirstPlayGestureHint`，避免 M5 触碰播放器内部代码）。
   - **本机偏好存储隔离（不入跨端备份表）**：`Prefs.java` 已有完善的白名单校验（`sanitizeSetting` / `INT_RANGES` / `BOOLEAN_KEYS`），且 `ReviewFixChecks.java:191` 强校验备份白名单 `Prefs.KEYS.length == 46`、`:311` 强校验持久化 `PLAY_SPEED` 上限为 `2.0f`。已锁定将 M2/M5 新增本机偏好键一律置于 `Prefs.KEYS` 之外（不纳入 `marco-movie-backup`）；M3a/M3b 弹幕设置直接在 `DanmuSettingsPanel.java` 与 `flutter/lib/core/danmu/` 内部管理独立键名（不改 `Prefs.java` 与 `storage_service.dart`）；M2 Flutter HUD 偏好在 `flutter/lib/ui/player/` 内封装 `SharedPreferences` 读写并在 `player_screen.dart` 播放设置面板暴露开关。
   - **Flutter `player_screen.dart`**：已通过 `_videoKernel.buildVideoSurface(...)` 渲染画面并存在 `desktop_player_window.dart` / `player_interaction_layers.dart`；M2/M3b/M4 需沿用 `player_screen.dart` 的最小接线边界，将逻辑放在 `flutter/lib/ui/player/`、`flutter/lib/ui/danmu/`、`flutter/lib/ui/motion/`。
5. **M4 着色器与 Windows 渲染后端约束**
   - `flutter/shaders/` 当前仅有 `glasswork.frag`（含 `#ifdef IMPELLER_TARGET_OPENGLES` 纹理坐标 Y 轴翻转处理），`apple_theme.dart` 明确标注 Windows 运行于 **Skia over ANGLE/D3D11** 后端（`ImageFilter.isShaderFilterSupported == false`，不支持 `BackdropFilter` + `ImageFilter.shader`）；因此 `transitions-spec.md`（M0）与 S41（M4）统一采用 `CustomPainter` + `Paint()..shader`（逻辑像素坐标系）绘制，不新增任何第三方包依赖，并强制实现 **减少动态效果 / 着色器编译失败 / 截图 > 16ms** 三重自动降级路径；Android TV 端严禁着色器与模糊。
6. **公开内容合规守卫（`scripts/check_public_content.py`）对 M0–M6 的约束**
   - 追踪文件内禁止出现特定本机路径模式与内网 IP（仅特定测试文件豁免），所有测试用例 URL 必须使用 `ALLOWED_HOSTS`、`127.0.0.1` 或 `.test` / `.example` / `.invalid` 保留域名（对 M3 弹幕模拟测试尤其关键）。
   - 当前脚本仅对 `.png` 放行跳过二进制检查，而未知二进制文件会触发 `unexpected binary`；已锁定 M5 `scripts/generate_demo_art.py` 唯一输出格式为 **8-bit 索引量化 `.png`**（14 张总计 `< 480 KB`），实现零守卫脚本改动。
   - 所有新增代码、规范文档与测试样例均严格遵守净室红线：不引用第三方闭源应用名称、不使用真实影片名/海报/公共影视目录 URL、不使用第三方商标图形。

---

## 5. 不在范围内（Out of Scope）

1. **只读平台与目录**：`tvos/`（Apple TV 原生客户端）、`flutter/ohos/`（HarmonyOS NEXT 原生宿主）、`flutter/lib/ui/tv/**`（鸿蒙大屏界面）及 `gateway/` 在本轮全部里程碑中保持只读，不纳入改造范围。
2. **回退或重改基线既有提交（`a3cbe546..aa0adb3acd`）**：本清单列出的 41 个基线既有提交（如直播高清策略、EPG、iOS 26 原生组件桥接、Spider 扩展面板、TV V17 架构）属于基线固有行为，M1–M6 仅做兼容避让，不对其既有业务逻辑做逆向回滚或重构。
3. **CI 工作流与历史发布归档改动**：`.github/workflows/**`、`docs/releases/**` 与各端版本号文件在 M0–M6 开发期间保持不变（发布文档与版本号仅在收尾阶段 M7 经人工确认后更新）。
