# Marco Movie iOS / iPadOS 0.7.5

发布日期：2026-11-24。应用版本 `0.7.5`（构建号 `98`），本次起提供**双包并行构建与 App 内自动分流更新**：主包基于 Xcode `26.6`（`iphoneos26.5` SDK，支持原生 iOS 26 / 27 Liquid Glass，`MinimumOSVersion = 15.0`），同时提供面向 iOS / iPadOS `14.0+` 设备的独立兼容包（Xcode `16.4` / `iphoneos18.5` SDK，`MinimumOSVersion = 14.0`）。本次更新汇总 `0.7.1` 至 `0.7.5` 的全部交互、播放、片源与详情页稳定性修复。

## 更新内容

- **双包并行构建与 App 内按系统版本自动分流更新**：
  - 并行产出 **iOS 15.0+ 主包**（含原生 Liquid Glass SDK）与 **iOS 14.0+ 兼容包**；
  - `AppUpdate` 与 `IosUpdateSheet` 按本机系统主版本自动匹配对应安装包：iOS 14.x 设备自动拉取并校验 `ios14-unsigned.ipa`（绝不误拉 `MinimumOSVersion = 15.0` 的主包），iOS 15.0+ / iOS 26 / iOS 27 设备自动拉取主包，并在保存文件名、旧包清理与镜像站同步中严格隔离。
- **详情页刷新、线路与剧集身份精准绑定及网盘/M3U 链路修复**：
  - 修复详情页下拉刷新请求状态、提示文案与松手动作一致性，支持刷新后发现新增剧集并准确保留用户手动选择的线路（覆盖同名线路、MacCMS `sid` 重排及夸克多分享重排场景）；
  - 修复同名剧集删除后旧选集弹层误播相邻条目的问题，无法唯一确认目标时阻止误播并提示重选；
  - 修复网盘分享部分撤回与临时 `503` 并发时的缓存回退逻辑：已确认撤回的分享彻底移除，临时故障分享保留历史剧集或可重试状态，过期重进与等待片源响应期间绝不显示或点播已撤回剧集；
  - 修复 M3U 内嵌夸克分享链接在详情页首帧剥离后丢失原始输入导致首次无法展开的问题，响应前拦截点播、响应后首击即播，下拉刷新可发现新增剧集，并完整保留普通 M3U 直链与有效缓存的即时播放；
  - 修复 XML 注释旧影片混入、根节点后附带源站错误文本误清缓存、以及夸克未返回 `stoken` 误标下架等问题。
- **原生液态玻璃交互、首页可读性与片源能力升级（汇总 0.7.1 – 0.7.4）**：
  - 升级苹果原生 SF Symbols 底部 Dock 图标、修复浮动 Logo 叠层顺序并恢复 `UiKitView` 之上原生 `UIMenu` 弹出；
  - 优化默认首页卡片文字对比度、海报接缝衔接与高清 Hero 海报匹配；
  - 增强配置中心、外部媒体库连接器、设备画质分级、剧集刮削、RTSP 直播、播放器 HUD 与 iPad / iPhone Duo 启动适配。

## 包信息与构建记录

- **未签名主包（iOS / iPadOS 15.0+，原生 iOS 26 / 27 Liquid Glass SDK）**：`MarcoMovie-0.7.5-ios-iphone-ipad-unsigned.ipa`（`63908850` B，兼容别名 `MarcoMovie-0.7.5-ios-unsigned.ipa`），SHA-256：`947784dd59bce99e2b56722972f34f62c3a9dd4d8b96e014649b139b63611cb0`。
- **未签名兼容包（iOS / iPadOS 14.0+ 通用兼容版）**：`MarcoMovie-0.7.5-ios14-unsigned.ipa`（`63910444` B），SHA-256：`15615c0d21a6001e42c1909f12379fa671ea069abd90fe48f7c2271ecf442b1f`。
- **对应源码包**：`MarcoMovie-ios-v0.7.5-source.zip`（`11533735` B），SHA-256：`3c1c0f76b4c9e904cddd5a2d0e18c09d292431b0d52c9d9af96a73d7dc94f808`。
- **构建提交与 CI 记录**：`88fd7229c6d0e2c457308ec077b07ef80a9bdaa5`。[iOS 15.0+ 主包构建（Job 137852332364 · Run 45219248528）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45219248528/job/137852332364) / [iOS 14.0+ 兼容包构建（Job 137852332310 · Run 45219248528）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45219248528/job/137852332310) / [公开守卫与离线校验（Job 137848711654）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45219248528/job/137848711654) / [Public content checks（45219246026）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45219246026)。

## 验证范围与已知限制

- **自动化与云端构建校验**：在提交 `88fd7229c6d0e2c457308ec077b07ef80a9bdaa5` 上通过了 `Public content checks`（Run `45219246026`）、`Build Multiplatform`（Run `45219248528`：`Public Guardrails & Offline Java Checks` + Xcode `26.6` / `iphoneos26.5` `MinimumOSVersion = 15.0` 主包 + Xcode `16.4` / `iphoneos18.5` `MinimumOSVersion = 14.0` 兼容包双包构建）、`23/23` 项详情/网盘/M3U 独立验收测试、`app_update_test.dart` 与 `ios_update_flow_test.dart`（`35/35` 项双包分流与下载校验）、`flutter/test_ios_package.py`（`12/12`）、`scripts/test_platform_packages.py`（`22/22`）、`scripts/check_public_content.py`（`1603` 文件）及 `scripts/sync_readme_versions.py --check`。本轮尚未宣称完成全型号物理 iPhone / iPad（含 iOS 14 与 iOS 26/27）真机覆盖安装与实机播放验收。
- **已知限制**：未签名 `.ipa` 需通过 TrollStore（巨魔）或个人自签工具安装；真系统级 Liquid Glass 需使用 `ios-iphone-ipad-unsigned.ipa` 主包并运行于支持该特性的 iOS / iPadOS 版本；iOS 14.x 设备请使用 `ios14-unsigned.ipa` 兼容包（自 `0.7.5` 起应用内检查更新会自动匹配）；第三方直播源、网盘与片源可用性取决于用户自行导入的上游服务及网络环境。
