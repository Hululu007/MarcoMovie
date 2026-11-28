# Marco Movie Android 电视 / 盒子 0.6.7

发布日期：2026-11-28。应用版本 `0.6.7`（版本代码 `104`）；最低 Android 6 / API 23（`armeabi-v7a`）。

## 本次更新

- **修复 Android 6.0 (API 23) 等老电视进入详情页/首页偶发 `libRScpp.so` 崩溃**：
  - 新增 `UiCompat.safeShadowRadius` 与 `UiCompat.setShadowLayer(TextView, ...)`，在 API 23 及以下自动禁用 `TextView` RenderScript 阴影模糊并在 API 24+ 将模糊半径安全钳制在 `25px` 以内，全面替换 `DetailScreen`、`HomeDock`、`HomeScreen`、`MiniDetails`、`MobileDetailScreen`、`PlayerChrome` 与 `TvV17DetailScreen` 中的裸调用。
- **修复电视端倍速播放卡顿与本地代理拉流限速 ~1 MB/s**：
  - `DecoderRenderersFactory` 新增 `resolveTvCodecOperatingRate` / `getCodecOperatingRateV23` 声明倍速硬件解码工况率；`MoviePlayer` 在倍速范围 `[0.25x, 4.0x]` 且非 `1.0x` 时自动退出 `tunnelingEnabled` 隧道模式；`MpvPlayer` 启用 `framedrop=vo`、`audio-pitch-correction=yes` 与 `af=scaletempo`；
  - 重构 `MediaDiskCache` 与 `HlsStreamProxy` 为复用 `OkHttp` 连接池的单连接 64 KiB 连续流式直传与异步有界缓存落盘（`MAX_PENDING_BLOCKS = 24`、`RequestScope` 即时取消），`LocalProxy` 开启 `TCP_NODELAY` 与 256 KiB 发送缓冲区。
- **修复海信 9655 等机型播放 4K/蓝光原盘 `SystemPlayer` `-38` 崩溃与无法回退**：
  - `SystemPlayer` 为 `getTrackInfo`、`getSelectedTrack`、`selectTrack`、`deselectTrack`、`getAudioSessionId` 与 `setPlaybackParams` 全面增加原生 `RuntimeException` 防护；
  - `MoviePlayer.isSystemPlayerUnsupportedContainer` 识别 `.iso` / `.bdmv` / `.m2ts` / `.mpls` 蓝光原盘容器，`PlaybackController` 对上述容器跳过系统播放器并在 `SystemPlayer.onError` 时通过 `_systemErrorFallback` 自动单次无缝切换内置解码内核。
- **修复电视端坚果云 WebDAV 同步报 `HTTP 409 读取失败` 与非 ASCII 路径编码问题**：
  - `CloudSync` 在首次 `GET` 返回 `409` 时先递归创建父目录并重试（不存在视为空库继续同步合并），并通过 `toAsciiRequestUrl` 对中文及空格路径做 ASCII 百分号归一化编码。
- **修复蜘蛛「网页配置」手机扫码被拒绝、电视自开手机配置网页与横向 Cookie 输入框无法扫码**：
  - 新增限时（15 分钟）且严格仅限局域网私有网段、仅放行 `/proxy` 非脚本/非媒体配置路由的 `TvLanConfigBridge`（保持 `LocalProxy` 严格绑定 `127.0.0.1` 不变）；
  - 拦截电视端自身通过 `ACTION_VIEW` 或结构化 `webview` / `url` / 本地 `qrcode` 响应打开 `:9978..9999/proxy` 的动作，改由 `MainActivity.showLanProxyConfigQr` + `TvQrInputHelper.showLanConfigQrDialog` 在电视端直接展示局域网扫码配置弹窗；
  - 放开 `PluginDialogStyler` 横向行内的 `EditText` 限制，并在 `TvQrInputHelper.attachToExistingPluginEditText` 中为横向 Cookie 输入行插入右侧扫码输入图标按钮。
- **修复全局搜索焦点乱跳/丢失、低内存电视卡顿无响应与新增按分组搜索**：
  - `GlobalSearchScreen` 新增 `userMovedRightPaneFocus` 防抢焦点守卫、移除 `updateFilterLabels()` 中多余的 `requestLayout()`、补全 `sourceFilters` 与 `tvResultRecycler` / 状态按钮之间的确定性 `DPAD_UP/DOWN` 导航；
  - 右上角新增「全部分组 / 指定分组」切换按钮（支持仅搜索指定站源分组）；
  - 缓存 `isLowRamTv()`、对 24+ 站源/低内存电视放宽 `scheduleRender` 合并窗口至 `180ms`、缓存「全部」计数排序结果，并对 `PluginDialogStyler` 的 `OnPreDrawListener` 增加 `240ms` 节流，降低 192 MB 内存电视 ANR 风险。
- **优化软件更新下载与详情页默认偏好源 / 默认线路生效**：
  - `UpdateManager` 收紧连接/读取超时并升级为 `128 KiB` 缓冲流，首源无进展失败时直接切入备用源；
  - `SourcePreferences.matchPreferredLineIndex` 支持归一化后缀变体与网盘家族关键词匹配，详情页弹窗切换默认线路后立即重绘并定位，选中默认偏好源在精选直达匹配中优先于通用站源优先检索。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（TV edition，`minSdk 23` / `targetSdk 28`；同字节兼容别名 `MarcoMovie-0.6.7-preview.apk`）。
- **TV APK SHA-256**：`MarcoMovie-0.6.7-android-tv.apk`（`56944838` B）— `4432c5e0d709f88fcbd37c54797bce904126b61382fb238e560ef8dd451518e2`。
- **APK v4 签名文件**：`MarcoMovie-0.6.7-android-tv.apk.idsig`（`452006` B）— `db4fb68fbcc0840bac4a760f7e02e6aeb156e2e1f33aad4c01210c0ca846a489`。
- **对应源码包 SHA-256**：`MarcoMovie-android-tv-v0.6.7-source.zip`（`23570514` B）— `b98b5ba4907f6d948eb93f20461aa28b5bed1bf285e8ce2ef3421ce22bf68680`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
- **精确构建提交与校验**：`1da4725fcdf1f641be0152ec857651e6ccdf58e0`（`git_dirty: false`，`armeabi-v7a` 与 CPython `3.11.17-0` `stamp=465dcbd59564bbd4`）。已通过 `check_public_content.py`（`2911` 文件）、`format_java --check`（`649` 文件）、`sync_readme_versions --check`、`run_api23_callback_checks.py`（`949` 应用类）、`run_local_proxy_checks.py`（`42` 项）、`run_hq_upgrade_checks.py`（`65` 项）、`run_cloud_sync_checks.py`（`108` 项）、`run_tv_playback_and_ratings_checks.py`（`36` 项）、`run_tv_ux_optimization_checks.py`（`491` 项）、`run_decoder_checks.py`、`run_global_search_checks.py`、`run_compat_checks.py`、`run_update_checks.py`、`run_review_fix_checks.py`、`run_cast_search_picker_checks.py`（`44` 项）、`run_checks.py`（`108+47+165/165+191+336+965+114+397+57`）、`run_conformance_checks.py`（`20/20`）、`run_guard_checks.py`（`170` 项）与 `test_lite_conformance.py`（`20/20`）。实体电视覆盖安装、API 23 老电视真机详情页、海信 9655 蓝光回放、手机扫局域网配置二维码及真实坚果云联调待实机验收后补齐。
