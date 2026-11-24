# Marco Movie iOS / iPadOS 0.7.6

发布日期：2026-11-24。应用版本 `0.7.6`（构建号 `99`），继续提供**双包并行构建与 App 内自动分流更新**：主包基于 Xcode `26.6`（`iphoneos26.5` SDK，支持原生 iOS 26 / 27 Liquid Glass，`MinimumOSVersion = 15.0`），同步产出面向 iOS / iPadOS `14.0+` 设备的独立兼容包（Xcode `16.4` / `iphoneos18.5` SDK，`MinimumOSVersion = 14.0`）。本次重点修复 iOS / iPadOS 14–18 底部 Dock 空白毛玻璃条、图标不可见、播放页悬浮条不自动隐藏以及首次安装冷启动白屏问题。

## 更新内容

- **根治 iOS 14–25 幽灵原生 Dock 遮挡与播放页不消失问题（双包同步生效）**：
  - 修复 `MarcoFlutterViewController.viewDidLayoutSubviews()` 在非 iOS 26 设备上调用 `bringRootChromeToFront()` 时误初始化 `MarcoIos27RootTabChromeController.shared`，导致未配置的空白原生胶囊（`zPosition = 1000`）覆盖 Flutter 底部 Dock、图标不可见且在播放页始终无法自动消失的问题；
  - 将原生根 Dock 控制器改为 `existingInstance` 延迟实例并增加 `isConfigured` 与 `isAvailable` 双重门禁，iOS 14–25 彻底不再创建或挂载原生根 Dock；
  - 修复 `< iOS 15` 圆形搜索/Logo 按钮写死 `cornerRadius = 31.0` 在宽屏顶部布局下被裁成菱形的问题，改为随 `dockSize * 0.5` 动态更新；修正 `isEffectiveDark(for:)` 在 `.unspecified` 状态下的深浅色判定。
- **全路由与播放页全局 Dock 自动隐藏保护**：
  - 新增 `IosRootTabNavigatorObserver` 与引用计数 `IosLiquidGlassBridge.acquireRootTabSuppression()`，在全屏 `PlayerScreen` 与任意二级路由推入时强制隐藏原生根 Dock，返回主界面后自动恢复，避免任何入口进入播放页后漏出悬浮栏。
- **iOS 14 首次安装冷启动白屏加固与启动页深浅色自适应**：
  - 引入 `MarcoBootstrapApp` 在启动瞬间立即绘制首帧并解除白屏 `LaunchScreen`，按系统深浅色显示自适应底色与品牌 Logo，初始化异常时提供“重新加载”恢复页而非静默停留在空白界面；
  - iOS 端延迟加载 `Mpv.framework`（仅在 `VideoKernel.create()` 实际使用 MPV 时初始化），避免首帧前同步 `dlopen` 阻塞；
  - 为 `StorageService.init()` 增加 `SharedPreferences` 冷启动竞态退避重试、`getApplicationSupportDirectory()` 2s 超时回退、Keychain 读写 2s 超时保护与 iOS 非阻塞 Keychain 水合（WebDAV 启动同步异步等待 `waitForCredentialsReady()`）；`IosLiquidGlassBridge.ensureInitialized()` 遇到冷启动 `MissingPluginException` 不再永久锁死失败状态；
  - `LaunchScreen.storyboard`、`Main.storyboard`、`MarcoFlutterViewController.viewDidLoad()` 与 `AppDelegate` 统一适配 iOS 13+ `systemBackgroundColor`，消除深色模式冷启动白闪。

## 包信息与构建记录

- **未签名主包（iOS / iPadOS 15.0+，原生 iOS 26 / 27 Liquid Glass SDK）**：`MarcoMovie-0.7.6-ios-iphone-ipad-unsigned.ipa`（`63909247` B，兼容别名 `MarcoMovie-0.7.6-ios-unsigned.ipa`），SHA-256：`e143423f039780f85d40514a590b7a1304c9ce76dace4b8e29be9928a79a341a`。
- **未签名兼容包（iOS / iPadOS 14.0+ 通用兼容版）**：`MarcoMovie-0.7.6-ios14-unsigned.ipa`（`63904663` B），SHA-256：`2e73155cb32176a632afeb715a6c483b526ccda7c4dce5def0791c468e357e4a`。
- **对应源码包**：`MarcoMovie-ios-v0.7.6-source.zip`（`11564624` B），SHA-256：`949264755a4188e82826d7210c388e5b60b2e4c8b3b278974971b880e046caca`。
- **构建提交与 CI 记录**：`98b61b6845b324161d404725161431a4e1dce2af`。[iOS 15.0+ 主包构建（Job 138154755838 · Run 45306989710）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45306989710/job/138154755838) / [iOS 14.0+ 兼容包构建（Job 138154755770 · Run 45306989710）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45306989710/job/138154755770) / [公开守卫与离线校验（Job 138153130151）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45306989710/job/138153130151) / [Public content checks（45306945458）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45306945458)。

## 验证范围与已知限制

- **自动化与云端构建校验**：在提交 `98b61b6845b324161d404725161431a4e1dce2af` 上通过了 `Public content checks`（Run `45306945458`）、`Build Multiplatform`（Run `45306989710`：`Public Guardrails & Offline Java Checks` + Xcode `26.6` / `iphoneos26.5` `MinimumOSVersion = 15.0` 主包 + Xcode `16.4` / `iphoneos18.5` `MinimumOSVersion = 14.0` 兼容包双包构建，并验证双包 `Info.plist` 版本号、最低系统版本与 `LaunchScreen.storyboardc` / `Main.storyboardc` 产物完整）、Flutter `3.38.9` 回归测试（含新增 `ios14_launch_and_dock_regression_test.dart` 共 `155/155` 通过）、Flutter `3.47.9` 交叉测试（`32/32` 通过）、`flutter/test_*.py`（`22/22` 通过）、`scripts/check_public_content.py`（`1604` 文件）及 `scripts/sync_readme_versions.py --check`。本轮尚未在物理 iPadOS 14.8.1 或全型号物理 iPhone / iPad 设备上完成真机覆盖安装与实机播放验收。
- **已知限制**：未签名 `.ipa` 需通过 TrollStore（巨魔）或个人自签工具安装；真系统级 Liquid Glass 需使用 `ios-iphone-ipad-unsigned.ipa` 主包并运行于支持该特性的 iOS / iPadOS 版本；iOS 14.x 设备请使用 `ios14-unsigned.ipa` 兼容包（应用内检查更新会自动匹配）；第三方直播源、网盘与片源可用性取决于用户自行导入的上游服务及网络环境。
