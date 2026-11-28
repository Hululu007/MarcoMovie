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

- **正式包名**：`com.pilipala.marcomovie`（Mobile edition，`minSdk 23` / `targetSdk 28`；兼容别名 `MarcoMovie-0.7.7-mobile.apk`）。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
- 说明：最终构建提交哈希、APK / `.idsig` / 源码包字节大小与 SHA-256 校验值见对应 GitHub Release 发布页及 [platform-releases.md](../platform-releases.md)。
