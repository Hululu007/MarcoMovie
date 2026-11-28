# Marco Movie Android 手机 / 平板 0.7.6

发布日期：2026-11-28。应用版本 `0.7.6`（版本代码 `106`）；最低 Android 6 / API 23（双架构 `armeabi-v7a` + `arm64-v8a`）。

## 本次更新

- **新增折叠屏半折悬停 HUD 与画面上下分离模式（自动开启）**：
  - 新增 `FoldableTabletopController`，兼容 Jetpack WindowManager FoldingFeature 与铰链传感器多层级识别，在横向折叠半折悬停姿态下自动进入悬停分屏模式（`[68°, 142°]` 切入 / `[55°, 155°]` 迟滞退出，防角度抖动误触），展开或合盖自动还原。
  - 上半屏严格承载视频画面、弹幕、字幕与轻触闪现顶栏；下半屏转为 `#FF0A0C10` 哑光暗色常驻触控台，提供返回 `<`、锁屏、弹幕开关、倍速、音效、双行线路/分辨率胶囊、选集、字幕、更多、全宽进度条与时间戳、左下播放/暂停及右下下一集。
  - 支持在设置与播放器「更多」面板随时开关 `折叠半折悬停分离模式`（`Prefs.FOLDABLE_TABLETOP_SPLIT_HUD`）。
- **彻底修复多仓全局搜索大量线路显示「未完成」问题**：
  - 将 `MobileSearchPage` 固定 6 线程搜索池升级为与电视端一致的优先级双通道 `SearchCoordinator`：HTTP / Emby / Alist 通道与插件爬虫通道隔离调度，原生插件通道上限提升至 16 线程、`400+` 多仓场景自动按来源数扩容全局会话超时预算（最高 `360s`），阻塞超时池不再饿死后续健康来源（411 源压测实现 `0 未完成`）。
- **整合结构化 Emby、局域网投屏中继、右上角状态定位、HUD 按钮自定义与 WebDAV 修复**：
  - 保留 `0.7.5` 结构化 Emby 连接与编辑、局域网投屏媒体中继 `LanCastMediaRelay`、横屏弹幕面板间距修复、播放页右上角状态定位（5 档停靠与微调）、底栏与快捷按钮自由排序及 WebDAV 云同步修复，同时修复「聚剧|四盘」等聚合盘搜源历史直连续播与搜索词匹配。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（Mobile edition，`minSdk 23` / `targetSdk 35`）。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
- 说明：最终构建提交哈希、APK 与源码包 SHA-256 校验值见对应 GitHub Release 发布页及 [platform-releases.md](../platform-releases.md)。
