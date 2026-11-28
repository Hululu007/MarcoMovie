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
- **统一全局搜索结果卡片样式与筛选标签展示**：
  - 将「全部」与各来源下的网盘/聚合源（如「聚剧|四盘」、夸克/网盘源）搜索结果统一为一致的 `2:3` 竖版海报卡片与等宽列布局，消除宽窄混排与右侧留白缺口，并在副标题中精简日期与画质标签且不再截断「全部」计数胶囊。
- **修复电视端播放页右上角进度与时间开关不生效问题**：
  - `PlayerChrome.shouldShowTvTopRightHud` 与 `updatePlaybackHud()` 不再因电视 HDR/杜比视界 `SurfaceView` 的底栏隐藏节流逻辑而连带隐藏右上角 HUD；使用 `Gravity.TOP | Gravity.RIGHT`、`bringToFront()` 与动态字号/边距刷新；在「更多」菜单切换开关时即时刷新并自动收起控制栏以便立刻看到右上角进度与时间生效。
- **剧集智能刮削保留清晰度、HDR/杜比与容量大小并清理嵌套网盘文件夹后缀**：
  - `TvSeriesScraper` 新增 `extractEpisodeSpecSummary()` / `extractEpisodeSizeTag()`，自动从原文件名提炼 `8K`/`4K`/`2K`/`1080P`/`720P`、`杜比`/`HDR10+`/`HDR`/`原盘`/`高码`/`60帧` 及 `GB`/`MB` 容量大小并在选集网格与播控选集弹窗中保留显示（如 `第01集 · 4K · 杜比 · 3.2GB`），同时剥离嵌套 `【...【...】...】` 目录后缀与连续点号 clutter。
- **修复扩展源配置中心网盘登录弹窗右侧越界裁切及遥控器无法点击问题**：
  - `PluginDialogStyler` 接管蜘蛛自定义非扫码 `PopupWindow` / 子面板窗口，放宽 `FLAG_NOT_FOCUSABLE`、接管返回键关闭与首次默认聚焦；识别同音网盘名（夸夸/优汐/摆渡/迅蕾/光雅/115/天意）与状态胶囊（`未登录`/`已登录` 等），规范横向行与可点击 `TextView` 边界与焦点态，彻底消除右侧白胶囊被弹窗边界切半且遥控器无法选点的问题。
- **彻底修复小米电视 3s 等 Android 6.0.1（API 23）设备选剧进入后闪退问题**：
  - 将 `android-tv/dependencies.json` 中携带未脱糖 API 24/26 字节码（`ThreadLocal.withInitial`、`ArrayList.sort`、`Stream`、`java.nio.file`）的 `jsoup 1.18.3` 降级为 API 23 兼容的 `jsoup 1.15.4`，消除爬虫详情解析触发的 `NoSuchMethodError`；同时在 API 23 上禁用需 API 24 Bionic 符号的 `MPV` 内核、修复 `Cms.evictDohCache` / `SpiderGatewayServer` / `TvAudioEffectProcessor` API 24+ 调用并加宽 `LinkageError` 安全兜底捕获。
- **电视端倍速播放改为当前剧连播有效、返回主页自动重置**：
  - 新增 `PlaybackControls.TvDramaSpeedSession`，电视端在播放器内调节的倍速仅在当前剧连续选集/换线播放时保持；返回主页、搜索页、片库分类或切换其他剧集后自动重置为 `1.0×`，不再将上一部剧的倍速延续到其他剧集。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（TV edition，`minSdk 23` / `targetSdk 28`）。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
- 说明：最终构建提交哈希、APK 与源码包 SHA-256 校验值见对应 GitHub Release 发布页及 [platform-releases.md](../platform-releases.md)。
