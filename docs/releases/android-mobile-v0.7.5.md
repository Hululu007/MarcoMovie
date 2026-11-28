# Marco Movie Android 手机 / 平板 0.7.5

发布日期：2026-11-28。应用版本 `0.7.5`（版本代码 `105`）；最低 Android 6 / API 23（`arm64-v8a` + 16 KB 页面对齐 `armeabi-v7a` / `arm64-v8a` 双架构原生库）。

## 本次更新

- **聚合盘搜 / 四盘源（「聚剧|四盘」等）历史记录直连续播**：
  - 将 `juju` / `szps` / `s_zps` / `聚剧` / `四盘` / `pansearch` 纳入 `Cms.Site.isNetdiskSite()`，对聚合/网盘源跳过易失内存会话明细缓存并在保存历史条目时过滤 `"0"` / `"1"` 占位 `vod_id`。
  - `WatchHistory.Entry` 新增清洁 `shareUrl` 持久化（仅允许公网盘分享 ID/URL，自动拦截含签名凭证/临时参数的地址），从历史卡片重新进入时优先使用真实分享 ID。
  - 当旧历史记录仅有 `"0"` / `"1"` 占位 ID 或上游缓存/分享失效时，`MobileDetailScreen` 静默通过同站清洁剧名搜索（`HistoryResumeMatcher.cleanSearchTitle`）重新绑定新详情并在后台原地迁移历史键，保留「继续播放」断点进度而不弹窗强制用户重新搜索。
- **结构化 Emby 媒体库表单、4K `.strm` 播放与浅/深色主题视觉对齐**：
  - 重构 `MobileEmbyAccounts` 为自适应浅/深色主题底部弹窗，支持**名称**、**是否允许云端同步**、**HTTPS** 开关（默认 `HTTP / 8096`）、服务器地址粘贴自动拆解、选填路径、端口号、用户名与明/密文密码切换，并接入局域网与 WebDAV 双向同步。
  - `MobileEmbyLibrary` 支持 `/emby` 遇到 404/405 自动回退裸根路径、空白 `Views` 回退「全部媒体」以及 `.strm` DirectPlay。
- **横屏播放弹幕顶部间距与导入页对比度修复**：
  - 修复横屏播放器内置弹窗（如弹幕设置）顶栏与系统状态栏之间多余留白，贴顶精准对齐并对齐横竖屏对比度。
- **修复安卓手机端本地代理 / 受限流 / 本地文件无法投屏问题**：
  - 新增按单次投屏会话随机 32 位令牌隔离的局域网 HTTP 中继 `LanCastMediaRelay` 与 `DlnaCastClient.prepareCastTarget`（配合 `HlsStreamProxy.headersForLocalUrl` 与多网卡 `MulticastSocket` SSDP 探测），使回环代理流（`127.0.0.1`）、带 `Cookie` / `Referer` / `Authorization` / 自定义 `User-Agent` 的远程流以及本地 `file:/` 离线视频与 HLS 分片均可直接投屏到同一局域网电视 / 盒子，并在停止投屏、退出播放或进入隐私空间时即时吊销会话；公网直链继续保持免中继直推。
- **播放页状态信息（右上角 HUD）位置支持手动调整**：
  - 支持在设置页（`ms-corner-hud`）与播放页「更多 -> 状态信息显示位置」选择 5 档停靠预设（右上/左上/顶部居中/右下/左下）、X/Y 坐标偏移滑条、16:9 实时预览及播放画面「直接在画面上拖动位置」模式（松手自动吸附最近边角并安全区夹紧）。
- **播放页 HUD 按钮支持自定义添减与排序**：
  - 新增 `MobilePlayerHudButtons` 统一编辑器（支持播放页「更多 -> 自定义播放页 HUD 按钮」与设置页 `ms-btn-order`），支持底栏 17 项功能按钮自由添加、移除、排序（支持清空底栏并持久化 `__none__`）以及顶部/左侧 5 项快捷按钮（顶栏画中画、顶栏投屏、上/下一集步进、弹幕胶囊、屏幕锁）独立显隐。
- **修复云同步 `WebDAV 读取失败 (HTTP 409)` 与中文路径编码问题**：
  - `CloudSync.syncWebdav()` 在 `GET` 收到 `HTTP 409` 时自动通过 `MKCOL` 补建缺失父目录并重试读取；`openConnection()` 新增 `toAsciiRequestUrl()` 对非 ASCII / 中文 WebDAV 路径进行标准 URI ASCII 编码，避免因父目录未建立或未编码路径触发 409 读取失败。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（Mobile edition，`minSdk 23` / `targetSdk 28`；同字节兼容别名 `MarcoMovie-0.7.5-mobile.apk`）。
- **Mobile APK SHA-256**：`MarcoMovie-0.7.5-android-mobile.apk`（`101036500` B）— `b6c20804919791c7298448d7e48a85f220a7638a569028da8c2694b8ea86e39b`。
- **APK v4 签名文件**：`MarcoMovie-0.7.5-android-mobile.apk.idsig`（`804262` B）— `5a98640a6c3b54dd0cc065f1368a860c8827d4287030d8cfd98734f1e9906bba`。
- **对应源码包 SHA-256**：`MarcoMovie-android-mobile-v0.7.5-source.zip`（`23512621` B）— `c75b15ff5e5cc79a2f05a08637926aa599eb4b6396837a4ebab2c33bd868be51`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
- **精确构建提交与校验**：`0c1077cf3c2d09af11364c69febe7b960b38e81f`（`git_dirty: false`，16 KB 页面对齐、双架构 CPython `3.11.17-0` `stamp=935667b6942cf29e`）。已通过 `check_public_content.py`（`2907` 文件）、`format_java --check`（`647` 文件）、`sync_readme_versions --check`、`run_api23_callback_checks.py`（`1020` 应用类）、`run_cast_search_picker_checks.py`（`51` 项）、`run_mobile_ui_redesign_checks.py`（`228` 项）、`run_ai_beta_checks.py`（`154` 项）、`run_cloud_sync_checks.py`（`106` 项）、`run_review_fix_checks.py`（`62` 项）、`run_local_proxy_checks.py`（`34` 项）、`run_checks.py`、`run_update_checks.py`、`run_conformance_checks.py`（`20/20`）与 `run_guard_checks.py`（`170` 项）。物理手机覆盖安装、真机 DLNA 电视投屏及真实 WebDAV 联调仍待后续补齐。
