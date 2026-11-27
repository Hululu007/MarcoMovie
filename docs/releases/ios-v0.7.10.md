# Marco Movie iOS / iPadOS 0.7.10

发布日期：2026-11-27。应用版本 `0.7.10`（构建号 `103`），继续提供**双包并行构建与 App 内自动分流更新**：主包基于 Xcode `26.6`（`iphoneos26.5` SDK，支持原生 iOS 26 / 27 Liquid Glass，`MinimumOSVersion = 15.0`），同步产出面向 iOS / iPadOS `14.0+` 设备的独立兼容包（Xcode `16.4` / `iphoneos18.5` SDK，`MinimumOSVersion = 14.0`）。本次版本落地与 Windows / Android 移动端完全统一的三端 `MMAILAB1` Ed25519 离线口令门禁与「AI 观影实验室」五大核心场景及双鉴权接入、更新后首次启动防骗与自愿赞助弹窗、设置页「支持开发者」卡片、Dock 长按气泡朝上避让与快捷菜单扩充、播放 HUD 底栏收纳与加高「更多」面板、全新透明流光丝带开屏融接动画、iPad 桌面图标冷启动黑屏修复，以及含中文路径的订阅源地址兼容解析。

## 更新内容

- **落地三端统一的 `MMAILAB1` Ed25519 离线口令门禁与「AI 观影实验室」五大核心场景**：
  - **跨端通用 RFC 8032 Ed25519 纯离线口令门禁**：与 Windows、Android 移动端共用唯一正式验签公钥与 `marco-ai-lab-v1:` 域分隔协议，手机离线发码器签出的一枚三端通用口令可在三端直接解锁；完整支持 `plat` 多平台组合（如 `all`、`ios,android`、`ios,windows`）、`shared`、`exp_oauth`、`min_vc` 与过期自动重锁（`nowSec > exp`），本机仅持久化已签名口令原文且每次启动重新离线验签。未解锁默认态仅在「设置 → 通用」展示单行收口入口「AI 观影实验室（内测中 · 输入口令开启）」，隐藏所有未解锁 AI 入口并在 `AiService` 层硬性拦截绕过；口令弹窗支持剪贴板自动提取口令与跳转官方交流频道【Marco交流区】（`https://pd.qq.com/s/N45e3aaawv?b=9`），解锁后支持随时更换口令或退出内测重新锁定。
  - **个人 API + 实验性订阅账号 PKCE 双鉴权与在线模型选择器**：支持标准 OpenAI 兼容（Chat Completions / Responses，自动适配 `o1` / `o3` / `o4` / `gpt-5` 推理模型参数）、Anthropic Messages 与 Google Gemini 协议，同时支持由 `exp_oauth` 口令权限管控的实验性 GPT 订阅账号 OAuth 2.0 PKCE 登录（本机回环回调与手动粘贴双通道，凭据仅存系统 Keychain），内置 `/models` 实时模型列表拉取与搜索选择，并修复设置子页滚动时顶栏文字重叠。
  - **五大核心观影 AI 场景与自定义提示词技能**：上线「AI 字幕工坊」（外挂字幕双语精翻与双语时间轴校准）、「零剧透剧集伴侣」（严格按当前观看集数边界生成前情提要与人物关系卡）、「多源画质优选与网盘选集整理」（跨站点清晰度排序及网盘正片/花絮自动归类）、「今晚看什么 · 心情策展官」（仅在用户自有片库与收藏历史中按氛围推荐，严格拦截任何外部 URL 输出）与「智能排障医生」（脱敏网络/解码日志诊断建议），并支持自定义快捷提示词技能。
- **新增每次更新后首次启动防骗与赞助弹窗及「关于与更新」支持卡片**：
  - **更新后首次打开温和提示（`PostUpdateWelcomeDialog`）**：每次版本升级后首次进入应用展示一次，包含永久免费防售卖/「激活码」防骗提醒、认准唯一官网更新渠道（`marcotv.wlj9919.top`）及自愿赞助快捷入口（直达 `https://marcotv.wlj9919.top/movie/#donate`），隐私空间解锁态静默且与全新安装首次声明自动去重。
  - **设置「关于与更新」支持开发者卡片**：新增克制真诚的支持说明卡片与直达官网捐赠区快捷按钮（无浏览器时自动复制链接提示）。
- **优化底部 Dock 长按气泡朝上弹出并丰富四栏快捷操作菜单**：
  - 修复 Flutter 液态玻璃 Dock 长按气泡向下遮挡 Dock 的问题，统一改为锚定在对应按钮正上方 `12pt` 向上弹出；
  - 扩充四个标签页长按快捷菜单：`主页`（搜索影片、切换片源、刷新主页、回到顶部）、`直播`（导入直播源、管理直播源、刷新频道列表、隐藏失效频道）、`片库`（继续上次播放、收藏、观看历史、离线下载、添加资源库）、`设置`（添加资源库、管理订阅、网盘账号、多端同步，以及解锁态 AI 观影实验室）。
