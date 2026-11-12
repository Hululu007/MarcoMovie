# Marco Movie macOS 0.5.14

发布日期：2026-11-12。应用版本：`0.5.14`（构建号 `64`）。本次更新正式上线全平台互通的 **`marco-movie-sync` v2 多端网络同步**（支持用户自配 WebDAV 自动云同步与局域网点对点双向直连同步），并包含此前合入的 21 套 `Guard` 纯数据插件适配、`XBPQ` / `XYQ` / `XPath` 规则引擎、选集页秒开提速及真实豆瓣 / 烂番茄评分胶囊恢复。

## 更新内容

- **全平台 `marco-movie-sync` v2 多端网络同步**：支持连接坚果云、NAS、Alist、Nextcloud 等标准 WebDAV 服务实现启动自动拉取与进度/收藏/订阅变更自动推送（支持 `MKCOL` 自动建目录与单调删除墓碑防复活），同时内置 5 分钟随机令牌局域网双向同步服务（`LanSyncServer`），无需云盘即可与同一网络下的 iPhone / iPad、Android 电视/手机或 Windows 电脑点对点双向合并。
- **可选公开订阅源同步与严格隐私隔离**：支持「同时同步我的订阅源配置」开关（默认开启），新 Mac 可一键同步公开订阅仓库、观看历史与收藏列表；关闭时仅同步进度与收藏并保留云端已有订阅。跨端点击缺失片源的历史或收藏自动回退至聚合搜索；隐私空间内容、本机 `file://` 配置、网盘 Cookie / Token 与 Emby 凭据严格保留在本机，绝不外发。
- **片源规则扩展、详情秒开与真实评分胶囊同步**：同步内置 21 套无 JIT `Guard` 协议适配器、纯 Dart `CspRuleEngines`（`csp_XBPQ` / `csp_XYQ` / `csp_XPath*`）与 `api.php/v1.vod` 解析，优化 `DetailScreen` 连接池复用与 4 路快源竞速，并恢复经年份与标题核验的真实豆瓣 / 烂番茄评分徽章（无真实数据时自动隐藏）。

## 包信息与构建记录

- **macOS 桌面应用包（Apple Silicon / Intel）**：`MarcoMovie-0.5.14-macos-desktop.zip`（更新兼容别名 `MarcoMovie-0.5.14-macos.zip`），SHA-256：`f74b08e03c28eea74abbf885ebd32feb93705bda5e9e4e49f80bac199f6d9364`。
- **对应源码包**：`MarcoMovie-macos-v0.5.14-source.zip`，SHA-256：`0db787258fa78e573c68399616e975137ff562fd28a470ecf4b0739a9e630870`。
- **构建提交**：`b851a910ff321820f5ac3354c39387e028de7bdd`。[多端原生构建与校验记录（43147174023）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43147174023)。

## 验证范围与已知限制

- 通过公共内容守卫检查、macOS 原生 Release 构建、打包 `Mpv.framework` 合成媒体回放校验及全部 `691` 项 Flutter 自动化测试。
- 应用压缩包未公证，首次打开请右键选择“打开”；自动化回归不代表已完成物理 Mac 设备及私人账号实机全片验收。
