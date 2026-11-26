# Marco Movie iOS / iPadOS 0.7.9

发布日期：2026-11-26。应用版本 `0.7.9`（构建号 `102`），继续提供**双包并行构建与 App 内自动分流更新**：主包基于 Xcode `26.6`（`iphoneos26.5` SDK，支持原生 iOS 26 / 27 Liquid Glass，`MinimumOSVersion = 15.0`），同步产出面向 iOS / iPadOS `14.0+` 设备的独立兼容包（Xcode `16.4` / `iphoneos18.5` SDK，`MinimumOSVersion = 14.0`）。本次为 iOS / iPadOS 专项体验升级与发热治理版本，涵盖无框四列资源库与 Apple 超椭圆图标重绘、Dock 长按原位弹泡与切页选中态同步、历史记录海报墙与长按删除、剧集下载自动收纳与多连接提速、设置页零重复重构、自备 API 的 AI 助手（第一阶段）、iPhone 17 Pro Max（iOS 27.0）发热根治，以及全新 Apple 风格 5 屏功能引导。

## 更新内容

- **重设计「添加资源库」无框四列图标流与 13 枚 Apple 风格图标**：移除图标下方外框卡片、描边与阴影，改为以图标为主体的对称四列排版（iPhone 一行 4 个，宽屏 5 列、iPad 6 列，单行紧凑标题居中）；采用 Apple 连续超椭圆（$n=5$）光感渐变与精细白色矢量图形重新绘制全部 13 枚资源库图标（Emby、Jellyfin、Plex、WebDAV、SMB、AList / OpenList、夸克、UC、百度、阿里、当前设备、手动输入、本地配置包）。
- **优化底部 Dock 长按不抬起悬浮并同步菜单切页选中态**：iOS 17.4+ 改为 `0.4s` 长按触发瞬态原位菜单锚点（`MarcoEphemeralMenuAnchorButton`），直接在按钮正上方弹出液态气泡菜单而不再让按钮缩放悬浮抬起（iOS 15–17.3 与 Flutter 回退路径同步取消按压缩放抬起）；通过长按气泡菜单切换页面后，底部 Dock 的选中标签状态自动对应切换并同步原生胶囊高亮。
- **观看历史升级为海报墙并支持长按删除与撤销**：iOS「片库 → 历史」改为 2:3 圆角海报墙网格（iPhone 3 列 / iPad 自适应多列），海报底部叠加播放进度条并展示上次观看集数或时间进度，支持点击平滑展开详情；长按任意历史海报弹出上下文菜单（`继续播放` / 红色破坏性 `删除记录`），删除后底部提供 3 秒一键撤销提示条。
- **离线下载剧集自动收纳展开与多连接并发提速**：
  - **按剧集自动收纳**：同一部剧的多集下载任务自动聚合收纳为单张剧集卡片（显示剧名、汇总进度条、`已完成 X/Y 集` 与合并实时下载速度），点击卡片可展开查看每一集的独立进度，并支持整剧一键全部暂停、继续或删除。
  - **下载速度深度优化**：HLS 分片并发数提升至 6 路（单主机连接上限提升至 `12`），将 `stage_manifest.json` 进度落盘改为 `1200ms` 节流合并写入（消除长分片清单逐片全量重写造成的磁盘 I/O 瓶颈），`>= 192 KB` 的 AES-128 加密分片移交后台 `Isolate` 解密，并对支持 `Accept-Ranges: bytes` 且体积 `>= 16 MB` 的直链 MP4 / MKV 文件启用 4 连接 HTTP `206` 分段并发下载（不支持分段的服务端自动安全回退单流）。
- **重构设置页信息架构并彻底消除重复入口**：将 iOS 设置页重新归纳为 `内容与来源`、`播放`、`外观与主页`、`数据与存储`、`通用` 5 大分组（共 16 个职责单一的根级入口），移除多余的二级中转包装页，清理此前跨分组重复出现的 `添加资源库`、`订阅与分组管理`、`配置中心`、`多端同步`、`CatPaw 运行时` 与 `重新查看新手引导` 等入口，同步更新设置搜索索引。
- **新增自备个人 API 的「AI 助手」（第一阶段）**：
  - **纯本地自备凭据架构**：唯一配置入口位于「设置 → 通用 → AI 助手」，默认关闭且默认接口地址为空 `""`；兼容 OpenAI Chat Completions、Anthropic Messages 与 Gemini GenerateContent 三种标准协议格式，API Key 仅加密保存在本机系统 Keychain（不纳入备份或云同步），内置连通性测试、本地 SHA-256 结果缓存、月度 Token 预算上限，并在隐私空间解锁期间硬性阻断外部调用。
  - **AI 模糊描述找片 + 脏文件名智能净化**：开启后在全局搜索页提供「AI 找片」入口，可根据剧情、场景或模糊印象提取候选影视名称并严格在用户已导入的自有片源中并发匹配真实结果；在浏览 SMB / WebDAV / AList / 个人网盘文件夹时自动后台静默清洗含压制组、分辨率、编码标签的杂乱文件名，无感展示干净片名与季集信息。
