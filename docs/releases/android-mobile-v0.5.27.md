# Marco Movie Android 手机 / 平板 0.5.27

> **发布说明草案**：发布日期待定；应用版本 `0.5.27`（版本代码 `95`，严格高于当前全包最高 `versionCode 93`，确保同包名 `com.pilipala.marcomovie` 覆盖升级不冲突）。待正式签名构建及真机 A/B 对照验收后补齐构建记录与校验摘要。

## 更新内容

- **媒体规格徽章引擎与详情/起播集成**：`MobileDetailScreen` 英雄区与线路选择器接入跨端统一纯文字媒体规格徽章（`MediaBadges` + `MediaBadgeView`，`4K`、`HDR10+`、`DV · ATMOS`、`DD+ 5.1` 等纯文本胶囊，零第三方商标图形）；播放页 `PlayerChrome` 与 `StartSpecBanner` 在首帧就绪后动态呈现融合实时轨道信息的规格徽章条，避开左上角返回按钮安全区并在 `3` 秒后优雅收拢。
- **触控手势状态机升级与原生细进度条复用**：完整保留已有「长按 `2.0×` 倍速」能力并由 `PlayerGestureStateMachine` 升级为**静止长按 `>= 350ms` 激活 `2.0×` → 左右横滑顺畅切换 `1.25× / 1.5× / 2.0× / 3.0×`（带触觉反馈）→ 上滑 `>= 48dp` 锁定倍速（顶部常驻解锁胶囊，切集/锁屏/返回自动恢复）**；支持左/中/右双击区域自定义、左/右 `28%` 区域 `650ms` 连击累加快退快进、边缘 `24dp` 防误触与来电/后台/多指/弹窗中断强制复位；仅放宽 `PlaybackController` 单行门控使手机/平板可直接复用 `SlimProgressBar` 常驻细进度条；新增 `3` 秒片头/片尾跳过倒计时胶囊与定时关闭面板，并在「设置 → 触控手势与 HUD」集中暴露本机独立偏好开关（不改动跨端同步白名单 `Prefs.KEYS`）。
- **清洁室 30 秒分片弹幕引擎与字幕置顶 Z 轴修正**：接入 `DanmuProvider` / `DandanplayProvider` / `DanmuSegmentCache` 与 `DanmuSettingsPanel`（默认服务地址为空 `""`，仅用户配置兼容服务或本地文件后生效），支持 `mmdanmu://v1` 来源绑定、有符号有效时钟、三窗口无缝跨界、`HTTP 410` 单飞重试、`180ms` Seek 防抖取消、线性运动学无碰撞轨道及静态 ReDoS 拦截器（屏蔽词在窗口入缓存时预过滤，不在 `onDraw` 重复匹配）；严格修正 `PlaybackControls` 子视图层级为 `视频表面 -> DanmakuView -> SubtitleOverlayView -> HUD 浮层`，彻底解决弹幕遮挡字幕问题。
- **分级进入转场、极光氛围与 5 幕新手引导**：`PlayerTransitionHelper` 按系统分层执行转场——Android 13+（API 33+）采用 AGSL `RuntimeShader` 纵深退场与安全卡片门户过渡（全出血竖屏不误传全屏背景以免遮挡首帧），API 23–32 采用纯硬件 `RenderNode` 缩放淡入并在动画期间通过 `GlassFreezeFrameLayout` 冻结 `GlassworkSurface` 重采样（保留已缓存模糊材质平滑绘制，不跳变纯色），开启减少动态效果时切为 `150ms` 线性淡入；空态欢迎页与「关于与更新」接入 `AuroraSurfaceView` 极光氛围背景（不可见自动停帧），缓冲等待升级为 `1.6s` `BrandLogoLoaderView` 金属丝带 `M` 加载器；新增首次安装（无现有配置且非损坏恢复时）与设置页可重看的 5 幕故事化 `OnboardingScreen`（配 `14` 张程序化抽象「示例」海报）及最多展示 `3` 次的首播手势提示胶囊 `FirstPlayGestureHint`。

## 包信息与构建记录

- **安装包（ARM64 + ARMv7 双架构，待正式构建）**：`MarcoMovie-0.5.27-android-mobile.apk`（兼容别名 `MarcoMovie-0.5.27-mobile.apk`），包名 `com.pilipala.marcomovie`。
- **SHA-256 / 源码包 / 构建记录**：待正式签名打包后填入。

## 验证范围与已知限制

- **已完成自动化验证（基于 `feat/ux-integration-20261120 @ 82f38cd2`）**：通过 `check_public_content.py`（`1507` 文件）、`format_java.py --check`（`261` 文件）、`run_checks.py`（含 `MediaBadgeChecks` `165/165`、`PlayerGestureChecks` `190` 项、`DanmuEngineChecks` `294` 断言、`MotionTokenChecks` `965` 断言、`OnboardingStateChecks` `114` 断言、`Wave2AndroidWireChecks` `397` 项）、`run_compat_checks.py`（`86` 项）、`run_review_fix_checks.py`（`58` 项）、`run_player_lock_checks.py`（`30` 项）、`run_seek_checks.py`（`25` 项）及 `run_conformance_checks.py`（`20/20`）。
- **待完成验证**：尚未生成新版本号正式包，亦未在物理 Android 手机与平板上完成与 `android-mobile-v0.5.26` 的 A/B 对照实机测试（含横竖屏切换、挖孔屏避让、来电中断倍速复位与 `60fps` 帧率验证）。
