# Marco Movie Windows 0.7.2

发布日期：2026-11-26。应用版本 `0.7.2`（构建号 `79`）。本次 Windows x64 专项稳定性与桌面体验升级重点根治正常关闭时的原生访问冲突崩溃（`0xc0000005`）、MPV 开启人声增强后无声、MDK 换集延迟释放纹理跨过窗口销毁边界等核心问题，并同步交付首次启动官方渠道声明、应用内双形态自动更新、窗口位置记忆、跨线路同集保进度与离线下载非阻塞冷启动等多项桌面端优化。

## 更新内容

- **根治 Windows 正常关闭时进程崩溃（`0xc0000005`）与统一退出生命周期（`AdaptiveShell` / `WindowsTrayService` / `prepare_platform.py`）**：
  - 统一直接退出与托盘菜单「退出」的单一退出入口（单次幂等执行、退出前保存观看进度），在 Win32 窗口销毁前先停止 Flutter 消息转发并阻断 `WM_DESTROY` / `WM_FONTCHANGE` 及销毁子窗口触发的同步重入；
  - 将原生 `flutter_controller_` 与 `window` 的析构严格收敛至 UI 线程并位于 `CoUninitialize()` 之前，同时将 `wakelock_channel_`、`tray_channel_`、`window_bounds_channel_` 及 `MarcoWebview2Plugin` 通道解绑与释放纳入确定性生命周期；修复 Windows 预退出钩子与销毁标记误写入 macOS / Linux 关闭路径的问题；
  - 完整保留「直接退出」与「关闭到托盘（隐藏 → 托盘恢复 → 托盘退出）」两种关闭语义，并经独立复检实测系统通知区域托盘图标完整交互链路。
- **修复 MPV 开启人声增强后无声及快速换集音轨/滤镜恢复竞态（`WindowsVideoQualityController` / `DesktopPlayerHud`）**：
  - 将 3 档人声增强（轻度 / 标准 / 影院人声）从当前 `libmpv-2.dll` FFmpeg 构建未启用的 `dynaudnorm` 切换为经内置 `libmpv-2.dll` 实测原生支持的 `lavfi=[equalizer=...]` 参数均衡链（立体声与 5.1 声道冷启动、实时热切、换集与重启均持续稳定输出音频），旧版 `cinemaVocal` 配置升级冷启动即直接有声；
  - 完善滤镜初始化失败时的运行时自动原声恢复机制：按播放器实例、媒体会话与恢复任务身份精确隔离，解决相邻换集两次失败漏掉新一集恢复及迟到旧日志误写正常新集配置的问题；将音轨选择事件订阅与当前媒体会话绑定，快速换集时丢弃旧集迟到选轨事件，同时完整保留本集用户手选音轨（如评论轨）。
- **根治 MDK 换集延迟释放纹理跨过窗口销毁边界的竞态（`MdkPlatformPlayer` / `PlayerScreen`）**：
  - 播放器销毁前等待在途纹理更新收敛并在有界退出超时后严格阻断后续回调访问已释放对象；在同一次 `updateTexture` 内部 `ReleaseRT` 与 `CreateRT` 之间引入取消与原生销毁边界门禁，确保已进入原生窗口销毁阶段时新增 `CreateRT` 次数严格为 `0`，同时不影响正常换集创建新纹理；
  - 完善 MDK 异常事件流监听与启动期自动回退 MPV 续播（覆盖零起播、断点续播、重复错误去重及换集后旧错误隔离，且不篡改用户持久化的默认 MDK 引擎偏好）。
