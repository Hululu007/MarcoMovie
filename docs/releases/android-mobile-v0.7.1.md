# Marco Movie Android 手机 / 平板 0.7.1

发布日期：2026-11-25。应用版本 `0.7.1`（版本代码 `101`）；最低 Android 6 / API 23，完整提供 `armeabi-v7a` + 16 KB 页面对齐 `arm64-v8a` 双架构原生库。本次为 Android 手机/平板端界面重构与核心网络/诊断/脚本稳定性升级版本，完成 Codex 多轮独立复审与 Android 16 真机前台验收。

## 本次更新

- **全新影院曜石移动 UI 架构、原创发现首页与无阶梯顺滑动效（`MobileRootShell` / `MobileHomePage` / `MobileDetailScreen` / `MobileMotion` / `MobilePosterTransition` / `MobileBottomSheet`）**：
  - 全面重构手机/平板端影院曜石视觉体系、悬浮毛玻璃底部/侧边 Dock 与 `MobileIcons` 原生矢量图标；修复底部 Dock 上弹扩展时的阶梯状弹跳，统一为平滑物理曲线；
  - 上线原创发现精选内容流与海报专题墙（`MobileCuratedDiscovery` / `MobileCuratedSection` / `MobileCuratedWallScreen` / `MobileFavoritePostcard` / `MobileFilterSheet`），优化海报卡片点击展开详情与返回时的无弹跳连续转场；
  - 重构分级设置页索引与二级配置流（`MobileSettingsScreen` / `MobileSettingsIndex`）、新版新手引导、单次防连点确认底部抽屉及播放器 HUD / 触控手势与细进度条细节。
- **DoH 并发选路、POST 幂等保护与跨域重定向健壮性修复（`Cms` / `RequestScope`）**：
  - 修复 Android 6（API 23）在 DoH 地址去重路径调用 API 24+ `LinkedHashMap.putIfAbsent` 的兼容性问题，改用 API 23 安全去重并保持 IPv4 优先与先到先序；
  - 修复表单 `POST` 发出后因换 UA 或转 DoH 导致的重复提交问题：请求体已发出后遇 HTTP 错误或超时立即停止重试，仅在建立 TCP 连接前失败时故障转移至健康 DoH IP；
  - 强化订阅与 `.py` 脚本拉取的多 IP 竞速与跨域重定向：单 IP 返回 404 或缺 `Location` 时不重复试探且保留真实错误；多 IP 竞速时快失败 500 或 200 HTML 拦截页不会取消慢成功健康节点；同域重定向锁定当前健康 IP，跨域重定向重新走 DoH 解析并剥离 `Authorization` / `Cookie`，目标域节点跳转登录页 HTML 或异常 302 后继续回退剩余候选 IP 且保留 5 跳上限；DoH 竞速线程池施加有界并发（上限 `12`）并支持 `RequestScope` 即时取消。
- **崩溃日志智能提醒策略与单次上报保护（`CrashReportStore` / `CrashReportDialog`）**：
  - 仅在明确确认前台异常退出（含前台 LMK）时触发启动提醒，过滤已确认后台内存回收（`importance >= 400`），同时保留无法判定前后台的旧版报告及已提交 Issue 记录不被误删；
  - 按报告唯一 ID 去重记录已提示状态（抵御系统时钟回拨与同毫秒报告），避免重复弹窗打扰；上报按钮引入单次消费防连点守卫，杜绝快速双击触发重复提交或迟到关闭回调覆盖已提交状态；支持返回键、点击遮罩与下拉手势顺畅关闭。
- **插件回调引用计数、内置 CPython 3.11 双 ABI 缓存隔离与构建交付加固（`CspEngine` / `NativePythonEngine` / `build_android_mobile.py`）**：
  - 修复插件初始化期间跨子加载器 `Activity` 同步时未就绪/失败插件越界发布、以及同一回调多次注册后单次注销导致有效子加载器失去同步的问题，改为按回调对象引用计数并在初始化结束后释放临时引用；
  - 为内置 CPython 3.11 `lib-dynload` 缓存印记纳入 ABI 标识并在缺失 `.so` 扩展时自动重新解压，避免 32/64 位切换引发 `_ssl` 等扩展加载异常；
  - 修复干净基线构建时 `urllib3 2.2.3` 源码归档地址（保持固定 SHA-256 校验）、`libmarco_python.so` 纯 SONAME 链接及构建产物全量回读与 APK v4（`.idsig`）强制验签。

## 验证范围与构建记录

- **自动化回归与构建守卫（精确构建提交 `aecbd9593d2e931caec129db5d941a1301e66024`）**：
  - 全套 `55/55` 项 `android-mobile/tests/run_*.py` 自动化回归测试（Zulu JDK 17.0.20.1）全部通过，含 `MobileCodexReviewChecks`（`59` 项行为回归 + 最终 APK DEX 零 `putIfAbsent` 检查 + 双 ABI Python 扩展对齐校验 + v4 `.idsig` 正确/错配/缺失三组验收）、`MobileUiRedesignChecks`（`190` 项）、API 23 字节码校验与更新隔离检查；
  - `scripts/format_java.py --check`（`604` 个 Java 文件）、`scripts/sync_readme_versions.py --check`、`scripts/check_public_content.py`（`2211` 文件）与 `git diff --check` 全部通过；
  - 官方正式签名（`v1/v2/v3/v4 = true`）、`zipalign` 与 16 KB ZIP 对齐校验全部通过。
- **Android 16 真机前台验收记录（Xiaomi 14 Ultra，`arm64-v8a`）**：
  - 与本次生产代码等价的 Codex 复审候选 `b3134e32` 在小米 14 Ultra 真机前台通过全部 3 项验收并经独立复核：① 连续 2 次冷启动进入首页零误弹崩溃提醒，手动打开诊断抽屉后返回键、点击遮罩、下拉手势均正常关闭；② 清空导入框后通过系统剪贴板粘贴订阅地址重新导入并实时刷新成功；③ 切换 `.py` Python 爬虫站点进入详情并点击播放，双帧截图画面与进度连续推进，高通 AVC 硬件解码器 5.406 秒渲染 `268` 帧、丢帧 `0`（`60 fps`），`48 kHz` 立体声音频正常输出，全程零崩溃。
- **硬件边界说明**：
  - 受现有物理设备条件限制，Android 6（API 23）真机、纯 32 位 `armeabi-v7a` 真机及 16 KB 内核页真机目前仅通过静态 DEX / ELF 对齐校验与 JVM 自动化测试覆盖，未声称完成对应硬件实机验收；其余在 `0.7.0` 中单列的 Android 17 真机等历史待验项亦保持透明保留。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（Mobile edition，`minSdk 23` / `targetSdk 28`；提供同字节兼容别名 `MarcoMovie-0.7.1-mobile.apk`）。
- **Mobile APK SHA-256**：`MarcoMovie-0.7.1-android-mobile.apk`（`100737492` B）— `08c4b0ae437500ec42e2b5c24c6bb087fd75e51c5004afb8a7a1028e57faac11`。
- **对应源码包 SHA-256**：`MarcoMovie-android-mobile-v0.7.1-source.zip`（`17228898` B）— `dc3c7eb1ab53f18f129713bdcf71991979e47420ec137bdeec4d9d40c543efd2`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`（与既有正式版一致，覆盖安装保留本地配置、收藏与观看记录）。
- **精确构建提交**：`aecbd9593d2e931caec129db5d941a1301e66024`。
- **跨端隔离**：本次仅独立发布 Android 手机/平板（`android-mobile-v0.7.1`），其余平台版本保持各自独立节奏不变。
