# Marco Movie iOS / iPadOS 0.5.32

发布日期：2026-11-17。应用版本：`0.5.32`（构建号 `82`），最低系统要求：iOS / iPadOS 14.0。本次更新升级网盘伪装 `.mp3` 视频原画播放、WebDAV 仅同步订阅源（隔离观看记录）模式及 JSON 备份文件直接导出与恢复能力。

## 更新内容

- **网盘伪装 `.mp3` 视频识别与原画播放（`#31`）**：夸克、UC、百度、阿里云盘分享自动将 `>= 15 MiB` 的伪装 `.mp3` 资源纳入可播放视频条目，并在播放器底层启用 `vid=auto` 视频轨道探测，解决伪装后缀片源黑屏仅有声音的问题。
- **WebDAV 仅同步订阅源模式（`#44`）**：云端同步新增「同时同步观看历史与收藏」开关；关闭后仅同步订阅源列表并完整保留云端已有的观看历史与收藏记录，方便多设备共享片源但各自独立保留观影进度。
- **JSON 备份文件直接导出与恢复（`#47`）**：备份与恢复弹窗新增「导出为 JSON 文件」与「选择 JSON 文件」按钮，配合文件内存读取兜底可在「文件」App 中直接保存或导入完整备份配置。

## 包信息与构建记录

- **未签名 IPA（iPhone / iPad 通用）**：`MarcoMovie-0.5.32-ios-iphone-ipad-unsigned.ipa`（更新兼容别名 `MarcoMovie-0.5.32-ios-unsigned.ipa`），SHA-256：`87a90092312dcdfbfc004ad58274b1501f03fb8a1902858b1c0191d5a9021532`。
- **对应源码包**：`MarcoMovie-ios-v0.5.32-source.zip`，SHA-256：`77ad179ca97058861c21fd20b84e0e34fc5dae1827f8ab73ccd62bfeb8dab157`。
- **构建提交**：`a3cbe546c3faa803e6be2b06bbe62b6767e503c9`。[多端原生构建与校验记录（44020396179）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44020396179)。

## 验证范围与已知限制

- 通过公共内容守卫检查、iOS Xcode 原生 Release 构建及全套 Flutter 自动化测试；未签名 IPA 支持巨魔（TrollStore）直接覆盖更新或自签工具安装。
