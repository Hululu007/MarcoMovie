# Marco Movie Android 手机 / 平板 0.7.4

发布日期：2026-11-28。应用版本 `0.7.4`（版本代码 `104`）；最低 Android 6 / API 23（`arm64-v8a` + 16 KB 页面对齐 `armeabi-v7a` / `arm64-v8a` 双架构原生库）。

## 本次更新

- **手机端一键扫码直绑电视 / 桌面 / Apple TV WebDAV**：
  - 应用内相机扫码（支持相册识别与剪贴板兜底）支持 `marco-bind-box-v1`（HMAC-SHA256 CTR + Encrypt-then-MAC）端到端加密通道与 `/bind` 端点；
  - 可将手机端已配置的 WebDAV 服务器、账号、加密密码与同步选项安全推送至对端并立即合并同步，或在手机尚未配置时从对端拉取配置完成自动绑定。
- **Emby / Jellyfin HTTP 8096、路径回退与 4K DirectPlay 修复**：
  - 连接弹窗默认协议调整为 `HTTP（8096）` 并支持 HTTPS 切换、选填端口/路径/名称与裸域名直填（自动剥离 `/web/` 浏览器路径）；
  - 登录支持 `/emby` 与根路径 `/` 自动回退、`bareRoot` 会话持久化、同源及 HTTP → HTTPS 安全重定向、标准 `X-Emby-Authorization` 头与 TLS 握手失败无凭据明确探测指引；
  - `PlaybackInfo` 默认启用并放行 4K HEVC / AV1 与多音轨 DirectPlay。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（Mobile edition，`minSdk 23` / `targetSdk 28`；同字节兼容别名 `MarcoMovie-0.7.4-mobile.apk`）。
- **Mobile APK SHA-256**：`MarcoMovie-0.7.4-android-mobile.apk`（`100995540` B）— `47201cfc2243927b33d6a7656f24c4879122957dc49388b9bd661467e15d2100`。
- **APK v4 签名文件**：`MarcoMovie-0.7.4-android-mobile.apk.idsig`（`804262` B）— `392764ab14127a00b13254a8064080d29d0796dff77cd11a47dff46775af49b7`。
- **对应源码包 SHA-256**：`MarcoMovie-android-mobile-v0.7.4-source.zip`（`23479060` B）— `c38e38a0b994bc3a1ab5b249de24b9b4029d4150cdb83c9d351cd30c8cd195ff`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
- **构建提交与校验**：`a9d5c8cb2bc5c083dc82639c3cbf7026c01882db`（`git_dirty: false`）。已通过 [Build & Verify Android Mobile APK (Job 140830652708 · Run 46096257329)](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46096257329/job/140830652708)、`run_api23_callback_checks.py`（`1008` 应用类）、`run_guard_checks.py`、`run_secure_storage_checks.py` 与手机端全套回归。物理设备升级实测待后续补齐。
