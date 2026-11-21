# Marco Movie Windows 0.5.25

> **发布说明草案**：发布日期待定；应用版本 `0.5.25`（构建号 `75`）。待 Windows x64 Release 构建（Inno Setup 安装包与绿色便携包）及真机 A/B 对照验收后补齐构建提交与校验摘要。

## 更新内容

- **桌面专属 Anime4K `v4.0.1` 实时画质增强（热切换 + `bilinear` 守卫）**：在尊重 MIT 许可的前提下内置 `bloc97/Anime4K v4.0.1` 6 枚官方 GLSL 着色器（含逐文件 SHA-256 校验与 `THIRD_PARTY_NOTICES.md` 声明），通过 `Anime4kController` 在播放器内支持 **「关闭 / 性能 / 均衡 / 画质」** 4 档热切换而不中断当前播放（`> 1080p` 片源弹窗展示显卡负载提示）；未开启时严格保持 Windows ANGLE/D3D11 既有低开销 `bilinear` 采样，仅在启用非关闭预设后临时切至 `spline36` 并注入着色器链，切回「关闭」或退出播放立即恢复默认 `bilinear`。
- **`DesktopPlayerHud` 键鼠播放交互、起播规格与细进度条**：完整保留 Windows `winFastGlass` 无模糊高速面板、静态 `WindowsBackdrop` 与 `185ms` 快速转场架构；`DesktopPlayerHud` 支持鼠标静止 `2.5s` 自动隐去、滚轮调音量、短按/长按 `←` / `→` 复用 `TvRemoteSeekController` 加速预览（带顶部预览胶囊、松手提交、`Esc` 抢占取消）、`S` 循环切换倍速、`[` / `]` 步进调速、`D` 一键开关弹幕、`Space` / `M` / `N` / `P` / `F` / `F11` / `Ctrl+W` 快捷键；嵌入小窗或文本框聚焦时严禁抢占焦点；新增 `StartSpecOverlay` 起播媒体规格徽章条、底部常驻细进度条、`3` 秒跳过倒计时胶囊与定时关闭面板（含最后 `30` 秒延长提示）。
- **清洁室 30 秒分片弹幕引擎与字幕置顶顺序**：接入 `DanmuSegmentCache` / `DandanplayProvider` / `DanmuLayer`（默认服务地址为空 `""`，支持最多 `8` 个兼容服务源与本机独立设置，不改动同步配置）；实现 `mmdanmu://v1` 来源绑定、有符号时钟、`30s` 分片按需拉取与预取、`HTTP 410` 单飞刷新上限、`180ms` Seek 防抖及静态 ReDoS 拦截器（`DanmuBlockFilter`）；`DanmuLayer` 采用有界 `TextPainter` 对象池实现高分屏低耗时滚动渲染，并与 `VideoKernel.buildSubtitleOverlay()` 配合保证字幕始终置于弹幕层之上。
- **详情规格徽章、快速安全转场、丝带加载与宽屏 5 幕新手引导**：`windows_detail.dart` 线路胶囊与详情页接入跨端统一纯文字媒体规格徽章（`MediaBadges`）；进入播放页时 Windows 走无黑洞、无额外重绘的 `185ms` 快速缩放过渡（若需截图且耗时 `> 16ms` 自动回退并立即释放 `ui.Image`）；缓冲指示器升级为 `1.6s` `BrandLogoLoader` 金属丝带 `M` 动画（减少动态效果时切为呼吸透明度）；新增宽屏双栏 5 幕独立新手引导（含 `14` 张程序化「示例」海报与快捷键演示，设置页「关于与更新」内提供「重新查看新手引导」入口）及桌面快捷键首播提示胶囊。

## 包信息与构建记录

- **Windows 64 位安装版（待正式构建）**：`MarcoMovie-0.5.25-windows-x64-setup.exe`（兼容别名 `MarcoMovie-0.5.25-windows-setup.exe`）。
- **Windows 64 位绿色便携版（待正式构建）**：`MarcoMovie-0.5.25-windows-x64-portable.zip`（兼容别名 `MarcoMovie-0.5.25-windows-x64.zip`）。
- **SHA-256 / 源码包 / 构建记录**：待 Windows x64 Release 构建完成后填入。

## 验证范围与已知限制

- **已完成自动化验证（基于 `feat/ux-integration-20261120 @ 82f38cd2`）**：通过 `scripts/check_public_content.py`（`1507` 文件）及 `18` 套跨端 UX / 一致性 / 鸿蒙隔离 `flutter test` 测试集共 `193` 项测试全绿（含 `media_badges_test`、`desktop_player_hud_test`、`wave2_anime4k_test`、`wave2_motion_wiring_test`、`detail_player_transition_integration_test`、`danmu_*_test`、`onboarding_test`、`wave2_wiring_and_gate1_test`、`conformance_test` 等，已实测覆盖 Windows `bilinear <-> spline36` 切换/恢复、`185ms` 快速路由、焦点不抢占与 `winFastGlass` 守卫）。
- **待完成验证**：尚未在 Windows 桌面开启开发者模式执行新版本号的 `flutter build windows --release` 与 Inno Setup 6 安装包打包、`libmpv-2.dll` 打包回放检验，以及 Windows 物理机 A/B 对照验收（含 Anime4K `v4.0.1` 着色器实际画面与 `4K` 弹幕帧率验证）。
