# Marco Movie Android Lite 0.5.4

发布日期：2026-11-12。应用版本：`0.5.4`（versionCode `54`）。专为 Android 4.0+（API 14+）老旧电视、机顶盒与老手机打造的超轻量独立版本（包名 `com.pilipala.marcomovie.lite`，可与标准版共存），本次更新同步接入全平台互通的 **`marco-movie-sync` v2 多端网络同步**。

## 更新内容

1. **兼容 API 14 老设备的 `marco-movie-sync` v2 多端同步（`LiteSync`）**
- 在保持单 DEX 超小体积与 Android 4.0+（TLS 1.2 兼容）最低要求的前提下，完整支持标准 WebDAV 自动云同步（含原生套接字 `MKCOL` 多级建目录、启动静默拉取与进度/收藏变更自动推送）及局域网点对点双向同步（`/<token>/sync`）。
- 顶栏新增「同步」快捷胶囊、首页新增「多端网络同步」入口，老盒子或老电视无需繁琐遥控打字，用手机局域网配对或连接同一 WebDAV 即可双向同步观看进度与收藏。

2. **多端公开订阅源无损互通与跨源搜索回退**
- 开启「同时同步我的公开订阅源配置」时，Android Lite 可直接拉取手机或电脑端的公开 JSON / XML / 多仓订阅配置一键启用；当云端存有标准版或桌面端的多份订阅时，Lite 写回云端会自动完整保留全部次要订阅条目，绝不覆盖丢失其他设备的多仓/多源配置。
- 打开外端同步的观看历史或收藏条目而当前源不存在对应站点时，自动回退至跨站全局搜索；导出订阅时自动剥离隐私标记与隐私分组条目。

## 包信息与构建记录

- **安装包**：`MarcoMovie-0.5.4-android-lite.apk`（更新兼容别名 `MarcoMovie-0.5.4-lite.apk`），官方正式签名。
- **SHA-256**：`a83807940add47514e3a9cef2d51648588dd5cb4fae72fc16b0fb2e7f4aae8ae`。
- **对应源码包**：`MarcoMovie-android-lite-v0.5.4-source.zip`，SHA-256：`0db787258fa78e573c68399616e975137ff562fd28a470ecf4b0739a9e630870`。
- **构建提交**：`b851a910ff321820f5ac3354c39387e028de7bdd`。[多端原生构建与校验记录（43147174023）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43147174023)。

## 验证范围与限制

- 通过公共内容守卫检查、API 14 `bootclasspath` 与 D8 `--min-api 14` 单 DEX 编译校验、`67` 项 TV Lite JVM 离线回归（含 v2 多订阅无损保留、隐私条目剥离、局域网双向同步与 WebDAV `MKCOL` 校验）、3 项 TLS 能力检查及官方正式签名校验；未声明实体老旧电视实机验收。
