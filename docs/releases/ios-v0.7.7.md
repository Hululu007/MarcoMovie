# Marco Movie iOS / iPadOS 0.7.7

发布日期：2026-11-26。应用版本 `0.7.7`（构建号 `100`），继续提供**双包并行构建与 App 内自动分流更新**：主包基于 Xcode `26.6`（`iphoneos26.5` SDK，支持原生 iOS 26 / 27 Liquid Glass，`MinimumOSVersion = 15.0`），同步产出面向 iOS / iPadOS `14.0+` 设备的独立兼容包（Xcode `16.4` / `iphoneos18.5` SDK，`MinimumOSVersion = 14.0`）。本次重点新增首次启动官方渠道与安全防伪声明及设置页联系反馈入口、个人媒体库与 SMB2 / 个人网盘直连浏览，并针对 iPad 冷启动、全屏系统栏、播放器控件排版、多窗口方向监听迁移、画中画及片尾回看续播完成全面加固。

## 更新内容

- **安装 / 升级后首次启动官方渠道与安全防伪弹窗（iOS / iPadOS）**：安装或覆盖升级后首次启动居中弹出官方渠道防伪声明，展示作者各社媒统一账号名 **`PILIPALA来信`**（小红书、B站、抖音、公众号、视频号，支持一键复制）、Marco 官网 **`marcotv.wlj9919.top`**（支持直接访问与复制）及防伪提醒「下载软件请认准官网地址，以防不明渠道软件添加病毒等不良内容」；确认状态仅保存于本机，写入异常时仍支持一次点击继续进入应用，弹窗退场或关闭时立即失效在途剪贴板写入。
- **设置页「联系与反馈作者」与「官网交流群」入口（iOS / iPadOS）**：设置页「关于」分组新增作者全平台社媒账号与官网交流群直达入口，明确区分打开浏览器成功、自动复制成功与两者均失败（双失败提供可手动选取的完整地址），绑定发起页面生命周期并对在途操作去重，防止过期外链请求覆盖用户主动复制的作者账号。
- **个人媒体库与局域网 SMB2 / 个人网盘直连浏览**：新增原生 SMB2 客户端、媒体文件夹浏览器与个人网盘选片页，扩展夸克 / UC / 百度 / 阿里云盘与 WebDAV / Emby 个人资源库浏览及播放接入能力。
- **iPad 冷启动、全屏系统栏与播放器控件排版修复**：增加启动诊断与恢复保护避免 iPad 冷启动白屏；修复 iPad / iPhone 全屏播放时状态栏与底部 Home Indicator 遮挡，以及播放控制按钮与时间文本重叠问题。
- **多窗口方向监听宿主迁移、画中画、硬件音量与片尾回看续播加固**：完善同一引擎多窗口/分屏切换及重挂空档期的方向监听自动恢复、退出撤销与网盘授权弹窗宿主隔离（保留双栏独立引擎隔离）；优化原生 `AVPlayer` 画中画（PiP）进入与恢复、硬件音量与蓝牙音频路由、竖屏直播伴侣、片尾回看防误跳下一集及退出重开精确续播。
- **iOS 液态玻璃交互、筛选、搜索与无障碍体验提升**：新增筛选面板与按压滑动菜单，优化底部 Dock、精选发现与全屏搜索体验，并同步完善 VoiceOver 无障碍与减弱动态效果适配。

## 包信息与构建记录

- **未签名主包（iOS / iPadOS 15.0+，原生 iOS 26 / 27 Liquid Glass SDK）**：`MarcoMovie-0.7.7-ios-iphone-ipad-unsigned.ipa`（`69083281` B，兼容别名 `MarcoMovie-0.7.7-ios-unsigned.ipa`），SHA-256：`948dd717c15c2b645243bdf71eb412e4832814bb171332f8c1f1e14d9c010005`。
- **未签名兼容包（iOS / iPadOS 14.0+ 通用兼容版）**：`MarcoMovie-0.7.7-ios14-unsigned.ipa`（`69082785` B），SHA-256：`3e4eadc9a6a943dd616f163ecea13cc2e1e686366f847aa34c59df6b9e15ed76`。
- **对应源码包**：`MarcoMovie-ios-v0.7.7-source.zip`（`21690001` B），SHA-256：`ded924efe9f527ef754b7e1e614e777a2d6cdc604ad7824cdcf2fd6902c24081`。
- **构建提交与 CI 记录**：`e628c3ab0e66535646ac33c85782661e6908a15d`（已合入 `main`，同步完成 `macos/` 桌面工程独立拆分）。[iOS 15.0+ 主包构建（Job 139759731848 · Run 45775524017）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45775524017/job/139759731848) / [iOS 14.0+ 兼容包构建（Job 139759731919 · Run 45775524017）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45775524017/job/139759731919) / [公开守卫与离线校验（Job 139758147005）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45775524017/job/139758147005) / [独立 macOS 校验构建（Run 45771010988）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45771010988)。

## 验证范围与已知限制

- **自动化与云端构建校验**：在提交 `e628c3ab0e66535646ac33c85782661e6908a15d` 上通过了 `Build Multiplatform` 双 IPA 工作流（Run `45775524017`：`Public Guardrails & Offline Java Checks` + `macos-26` / Xcode `26.6` / `iphoneos26.5` `MinimumOSVersion = 15.0` 主包与全量 `1564` 项 `flutter test` + `macos-15` / Xcode `16.4` / `iphoneos18.5` `MinimumOSVersion = 14.0` 兼容包，双包 `Info.plist` 版本 `0.7.7 (100)` 与 SHA-256 核对一致）、R19 独立复审闭环回归探针（含定制 Runner Debug/Release 编译、宿主迁移/空档恢复/退出撤销与公告剪贴板专项校验）、独立 `macos/` 回归构建（Run `45771010988`，`1437` 项测试通过）、`scripts/check_public_content.py`（`2737` 文件）及 `scripts/sync_readme_versions.py --check`。本轮尚未在全型号物理 iPhone / iPad 设备上完成逐项实机覆盖升级与播放抽检。
- **已知限制**：未签名 `.ipa` 需通过 TrollStore（巨魔）或个人自签工具安装；真系统级 Liquid Glass 需使用 `ios-iphone-ipad-unsigned.ipa` 主包并运行于支持该特性的 iOS / iPadOS 版本；iOS 14.x 设备请使用 `ios14-unsigned.ipa` 兼容包（应用内检查更新会自动匹配）；第三方直播源、网盘与片源可用性取决于用户自行导入的上游服务及网络环境。
