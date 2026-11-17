# Marco Movie Apple TV 0.1.0

发布日期：2026-11-17。应用版本：`0.1.0`（构建号 `1`），最低系统要求：tvOS 16.0。本次发布为 Marco Movie 原生 Apple TV（`tvOS`）首发版本，基于 Swift 5.9、SwiftUI、AVKit 与内嵌 QuickJS-NG 打造 10 英尺大屏交互体验，并与全平台互通同步备份及 4K 网盘原画分片代理。

## 更新内容

- **原生 tvOS 10 英尺大屏交互与 Siri Remote 焦点引擎**：专为 Apple TV 大屏设计顶部导航栏（首页、直播、搜索、片库、设置）、自适应多列海报墙、详情选集页、遥控方向键连续焦点移动与系统语音/键盘搜索。
- **多格式订阅、直播与本机 QuickJS-NG 脚本宿主**：支持 JSON / XML CMS 采集源、2423 Hex-AES / Base64 / 图片隐写配置解码、多仓（`storeHouse` / `urls` / `depots`）聚合切换、M3U / TXT 直播频道分组播放，以及基于 C 源码静态编译的 QuickJS-NG ES2023 轻量脚本源（含 `init` / `home` / `category` / `detail` / `search` / `play` 与 12 秒看门狗保护）。
- **4K 网盘扫码授权与 6 路并发 Range 回环代理**：设置内提供夸克、UC、百度网盘、阿里云盘四盘官方扫码登录（凭据存入系统 Keychain 并严格校验无控制字符）；内置 `127.0.0.1` 随机端口一次性令牌 `TvNetdiskRangeProxy`，支持 `6 × 1 MiB` 滑动窗口并发分片预取、尾部元数据秒跳与上游 `401` / `403` 自动刷新重连。
- **AVPlayer 4K HDR 画质徽标与多音轨/内封字幕切换**：播放页实时检测并展示 `4K`、`Dolby Vision`、`HDR10`、`HLG` 画质胶囊徽标，支持倍速（`0.75x`–`2.0x`）、画面比例、多音轨切换、内封字幕切换、片头片尾跳过记忆及续播进度自动保存。
- **全平台同步与备份互通**：完整接入 `marco-movie-sync` v2 协议（支持 WebDAV 云同步、仅同步订阅源隔离观看记录模式、局域网 `/configure/<token>` 手机扫码配对导入与双向同步）及 `marco-movie-backup` JSON 备份互通。

## 包信息与构建记录

- **未签名 IPA（Apple TV / tvOS 16.0+）**：`MarcoMovie-0.1.0-tvos-appletv-unsigned.ipa`（更新兼容别名 `MarcoMovie-0.1.0-appletv-unsigned.ipa`），SHA-256：`02e7c3cef2c999800ddf69aa4bc22715019ef045b0ec26354dd08e8defb5cdad`。
- **对应源码包**：`MarcoMovie-appletv-v0.1.0-source.zip`，SHA-256：`f7e4395a82c78c722230c93460000deb473ad1b4b49d1f993baa95d6807aed85`。
- **构建提交**：`511f5b2daea0d7d604c73a6cfd518cc8b8afd707`。[多端原生构建与校验记录（44111559315）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44111559315) · [公共内容守卫检查（44111559279）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44111559279)。

## 验证范围与已知限制

- 通过公共内容守卫检查、`swift test` 10 组自动化单元与协议回归测试（覆盖 CMS 解析、QuickJS-NG 脚本宿主、网盘凭据校验、6 路 Range 回环代理及 HDR 轨道元数据识别）以及 macOS Xcode `appletvos` Release 原生构建与 Mach-O 平台头校验。
- 已知限制：发布包为未签名 `.ipa`，需通过 Xcode、Sideloadly、自签工具或巨魔（TrollStore tvOS）安装；受 tvOS 系统限制不支持 Android JAR 插件、JIT 执行或持久化磁盘大缓存；尚未宣称完成全型号物理 Apple TV 硬件与第三方私有账号完整长片验收。
