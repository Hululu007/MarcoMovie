# Marco Movie iOS / iPadOS 0.7.8

发布日期：2026-11-26。应用版本 `0.7.8`（构建号 `101`），继续提供**双包并行构建与 App 内自动分流更新**：主包基于 Xcode `26.6`（`iphoneos26.5` SDK，支持原生 iOS 26 / 27 Liquid Glass，`MinimumOSVersion = 15.0`），同步产出面向 iOS / iPadOS `14.0+` 设备的独立兼容包（Xcode `16.4` / `iphoneos18.5` SDK，`MinimumOSVersion = 14.0`）。本次为纯 iOS / iPadOS 专项修复，重点解决底部 Dock 长按误选整条与气泡偏移、资源库排版与图标统一性、片库筛选空/裸序号按钮，以及 iPad Pro 2020（iPadOS 15.4）异常发热问题。

## 更新内容

- **修复 iOS 底部 Dock 长按整条被选中且气泡固定靠左**：在 `MarcoNativeLiquidTabCapsuleView` 中为每个 Tab 槽位建立独立 `previewPillView`，触发长按前清理并复位滑块透镜动画，补齐 iOS 16+（`highlightPreviewForItemWithIdentifier` / `dismissalPreviewForItemWithIdentifier`）与 iOS 13–15（`previewForHighlightingMenuWithConfiguration` / `previewForDismissingMenuWithConfiguration`）定向预览代理，并在 `touchesBegan` 重置上下文菜单状态。长按单个按钮（如右侧「设置」）时仅抬起该按钮，并在其正上方就近弹出快捷菜单。
- **重做「添加资源库」对称网格排版与统一风格图标**：将 4 组资源库调整为左右 `16pt` 对称外边距的等高圆角卡片网格（图标与 2 行标题居中，2 / 3 / 4 列下左右卡片与图标边距严格对称，一屏内排布更紧凑）；重绘全部 13 个资源库图标为统一圆角方圆（squircle）风格，同时赋予 13 套互不重复的配色与专属几何符号（Emby、Jellyfin、Plex、WebDAV、SMB、AList / OpenList、夸克、UC、百度、阿里、当前设备、手动输入、本地配置包）。
- **修复「片库筛选」异常空白与裸序号按钮**：在 [ios_filter_sheet.dart](../../flutter/lib/ui/ios_filter_sheet.dart)、[adaptive_shell.dart](../../flutter/lib/ui/adaptive_shell.dart) 与原生 `MarcoNativeFilterSheetController` 双端同步过滤空白、零宽/控制字符、纯符号、空 ID、孤立序号及重复「全部」项；将上游片源中紧随分组出现的裸续页序号（如 `热门电影①` 后的 `②`、`③`，或 `好莱坞` 后的 `①`–`⑤`）自动补全前缀为完整标签，确保一级分类聚合与顶部已选摘要显示清晰准确。
- **优化 iPad Pro 2020（iPadOS 15.4）及旧版 iOS 异常发热（仅 iOS 端）**：
  - 停止 `AppleAmbientBackground` 在 iOS 120Hz ProMotion 屏幕上的常驻后台呼吸空转（并补充浅色模式、退后台、非当前路由及减弱动态效果自动暂停），海报氛围改用无 `ShaderMask` 且模糊半径上限 `24` 的轻量层；`AuroraBackground` 在 iOS 端限帧至约 30fps 并在热降频时立即停止。
  - `GlassworkBackdrop` 在 iOS `< 26` 回退路径禁用 54-tap `glasswork.frag` 片元着色器、收紧模糊 `sigma <= 10` 并改用 `TileMode.clamp`；通过 `ProcessInfo.thermalStateDidChangeNotification` 实时桥接系统热状态，设备进入 `.serious` / `.critical` 热压时平滑关闭 `BackdropFilter` 降级为半透明面罩（不重建子组件树）。
  - 去除 iOS 竖屏播放器背景的双重全屏模糊叠加（改为 `RepaintBoundary` 缓存单层 `sigma = 22` 海报模糊），并在详情页 iOS `< 26` / 热降频 / 滚动模糊期间避免嵌套 `ShaderMask + BackdropFilter`。
  - `DeviceQualityProfiler` 补全 `iPad8,1`–`iPad8,12`（含 `iPad Pro 11"/12.9" (2020)`）型号识别并收紧非 M 系列 iPad 的超分默认门槛；`IosMpvProfile` 为 iOS `< 16` 或热降频设备自动启用低温播放档位（关闭逐帧 `hdr-compute-peak` 与 `dither-depth`，使用 `video-sync=audio`）。

