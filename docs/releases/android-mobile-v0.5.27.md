# Marco Movie Android 手机 / 平板 0.5.27

发布日期：2026-11-21。应用版本 `0.5.27`（版本代码 `95`，严格高于既有全包最高 `versionCode 93`，确保同包名 `com.pilipala.marcomovie` 覆盖升级不冲突）。本次更新围绕 Android 手机与平板端统一纯文字媒体规格徽章、触控手势长按/横滑/上滑锁定倍速状态机、清洁室 30 秒分片弹幕与字幕置顶 Z 轴修正、API 33+ AGSL 与 API 23–32 硬件平滑转场、极光氛围及 5 幕故事化新手引导进行升级。

## 更新内容

- **媒体规格徽章引擎与详情/起播集成**：`MobileDetailScreen` 英雄区与线路选择器接入跨端统一纯文字媒体规格徽章（`MediaBadges` + `MediaBadgeView`，`4K`、`HDR10+`、`DV · ATMOS`、`DD+ 5.1` 等纯文本胶囊，零第三方商标图形）；播放页 `PlayerChrome` 与 `StartSpecBanner` 在首帧就绪后动态呈现融合实时轨道信息的规格徽章条，避开左上角返回按钮安全区并在 `3` 秒后优雅收拢。
- **触控手势状态机升级与原生细进度条复用**：完整保留已有「长按 `2.0×` 倍速」能力并由 `PlayerGestureStateMachine` 升级为**静止长按 `>= 350ms` 激活 `2.0×` → 左右横滑顺畅切换 `1.25× / 1.5× / 2.0× / 3.0×`（带触觉反馈）→ 上滑 `>= 48dp` 锁定倍速（顶部常驻解锁胶囊，切集/锁屏/返回自动恢复）**；支持左/中/右双击区域自定义、左/右 `28%` 区域 `650ms` 连击累加快退快进、边缘 `24dp` 防误触与来电/后台/多指/弹窗中断强制复位；仅放宽 `PlaybackController` 单行门控使手机/平板可直接复用 `SlimProgressBar` 常驻细进度条；新增 `3` 秒片头/片尾跳过倒计时胶囊与定时关闭面板，并在「设置 → 触控手势与 HUD」集中暴露本机独立偏好开关（不改动跨端同步白名单 `Prefs.KEYS`）。
- **清洁室 30 秒分片弹幕引擎与字幕置顶 Z 轴修正**：接入 `DanmuProvider` / `DandanplayProvider` / `DanmuSegmentCache` 与 `DanmuSettingsPanel`（默认服务地址为空 `""`，仅用户配置兼容服务或本地文件后生效），支持 `mmdanmu://v1` 来源绑定、有符号有效时钟、三窗口无缝跨界、`HTTP 410` 单飞重试、`180ms` Seek 防抖取消、线性运动学无碰撞轨道及静态 ReDoS 拦截器（屏蔽词在窗口入缓存时预过滤，不在 `onDraw` 重复匹配）；严格修正 `PlaybackControls` 子视图层级为 `视频表面 -> DanmakuView -> SubtitleOverlayView -> HUD 浮层`，彻底解决弹幕遮挡字幕问题。
- **分级进入转场、极光氛围与 5 幕新手引导**：`PlayerTransitionHelper` 按系统分层执行转场——Android 13+（API 33+）采用 AGSL `RuntimeShader` 纵深退场与安全卡片门户过渡（全出血竖屏不误传全屏背景以免遮挡首帧），API 23–32 采用纯硬件 `RenderNode` 缩放淡入并在动画期间通过 `GlassFreezeFrameLayout` 冻结 `GlassworkSurface` 重采样（保留已缓存模糊材质平滑绘制，不跳变纯色），开启减少动态效果时切为 `150ms` 线性淡入；空态欢迎页与「关于与更新」接入 `AuroraSurfaceView` 极光氛围背景（不可见自动停帧），缓冲等待升级为 `1.6s` `BrandLogoLoaderView` 金属丝带 `M` 加载器；新增首次安装（无现有配置且非损坏恢复时）与设置页可重看的 5 幕故事化 `OnboardingScreen`（配 `14` 张程序化抽象「示例」海报）及最多展示 `3` 次的首播手势提示胶囊 `FirstPlayGestureHint`。

## 包信息与构建记录

- **安装包（ARM64 + ARMv7 双架构）**：`MarcoMovie-0.5.27-android-mobile.apk`（`64419499` B，更新兼容别名 `MarcoMovie-0.5.27-mobile.apk`），包名 `com.pilipala.marcomovie`，`minSdk 23` / `targetSdk 28`。
- **APK SHA-256**：`df9a5213b3e8df746b31b4fbec16e2e6898a4b21a2057652c233311dd3617c98`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`（与既有正式版一致，支持保留本地数据直接覆盖安装）。
- **对应源码包 SHA-256**：`MarcoMovie-android-mobile-v0.5.27-source.zip`（`10708828` B）— `a073faed1f0098cc77830a7cfaef10a27c3473fa305509fc8abd149fcafe3009`。
- **构建提交与 CI 记录**：`78017bfb79cf4430681436b53cfcf67b77f44e5b`。[多端构建与校验记录（44857333769）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44857333769) / [公开守卫记录（44857333149）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44857333149)。

## 验证范围与已知限制

- **已完成自动化构建与校验**：在 `78017bfb79cf4430681436b53cfcf67b77f44e5b` 通过 GitHub Actions 公开守卫（`1513` 文件）、`DanmuEngineChecks`（`294` 断言）、`CmsChecks`（`57` 项）、`34` 项 Flutter 三端一致性与 Android 构建验证，并在本地通过 `MARCOMOVIE_RELEASE=1` 官方签名构建、`API 23` 字节码校验（`627` 应用类）、`native Guard import`（`170` 项）与 `zipalign`/签名检验。
- **待完成真机验证**：尚未在物理 Android 手机与平板上完成与 `android-mobile-v0.5.26` 的 A/B 对照实机测试（含横竖屏切换、挖孔屏避让、来电中断倍速复位与 `60fps` 帧率验证）。
