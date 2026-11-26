# Marco Movie Windows 0.7.3

发布日期：2026-11-26。应用版本 `0.7.3`（构建号 `80`）。本次 Windows x64 桌面端更新上线每次更新后启动的官方渠道/防骗与捐赠支持弹窗、「继续观看」历史竖屏海报墙，以及采用全平台统一 Ed25519 离线签名口令解锁的 Windows 专属「AI 实验室」（一期四项能力与 OpenMinis 风格合规多服务商接入层）。

## 更新内容

- **每次更新后启动弹窗与官网捐赠支持入口（`WindowsPostUpdateNoticeDialog` / `WindowsPostUpdateNoticePrefs` / `OfficialChannelInfo`）**：
  - 每次覆盖升级到新版本（按 `version+build` 本机记录）后首次启动温和展示一次感谢说明，强调项目永久免费开源无广告、提醒谨防第三方收费包/「激活码」诈骗并认准唯一官方更新渠道 `marcotv.wlj9919.top`；
  - 提供直达官网捐赠区（`https://marcotv.wlj9919.top/movie/#donate`）的「前往官网捐赠支持」按钮与零压迫、无倒计时的「进入应用」按钮，具备打开失败自动复制及手动选取三重兜底，隐私空间与数据损坏恢复期静默，新安装自动与首次官方声明去重不连弹；
  - 「设置 → 更多设置 → 联系反馈与官方交流」同步新增「捐赠支持作者」入口，点击「联系与反馈」或「官方渠道安全声明」亦可随时重看完整提示。
- **「我的 → 继续观看」升级为 2:3 竖屏影院海报墙（`windows_shell.dart`）**：
  - 改为响应式 3–6 列 `2:3` 竖屏海报墙，延续 `GridView.builder` 虚拟滚动与滚动位置记忆，底部叠加渐变蒙层、剧集胶囊、精细播放进度条与播放角标，卡片下方以 `mm:ss` / `h:mm:ss` 格式展示已观看进度；
  - 支持右上角快捷删除与右键菜单（「继续播放」/「删除记录」），删除单条历史后弹出 3 秒可撤销横幅一键恢复。
- **Windows 设置新增「AI 实验室」（Ed25519 离线口令解锁 + OpenMinis 风格多服务商合规接入 + 一期四项能力）**：
  - **Ed25519 离线签名口令门禁（`AiLabPasscodeVerifier` / `AiLabPasscodeStore` / `scripts/sign_manifest.py`）**：默认锁定，输入全平台统一 `MMAILAB1.<payload>.<sig>` 离线签名口令后纯本机 RFC 8032 Ed25519 验签解锁（不联网校验账号、每次冷启动重新验签防篡改、支持随时重新锁定）；未解锁前所有搜索/挑片/详情净化入口均自动隐藏不打扰普通用户；
  - **合规多服务商与订阅接入层（`AiProviderProfile` / `OpenRouterPkceManager` / `GitHubCopilotDeviceFlow` / `AiLocalDiscovery` / `AiModelCatalogFetcher`）**：支持 OpenRouter 官方 PKCE 浏览器回环一键授权（`127.0.0.1` 临时端口）、GitHub Copilot 官方 RFC 8628 设备码登录与短期会话令牌自动续期、本机 Ollama（`11434`）与 LM Studio（`1234`）离线零配置免 Key 自动发现、多服务商实例一键热切（DeepSeek / 通义千问 / Kimi / 硅基流动 / 智谱 / OpenAI / Anthropic / Gemini / 自定义兼容接口）、一键拉取可用模型列表与主/轻量双档模型路由；所有密钥仅存 Windows 本机加密凭据库且自动日志脱敏，隐私空间全程硬性阻断外部 AI 请求，严格拦截模型输出中的外部 URL 链接；
  - **一期四项实验能力**：设置页 AI 实验室控制中心、搜索页「AI 找片」（自然语言推荐片名后在自有片源搜索）、「我的」页「AI 为你挑片」（仅用户主动触发且只发送去重后的公开片名），以及详情页「AI 净化选集」（非阻塞批量清洗杂乱网盘/压制组文件名，不改写原始播放地址）。

## 包信息与构建记录

- **Windows 64 位安装版（Inno Setup）**：`MarcoMovie-0.7.3-windows-x64-setup.exe`（`72280046` B，兼容别名 `MarcoMovie-0.7.3-windows-setup.exe`），SHA-256：`052e92ecbf66c9cc04d491ca2e25f8889b0ad2444ad936661bd8299468da9154`。
- **Windows 64 位绿色便携版**：`MarcoMovie-0.7.3-windows-x64-portable.zip`（`103592687` B，兼容别名 `MarcoMovie-0.7.3-windows-x64.zip`），SHA-256：`f6df486795c853c3c61113b25aad715d6c4f249f10d3e608af21ab7c34498f31`。
- **对应源码包**：`MarcoMovie-windows-v0.7.3-source.zip`（`22022701` B），SHA-256：`ac2144f2b667fabb3498ba336a46dbccd30aed067b1660b382126d4ccb20d014`。
- **构建提交与 CI 记录**：主分支发布提交 `a11deb29e2882dec4d11a0188007acb2e56fbdd0`。[Windows x64 原生构建与全量校验（Job 140020244743 · Run 45851212660）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45851212660/job/140020244743) / [公开守卫与跨端离线校验（Job 140017763788）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45851212660/job/140017763788)。

## 验证范围与已知限制

- **云端与本地自动化及实机成品验证**：
  - GitHub Actions `Build Multiplatform`（Run `45851212660`，`windows-latest` / Flutter `3.38.9` / Inno Setup 6）全绿通过：`scripts/check_public_content.py`（`2772` 追踪文件）、`scripts/sync_readme_versions.py --check`、`scripts/sign_manifest.py self-test`、全量 `1675` 项 Flutter 单元测试（含新增 `windows_post_update_notice_test.dart` 与 `windows_073_history_and_ai_lab_test.dart`，`18` 项非 Windows 专属跳过，`0` 失败）、`30` 项 `flutter/test_*.py` 打包与 runner 校验及打包 `libmpv-2.dll` 原生播放校验；
  - 已完成 Python 签发工具与 Dart 嵌入式公钥对真实 `MMAILAB1` 永久/30天离线签名口令的跨语言离线验签校验；
  - 对云端下载的正式 `0.7.3`（`80`）便携包成品在本机 Windows x64 实测：校验全部 SHA-256 摘要与别名字节一致、`marco_movie.exe` 文件版本 `0.7.3+80`、核心 DLL（`flutter_windows.dll` / `libmpv-2.dll` / `fvp.dll` / `mdk.dll` / `ffmpeg-9.dll` / `libass.dll` / `quickjs_c_bridge_plugin.dll`）齐全，14 轮真实进程退出冒烟（10 轮空闲 `WM_CLOSE` + 原生 Win32 调试器监测零 `0xC0000005` + `Alt+F4` + 10 连关 + 托盘退出）全部返回退出码 `0`、零残留进程、零新增 Application/WER 崩溃事件。
- **已知限制**：安装包与便携程序未购买商业代码签名证书，Windows SmartScreen 首次运行如提示未知发布者需手动确认运行；OpenRouter PKCE / GitHub Copilot 在线真实账号授权与本机 Ollama/LM Studio 实机推理目前通过离线回环/模拟 HTTP 测试覆盖，尚未在所有第三方 AI 网关与商业订阅账号上做穷尽线上实测；AI 实验室需先通过作者离线签发的 Ed25519 口令解锁并由用户自行配置合法模型服务。
