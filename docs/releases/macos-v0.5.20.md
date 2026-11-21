# Marco Movie macOS 0.5.20

发布日期：2026-11-21。应用版本 `0.5.20`（构建号 `70`）。本次更新延续 Apple Silicon / Intel 通用桌面架构与本地数据兼容，新增桌面专属 `Anime4K v4.0.1` 4 档热切换、`DesktopPlayerHud` 键鼠交互与细进度条、清洁室 30 秒分片弹幕引擎、Impeller Metal 门户转场、极光背景与丝带加载器及宽屏双栏 5 幕新手引导。

## 更新内容

- **桌面专属 Anime4K `v4.0.1` 实时画质增强（热切换不中断播放）**：内置 MIT 许可 `bloc97/Anime4K v4.0.1` 6 枚官方 GLSL 着色器并经逐文件 SHA-256 校验（许可与清单记录于 `THIRD_PARTY_NOTICES.md` 与 `flutter/assets/shaders/anime4k/manifest.json`），macOS 桌面播放器内支持 **「关闭 / 性能 / 均衡 / 画质」** 4 档实时热切换与高分辨率显卡负载提醒，切回关闭立即卸载着色器链。
- **`DesktopPlayerHud` 键鼠交互、起播规格与细进度条**：完整保留桌面原有交互与沙盒导入特性，接入 `DesktopPlayerHud`（鼠标静止 `2.5s` 自动隐藏、滚轮调音量、`←` / `→` 加速预览与 `Esc` 取消、`S` / `[` `]` 倍速、`D` 弹幕开关、`Cmd+W` 退出保存进度），新增 `StartSpecOverlay` 起播规格徽章、底部常驻细进度条、`3` 秒跳过倒计时与定时关闭面板；`detail_screen.dart` 线路胶囊与详情页同步接入 `MediaBadges` 纯文字媒体规格徽章。
- **清洁室 30 秒分片弹幕引擎与无碰撞渲染**：接入 `DanmuSegmentCache` / `DandanplayProvider` / `DanmuLayer`（默认服务地址为空 `""`）与本机独立弹幕设置面板；支持 `mmdanmu://v1` 来源绑定、有符号时钟、`30s` 分片按需拉取与 `60%` 预取、`HTTP 410` 单飞重试、`180ms` Seek 防抖取消、静态 ReDoS 拦截器与有界 `TextPainter` 对象池；与 `VideoKernel.buildSubtitleOverlay()` 配合保证字幕层始终压在弹幕层上方。
- **Impeller Metal 门户转场、极光背景、丝带加载与宽屏引导**：接入基于 `player_enter.frag` 的影院门户转场（严格在逻辑像素空间运行，独立海报优先同步复用或限幅 `<= 720px` 解码并 `50ms` 超时保护，任何结束/取消/异常路径即时 `dispose()` `ui.Image` 与 `FragmentShader` 纹理，支持减少动态效果、`> 16ms` 超预算及加载失败三重自动降级）；接入 `aurora.frag` 极光背景（路由隐藏、窗口失焦、后台或开启减少动态效果立即停止 `Ticker`）与 `1.6s` `BrandLogoLoader` 金属丝带 `M` 加载器；新增宽屏双栏 5 幕独立新手引导（含 `14` 张程序化「示例」海报）及桌面快捷键首播提示。

## 包信息与构建记录

- **macOS 桌面应用包（Apple Silicon / Intel）**：`MarcoMovie-0.5.20-macos-desktop.zip`（`120066341` B，更新兼容别名 `MarcoMovie-0.5.20-macos.zip`），SHA-256：`fad92c6c1f554ff238ecfbcda4ada170bfb86a30a19fdefe114aec28eb8ef10e`。
- **对应源码包**：`MarcoMovie-macos-v0.5.20-source.zip`（`10677076` B），SHA-256：`b5bfc9f59d43eff22aa328a6a8eff747d281317ec7dfebfe04b156427f9579db`。
- **构建提交与 CI 记录**：`78017bfb79cf4430681436b53cfcf67b77f44e5b`。[macOS 原生构建与全量校验（44857333769）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44857333769) / [公开守卫记录（44857333149）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44857333149)。

## 验证范围与已知限制

- **已完成自动化构建与校验**：在 `78017bfb79cf4430681436b53cfcf67b77f44e5b` 上于 macOS 云端 Runner 完成 `flutter test` 全套测试（`1179` 项通过、`9` 项非桌面平台专属跳过）、`Mpv.framework/Mpv` 打包媒体回放校验（`3` 项通过）、`flutter build macos --release` 原生编译打包及 `1513` 个追踪文件公开内容守卫校验。
- **待完成真机验证**：尚未在物理 Mac 上完成与 `macos-v0.5.19` 的 A/B 对照实机验收（含 Retina 高分屏门户转场纹理内存释放与 Anime4K 热切换实测）。应用压缩包未进行 Apple 公证（Notarization），首次打开需按 macOS 提示右键选择“打开”。