## 包信息与构建记录

- **未签名主包（iOS / iPadOS 15.0+，原生 iOS 26 / 27 Liquid Glass SDK）**：`MarcoMovie-0.7.8-ios-iphone-ipad-unsigned.ipa`（`69100959` B，兼容别名 `MarcoMovie-0.7.8-ios-unsigned.ipa`，两者字节级完全相同），SHA-256：`13417aa1320839aaa8544f5aea6d4e4997efb3efa473c1893388e1c683854a79`。
- **未签名兼容包（iOS / iPadOS 14.0+ 通用兼容版）**：`MarcoMovie-0.7.8-ios14-unsigned.ipa`（`69100517` B），SHA-256：`3c5790b3ef537b9288c8ca43ee1da53883480afe81d13aea7316c5847385abbb`。
- **对应源码包**：`MarcoMovie-ios-v0.7.8-source.zip`（`21705365` B），SHA-256：`852d7a10592b8e71d9c360dbf604f2420da5a66348ab5a3181eb45f0c85080dd`。
- **构建提交与 CI 记录**：`4b38952f249e01bff9de2bf8c9c70931b2bdd0ea`（已快进合入 `main`）。[iOS 15.0+ 主包构建（Job 139834064798 · Run 45797469001）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45797469001/job/139834064798) / [iOS 14.0+ 兼容包构建（Job 139834064780 · Run 45797469001）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45797469001/job/139834064780) / [公开守卫与离线校验（Job 139831711183）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45797469001/job/139831711183)。

## 验证范围与已知限制

- **自动化与云端构建校验**：在提交 `4b38952f249e01bff9de2bf8c9c70931b2bdd0ea` 上通过了 `Build Multiplatform` 双 IPA 工作流（Run `45797469001`：`Public Guardrails & Offline Java Checks` 含 `2739` 个追踪文件公开合规与 `README.md` 对齐校验 + `macos-26` / Xcode `26.6` / `iphoneos26.5` `MinimumOSVersion = 15.0` 主包与全量 `1574` 项 `flutter test` 通过、`15` 项非 iOS 跳过 + `macos-15` / Xcode `16.4` / `iphoneos18.5` `MinimumOSVersion = 14.0` 兼容包），并核对双包 `Info.plist` 版本 `0.7.8 (101)`、`MinimumOSVersion`（`15.0` / `14.0`）与全部资产 SHA-256 一致；新增 `flutter/test/ios_077_feedback_regressions_test.dart` 与 `flutter/test_ios_package.py` 回归测试覆盖本次 4 项修复。本轮尚未在物理 iPhone（iOS 26+）与 iPad Pro 2020（iPadOS 15.4）实机上完成覆盖升级与连续静置/播放测温验收。
- **已知限制**：未签名 `.ipa` 需通过 TrollStore（巨魔）或个人自签工具安装；`MarcoMovie-0.7.8-ios-iphone-ipad-unsigned.ipa` 与 `MarcoMovie-0.7.8-ios-unsigned.ipa` 为同一份 iOS 15.0+ 主包（后者为旧版应用内更新兼容别名），手动安装任选其一即可；iOS 14.x 设备请使用 `ios14-unsigned.ipa` 兼容包（应用内检查更新会自动匹配）；第三方直播源、网盘与片源可用性取决于用户自行导入的上游服务及网络环境。