- **桌面端交互、更新与启动体验升级**：
  - 新增首次启动官方渠道与防伪提示、设置页作者各社媒账号（`PILIPALA来信`）与官网交流群入口，以及内置 `WindowsUpdateSheet` 应用内更新（自动按运行路径区分 Inno Setup 安装版与绿色便携版，支持镜像/GitHub 双源、SHA-256 校验、断点重试与禁止旧版本降级提示）；
  - 新增多屏安全的 Windows 窗口位置与尺寸记忆（`WindowsWindowBoundsController` + 原生注册表首帧前定位）、跨线路同集识别与保留进度切换、直播内嵌小窗展开继承当前频道与备用路线、多源聚合与播中换源（`WorkAggregation`），以及 `DownloadService` 离线索引异步非阻塞冷启动与「我的」页虚拟滚动优化。

## 包信息与构建记录

- **Windows 64 位安装版（Inno Setup）**：`MarcoMovie-0.7.2-windows-x64-setup.exe`（`72209363` B，兼容别名 `MarcoMovie-0.7.2-windows-setup.exe`），SHA-256：`d5e0fdd42556e7594542cc1b00351e486c17a66e76fc495e687ace4e00a76e98`。
- **Windows 64 位绿色便携版**：`MarcoMovie-0.7.2-windows-x64-portable.zip`（`103492098` B，兼容别名 `MarcoMovie-0.7.2-windows-x64.zip`），SHA-256：`0f8284f262cae12ee2e5d66ee22a809e33d61c65591d04b70c36e19e5a996d2e`。
- **对应源码包**：`MarcoMovie-windows-v0.7.2-source.zip`（`21901506` B），SHA-256：`5634501ea9af0ba5a2d867850dad51937d3edabf50603e92676af01294e6d88b`。
- **构建提交与 CI 记录**：主分支发布提交 `e196d53b08a4df0e59028a059a168943df976479`（与云端验证构建提交 `7716fe42fe6201bcd1c57fb2481e73096885c67b` 的 `flutter/`、`shared/`、`scripts/` 与 `README.md` 字节级一致）。[Windows x64 原生构建与全量校验（Job 139966489463 · Run 45835704452）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45835704452/job/139966489463) / [公开守卫与跨端离线校验（Job 139963875072）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45835704452/job/139963875072)。

## 验证范围与已知限制

- **云端与本地自动化及实机成品验证**：
  - GitHub Actions `Build Multiplatform`（Run `45835704452`，`windows-latest` / Flutter `3.38.9` / Inno Setup 6）全绿通过：`scripts/check_public_content.py`（`2764` 追踪文件）、`scripts/sync_readme_versions.py --check`、`test_windows_installer.py`、`test_prepare_windows_runner.py`（含 `0.7.1` 旧 runner 增量升级幂等校验）、全量 `1662` 项 Flutter 单元测试（`18` 项非 Windows 专属跳过，`0` 失败）及 `13` 项打包 `libmpv-2.dll` 原生播放校验；
  - 对云端下载的正式 `0.7.2`（`79`）便携包成品在本机 Windows x64 实测：全部 11 项核心组件齐全、`marco_movie.exe` 文件版本为 `0.7.2+79`、14 轮真实进程退出测试（10 轮空闲 `WM_CLOSE` + 原生 Win32 调试器 `0xC0000005` 监测 + `Alt+F4` + 快速 10 连关 + 托盘退出）全部返回退出码 `0`、零访问冲突、零残留进程且 Windows Application / WER 无新增崩溃事件；使用云端正式 `libmpv-2.dll` 与 `fvp.dll` 复测 `native_windows_audio_loudness_test.dart`（滤镜故障恢复 `65649` 帧 RMS `2037.3`）及 `actual_mdk_shell_exit_test.dart`（销毁后新增 `CreateRT = 0`）均通过，并承接前序独立复检通过的 16 进程成品退出、真实系统托盘图标隐藏/恢复/退出及双音轨 PCM 频谱验收。
- **已知限制**：安装包与便携程序未购买商业代码签名证书，Windows SmartScreen 首次运行如提示未知发布者需手动确认运行；尚未在所有 Windows 版本、全代际显卡驱动与第三方片源上完成穷尽验证；动态网页嗅探与 WebView2 异步 JS 依赖系统已安装 Microsoft Edge WebView2 Runtime。
