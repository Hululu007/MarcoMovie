# Marco Movie iOS / iPadOS 0.7.12 (build 105)

> 仅包含 `iOS / iPadOS` 独立版本变更；Android 手机、Android 电视、Android Lite、Windows、macOS、Apple TV 与 HarmonyOS NEXT 保持各自独立发布节奏。

## 本版更新内容

1. **结构化 Emby 媒体库连接、编辑与协议 / 4K STRM 兼容升级**
   - 重构 iOS `连接 Emby 媒体库` 与 `订阅管理 → 编辑 Emby` 表单：支持填写自定义**名称**、**是否允许云端同步**开关（关闭后凭据与订阅严格保留在本机）、**HTTPS** 开关（默认 `HTTP / 8096`，开启 `HTTPS` 自动切换 `443` 并按需展开「忽略证书校验」）、**服务器地址**（支持裸域名/IP 及粘贴完整 URL 自动识别协议/端口/路径）、**路径（选填）**、**端口号**、**用户名**与支持明文/密文切换的**密码**输入框（保留未裁剪密码与空密码登录，并支持「仅修改名称与云端同步状态时免密续验」）。
   - 强化 `EmbyLibrary` 协议兼容：支持 `/emby` 遇到 `HTTP 404 / 405` 时自动回退裸根路径 `/` 并跨重启持久化；处理同源及 HTTP→HTTPS 重定向；补充标准 `X-Emby-Authorization` 与客户端 `User-Agent`；对 HTTPS 连 HTTP 端口的 TLS 握手失败提供中文探测指引；`PlaybackInfo` 放行 `EnableDirectPlay`（HEVC / H.265 / AV1 / 多音轨）及跨源 `.strm` HTTP 直链安全隔离播放；接入多端 WebDAV / 局域网 `emby_accounts` 双向同步（本地备份仍零凭据泄漏）。
2. **局域网扫码一键绑定 WebDAV（`marco-bind-box-v1`）**
   - 合入跨端 LAN 扫码直绑 WebDAV 重构与原生 iOS `AVCaptureSession` 二维码扫描视图（含相册/剪贴板兜底及 `NSCameraUsageDescription`），支持扫码或粘贴配对链接端到端加密互换 WebDAV 配置并立即双向合并历史、收藏与订阅。
3. **AI 观影实验室口令本机钥匙串持久保存**
   - 解锁后的 `MMAILAB1` 口令持久保存至本机 Keychain，关闭并重启应用后自动恢复解锁状态，无需重复输入。
4. **Codex 模型列表净化与 HTTP 400 容错**
   - 从模型目录中过滤无法在 Codex 订阅通道使用的内置/后缀模型，仅展示已验证可用模型，并在遭遇模型下线导致 `HTTP 400` 时自动自愈回退可用主模型。
5. **AI 联网搜索并匹配在线弹幕**
   - 新增 `AiDanmuMatcher`，利用 AI 提取剧名、别名、季集与年份后在线检索匹配 B 站 / 弹弹play 弹幕源并注入 `DanmuSegmentCache` 分段缓存，支持随进度拖动与偏移即时渲染。

## 云端双包构建与自动化验证

- GitHub Actions `Build Multiplatform`（[`46095499184`](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46095499184) · 提交 [`89098494`](https://github.com/Pilipala9919/MarcoMovie/commit/890984945a754fc0a5be5b0c7475cb2c8b149eb2)，发布仓库主线合入 Android 端非 Flutter 补丁至 [`66f17867`](https://github.com/Pilipala9919/MarcoMovie/commit/66f178674c52e7baf20ad4881a3d508ca8ab8ed5)）：
  - 前置公开守卫与一致性检查（[`140825777452`](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46095499184/job/140825777452)）：`check_public_content.py`（`2888` 个追踪文件零告警）、`sync_readme_versions.py --check`、跨端脚本/Python 打包测试及 `79` 项三端一致性测试全部通过。
  - 主包 `Build iOS & iPadOS`（[`140826862151`](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46095499184/job/140826862151)，`macos-26` / `Xcode 26.6` / `iphoneos26.5`，`MinimumOSVersion = 15.0`）：全量 `1796` 项 `flutter test` 通过（`18` 项桌面专项跳过）。
  - 兼容包 `Build iOS 14.0+ Compat`（[`140826862137`](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46095499184/job/140826862137)，Xcode 16，`MinimumOSVersion = 14.0`）：构建与校验通过。
- 发布资产已校验字节一致（主包与兼容别名）、`Info.plist`（`0.7.12` / `105`、`MinimumOSVersion`、`NSCameraUsageDescription`）及全部 SHA-256 摘要。真实多机型物理 iPhone / iPad 实机安装升级、外部真实 Emby/AI 网关与实机扫码仍待真机验收。

## 资产校验清单（SHA-256）

| 文件 | 大小 (Bytes) | SHA-256 |
|---|---:|---|
| `MarcoMovie-0.7.12-ios-iphone-ipad-unsigned.ipa` | 69843367 | `0f6a79c3b7881aa5eb06ad27cfe6dff91031bffe5e1a9fbca852e13166c2bc13` |
| `MarcoMovie-0.7.12-ios-iphone-ipad-unsigned.ipa.sha256` | — | `MarcoMovie-0.7.12-ios-iphone-ipad-unsigned.ipa` 校验摘要 |
| `MarcoMovie-0.7.12-ios-unsigned.ipa` | 69843367 | `0f6a79c3b7881aa5eb06ad27cfe6dff91031bffe5e1a9fbca852e13166c2bc13` |
| `MarcoMovie-0.7.12-ios-unsigned.ipa.sha256` | — | `MarcoMovie-0.7.12-ios-unsigned.ipa` 校验摘要 |
| `MarcoMovie-0.7.12-ios14-unsigned.ipa` | 69842541 | `c48d74299d3630c8ed88acd0613acc57bb11f44534895c8c234846f94dfd46c5` |
| `MarcoMovie-0.7.12-ios14-unsigned.ipa.sha256` | — | `MarcoMovie-0.7.12-ios14-unsigned.ipa` 校验摘要 |
| `MarcoMovie-ios-v0.7.12-source.zip` | 23300081 | `384e9537a9194c74771b5b4517e9541a07f0b73bbae916004dc28cc8136d2a0c` |
| `MarcoMovie-ios-v0.7.12-source.zip.sha256` | — | `MarcoMovie-ios-v0.7.12-source.zip` 校验摘要 |
