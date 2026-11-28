# Marco Movie Android 手机 / 平板 0.7.7

发布日期：2026-11-28。应用版本 `0.7.7`（版本代码 `107`）；最低 Android 6 / API 23（双架构 `armeabi-v7a` + 16 KB 页面对齐 `arm64-v8a`）。

## 本次更新

- **修复平板与手机关闭首页「沉浸式巨幅海报」后顶栏悬空遮挡与滚动跳位问题**：
  - `MobileHomePage.computeFloatingHeaderTranslationY` 在关闭沉浸式海报时让顶部品牌/站源栏 `floatingTopBar` 随 `scrollY` `1:1` 平滑上移收起并设为透明无背景、离屏后隐藏，彻底避免悬浮顶栏遮挡滚动后的海报卡片；
  - 同步修正无沉浸式海报时首组精选模块（`firstUnderHero`）顶距、拦截滚动容器子项抢焦点（`FOCUS_BLOCK_DESCENDANTS`）并在异步刷新后保持原滚动位置 `savedScrollY`。
- **修复本地代理直链与 HLS 拉流网速卡在 ~1 MB/s 导致大体积视频卡顿问题**：
  - 重构 `MediaDiskCache` 与 `HlsStreamProxy`：将直链逐块（256 KiB）串行新建短连接请求与同步阻塞写盘改造为复用 `MoviePlayer.mediaHttpClient()` 连接池的单连接连续流式直传（64 KiB 分片边读边下发）、有界异步写盘与异步容量裁剪，并在播放器切换/寻址关闭流时通过 `RequestScope` 即时取消上游请求；
  - `LocalProxy` 本地回环套接字开启 `TCP_NODELAY` 并配置 256 KiB 发送缓冲区，消除小分片回传延迟与本地吞吐瓶颈。
- **修复剧集详情页部分海报模糊、未拉取到高清封面问题**：
  - `MobileDetailScreen` 在 `PosterHookImageView` 中新增分辨率单调门控 `shouldAcceptPosterBitmap` 与 `applyPosterBitmap(bm, isHd)`，防止异步晚到的低清缩略图覆盖已渲染的高清海报；
  - `ImageLoader.upgradePosterUrl(..., detail=true)` 扩展腾讯（`puui.qpic.cn`）、爱奇艺（`pic*.iqiyipic.com`）、芒果 TV（`*.hitv.com`）等 CDN 原图尺寸升格规则，并在 `fetchPosterBytesWithFallback` 增加 `.webp` / `.jpg` 与豆瓣镜像（`img9` / `img1`）回退；
  - 抽取 `SeasonParser.stripSeriesEditionSuffix` 剥离「第X季 / 沪语版 / 未删减版」等版本后缀进行基准剧名二次回退，放宽多季年份差容忍度（`diff <= 6`），移除 Rexxar 过早截断并补充百科竖图兜底，合理下调竖版高清分辨率门槛（`360×500`）。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（Mobile edition，`minSdk 23` / `targetSdk 28`；同字节兼容别名 `MarcoMovie-0.7.7-mobile.apk`）。
- **Mobile APK SHA-256**：`MarcoMovie-0.7.7-android-mobile.apk`（`101052884` B）— `bce1f467e7b38050ac3773d2d358a32c99b686fad91dce7ba3c0aa9ec95755ef`。
- **APK v4 签名文件**：`MarcoMovie-0.7.7-android-mobile.apk.idsig`（`804262` B）— `cf7fa6838fade4dbfecd1df8945946afdf1cc368cfab08d901ccef6c4d387067`。
- **对应源码包 SHA-256**：`MarcoMovie-android-mobile-v0.7.7-source.zip`（`23549144` B）— `430cecd2dd606f2b654d13114344ae5919b745dc72529831646a204475c19356`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
- **精确构建提交与校验**：`416cf4551fe55da3571539d6405672b7a09c78d9`（`git_dirty: false`，16 KB 页面对齐、双架构 CPython `3.11.17-0` `stamp=027f821a1ad1128d`）。已通过 `check_public_content.py`（`2909` 文件）、`format_java --check`（`648` 文件）、`sync_readme_versions --check`、`run_api23_callback_checks.py`（`1027` 应用类）、`run_hq_upgrade_checks.py`（`68` 项）、`run_local_proxy_checks.py`（`34` 项）、`run_batch1_mobile_checks.py`（`27` 项）、`run_mobile_ui_redesign_checks.py`（`238` 项）、`run_checks.py`、`run_review_fix_checks.py`（`62` 项）、`run_update_checks.py`（`56+45` 项）、`run_conformance_checks.py`（`20/20`）与 `run_guard_checks.py`（`170` 项）。物理平板关闭沉浸式海报滚动、高码率代理长片实测速率与低清剧集海报线上拉取实机验收待后续补齐。
