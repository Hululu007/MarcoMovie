# Marco Movie Windows 0.5.14

发布日期：2026-11-11。应用版本：`0.5.14`（构建号 `64`）。本次更新专门修复 Windows 端播放夸克、UC、百度等网盘 4K / 原画大体积剧集时卡在 `00:00`“正在缓冲…”无限加载的问题，并包含桌面端此前已合入的百度分享重定向签名、详情页分享提示、并发搜索优化与设置页滚动视口修复。

## 更新内容

- **本地网盘流代理（`CloudMediaProxy`）断连回收与吞吐修复**：监听播放器本地回环响应套接字关闭事件，当 `libmpv` / FFmpeg 完成 `ftyp`、`moov` 或音视频交错 `Range` 探测并断开连接时立即取消对应上游网盘 HTTP 流，避免残留僵尸流持续占用带宽；将单租约并发连接上限由 `4` 提升至 `16`，将逐块强制 `flush()` 改为 `256 KB` 分批回压刷新，并修复百度网盘外部 CDN 重定向剥离 `Cookie` 时的请求头映射类型异常。
- **首帧起播监控与自动画质降档恢复（`PlaybackStartup`）**：修复 `libmpv` 解出第 0 帧（约 `40 ms` 时间戳与 `3840 × 2160` 分辨率）即提前取消起播超时并阻断清晰度回退的问题。现要求播放位置实际推进至少 `250 ms` 才确认起播；在首播窗口（`< 3 秒`）内若因原画码率过高持续停留在缓冲状态满 `12 秒`（或总起播等待满 `15 秒`）且存在备选清晰度 / 线路，将自动切换至下一可用清晰度（如 `原画 -> 4K -> 超清`）并给出提示，同时兼容断点续播与跳过片头偏移重锚定。
- **Windows `libmpv` 内存缓存与协议参数加固**：显式设置 `cache-on-disk=no` 与 `cache-pause-wait=1`，消除 Windows 下 `MPV[error/lavf]: Failed to create file cache.` 磁盘缓存报错；修正 `demuxer-lavf-o` 合并逻辑，完整保留 HLS / 分段重试与协议白名单（`seg_max_retry=5`、`allowed_extensions=ALL`、`protocol_whitelist`）并叠加断线重连参数。
- **播放交互与轨道信息完善**：加载或缓冲期间保持顶部返回栏与底部清晰度切换入口常显、不再在 4 秒后自动隐藏；播放错误页新增“切换画质”按钮；桌面端新增 `tracks` 流监听以准确展示当前音视频编码信息。

## 包信息与构建记录

- **安装版（推荐）**：`MarcoMovie-0.5.14-windows-x64-setup.exe`（更新兼容别名 `MarcoMovie-0.5.14-windows-setup.exe`），SHA-256：`35cc235ccacdac3f3521b7c2dffb919a67a4fd9239c931ea39de3986526ff025`。
- **绿色便携版**：`MarcoMovie-0.5.14-windows-x64-portable.zip`（兼容别名 `MarcoMovie-0.5.14-windows-x64.zip`），SHA-256：`978c503cadbbfe0c4c1537a6628996fc098e6fac86d834381d6ec0c438b6bff7`。
- **对应源码包**：`MarcoMovie-windows-v0.5.14-source.zip`，SHA-256：`cf8b6754e6321aeea302ab030005be856e9143a649d0205803450cddaedafe42`。
- **构建提交**：`deb0a69a55401e6ae1ecaac74f03bb80ec7971d9`。[Windows x64 构建与原生解码检查记录（42966475277）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42966475277) · [公共内容与宿主守卫检查（42965287044）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42965287044)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Python / JS / CatPaw 共享宿主检查，以及全部 `657` 项 Flutter 自动化测试与打包 `libmpv-2.dll` 合成鉴权回放回归（覆盖 `Range` 探测断连回收、MP4 首帧 `00:00` 缓冲停滞自动降档、断点续播重锚定、百度跨域重定向及无磁盘缓存报错校验）。
- 本版本仅发布 Windows x64 安装版与绿色便携版，不变更 Android、macOS 或 iOS 已发布版本。更新前请先退出正在运行的旧版程序。
- 自动化与合成媒体回归验证传输代理、缓冲状态机与打包解码链路，不代表已使用用户私人网盘账号对特定第三方原片完成全片实机验收；网盘服务端限速、失效分享或站点验证仍按实际状态提示。
