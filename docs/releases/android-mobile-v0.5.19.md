# Marco Movie Android 手机 / 平板 0.5.19

发布日期：2026-11-11。版本代码：76。

## 设置页重构为全屏一级 / 二级页面体系

- 移除手机端设置页点击分类后弹出的底部抽屉弹窗（`MobileIosSettings`），改为纯页面内的一级分类列表 → 二级详情设置页全屏导航：一级页面保留 `32sp` 大标题与六大液态玻璃胶囊，二级页面提供顶部圆形 `‹` 返回按钮、分类标题与分组液态玻璃卡片，并完整接管系统侧滑/物理返回键与底部“设置”标签二次点按回顶。

## 网盘登录与移动端弹窗统一居中悬浮显示

- 将顶栏“网盘与账号中心”（`AccountPanel`）、单选列表选择器（`MobileShell.showDrawerPicker`）、详情页“全部剧集”面板（`MobileDetailScreen`）、片源选择面板（`SourcePicker`）以及第三方扩展网盘登录/扫码/排序弹窗（`PluginDialogStyler`）统一调整为屏幕正中悬浮的圆角深色液态玻璃卡片（`Gravity.CENTER`），保留上下左右呼吸边距，不再紧贴屏幕底部。

## 修复云盘按钮点击闪退

- 修复 `PluginDialogStyler` 在美化扩展原生弹窗时调用 `View.setTag(android.R.id.background, ...)` 触发 Android 框架 `IllegalArgumentException`（要求应用级资源 ID）导致点击“我的云盘 / 网盘账号授权 / 推送凭据 / 线路排序”及云盘弹窗内二级按钮时主线程闪退的问题；改为 `WeakHashMap` 无侵入追踪，剥离中间容器灰白底色并移除跨窗口 `GlassworkSurface` 与 `LayoutParams` 强转隐患。

## 恢复选集详情页自动切换高清竖版海报

- 修复 `ImmersivePoster.resolveHdPortraitPoster` 在片源返回低清缩略图 URL 时提前跳过第三方权威高清竖版封面拉取的问题：对非“漫剧 / 动态漫 / 短剧”正片条目重新启用豆瓣与哔哩哔哩官方高清竖版海报校验拉取与 16:9 分集剧照同步刷新。
- 修正封面标题归一化与副标题前缀匹配逻辑，严格保留续作/分季序号（如 `斗罗大陆2` / `斗罗大陆II` / `第二季`），避免第二季误拉取第一季封面或串入动态漫封面；并在 `PosterHookImageView` 锁定已就绪的高清位图，防止慢速低清源图回写覆盖。

## 播放资源拉取与起播速度优化

- 点击搜索结果、切换底部标签或进入详情选集页时立即终止后台未完成的多源并发检索（`SearchCoordinator`），并在第三方运行态扩展片源详情页跳过后台自动关联分季搜索，释放 `SourceGate` 互斥锁使 `engine.player()` 零排队执行；同时为续作搜索增加首轮命中正片即刻返回快速通道。
- `MediaOptions.episode` 在网盘扩展同时返回本地回环 `/proxy` 与同档位“原画 / 直连”CDN 地址时优先直连云盘 CDN（保留 `/proxy` 作为自动回退，且不将原画降级为低码率转码流）。
- `MoviePlayer` 对云盘 CDN 与非清单类本地 `/proxy` 地址跳过额外的 `Range: bytes=0-511` 预探测往返连接（避免触发扩展代理重复建连，保留容器解析异常自动回退 HLS 机制），并将 `PlaybackController` 解析与播放器初始化迁移至独立专用线程池、与横屏渲染表面创建并行预备。

## 验证范围与限制

- 通过公共内容守卫检查、Java 代码格式检查、离线纯 JVM 单元回归（含续作检索快速通道、分季标题隔离与网盘直连原画优选新增断言）及 Android 官方正式签名构建与包体校验。
- 本版本仅发布 Android 手机 / 平板安装包（`MarcoMovie-0.5.19-android-mobile.apk` 及兼容别名 `MarcoMovie-0.5.19-mobile.apk`），使用官方正式签名，支持应用内直接覆盖安装升级；不变更电视端、Lite、Windows、macOS 或 iOS 已发布版本。
- 自动化构建与离线回归不代表特定实体手机型号或真实第三方网盘账号播放已完成实机验收。
