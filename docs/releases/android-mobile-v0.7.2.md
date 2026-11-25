# Marco Movie Android 手机 / 平板 0.7.2

发布日期：2026-11-25。应用版本 `0.7.2`（版本代码 `102`）；最低 Android 6 / API 23，完整提供 `armeabi-v7a` + 16 KB 页面对齐 `arm64-v8a` 双架构原生库。本次为 Android 手机/平板端官方渠道防伪提示与作者反馈入口升级版本。

## 本次更新

- **安装后首次启动官方渠道与安全防伪弹窗（`MobileAuthorNotice` / `MainActivity` / `CrashReportDialog`）**：
  - 安装后首次正常启动展示影院曜石底部抽屉弹窗，清晰呈现作者各社媒统一账号名 **`PILIPALA来信`**（`小红书`、`B站`、`抖音`、`公众号`、`视频号`，支持一键复制账号名）、Marco 官网 **`marcotv.wlj9919.top`**（支持直接访问或复制网址），并突出提示防伪安全提醒：**「下载软件请认准官网地址，以防不明渠道软件添加病毒等不良内容。」**
  - 使用独立本机状态文件（`marco_first_launch_notice`）按版本号严格控制仅在首次正常启动弹出一次（不改动 `Prefs.KEYS` 46 项备份结构）；隐私空间内与异常恢复期间自动静默，展示期间避免与启动崩溃弹窗叠加，全新安装关闭弹窗后无缝衔接 5 幕新手引导。
- **设置页新增「联系与反馈作者」与官网交流群入口（`MobileSettingsScreen` / `MobileSettingsIndex`）**：
  - 设置首页「互联与系统」新增直达入口 **「联系与反馈作者（PILIPALA来信）」**，一键打开完整社媒账号、Marco 官网与官网交流群面板；
  - 设置「存储、备份与关于」新增独立分组 **「联系与反馈作者」**，提供 **「各社媒账号名（PILIPALA来信）」**、**「官网交流群（`https://marcotv.wlj9919.top/movie/#group`）」** 与 **「Marco 官网（`marcotv.wlj9919.top`）」**；外部跳转严格限定官方 HTTPS 域名，本机无浏览器时自动降级复制链接至剪贴板；
  - 设置顶栏搜索索引完整收录 `PILIPALA来信`、`小红书`、`B站`、`抖音`、`公众号`、`视频号`、`交流群`、`反馈`、`marcotv.wlj9919.top` 等关键词直达高亮。

## 验证范围与构建记录

- **全量自动化回归与守卫（精确构建提交 `85571cd1aa31a3f4a1f2f983e5fdebb7d3cf63ff`）**：
  - 全部 `55/55` 项 `android-mobile/tests/run_*.py` 手机端回归测试（Zulu JDK 17.0.20.1）全部通过，含 `MobileUiRedesignChecks`（`197/197`，新增 7 项首次启动一次性状态机、隐私空间抑制、单次关闭回调、官方 HTTPS 白名单、设置搜索索引与代码接线断言）、`MobileCodexReviewChecks --verify-apk`（`59/59` + 最终 APK DEX 零 `putIfAbsent` + 双 ABI 16 KB Python 扩展校验 + v4 `.idsig` 三组验收）、`ReviewFixChecks`（`62/62`，`Prefs.KEYS == 46`）、`OnboardingStateChecks`（`114/114`）、`Wave2AndroidWireChecks`（`441/441`）与 API 23 字节码校验；
  - `scripts/format_java.py --check`（`605` 文件）、`scripts/sync_readme_versions.py --check`、`scripts/check_public_content.py`（`2216` 文件）与 `git diff --check` 全部通过；
  - 官方正式签名（`v1/v2/v3/v4 = true`）、`zipalign` 与 16 KB 对齐校验全部通过。
- **Android 16 真机实机预览（Xiaomi 14 Ultra，`arm64-v8a`）**：
  - 同代码正式签名 `0.7.2`（`102`）预览包已在小米 14 Ultra 上完成 `0.7.1 → 0.7.2` 同签名无损覆盖安装并实拍确认首次启动「官方渠道与安全提示」弹窗排版、社媒标签、官网地址与安全提示均正常显示。
- **硬件边界说明**：
  - 受现有物理设备条件限制，Android 6（API 23）真机、纯 32 位 `armeabi-v7a` 真机与 16 KB 内核页真机继续由静态 DEX / ELF 校验与 JVM 自动化测试覆盖。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（Mobile edition，`minSdk 23` / `targetSdk 28`；提供同字节兼容别名 `MarcoMovie-0.7.2-mobile.apk`）。
- **Mobile APK SHA-256**：`MarcoMovie-0.7.2-android-mobile.apk`（`100745684` B）— `71c90eabfc308094d454e30ddbf28cb663e39e6156ed65ea28a73b4a0c381e21`。
- **对应源码包 SHA-256**：`MarcoMovie-android-mobile-v0.7.2-source.zip`（`17258825` B）— `21c3c932ef588dccc272b67cbb4a278156da3723ba23dc7ad382d8c2d5a75193`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`（与既有正式版一致，覆盖安装保留本地配置、收藏与观看记录）。
- **精确构建提交**：`85571cd1aa31a3f4a1f2f983e5fdebb7d3cf63ff`。
- **跨端隔离**：本次仅独立发布 Android 手机/平板（`android-mobile-v0.7.2`），其余平台版本保持各自独立节奏不变。
