# Marco Movie Android Lite 0.5.5

发布日期：2026-11-14。应用版本：`0.5.5`（versionCode `55`）。专为 Android 4.0+（API 14+）老旧电视、机顶盒与老手机打造的超轻量独立版本（包名 `com.pilipala.marcomovie.lite`，可与标准版共存），本次更新新增订阅源各线路手动分组编删、电视搜索手机扫码输入、老电视 DLNA / 网页投屏接收及旧系统根证书 TLS 兼容加固。

## 功能与同步

- 顶部导航栏与首页快捷栏新增「投屏」入口（`LiteCast`），在 API 14+ 单 DEX 轻量环境下同时支持 UPnP / DLNA 标准媒体投屏接收（手机视频 App 搜索「Marco Movie Lite」直投）与局域网扫码网页直投及遥控（播放/暂停/进度跳转/音量调节）。
- 搜索页新增「手机扫码输入」按钮，手机扫描电视屏幕二维码即可网页输入片名推送至老电视直接触发搜索，告别老旧遥控器逐字拼写。
- 内置 Conscrypt TLS 引擎与 Let's Encrypt `ISRG Root X1` 根证书复合信任链，解决 Android 4.0–7.0 老电视因系统根证书过期无法拉取 HTTPS 订阅源与海报的问题，并加固局域网配对服务 5 分钟自动过期保护。

## 片源与播放

- 线路管理页支持分组胶囊筛选、手动新建/分配单条或批量线路分组、手动编辑单条线路（名称、分组、API、解析 `playUrl`、扩展 `ext`、可搜索开关及恢复默认）、删除单条/批量删除线路与恢复已删线路；刷新订阅后自动保留自定义设置。
- 解除配置拉取 `identity` 限制并支持透明 GZIP 解压、双 UA 回退、20 项三端订阅解析一致性对齐及不可用线路灰显具体原因说明。

## 包信息与构建记录

- **安装包**：`MarcoMovie-0.5.5-android-lite.apk`（更新兼容别名 `MarcoMovie-0.5.5-lite.apk`），官方正式签名。
- **SHA-256**：`1df8e73937c37fcc8c65ac08ac5051515b023b0577baadf916fb02216aa81e9a`。
- **对应源码包**：`MarcoMovie-android-lite-v0.5.5-source.zip`，SHA-256：`90255894dc49d9416af602a4075147e8706fdb0052a642adc19507ad34b26c85`。
- **构建提交**：`9a7cba393e69825031ac29230cb5afa1e0961d41`。[多端原生构建与校验记录（43575866858）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43575866858)。

## 验证范围与已知限制

- 通过公共内容守卫检查、API 14 `bootclasspath` 与 D8 `--min-api 14` 单 DEX 编译校验、`193` 项 TV Lite JVM 离线回归（含 DLNA / 网页投屏、搜索扫码输入、线路分组编删）、20 项三端规范一致性测试、8 项 TLS 能力检查及官方正式签名校验；未声明实体老旧电视实机穷举验收。
