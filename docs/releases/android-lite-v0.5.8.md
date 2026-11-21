# Marco Movie Android Lite 0.5.8

发布日期：2026-11-21。应用版本 `0.5.8`（versionCode `58`）。专为 Android 4.0+（API 14+）老旧电视、机顶盒与老手机打造的超轻量单 DEX 独立版本（包名 `com.pilipala.marcomovie.lite`，可与标准版共存），本次更新在零第三方库/动画引入的前提下落地与标准版完全一致的纯文字媒体规格标签（`LiteBadges`）。

## 更新内容

- **详情元数据行与线路胶囊纯文字规格标签（`LiteBadges`）**：在严格不引入图片资源、第三方库或复杂动画的前提下，新增纯 Java API 14 兼容的 `LiteBadges` 规范引擎；在 `LiteActivity` 详情页元数据行（最多 `4` 项）与播放线路选择胶囊（最多 `3` 项）自动提取并拼接纯文字媒体规格标签（如 `4K · HDR10 · DD+ 5.1`），与标准版及桌面/iOS 端共享同一套 `45` 条匹配规则与 `3` 条组合规则，保留字面量 `'+'` 号（正确识别 `HDR10+`、`DD+`）。
- **超轻量单 DEX 兼容性保持不变**：保持仅做规格标签增量接入，不引入分片弹幕渲染层、着色器转场、极光背景或引导动画，继续维持 API 14 单 DEX 架构、Conscrypt TLS + `ISRG Root X1` 根证书兼容、DLNA / 网页投屏接收、手机扫码搜索与线路分组编删能力。

## 包信息与构建记录

- **安装包**：`MarcoMovie-0.5.8-android-lite.apk`（`1279136` B，更新兼容别名 `MarcoMovie-0.5.8-lite.apk`），包名 `com.pilipala.marcomovie.lite`，`compile_api: 14` / `min_api: 14`。
- **APK SHA-256**：`3884d1522374b9d0a8b77a92dd361955cad6de96d164e53df60304d408560942`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`（支持 `v1/v2/v3` 签名，直接覆盖既有 Lite 版本）。
- **对应源码包 SHA-256**：`MarcoMovie-android-lite-v0.5.8-source.zip`（`10698244` B）— `e620844e9ca35eab844110f260ef9b4d0e6e19565ddd150b32ae6c17454f4019`（附构建报告 `build-report.json`）。
- **构建提交与 CI 记录**：`78017bfb79cf4430681436b53cfcf67b77f44e5b`。[多端构建与校验记录（44857333769）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44857333769) / [公开守卫记录（44857333149）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44857333149)。

## 验证范围与已知限制

- **已完成自动化构建与校验**：在 `78017bfb79cf4430681436b53cfcf67b77f44e5b` 通过 API 14 `bootclasspath` 与 `D8 --min-api 14` 单 DEX 编译、`194` 项 TV Lite JVM 回归、`8` 项 TLS 能力检查、`1513` 追踪文件公开守卫、官方正式签名校验及 GitHub Actions 多端流水线校验（全任务通过）。
- **待完成真机验证**：尚未在物理 Android 4.x 旧盒子上对照 `android-lite-v0.5.7` 完成实机焦点与冷启动验收。
