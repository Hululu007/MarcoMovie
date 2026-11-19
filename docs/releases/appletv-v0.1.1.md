# Marco Movie Apple TV 0.1.1

发布日期：2026-11-19。应用版本：`0.1.1`（构建号 `2`），最低系统要求：tvOS 16.0。本次更新将 Apple TV 剧集详情页全面升级为全屏沉浸式影院布局，重构大屏选集页网格与分页体验，并为原生 tvOS QuickJS-NG 引擎补齐 DRPY2、60+ 套 Guard 数据适配器及 CatPaw 加密源本机执行能力（无外部 Node 依赖）。

## 更新内容

- **沉浸式剧集详情页（`DetailView`）**：以全屏动态海报剧照画布铺底并融合当前客厅柔光主题与多段渐变遮罩，保留左上角轻量返回胶囊与右上角 `Marco Movie` 标识；主视觉区集中展示片源/年份/分类/4K 原画徽标、大字号片名、观看进度条、简介与高对比度续播/选集/收藏/网盘扫码操作栏，底部悬浮玻璃坞承载多线路切换（`4K 云盘` 与 `HLS` 徽标）及横向分集快览。
- **全屏选集页布局重构（`EpisodeSelectionView`）**：新增独立清晰顶栏（返回、片名与当前线路集数、正/倒序、云盘扫码），在居中磨砂影院卡片内提供多线路切换、未授权网盘快捷登录横幅、每页 20 集分组胶囊（`1-20` / `21-40` …）与 **5 列 × 4 行零溢出玻璃选集网格**，遥控方向键单屏直选任意剧集，续播集高亮显示观看百分比与蓝色进度条。
- **原生 QuickJS-NG 引擎补齐 DRPY2 / Guard / CatPaw 加密源与 WEX/FTY 同步资产**：新增纯 Swift `CatPawCrypto`（基于 `CommonCrypto` 实现 AES-CBC/ECB/CTR 等对称加解密）与 `DrpyGuardHost`，在 `QuickJSBridge` 中扩展 `mm_http_request`、多编码解码与脚本适配桥接，并在 `.ipa` 内直接打包 `26` 项 `catpaw/` 脚本资产与 `6` 项 `js-host/` 公共库，彻底消除“缺少 CatPaw 本机运行组件”提示。
- **动态版本注入与构建一致性**：`tvos/prepare_tvos.py` 改为自动读取 `flutter/edition-versions.json` 写入 Xcode `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`，确保安装包内 `Info.plist` 与发布版本严格一致。

## 包信息与构建记录

- **未签名 IPA（Apple TV / tvOS 16.0+）**：`MarcoMovie-0.1.1-tvos-appletv-unsigned.ipa`（更新兼容别名 `MarcoMovie-0.1.1-appletv-unsigned.ipa`），SHA-256：`fef4c3f2cb0e8fc6c8f938b4f037a2831aac697d1208529175aa0fb8153d3ab6`。
- **对应源码包**：`MarcoMovie-appletv-v0.1.1-source.zip`，SHA-256：`0e10b18b05487f29ea61eca6651964b045452e89fa1861c830e279eff5fb47c4`。
- **构建提交**：`7b7239320e50e9c7f42eadca90be297b89e4b696`。[多端原生构建与校验记录（44516706715）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44516706715) · [公共内容守卫检查（44516706686）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44516706686) · [Apple TV 4K 模拟器实机视觉验收（44502110728）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44502110728)。

## 验证范围与已知限制

- 通过公共内容守卫检查、macOS 原生 `swift test` 全部 `14` 项单元测试（覆盖 QuickJS-NG + DRPY2 / Guard / CatPaw 加密协议、CMS 解析、网盘凭据校验、6 路 Range 回环代理及 HDR 轨道识别）、Xcode `appletvos` Release 构建与包内 `Info.plist`（`0.1.1` / build `2`）及 `catpaw/`（`26` 项）/`js-host/`（`6` 项）完整性自检，以及 Apple TV 4K 模拟器 9 场景 1080p 截图验收。
- 已知限制：发布包为未签名 `.ipa`，需通过 Xcode、Sideloadly、自签工具或巨魔（TrollStore tvOS）安装；受 tvOS 系统沙盒限制不支持 Android JAR 插件、JIT 执行或持久化大缓存；自动化、模拟器及云端构建校验不代表物理 Apple TV 硬件与第三方私有账号完整长片人工验收。
