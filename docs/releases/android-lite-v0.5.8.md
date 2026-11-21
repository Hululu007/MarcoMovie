# Marco Movie Android Lite 0.5.8

> **发布说明草案**：发布日期待定；应用版本 `0.5.8`（versionCode `58`）。专为 Android 4.0+（API 14+）老旧电视、机顶盒与老手机打造的超轻量单 DEX 独立版本（包名 `com.pilipala.marcomovie.lite`，可与标准版共存）。待正式签名打包及老旧盒子 A/B 对照验收后补齐构建记录。

## 更新内容

- **详情元数据行与线路胶囊纯文字规格标签（`LiteBadges`）**：在严格不引入图片资源、第三方库或复杂动画的前提下，新增纯 Java API 14 兼容的 `LiteBadges` 规范引擎；在 `LiteActivity` 详情页元数据行（最多 `4` 项）与播放线路选择胶囊（最多 `3` 项）自动提取并拼接纯文字媒体规格标签（如 `4K · HDR10 · DD+ 5.1`），与标准版及桌面/iOS 端共享同一套 `45` 条匹配规则与 `3` 条组合规则，保留字面量 `'+'` 号（正确识别 `HDR10+`、`DD+`）。
- **超轻量单 DEX 兼容性保持不变**：保持仅做规格标签增量接入，不引入分片弹幕渲染层、着色器转场、极光背景或引导动画，继续维持 API 14 单 DEX 架构、Conscrypt TLS + `ISRG Root X1` 根证书兼容、DLNA / 网页投屏接收、手机扫码搜索与线路分组编删能力。

## 包信息与构建记录

- **安装包（待正式构建）**：`MarcoMovie-0.5.8-android-lite.apk`（更新兼容别名 `MarcoMovie-0.5.8-lite.apk`），包名 `com.pilipala.marcomovie.lite`。
- **SHA-256 / 源码包 / 构建记录**：待正式签名打包后填入。

## 验证范围与已知限制

- **已完成自动化验证（基于 `feat/ux-integration-20261120 @ 82f38cd2`）**：通过 `check_public_content.py`（`1507` 文件）、`scripts/test_lite_jvm.py`（API 14 `bootclasspath` 编译与 `D8 --min-api 14` 单 DEX 校验、`194` 项 TV Lite JVM 回归及 `8` 项 TLS 能力检查）、`scripts/test_lite_conformance.py`（`20` 项三端一致性套件中 `18` 项通过、`2` 项 Lite 配置跳过）以及 `MediaBadgeChecks`（验证 `LiteBadges` 与 `MediaBadges` 在 `165/165` 黄金样例上完全零差异）。
- **待完成验证**：尚待写入新版本号构建正式包并核验最终单 DEX 字节大小与方法数增量，以及在 Android 4.x 物理旧盒子上对照 `android-lite-v0.5.7` 完成实机焦点与冷启动验收。