- **精简播放页底部 HUD 控制栏并加高「更多」气泡面板**：将底部低频按钮（响度增强、音轨选择、播放内核切换等）统一收纳进右上角「更多」面板，底栏仅保留选集、倍速、字幕、弹幕与画面比例等高频操作；保持「更多」气泡宽度不变并将纵向最大可用高度提升至屏幕高度的 `78%`（上限 `560pt`），减少面板内滚动拥挤。
- **重做无方框透明流光丝带开屏动画并修复 iPad 桌面冷启动黑屏**：
  - **全新高级感开屏过渡**：移除旧版方形底板图标，绘制无边框透明金属丝带 `M` 标志（`LOGO_MARK`），配合细腻微光呼吸与进入主页时的平滑缩放消融过渡；
  - **修复 iPad 从主屏幕图标打开偶发黑屏卡住**：移除 iOS / iPadOS 启动入口对非本端 `OhosRuntime` 通道探测的同步等待以确保首帧在启动事务内立即上屏，并在原生 `AppDelegate` / `MarcoFlutterViewController` 补齐 `UIScene` 激活与窗口尺寸就绪后的首帧重绘唤醒。
- **修复含中文路径与非 ASCII 字符的订阅源地址无法解析**：在 `CmsClient` 请求入口新增 `_normalizeHttpUri` 百分号编码归一化（保留既有合法转义与锚点参数，自动编码 `/聚合/api.json` 等中文路径段），完善 `text/plain` 仓库原始配置响应 UTF-8 解码兼容。

## 包信息与构建记录

- **未签名主包（iOS / iPadOS 15.0+，原生 iOS 26 / 27 Liquid Glass SDK）**：`MarcoMovie-0.7.10-ios-iphone-ipad-unsigned.ipa`（`69468545` B，兼容别名 `MarcoMovie-0.7.10-ios-unsigned.ipa`，两者字节级完全相同），SHA-256：`ead1f601731a4d382d86846bfba49576469bc51d58af668ca0d18141e5eb2881`。
- **未签名兼容包（iOS / iPadOS 14.0+ 通用兼容版）**：`MarcoMovie-0.7.10-ios14-unsigned.ipa`（`69467034` B），SHA-256：`03b015dca08e5953fd81c3ec9152c1f9dc195c63d13eecaa35825df66cf2481e`。
- **对应源码包**：`MarcoMovie-ios-v0.7.10-source.zip`（`22096812` B），SHA-256：`ef176088babe6484d4f13fd3b4cecbe9dda678bd3e9e8e597eccaf5cec659c11`。
- **构建提交与 CI 记录**：`b7f8d2c5de5bddd25ed2956ec11ca325ea5b2c7c`（已合入 `main`）。[iOS 15.0+ 主包构建（Job 140244315468 · Run 45918436566）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45918436566/job/140244315468) / [iOS 14.0+ 兼容包构建（Job 140244315426 · Run 45918436566）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45918436566/job/140244315426) / [公开守卫与离线校验（Job 140243153066）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45918436566/job/140243153066)。

## 验证范围与已知限制

- **自动化与云端构建校验**：在提交 `b7f8d2c5de5bddd25ed2956ec11ca325ea5b2c7c` 上通过了 `Build Multiplatform` 双 IPA 工作流（Run `45918436566`：`Public Guardrails & Offline Java Checks` 含 `2779` 个追踪文件公开合规、`README.md` 版本对齐与 Flutter 3.38.9 三端一致性测试 + `macos-26` / Xcode `26.6` / `iphoneos26.5` `MinimumOSVersion = 15.0` 主包构建与全量 `1690` 项 `flutter test` 单测通过、`18` 项跳过 + `macos-15` / Xcode `16.4` / `iphoneos18.5` `MinimumOSVersion = 14.0` 兼容包构建），核对双包 `Info.plist` 版本 `0.7.10 (103)`、`MinimumOSVersion`（`15.0` / `14.0`）及全部 8 项发布资产 SHA-256 一致；新增 `ios_0710_feedback_test.dart`（含真实手机离线发码器三端通用口令验签、多平台范围拦截、过期自动重锁、未解锁态入口隐藏及本轮全部 UI/解析回归）与 `test_brand_icon.py` 专项测试。本轮尚未在全型号物理 iPhone / iPad 真机上完成覆盖升级、iPad 桌面冷启动与真实外部 AI 服务商在线穷尽实测验收。
- **已知限制**：未签名 `.ipa` 需通过 TrollStore（巨魔）或个人自签工具安装；`MarcoMovie-0.7.10-ios-iphone-ipad-unsigned.ipa` 与 `MarcoMovie-0.7.10-ios-unsigned.ipa` 为同一份 iOS 15.0+ 主包（后者为旧版应用内更新兼容别名），手动安装任选其一即可；iOS 14.x 设备请使用 `ios14-unsigned.ipa` 兼容包（应用内检查更新会自动匹配）；AI 观影实验室处于内测阶段需口令开启，且不内置任何第三方接口密钥，需用户自行配置合规凭据后使用。
