# Marco Movie Android 手机 / 平板 0.7.0

发布日期：2026-11-24。应用版本 `0.7.0`（版本代码 `100`）；最低 Android 6 / API 23，完整提供 `armeabi-v7a` + 16 KB 页面对齐 `arm64-v8a` 双架构原生库。本次为 Android 手机/平板独立工程化后的首个大版本：围绕播放稳定性、弹幕同步、首页海报、隐私数据与订阅一致性、分轨离线 HLS 播放与低空间更新续传完成专项修复与 Codex 多轮独立复审。

## 本次更新

- **离线多段 fMP4 HLS 跨段播放与长清单流式选核（`DownloadManager` / `PlaybackController` / `MobileInlinePlayer`）**：
  - 完整保留分离音轨与多 `#EXT-X-MAP` / `#EXT-X-DISCONTINUITY` 离线 HLS 清单和初始化分段，缺失第二初始化片段或必需音轨时显式报错且绝不误标完成；
  - `PlaybackController` 采用 UTF-8 逐行流式扫描本地离线 `.m3u8`（移除 `512 KiB` 前缀截断，兼容 `master.m3u8` 与旧版直连单文件 `.m3u8`，命中立即短路，零网络 I/O）：全局选择 **MPV** 时，对不兼容的多 `#EXT-X-MAP` / 断点 fMP4 离线 HLS 自动单次回退至 **Media3** 播放，界面显式标注 `Media3（单次回退）` 并完整保留用户的全局 `MPV` 偏好；长单 MAP 离线 HLS、纯 MPEG-TS 与普通 MP4 继续尊重用户选择的内核。
- **弹幕拖动同步、首页海报稳定性与小窗/全屏播放统一（`DanmakuView` / `ImageLoader` / `MobileHomePage` / `PlaybackController`）**：
  - 修复连续拖动及暂停恢复后弹幕冻结停更问题，隐藏、关闭或销毁后立即停止预约绘制；
  - 修复首页首推与网格海报空白、串图及滚动回显异常，过滤过期回调并保护同 URL 多控件绑定；
  - 统一竖屏小窗与全屏的选核、回退、进度持久化与会话校验，防止弱网延迟重连或旧回调篡改当前集；遵循 `AUTO_SWITCH_KERNEL` 开关并在切换内核前保全续播位置；修复释放态与 MPV 路径空指针保护，以及社区 IntroDB v4 毫秒区间与手动片尾剩余时长语义统一。
- **隐私数据、活动订阅、删除墓碑与搜索会话隔离（`ConfigStore` / `SourceController` / `CloudSyncDialog` / `MobileSearchPage`）**：
  - 私密空间搜索历史与播放进度严格隔离不落盘至公开记录；
  - 强化配置快照与偏好一致性，消除订阅/本地 JSON 并发刷新或冷启动中断时的选站与相对地址串源；旧版未记录文档身份的同名本地脚本导入提供「替换 / 保留并新增」选择框保护原首选片源；
  - 接通单删、清空与取消收藏的幂等删除墓碑，防止云同步复活已删记录；多源搜索按查询序号与空间隔离结果并优化增量追加滚动稳定性；完善启动崩溃守卫与故障站跳过恢复，避免迟到旧请求异常误伤健康首选站。
- **低空间更新续传与密钥说明修正（`UpdateManager` / `UpdatePolicy` / `MobileSettingsScreen`）**：
  - 更新下载在校验临时文件有效后按剩余字节与 `16 MiB` 预留空间判断续传，覆盖异常 Range 响应与摘要/签名/手机通道隔离校验；修正 MDBList 密钥存储提示与实际本机私有存储行为一致。

## 验证范围与构建记录

- **生产代码选核与自动化回归（精确构建与审阅提交 `d4b06a0954e24760377d444a83ca51db2dab7a2f`）**：
  - **超过 `512 KiB` 的长清单已通过生产代码选核复验**：以重编 `classes.jar`（`9bd38db1...`）验证 `long-dual`（`532,474 B`，断点位于 `532,128 B`）单次规划至 `Media3`，`long-single`（`532,421 B`）与长纯 MPEG-TS 保留 `MPV`；
  - 全套 `53/53` 项手机端自动化回归测试（Zulu JDK 17.0.20.1）首跑全通过（`0` 重跑、`0` 失败），公开内容守卫、README 版本校验、`format_java --check` 与 `git diff --check` 全部通过。
- **Android 16 真机实测记录（最终签名 APK `fb816102...`，已核对机内 `base.apk` 哈希一致）**：
  - **离线双 MAP HLS 跨段播放（通过）**：在 Android 16 真机（Xiaomi 14 Ultra，`arm64-v8a`）从「离线下载 → 播放」验证自然播放跨过 12 秒及重开后连续拖动 `16s → 3s → 18s`，画面（`640×360` ↔ `960×540`）与 `AudioFlinger` 活跃音轨（`44.1 kHz` ↔ `48 kHz`）均正常切换推进，离线期间媒体网络请求增量为 `0`；全局选 `MPV` 时本次播放回退到 `Media3`（界面标明 `Media3（单次回退）`），全局偏好保留为 `MPV`；
  - **沿用同机已通过记录**：`#60` 弹幕（Android 16 连续 6 次拖动与暂停恢复同步）、`#71` 首页海报（18 张 `type=1` CMS 首推/网格/详情/滚出滚回无空白无串图），以及全局 `Media3` 双 MAP、单 MAP 离线 HLS（实跑 `MPV`）、普通 MP4（实跑 `MPV`）与受控故障源恢复均已通过。
- **单列待验证项（相关 Issue 保持开放）**：
  - 正式版 `0.6.0 (98)` 覆盖升级（含非空收藏留存及旧版同名本地脚本「替换 / 保留并新增」，待独立测试机验收）；
  - Android 17 ARM 真机上的 `#72` / `#73`（Java 空指针与原生 `SIGABRT` 分别待验）；
  - `#14` / `#2` 原用户反馈片源样本；
  - 息屏试听。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（Mobile edition，`minSdk 23` / `targetSdk 28`；提供同字节兼容别名 `MarcoMovie-0.7.0-mobile.apk`）。
- **Mobile APK SHA-256**：`MarcoMovie-0.7.0-android-mobile.apk`（`100544980` B）— `fb816102d5a15a1ea8d000827a0ddd1efc4b7212565c5413ccec3302e366a2db`。
- **对应源码包 SHA-256**：`MarcoMovie-android-mobile-v0.7.0-source.zip`（`16691388` B）— `c94ac6709e0d56027e35348b7c6325925eefc513f3539cca9494c469b472f0a5`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`（与既有正式版一致，覆盖安装保留本地配置与观看记录）。
- **精确构建提交**：`d4b06a0954e24760377d444a83ca51db2dab7a2f`。
- **跨端隔离**：本次仅独立发布 Android 手机/平板（`android-mobile-v0.7.0`），其余平台版本保持各自独立节奏不变。
