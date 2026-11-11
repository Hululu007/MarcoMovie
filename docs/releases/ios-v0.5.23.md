# Marco Movie iOS / iPadOS 0.5.23

发布日期：2026-11-12。应用版本：`0.5.23`（构建号 `73`），最低系统要求：iOS / iPadOS 14.0。本次更新集中修复第三方订阅中大量 `Guard` / `XBPQ` / `XYQ` / `XPath` 规则线路提示「该插件需要相应运行环境」无法使用的问题，将详情选集页（`DetailScreen`）平均约 5 秒的数据拉取耗时压降至秒级响应，并恢复选集页真实豆瓣评分与烂番茄新鲜度胶囊展示（缺失对应数据时自动隐藏）。

## 核心修复与优化

1. **大规模扩展内置纯数据插件与声明式规则引擎适配（不执行外部 DEX / JAR / `.so`）**
- 在无 JIT 的 `NodeMobile`（`--jitless`）沙箱中新增 21 套 `Guard` 纯数据参数提取器与协议适配器（覆盖 `Czzy`、`Hdhive`、`Libvio`、`Nmyswv`、`Wencai`、`App99`、`AppSx`、`Jpys`、`Bili`、`Biliych`、`Alllive`、`Goodomen`、`88kanqiu`、`Cg51`、`DuoDuo`、`Huban`、`Mogg`、`MiMei`、`Taipan`、`XiaoZhan`、`S_zps` 及其 `Guard` 变体，并补齐多版本插件包 `AppTT` 映射与 `mmshare://` 网盘分享目录自动展开）。
- 新增纯 Dart 声明式规则引擎 `CspRuleEngines`（原生支持 `csp_XBPQ`、`csp_XYQ`、`csp_XPath` / `csp_XPathFilter` / `csp_XPathMacFilter` 及带注释/尾逗号的相对路径规则 JSON），补齐 `csp_AppYsV2` 对 `api.php/v1.vod` 接口与 `vod_play_list` 的解析，修复 `csp_Bili` 相对配置路径解析。
- 优化「切换片源」页面体验：自动过滤纯防诈提示横幅与 `Push` 推送伪站点，默认收起底部的 `当前设备未适配 (N)` 折叠分组，并为因系统限制暂不支持的磁力 P2P、人机滑块验证及专用 DRM 短剧组件提供清晰的中文原因说明。

2. **详情选集页（`DetailScreen`）加载全链路提速**
- 进入详情页时立即中断后台搜索与分类翻页任务，释放网络与运行时槽位；为 `JsSourceHost` 增加 `detail` / `play` / `proxy` 高优插队调度，避免选集拉取排队等待慢速目录请求。
- 为 `CmsClient` 引入持久连接池复用（消除重复 TLS 握手开销）、5 分钟详情结果缓存与同影片并发请求合并（Single-Flight）；列表已携带剧集数据的源支持首帧零等待直出选集，网盘分享拉取超时由 `40s` 收敛至 `8s`，推荐卡片聚合匹配改为优先竞速直连点播源（4 路并发、首个有效源胜出即刻返回并取消慢源）。
- 将百科分集简介与剧照等次要外部资料延后至选集加载完成后异步补充，仅在标题含明确季号时触发关联分季检索。

3. **恢复选集页真实豆瓣与烂番茄评分徽章（无数据严格隐藏）**
- 在 `CmsParser` 与 `PosterLoader` 中支持从源站字段及公开影视检索结果中提取经年份与标题核验的真实豆瓣评分（`豆瓣 ★ X.X`）与烂番茄新鲜度（`烂番茄 XX%`），配备 160 条内存缓存与空结果负缓存，避免重复请求。
- 在 iPhone 竖屏与 iPad 横宽屏详情页信息区独立渲染评分胶囊：仅展示存在真实数据的项目，缺失任一评分或两者皆无时严格隐藏对应徽章，绝不生成估算分数。

## 包信息与构建记录

- **未签名 IPA（iPhone / iPad 通用）**：`MarcoMovie-0.5.23-ios-iphone-ipad-unsigned.ipa`（更新兼容别名 `MarcoMovie-0.5.23-ios-unsigned.ipa`），SHA-256：`847edb3b21ae3e4339859072eaaf6e12dfc935e66de73c828728ef8163efd5f4`。
- **对应源码包**：`MarcoMovie-ios-v0.5.23-source.zip`，SHA-256：`c8763a9892ccf33c9c4dcc81a9c7c00387e0df8896cab6fcbabebfc25afc32e7`。
- **构建提交**：`77dc5924f44fb7f8d5f55871f8828997ce6d1e35`。[多端原生构建校验记录（43092631701）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43092631701) · [iOS 内嵌运行时回归（43092631818）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43092631818) · [跨平台片源回归（43092631681）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43092631681) · [公共内容守卫（43092631795）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43092631795)。

## 验证范围与已知限制

- 通过公共内容守卫检查、`node --jitless` 无 JIT 插件常量提取与协议适配回归、Python / JS / CatPaw 共享宿主检查、iOS Xcode 原生 Release 构建及全部 688 项 Flutter 自动化测试（覆盖 21 套 `Guard` 适配器映射、`XBPQ` / `XYQ` / `XPath` / `api.php/v1.vod` 端到端解析、`mmshare://` 展开、详情并发合并与快源竞速、首帧选集直出及豆瓣 / 烂番茄真实评分显隐规则）。
- 未签名 IPA 支持巨魔（TrollStore）覆盖安装或自签工具签名安装；自动化构建与协议回归不代表已完成 iPhone / iPad 实机及用户私人账号全片验收，涉及站点人机验证、算力验证、图形验证码、P2P 磁力内核或专用 DRM 的流仍保持安全拦截。
