# Marco Movie Android Lite 0.5.11

发布日期：2026-11-28。应用版本 `0.5.11`（版本代码 `61`）；最低 Android 4.0 / API 14 单 DEX 超轻量独立版本（包名 `com.pilipala.marcomovie.lite`）。

## 本次更新

- **Emby / Jellyfin HTTP 8096 与直连兼容全面修复**：
  - 连接弹窗新增 `HTTP / HTTPS` 协议切换开关（默认 `HTTP`、默认端口 `8096`）、选填端口/路径/名称与裸域名直填，支持粘贴 `/web/` 浏览器地址自动归一化；
  - 登录自动兼容 `/emby` 与根路径 `/` 回退、`bareRoot` 会话标记与 HTTP → HTTPS 安全重定向，TLS 握手失败时提供无凭据 HTTP 端口探测诊断指引，并放行 4K / 多音轨 DirectPlay。

## 包信息与校验

- **安装包**：`MarcoMovie-0.5.11-android-lite.apk`（`1328288` B；兼容别名 `MarcoMovie-0.5.11-lite.apk`），`compile_api: 14` / `min_api: 14`，`armeabi-v7a` 单 DEX。
- **APK SHA-256**：`3a4c3a3e1910ac3d498ca807cb42ca890d91a852c4bda255a5b205112bceee5f`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
- **对应源码包 SHA-256**：`MarcoMovie-android-lite-v0.5.11-source.zip`（`23472470` B）— `77be1f58da9d24cfbf645eb994e6cac1159a8a47bb09741e9646b3b846be5b88`。
- **构建提交与验证**：`a9d5c8cb2bc5c083dc82639c3cbf7026c01882db`（[Job 140830652662 · Run 46096257329](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46096257329/job/140830652662)）。已通过 API 14 单 DEX 构建与官方正式签名校验、`280` 项 JVM 回归、`8` 项 TLS 校验与 `20/20` 三端源一致性校验；实体 Android 4.x 电视盒实机播放待实测。
