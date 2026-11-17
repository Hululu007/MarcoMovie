# Marco Movie macOS 0.5.19

发布日期：2026-11-17。应用版本：`0.5.19`（构建号 `69`）。本次更新修复 macOS 本地订阅文件与离线配置包选择无响应问题，同步升级桌面播放器鼠标唤醒防抖、网盘伪装 `.mp3` 视频原画播放、WebDAV 仅同步订阅源模式及 JSON 备份文件直接导出与恢复。

## 更新内容

- **本地订阅与离线 `.zip` 配置包导入修复（`#57`）**：为 macOS 应用补齐 `com.apple.security.files.user-selected.read-write` 用户自选文件沙盒权限并增加内存字节流读取兜底，修复设置页与首页点击「选择本地配置 / 离线包」无反应的问题。
- **桌面播放器鼠标防抖与自动隐藏优化（`#50`）**：去重指针移动事件，控制栏收起后需 `350ms` 内累计移动 `>= 12px` 才唤醒，空闲自动隐藏缩短至 `2.2s`，观影体验更沉浸。
- **网盘伪装 `.mp3` 视频识别播放（`#31`）**：夸克、UC、百度、阿里云盘分享自动将 `>= 15 MiB` 的伪装 `.mp3` 识别为视频并在 `mpv` 强制开启 `vid=auto`，修复只出声无画面问题。
- **WebDAV 仅同步订阅源模式与 JSON 备份文件读写（`#44` / `#47`）**：WebDAV 新增「同时同步观看历史与收藏」开关（关闭后仅同步订阅源，实现多设备观看记录隔离且不清空云端原有记录）；备份恢复弹窗支持一键导出与选择本地 `.json` 文件。

## 包信息与构建记录

- **macOS 桌面应用包（Apple Silicon / Intel）**：`MarcoMovie-0.5.19-macos-desktop.zip`（更新兼容别名 `MarcoMovie-0.5.19-macos.zip`），SHA-256：`e8620a66d5b2e5815f2ba8ce9ba9c3118eba12875c68cbc4cab06d8dbbdddfaf`。
- **对应源码包**：`MarcoMovie-macos-v0.5.19-source.zip`，SHA-256：`9c4356bb4bec4ac3aa672b501c0edb0ceb221fbd00d609c650c0198b7e27b1fa`。
- **构建提交**：`a3cbe546c3faa803e6be2b06bbe62b6767e503c9`。[多端原生构建与校验记录（44020396179）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44020396179)。

## 验证范围与已知限制

- 通过公共内容守卫检查、macOS 原生 Release 构建、沙盒权限重签校验、`Mpv.framework` 媒体回放测试及全套 Flutter 自动化回归；应用压缩包未公证，首次打开请右键选择“打开”。
