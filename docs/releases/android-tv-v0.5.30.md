# Marco Movie Android 电视 / 盒子 0.5.30

发布日期：2026-11-21。应用版本 `0.5.30`（版本代码 `94`）；最低 Android 6 / API 23。本次更新围绕电视大屏端 V17 沉浸影院详情接入统一媒体规格徽章、遥控器 3 秒片头/片尾跳过与定时关闭、清洁室 30 秒分片弹幕引擎与帧率自适应降级、零模糊硬件进入转场及遥控器 5 幕新手引导进行升级；Apple TV 与 HarmonyOS NEXT（`0.1.1`）保持不变。

## 本次更新

- **V17 沉浸影院详情接入媒体规格徽章**：在保留 `TvV17DetailScreen` 左对齐巨幅背景、豆瓣/烂番茄评分行、`HomeAmbient` 6 档动态氛围光与演职员表的基础上，接入跨端统一纯文字媒体规格徽章引擎（`MediaBadges` + `MediaBadgeView`，共享 `45` 条规则与 `3` 条组合规则）；绕过 `URLDecoder` 对 `'+'` 号的破坏，完整保留 `HDR10+`、`DD+`、`DV · ATMOS` 等大字号纯文字胶囊，并适配 `100% / 110% / 120%` 电视界面缩放与遥控焦点高亮。
- **遥控器 3 秒跳过倒计时、定时关闭与护航守卫**：保留现有 `PlaybackController` → `SeekGesture` 遥控左右长按加速快进预览（`30s/s` 起线性递增至 `240s/s`）与 `TvMarkerHost` 上键标记流程，新增遥控焦点友好的 `3` 秒片头/片尾跳过倒计时胶囊（支持确认立即跳过、返回/取消或 `OK` 键状态同步）与会话级定时关闭面板（`关闭 / 15 / 30 / 60 / 90 分钟 / 播完本集`，最后 `30` 秒提示并支持一键 `+15` 分钟延长）。
- **清洁室 30 秒分片弹幕引擎与低配电视帧率自适应**：升级 `DanmakuView` 接入 `DanmuProvider` / `DandanplayProvider` / `DanmuSegmentCache`（默认服务地址为空 `""`，仅在用户配置兼容服务地址或导入本地弹幕文件后生效）；支持 `mmdanmu://v1` 来源绑定、有符号有效时钟（负偏移不冻结 `0.0s` 弹幕）、`30s` 窗口按需拉取与 `60%` 预取、`{w-1, w, w+1}` 三窗口无缝跨界、`HTTP 410` 单飞刷新（单窗最多 `1` 次、单集 `<= 3` 次）、`180ms` Seek 防抖取消、线性运动学尾缘无碰撞轨道与 `O(N)` 静态 ReDoS 拦截器；屏蔽词预过滤移出 `onDraw` 热路径，确保稳态绘制零额外分配；内置 `30` 帧窗口 `P90` 帧耗时自适应降级（`2..8` 行）并在 `PlaybackControls` 严格确保字幕层始终压在弹幕层上方。
- **电视端零模糊轻量化动效与遥控版 5 幕新手引导**：`FocusMotion` 补齐 `Prefs.REDUCED` 减少动态效果守卫（固定 `1.0×` 缩放，保留高亮描边）；详情进入播放采用 `<= 220ms` 纯硬件缩放淡入（严禁着色器与实时模糊），缓冲等待接入 `1.6s` F8 金属丝带 `M` 加载器（`BrandLogoLoaderView`）；新增独立遥控器 5 幕新手引导（`OnboardingScreen`，全 D-pad 焦点链、支持返回键随时跳过、首页与设置「重新查看新手引导」可重看）及 `14` 张程序化生成的抽象几何「示例」海报，并接入最多展示 `3` 次的遥控首播操作提示（`FirstPlayGestureHint`）。

## 验证边界

- **已完成自动化构建与回归校验（精确构建提交 `78017bfb79cf4430681436b53cfcf67b77f44e5b`）**：
  - GitHub Actions 守卫与 Android 编译验证：[Public content checks（44857333149）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44857333149) 与 [Build Multiplatform（44857333769）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44857333769) 全任务通过（`1513` 追踪文件零告警、README 版本对齐、`DanmuEngineChecks` `294` 断言、`CmsChecks` `57` 项、`Glasswork` `14` 场景、`34` 项 Flutter 三端规范测试及 Android 工程编译校验）；
  - 本地官方正式签名构建（`MARCOMOVIE_RELEASE=1`，`git_dirty: false`）通过 `API 23` 回调字节码校验（`627` 个应用类）、`native Guard import`（`170` 项）及 `v1/v2/v3` 签名与 `zipalign` 校验（并已在前序基线提交完成全套 `android/tests/run_checks.py` 与专题回归验证）。
- **待完成真机实测项（严禁未测先宣称）**：
  - 尚未在物理 Android 9 ARM32 电视盒子上完成 `android-tv-v0.5.30` 与 `android-tv-v0.5.29` 的 A/B 对照实机验收（含 `dumpsys gfxinfo framestats` 验证全链路 `>= 50fps`、遥控器长按快进与分片弹幕稳态帧率实测）。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（TV edition，`minSdk 23` / `targetSdk 28`；同字节兼容别名 `MarcoMovie-0.5.30-preview.apk`）。
- **TV APK SHA-256**：`MarcoMovie-0.5.30-android-tv.apk`（`36639635` B）— `bf10e758ca7d5ee8b0ab207a114e206a7a613521def739eaa9c97de21aa75ae5`。
- **对应源码包 SHA-256**：`MarcoMovie-android-tv-v0.5.30-source.zip`（`10694716` B）— `bf212f4fc77844f1ab44795fc5dff3ef0da8d27f64c36c15b7c12c3cf95be242`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`（与既有正式版一致，覆盖安装保留配置、收藏与观看记录）。
- **精确构建提交**：`78017bfb79cf4430681436b53cfcf67b77f44e5b`。[多端构建与校验记录（44857333769）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44857333769)。
- **跨端隔离**：本次发布范围与 Apple TV（`0.1.1`）及 HarmonyOS NEXT（`0.1.1`）无关，两者版本号与代码保持不变。