- **根治 iPhone 17 Pro Max（iOS 27.0）等机型高刷与播放异常发热（仅 iOS 端）**：
  - 修复 iOS 端轻量 `Anime4K` 超分默认误开启导致每次起播常驻挂载实时卷积着色器的问题（改为默认关闭，仅用户手动开启时生效），并打通纯 `libmpv` 播放路径的系统热状态降级回调（`.fair` 温升即提前切换低温播放档位）。
  - 在包含 iOS 26 / 27 在内的全系 iOS 禁用高开销 54-tap `glasswork.frag` 着色器、收紧模糊半径（常规 `<= 10`，`.fair` 温升 `<= 6`，`TileMode.clamp`）并将首页 `aurora` 设为静态背景；播放控制栏自动隐藏且关闭底部细进度条时停止进度 `setState()` 重建（`0 Hz`，仅开启细条时限频 `1 Hz`，唤出控制栏或拖动跳转时即时刷新），原生 `AVPlayer` 时间观察间隔放宽至 `0.5s` 并在暂停/后台去重。
  - `IosNativeRouteGate` 在 120Hz 列表滚动、后台 `TickerMode` 停用或热降频时自动将可滚动原生 `UiKitView` 替换为轻量占位；根部原生液态 Dock 隐藏时真正设置 `isHidden = true` 停止离屏玻璃合成，并将形变 `CADisplayLink` 限帧至 `60fps`；海报网格启用 `ResizeImage` 按屏幕实际像素宽度解码，大幅降低显存占用与 GPU 纹理带宽。
- **重做简洁 Apple 风格 5 屏新手功能引导**：全新设计 `欢迎使用 Marco`、`连接你的内容来源`、`自由浏览与精准找片`、`手势直觉与沉浸视听`、`多端同步与隐私守护` 5 屏导览，聚焦核心功能上手方法，配备定制 Apple 风格矢量示意插画，完整适配深浅色模式、iPad 居中卡片/横屏双栏与系统动态字体缩放，全程零常驻循环动画。

## 包信息与构建记录

- **未签名主包（iOS / iPadOS 15.0+，原生 iOS 26 / 27 Liquid Glass SDK）**：`MarcoMovie-0.7.9-ios-iphone-ipad-unsigned.ipa`（`69261118` B，兼容别名 `MarcoMovie-0.7.9-ios-unsigned.ipa`，两者字节级完全相同），SHA-256：`78b9d71724b2a767a5758d33f42f3d4a6d57d051b62a3cbabdae88a57c0eafa0`。
- **未签名兼容包（iOS / iPadOS 14.0+ 通用兼容版）**：`MarcoMovie-0.7.9-ios14-unsigned.ipa`（`69260297` B），SHA-256：`04a3893acc952da3bc9e69a440a24b0524c25bb73992d1744492a8f9eeadcee1`。
- **对应源码包**：`MarcoMovie-ios-v0.7.9-source.zip`（`21820252` B），SHA-256：`55beba569f7aaf337a1b4804408e8ed17684f3827e5b4ad4ed5f0616efc3d230`。
- **构建提交与 CI 记录**：`7160bbc208dd221894e6460510f6a520069718af`（已快进合入 `main`）。[iOS 15.0+ 主包构建（Job 139911058013 · Run 45819945026）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45819945026/job/139911058013) / [iOS 14.0+ 兼容包构建（Job 139911058067 · Run 45819945026）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45819945026/job/139911058067) / [公开守卫与离线校验（Job 139909320752）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45819945026/job/139909320752)。

## 验证范围与已知限制

- **自动化与云端构建校验**：在提交 `7160bbc208dd221894e6460510f6a520069718af` 上通过了 `Build Multiplatform` 双 IPA 工作流（Run `45819945026`：`Public Guardrails & Offline Java Checks` 含 `2753` 个追踪文件公开合规、`README.md` 版本对齐与 Flutter 3.38.9 三端一致性测试 + `macos-26` / Xcode `26.6` / `iphoneos26.5` `MinimumOSVersion = 15.0` 主包构建与全量 `flutter test` 套件通过 + `macos-15` / Xcode `16.4` / `iphoneos18.5` `MinimumOSVersion = 14.0` 兼容包构建），核对双包 `Info.plist` 版本 `0.7.9 (102)`、`MinimumOSVersion`（`15.0` / `14.0`）及全部 8 项发布资产 SHA-256 一致；新增 `ios_079_dock_menu_selection_test.dart`、`ios_079_history_downloads_test.dart`、`ios_079_download_engine_test.dart`、`ios_079_settings_ia_test.dart`、`ios_079_ai_phase1_test.dart`、`ios_079_thermal_ios27_test.dart`、`ios_079_onboarding_flow_test.dart` 等 7 组专项回归测试覆盖本轮全部改动。本轮尚未在物理 iPhone 17 Pro Max（iOS 27.0）、iPad Pro 2020（iPadOS 15.4）及 iOS 14.x 真机上完成覆盖升级、长时静置/播放温升与真实个人 AI 接口实测验收。
- **已知限制**：未签名 `.ipa` 需通过 TrollStore（巨魔）或个人自签工具安装；`MarcoMovie-0.7.9-ios-iphone-ipad-unsigned.ipa` 与 `MarcoMovie-0.7.9-ios-unsigned.ipa` 为同一份 iOS 15.0+ 主包（后者为旧版应用内更新兼容别名），手动安装任选其一即可；iOS 14.x 设备请使用 `ios14-unsigned.ipa` 兼容包（应用内检查更新会自动匹配）；AI 助手不内置任何接口地址或密钥，需用户自行配置合规的个人 API 后方可使用。
