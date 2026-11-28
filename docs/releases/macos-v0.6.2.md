# Marco Movie macOS 0.6.2

发布日期：2026-11-28。应用版本 `0.6.2`（构建号 `74`）；Apple Silicon（`arm64`）与 Intel（`x86_64`）通用桌面应用。

## 本次更新

- **macOS 专项流畅度、4K 臻彩与桌面体验升级**：合入 `CVDisplayLink` 屏幕刷新率自适应视频同步机制，改善 4K / 臻彩分类识别与高画质网盘选集体验，完善 Finder 本地 `.json`/`.zip` 导入、起播阶段与网速遥测、后台无感订阅刷新、有界下一集预缓冲及多显示器窗口尺寸记忆。
- **桌面端 WebDAV 局域网扫码直绑**：macOS「云同步」新增 `marco-bind-box-v1` 加密二维码生成，移动端扫码即可安全推送或同步 WebDAV 配置与凭据。
- **Emby / Jellyfin HTTP 8096 与 4K DirectPlay 修复**：连接弹窗默认采用 `HTTP + 8096` 并支持 HTTPS 切换与裸域名输入，登录兼容 `/emby` 与根路径 `/` 回退、标准 `X-Emby-Authorization` 头与 TLS 握手无凭据引导，默认启用 DirectPlay。

## 包信息与构建记录

- **macOS 桌面应用包**：`MarcoMovie-0.6.2-macos-desktop.zip`（`137098074` B，兼容别名 `MarcoMovie-0.6.2-macos.zip`），SHA-256：`bee810d5b7a02fdca92c84a75022e0a2235fcc11e30974c6ec99fe74f28c19ff`。
- **对应源码包**：`MarcoMovie-macos-v0.6.2-source.zip`（`23463045` B），SHA-256：`fe035c386a0618c30026239fd9ee5f8c41842c043a46ee739cb3313071b51c5a`。
- **构建提交与 CI 记录**：`4475ca1b22acefa3a282bbe0ce25186601f0d995`。[Build macOS Desktop (Job 140838786693 · Run 46098959246)](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46098959246/job/140838786693) / [Public Guardrails (Job 140836821198)](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46098959246/job/140836821198)。
- **已知限制**：应用采用 ad-hoc 签名未做 Apple 公证，首次运行如遇拦截需右键选择“打开”；物理 Apple Silicon / Intel Mac 手工 GUI 实测仍待补充。
