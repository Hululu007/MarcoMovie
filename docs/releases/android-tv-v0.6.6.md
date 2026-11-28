# Marco Movie Android 电视 / 盒子 0.6.6

发布日期：2026-11-28。应用版本 `0.6.6`（版本代码 `103`）；最低 Android 6 / API 23（32 位 `armeabi-v7a`）。本版本合入 `0.6.5` 首页背景防菱形纹修复，并新增大屏弹窗对齐与聚合盘搜源历史记录直连续播修复。

## 本次更新

- **修复「选线路与选集」等电视端弹窗卡片未对齐与边缘留白不均问题**：
  - `MainActivity.row()` 与 `DanmuSettingsPanel` 全部横向行布局显式关闭 `baselineAligned`，消除混合单行/多行文本卡片基准线导致的阶梯错位。
  - `DetailScreen` 引入同步测量等高行容器 `EqualHeightEpisodeRow`，在首轮 `measure` 即把同排剧集卡对齐至一致高度，并对齐 `AppDialog` 标题/底部按钮、线路头部与选集网格左右外边距（`col == 0` / 末列归零）。
  - 统一 `TvDetailHost.showEpisodesDialog`、`SourcePicker` 页脚网格及 `TvDanmuSearchDialog` 搜索框与按钮高度（`42dp`），消除右侧额外缩进。
- **修复「聚剧|四盘」等聚合盘搜源历史记录重开失效需重搜的问题**：
  - `Cms.Site.isNetdiskSite()` 识别 `聚剧` / `四盘` / `csp_S_zps`；`TvDetailHost` 在遇到 `"0"` / `"1"` 占位 `vod_id`、无可用线路或详情失效时，先自动以净化标题（`HistoryResumeMatcher.cleanSearchTitle`）执行同站静默重匹配（优先于跨源跳转），就地绑定并迁移历史条目键至新版可用片源，保留断点「继续播放」位置。
- **合入 0.6.5 电视端背景菱形纹修复（`ARGB_8888`）**：
  - 保留 `HomeAmbient.acquireTvScratchBitmap()` 32 位 `ARGB_8888` 柔光渐变双缓冲，消除低色深缩放至 1080p 电视大屏时产生的菱形棋盘抖动纹。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（TV edition，`minSdk 23` / `targetSdk 28`）。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
- 说明：最终构建提交哈希、APK 与源码包 SHA-256 校验值见对应 GitHub Release 发布页及 [platform-releases.md](../platform-releases.md)。
