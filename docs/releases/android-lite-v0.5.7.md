# Marco Movie Android Lite 0.5.7

发布日期：2026-11-17。应用版本：`0.5.7`（versionCode `57`）。专为 Android 4.0+（API 14+）老旧电视、机顶盒与老手机打造的超轻量独立版本（包名 `com.pilipala.marcomovie.lite`，可与标准版共存），本次更新支持直接导入单采集站 MacCMS 接口地址，并延续完整的老设备 TLS 证书兼容与局域网投屏能力。

## 更新内容

- **单采集站 MacCMS 接口直接导入（`#55`）**：当导入地址直接返回单站 MacCMS JSON（`code`/`list`/`class`）或苹果 CMS XML（`<rss>`/`<list>`）数据时，`LiteCatalog` 自动清洗临时筛选参数并包装为独立站点卡片，无需额外编写包含 `sites` 数组的外层订阅配置文件即可直接浏览与搜索。
- **超轻量老设备兼容保障**：保持 API 14 单 DEX 架构、内置 Conscrypt TLS + Let's Encrypt `ISRG Root X1` 根证书信任链、DLNA / 网页投屏接收、手机扫码搜索输入与订阅线路分组编删能力。

## 包信息与构建记录

- **安装包**：`MarcoMovie-0.5.7-android-lite.apk`（更新兼容别名 `MarcoMovie-0.5.7-lite.apk`），官方正式签名。
- **SHA-256**：`41fdad3070f4b88d5ab68cc9fd0176935d8428ba99fa365e01e26a4b78329826`。
- **对应源码包**：`MarcoMovie-android-lite-v0.5.7-source.zip`，SHA-256：`faab2c634c65d721f9ae71336dd43c0b168cae14c01fc0a714f3de3334a6df6b`。
- **构建提交**：`a3cbe546c3faa803e6be2b06bbe62b6767e503c9`。[多端原生构建与校验记录（44020396179）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44020396179)。

## 验证范围与已知限制

- 通过公共内容守卫检查、API 14 `bootclasspath` 与 D8 `--min-api 14` 单 DEX 编译校验、`194` 项 TV Lite JVM 离线回归、20 项三端规范一致性测试、8 项 TLS 能力检查及官方正式签名校验；未声明实体老旧设备穷举验收。
