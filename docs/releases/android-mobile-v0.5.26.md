# Marco Movie Android 手机 / 平板 0.5.26

发布日期：2026-11-17。版本代码：`89`。本次更新围绕 Android 手机与平板端的多源搜索滑动流畅度、网盘伪装 `.mp3` 视频播放、浏览器扩展弹幕推送、Android 6 HTTPS 证书兼容及 WebDAV 仅同步订阅源模式进行集中升级。

## 更新内容

- **多源并发搜索滑动流畅度优化（`#45`）**：搜索结果流新增 `220ms` 增量刷新节流，手指按住与上下滑动期间自动延后列表重排，并按 `siteKey + vodId` 复用已构建结果行视图，消除多源并发返回时的跳帧与卡顿。
- **伪装 `.mp3` 视频播放与本地协议兼容（`#31` / `#41` / `#28`）**：`MoviePlayer` 将 MP4 / MKV / FLV / AVI 严格魔数容器提取器置于 `Mp3Extractor` 之前并开放 `.mp3` 的 `#EXTM3U` 嗅探，解决网盘伪装 `.mp3` 视频只出声无画面问题；支持 `clan://` 本地存储协议解析；`CspEngine` 遇到损坏 JAR 自动清理缓存重试一次并输出脱敏诊断信息。
- **扩展推送弹幕与 Android 6 HTTPS 握手修复（`#36` / `#55`）**：`LocalProxy` 新增回环 `/action`（`do=refresh&type=danmaku` / `subtitle`）与 `/proxy?do=danmaku` 弹幕推送接口（保留防跨站 `Origin` / `Sec-Fetch-Site` 校验）；为 API 23（Android 6）注入 `[系统信任库 + ISRG Root X1]` 复合证书链并补齐 `SniOverrideSocketFactory` 全重载 SNI 透传。
- **WebDAV 仅同步订阅源模式（`#44`）**：云端同步新增「仅同步订阅源（隔离观看记录）」开关，开启后仅同步订阅源配置且完整保留远端已有的历史与收藏数据，满足多设备共用订阅但观影记录互不干扰的场景。

## 包信息与构建记录

- **安装包（ARM64 + ARMv7 双架构）**：`MarcoMovie-0.5.26-android-mobile.apk`（更新兼容别名 `MarcoMovie-0.5.26-mobile.apk`），官方正式签名，支持应用内直接覆盖升级。
- **SHA-256**：`8842ecec24f61283479ba6a2ace92ed4786ca43a7193546a5bdd2b3c1a4d93a9`。
- **对应源码包**：`MarcoMovie-android-mobile-v0.5.26-source.zip`，SHA-256：`4084d3dca2987826bc7e6c7d0e9ceabefe6106bb22f8066f292217f984d46bf3`。
- **构建提交**：`a3cbe546c3faa803e6be2b06bbe62b6767e503c9`。[多端原生构建与校验记录（44020396179）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44020396179)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Java 格式检查、纯 JVM 全套离线回归、API 23 字节码与 TLS 检查、16KB 页对齐双架构原生构建及官方正式签名校验。
