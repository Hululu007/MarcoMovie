# Marco Movie iOS / iPadOS 0.5.35

> **发布说明草案**：发布日期待定；应用版本 `0.5.35`（构建号 `85`），基于 Xcode 26.6 / iOS 26 SDK 编译并继续兼容 iOS / iPadOS 14.0+（iOS 14–18 自动平滑回退高保真毛玻璃组件）。待 Mac 环境 Xcode 打包及 iPhone / iPad 真机 A/B 对照验收后补齐构建提交与校验摘要。

## 更新内容

- **统一 iOS / iPadOS 26 同心液态玻璃播放页重构（`IosPlayerChrome`）**：全面淘汰旧版混合暗色方块胶囊与右侧 `16` 项拥挤竖向滚动条，使播放页与 `0.5.34` 的原生 Liquid Glass 首页、全屏搜索及设置页美学浑然一体：
  - **顶部空间悬浮栏**：左侧 `40pt` 同心圆角玻璃返回胶囊（`radius = 20pt`，极窄分屏下自动折叠为圆形图标）+ 清晰片名与分集层级 + 整合式动态媒体规格徽章条（`4K`、`DV · ATMOS`、`HDR10+` 等同心纯文字胶囊，与返回键严格安全隔离）+ 右侧 `40pt` 圆形玻璃快捷组（弹幕开关、音轨/字幕、`…` 更多与定时关闭提示点）。
  - **中央折射播控区与流光底部胶囊坞**：`56pt / 76pt / 56pt` 折射高光玻璃圆形按钮（快退 15s / 播放暂停 / 快进 15s）；底部采用触控时由 `5pt` 弹性膨胀至 `10pt` 的流体伸缩进度条胶囊（`IosFluidScrubberCapsule`，支持片头/片尾标记点，父级取消scrub时自动清理指针防止误跳）+ `<= 7` 项精简主操作胶囊坞（选集/信号、线路、倍速、弹幕设置、画面、锁屏、全屏/竖屏），其余低频操作收归原生菜单。
  - **零多 `UiKitView` 视频切片与功耗/无障碍守卫**：活跃 `60fps` 视频纹理上方零散落 `UiKitView`；`glasswork.frag` 仅在 HUD 可见期激活，隐藏后零 GPU 着色器开销；`MarcoLiquidGlass.swift` 桥接系统 `UIAccessibility.isReduceTransparencyEnabled` 实时监听与原生 `showOptionSheet`（`UISheetPresentationController` 半屏选择器），倍速、定时关闭、画面/内核、音轨、字幕与弹幕设置优先呼出原生 iOS 26 面板（带防重入单飞锁与 `MarcoDeinitSentinel` 清理），iOS 14–18 与开启降低透明度时自动优雅回退；`ios_settings.dart` 新增的「播放界面与 HUD」与弹幕设置开关均采用原生 `IosNativeSwitch`。
- **触控长按倍速升级、起播规格与定时/跳过体验**：保留并升级触控长按（`>= 350ms`）`2.0×` 倍速为「长按激活 → 左右横滑顺滑切换 `1.25× / 1.5× / 2.0× / 3.0×` → 上滑 `>= 48dp` 锁定倍速（顶部常驻解锁胶囊）」全链路状态机，支持两侧双击步进（`5s / 10s / 15s` 或播放暂停）与多指/后台/切集安全复位；接入 `StartSpecOverlay` 起播规格条（仅控件隐藏时展示）、底部常驻 `SlimProgressBar`、`3` 秒跳过倒计时胶囊与 `SleepTimerController` 定时关闭（注：桌面 Anime4K 不在 iOS 端开放）。
- **无黑洞详情进播放门户转场、极光背景与丝带加载**：`IosNativeRouteGate` 新增 `runWithPlaceholders` 深度计数门控（附 `100ms` 帧超时与 `try/finally` 异常恢复），进入播放器截图前单帧将详情页 `UiKitView` 替换为等尺寸玻璃占位符，彻底消除原生玻璃按钮截图黑洞；`player_enter.frag` 严格仅对 `uBackdropTex` 在 OpenGLES 下翻转 Y 轴而不翻转独立解码海报纹理（`uPosterTex`），iPhone 全出血竖屏布局无独立 `2:3` 海报卡时执行纯纵深后退与暗角过渡（零灰块遮挡），iPad 宽屏卡片布局复用渲染图像或限幅 `<= 720px` 解码海报完成门户展开，任何异常/超时/取消即时 `dispose()` GPU 纹理；空态/引导页接入 `aurora.frag` 极光背景，缓冲状态升级为 `1.6s` `BrandLogoLoader` 金属丝带 `M` 加载动画。
- **清洁室 30 秒分片弹幕引擎与原生按钮 5 幕新手引导**：接入 `DanmuSegmentCache` / `DandanplayProvider` / `DanmuLayer`（默认服务地址为空 `""`，支持弹幕设置半屏面板、字幕置于弹幕之上 Z 轴、静态 ReDoS 拦截器与 `HTTP 410` 单飞重试）；新增适配手机竖屏与 iPad 宽屏双栏的 5 幕故事化 `OnboardingScreen`（iOS 26 主按钮采用 `IosNativeGlassButton`，重看引导时完整保留用户原有毛玻璃模糊档位，附 `14` 张程序化「示例」海报）及首播手势提示胶囊；`detail_screen.dart` 英雄区与线路胶囊同步接入 `MediaBadges` 同心液态玻璃规格徽章。

## 包信息与构建记录

- **未签名 IPA（iPhone / iPad 通用，待正式构建）**：`MarcoMovie-0.5.35-ios-iphone-ipad-unsigned.ipa`（更新兼容别名 `MarcoMovie-0.5.35-ios-unsigned.ipa`）。
- **SHA-256 / 源码包 / 构建记录**：待 Mac 环境 Xcode Release 构建完成后填入。

## 验证范围与已知限制

- **已完成自动化验证（基于 `feat/ux-integration-20261120 @ 82f38cd2`）**：通过 `scripts/check_public_content.py`（`1507` 文件）及 `18` 套跨端 UX / 一致性 / 鸿蒙隔离 `flutter test` 测试集共 `193` 项测试全绿（含 `ios_player_chrome_test`、`player_hud_test`、`player_gesture_state_machine_test`、`detail_player_transition_integration_test`、`motion_player_enter_transition_test`、`danmu_*_test`、`onboarding_test`、`wave2_motion_wiring_test`、`wave2_wiring_and_gate1_test` 等，已覆盖 `IosNativeRouteGate` 占位恢复、竖屏无灰块遮挡、`reduceTransparency` 降级、多指打断防误 seek 与 `!OhosRuntime.isOhos` 隔离）。
- **待完成验证**：尚未在 Mac Xcode `26.6` 执行新版本号 Release `.ipa` 打包与二进制/最低版本校验，亦未在物理 iPhone（含灵动岛/刘海屏与 iOS 26 / iOS 15–18 设备）及 iPad（分屏多任务与全屏状态栏协同）上完成对照 `ios-v0.5.34` 的真机 A/B 验收。
