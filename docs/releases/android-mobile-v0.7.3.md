# Marco Movie Android 手机 / 平板 0.7.3

发布日期：2026-11-28。应用版本 `0.7.3`（版本代码 `103`）；最低 Android 6 / API 23，完整提供 `armeabi-v7a` + 16 KB 页面对齐 `arm64-v8a` 双架构原生库。本次为 Android 手机 / 平板端综合功能升级与 17 轮独立复审稳定性加固版本。

## 本次更新

- **三端统一 `MMAILAB1` Ed25519 离线口令门禁「AI 观影实验室」**：
  - 与 Windows / iOS 完全对齐同一套 RFC 8032 Ed25519 离线口令载荷规范（支持多平台组合、`shared`、`exp_oauth`、`min_vc` 与过期自动重锁）；未解锁时在设置页收敛隐藏明细能力并全链路拦截未授权推理请求，隐私空间硬性阻断。
  - 支持自备 API Key（BYOK）与实验性 PKCE OAuth 双鉴权，同步配套离线 HTML 发码器（加密密钥库持久化与双库校验）。
- **默认网盘优先级排序、个人媒体库、4K 拖动与四向可定制 Dock**：
  - 新增可视化默认网盘优先级排序面板并自动作用于详情页默认播放线路；补齐个人网盘/媒体文件夹浏览、4K 拖动响应、Android 16 Media3 ABR 轨解析与自动弹幕同步开关一致性。
  - 平板与折叠屏新增顶部 / 底部 / 左侧 / 右侧四向可定制悬浮 Dock，优化搜索、直播分栏与播放 HUD 交互。
- **跨站精准续播、多端同步与 Windows 稳定标识互通**：
  - 升级 `HistoryResumeMatcher` 优先核验集名/线路名/片名中的季集身份再应用同盘偏好；同站原盘消失（剧集与单集电影）或候选无法辨季时不再误换盘或串季，等待用户明确选择。
  - 对齐 Dart / Java 路径与查询参数归一化规则（含空格、字面加号、编码路径与同名文件），实现正式 Windows `0.7.3+` ↔ Android 双向续播完整保留 `episodeMediaId` 并修复仅订阅同步无损合并。
- **详情页手选同步、线路管理与离线缓存精准去重**：
  - 竖屏直点剧集卡、后台分季迟到返回及置顶/移动/隐藏非当前线路后，按稳定 `lineId` 同步主按钮文案、目标与分页；隐藏当前手选线路后严格保持「等待重选」，打开离线缓存默认勾选 `0` 集。
  - 详情页向离线缓存选择器传递确切剧集对象/媒体身份；`DownloadManager` 支持同名异源媒体指纹区分与旧 4 段任务键无损迁移，规范查询参数时对不同业务键排序、对同键多值保留原始次序，并识别剥离七牛私有链接配套 `e` + `token` 授权参数（同时保留无凭证 `e=1` / `e=2` 分集区分）。
- **每次更新后官方防伪与自愿赞助提示**：
  - 升级后首次正常启动温和展示一次永久免费防伪提醒、唯一官方更新渠道（`marcotv.wlj9919.top`）与自愿赞助入口，同步补齐作者腾讯视频号社媒标识。

## 验证范围与硬件边界

- **精确构建提交与复审闭环**：构建提交 `5abee50a7815b42c29291eb7fb3d1928b4556ff7`（`git_dirty: false`，`android-tv/`、`lite/`、`flutter/`、`macos/`、`shared/` 相对 `origin/main` 零改动），历经 17 轮独立复审（最终 P0 = 0、P1 = 0）。
- **合并后构建与全量自动化复验**：
  - `scripts/format_java.py --check --paths android-mobile`（`641` 个 Java 文件）、`scripts/sync_readme_versions.py --check`、`scripts/check_public_content.py`（`2837` 个追踪文件）全部通过；
  - `run_mobile_codex_review_checks.py --verify-apk`（终版 APK DEX API 23 零禁用符号 + CPython `3.11.17-0` 双 ABI `stamp=3873e0f948966bc8` + `.idsig` v1/v2/v3/v4）、`run_mobile_detail_primary_button_checks.py`（`121` + `11` 真实队列回归）、`run_download_security_checks.py`、`run-query-audit.py`（4/4 用例 `acceptance=PASS`）、`run_ios_077_parity_checks.py`（`22` 套件）、`run_ai_beta_checks.py --require-node`（`154` 项）、`run_mobile_ui_redesign_checks.py`（`217` 项）、`run_cloud_sync_checks.py`（`96` 项）全部通过；
  - 同分支第 17 轮候选 `9768c4a8` 亦完成官方 `windows-v0.7.3` Dart ↔ Android Java 双向实跑（`22/22` 向量 + 3 组同名文件 WoGG 闭环）、冷进程弹幕/兼容/守卫/直播/Emby 与无头 Edge 发码器实测。
- **物理真机与边界如实说明**：
  - Xiaomi `24031PN0DC`（Android 16，`arm64-v8a`）最近一次物理真机装机与冷启动通过（`202ms`，零崩溃）对应第 15 轮候选 `49cd2f08` 产出包（SHA-256 `1a6bff76cb41f853d8c05cd899421b1a2037a76d08b27d945f85b48c8937f3c6`）；最终合并发布提交 `5abee50a` 的终版 APK（`f0e06d02...`）因发布时该设备离线尚未再次装机。
  - Android 6（API 23）物理老机型、纯 32 位 `armeabi-v7a`、16 KB 内核页与折叠屏真机由静态 DEX/ELF 校验及 JVM 自动化测试覆盖。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（Mobile edition，`minSdk 23` / `targetSdk 28`；提供同字节兼容别名 `MarcoMovie-0.7.3-mobile.apk`）。
- **Mobile APK SHA-256**：`MarcoMovie-0.7.3-android-mobile.apk`（`100979156` B）— `f0e06d02f87e566ca908c75dfc75517f914ee300de3fbf9f4269a62efdca7bb2`。
- **APK v4 签名文件**：`MarcoMovie-0.7.3-android-mobile.apk.idsig`（`804262` B）— `5b06df7658ab8afec35646a493ff58c0904ab294f3e3c93517b1055e5db860b5`。
- **对应源码包 SHA-256**：`MarcoMovie-android-mobile-v0.7.3-source.zip`（`23147534` B）— `912f51b9536ec114ebce7faa3e9a45e9641674a1d02926c0a3bc476c2bf8e71c`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`（`v1/v2/v3/v4 = true`，与既有正式版一致，覆盖安装保留本地配置、收藏与观看记录）。
- **精确构建提交**：`5abee50a7815b42c29291eb7fb3d1928b4556ff7`。
- **跨端隔离**：本次仅独立发布 Android 手机 / 平板（`android-mobile-v0.7.3`），其余平台版本保持各自独立节奏不变。
