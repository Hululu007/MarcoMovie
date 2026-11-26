# Marco Movie Windows 0.7.4

发布日期：2026-11-27。应用版本 `0.7.4`（构建号 `81`）。本次 Windows x64 更新将 AI 实验室 Ed25519 离线签名口令验证体系与 Android 移动端、iOS 完全对齐为统一的跨端 `MMAILAB1` 协议，实现同一把 Ed25519 私钥签发的口令在 Windows / iOS / Android 移动端三端完全互通，同时完整承接 `0.7.3` 的更新后捐赠/防骗弹窗、竖屏「继续观看」海报墙与 AI 实验室一期全部能力。

## 更新内容

- **AI 实验室 Ed25519 离线口令升级为全端统一跨端协议（`AiLabPasscodeVerifier` / `AiLabPasscodeStore` / `WindowsAiLabPanel` / `scripts/sign_manifest.py`）**：
  - 保持统一 RFC 8032 Ed25519 公钥（`1dbeaed851b873d7c327d30d718fca0ac1509ef5ac4061b9bd1aa90c841c6929`）与签名域（`marco-ai-lab-v1:`）不变，向后完全兼容旧版口令与已解锁 Windows 用户的本地解锁状态；
  - 补齐统一跨端载荷字段解析：`shared`（频道通用 / 专属测试标识）、`exp_oauth`（实验性 OAuth 权限标识）、`min_vc`（可选最低构建号校验 `versionTooOld`）与可选随机 `n` nonce，并在 Windows AI 实验室已解锁状态栏同步展示「频道通用」与「实验 OAuth 权限」状态标签；
  - 升级 `matchesPlatform(...)`：支持 `all`、`*`、空字符串，以及逗号/分号/斜杠/空白分隔的多平台组合列表（如 `windows,ios`、`android,windows`、`iphone;pc`）与跨端别名归一化（`android-mobile`/`mobile` → `android`、`win`/`pc` → `windows`、`iphone`/`ipad` → `ios`、`mac`/`osx` → `macos`）；
  - `AiLabPasscodeStore` 与验签入口取消硬编码 `'windows'`，改为按实际运行平台自动识别（`Platform.isWindows` / `Platform.isIOS` / `Platform.isMacOS` / `Platform.isAndroid`）；
  - 同步升级 `scripts/sign_manifest.py` 的 `issue-ai-lab-token` / `verify-ai-lab-token`（支持 `--plat`、`--shared`、`--exp-oauth`、`--min-vc` 与自动 6 位随机 nonce），与 Android 端发码工具及手机离线发码器产出的口令 100% 互通。

## 包信息与构建记录

- **Windows 64 位安装版（Inno Setup）**：`MarcoMovie-0.7.4-windows-x64-setup.exe`（`72279794` B，兼容别名 `MarcoMovie-0.7.4-windows-setup.exe`），SHA-256：`f47831bf3c7c2a980a8693b6b153845a234b8f53610b27dd724a4cc4c15b3a95`。
- **Windows 64 位绿色便携版**：`MarcoMovie-0.7.4-windows-x64-portable.zip`（`103593109` B，兼容别名 `MarcoMovie-0.7.4-windows-x64.zip`），SHA-256：`2bc910b3522fa134eaed5ed100b45fa93f09c53626aa42069c0509207a2bd89b`。
- **对应源码包**：`MarcoMovie-windows-v0.7.4-source.zip`（`22032602` B），SHA-256：`b484963ce8c1ee67c4f0d28289f7aafe248ba7ced2c8310d2fbbf62171f02150`。
- **构建提交与 CI 记录**：主分支发布提交 `096ffab52200e580035b9b6e8fc184136240fbb0`（含跨端协议对齐提交 `d0335be6190c79e4a1dbeb72bcf10f8cdf4f6d4b`）。[Windows x64 原生构建与全量校验（Job 140063891299 · Run 45863936988）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45863936988/job/140063891299) / [公开守卫与跨端离线校验（Job 140061808277）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45863936988/job/140061808277)。

## 验证范围与已知限制

- **云端与本地自动化及实机成品验证**：
  - GitHub Actions `Build Multiplatform`（Run `45863936988`，`windows-latest` / Flutter `3.38.9` / Inno Setup 6）全绿通过：`scripts/check_public_content.py`（`2773` 追踪文件）、`scripts/sync_readme_versions.py --check`、`scripts/sign_manifest.py self-test`、全量 `1676` 项 Flutter 单元测试（含跨端实签 `MMAILAB1` 通用口令、`ios,android` 拒识、`android,windows` 放行、`exp_oauth`/`min_vc` 解析与动态平台识别单测，`18` 项非 Windows 专属跳过，`0` 失败）及打包 `libmpv-2.dll` 原生播放校验；
  - 对云端下载的正式 `0.7.4`（`81`）便携包成品在本机 Windows x64 实测：校验全部 SHA-256 摘要与别名字节一致、`marco_movie.exe` 文件版本 `0.7.4+81`、全部核心 DLL（`flutter_windows.dll` / `libmpv-2.dll` / `fvp.dll` / `mdk.dll` / `ffmpeg-9.dll` / `libass.dll` / `quickjs_c_bridge_plugin.dll`）齐全，14 轮真实进程退出冒烟（10 轮空闲 `WM_CLOSE` + 原生 Win32 调试器监测零 `0xC0000005` + `Alt+F4` + 10 连关 + 托盘退出）全部返回退出码 `0`、零残留进程、零新增 Application/WER 崩溃事件。
- **已知限制**：安装包与便携程序未购买商业代码签名证书，Windows SmartScreen 首次运行如提示未知发布者需手动确认运行；AI 实验室需先通过离线 Ed25519 签名口令解锁并由用户自行配置合法模型服务。
