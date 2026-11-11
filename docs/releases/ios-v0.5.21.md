# Marco Movie iOS / iPadOS 0.5.21

发布日期：2026-11-11。应用版本：`0.5.21`（构建号 `71`），最低系统要求：iOS / iPadOS 14.0。本次更新集中修复 iOS 实机反馈的电视直播报错、iOS 系统风格多级设置页面重构、版本号归位至「关于与更新」、`T4` 插件包 `guard_artifact_invalid` 报错，以及「切换片源」全屏二级页面与 `Appgz` / `AppTT` 直连点播插件适配。

## 核心修复与优化

1. **电视直播目录解析、代理过滤与多线路播放修复**
- 解包 `proxy://do=live&type=txt&ext=...` 与本地回环 `/proxy?do=live&type=txt&ext=...` 包装地址，自动还原真实远程直播订阅链接；对依赖外部本机 `127.0.0.1` 专用插件代理的直播源在 iOS 端自动识别过滤并提供清晰中文提示，不再显示原始 `SocketException: Connection refused` 报错。
- 当本机系统残留失效本地 HTTP 代理（`127.0.0.1:<port>` 拒绝连接）时自动绕过失效代理直连拉取；直播播放器固定 `1.0x` 倍速、禁用点播续播与片头片尾跳过，并在单频道含多条备用源时起播失败自动切换下一线路。

2. **原生 iOS 系统设置风格多级页面重构与版本号归位**
- 移除一级「设置」页顶部的版本号副标题，将应用名称与版本号统一展示在「关于与更新」二级页面内，并将软件更新检查卡片直接内嵌至「关于与更新」页面中。
- 将 iOS 端各级设置项、订阅管理、隐私空间、Emby 媒体库、网盘账号中心、「切换片源」与「管理线路」全部由液态玻璃浮层弹窗重构为原生 iOS 系统设置风格全屏 `CupertinoPageRoute` 二级 / 三级页面（`#1C1C1E` 圆角分组卡片、`29×29` 圆角彩色图标、左上角 `< 设置` / `< 返回` 导航与边缘侧滑返回，彻底消除底部 Dock 重叠遮挡）。

3. **修复 iOS 端 `T4` 点播源 `guard_artifact_invalid` 报错**
- 修复 iOS `NodeMobile` 无 ICU（`--without-intl`）环境下 `new TextDecoder('utf-8', { fatal: true })` 抛出 `ERR_NO_ICU` 导致 `奶酪`、`光影` 等 `csp_T4Guard` / `csp_T4` 站点误报 `插件包格式无效 (guard_artifact_invalid)` 的问题，改为不依赖 ICU 的纯 JS 严格 RFC 3629 UTF-8 解码校验。

4. **新增 `AppTT` 协议适配并开放 `Appgz` 直连点播源**
- 修复内置 `SourceHttp` 发送 `POST` 请求未附带明确 `Content-Length` 导致部分上游网关断开连接的问题。
- 新增 `csp_AppTTGuard` / `csp_AppTT`（如「热播 | 多线」）纯数据配置提取与参数化协议适配，并在 `GuardSource` / `CspBridge` 中正式启用 `csp_AppgzGuard` / `csp_Appgz`（如「瓜子 | 不卡」）与 `csp_AppTTGuard` / `csp_AppTT` 直连点播源（涉及站点人机验证、算力验证、图形验证码或共享账号凭据的插件仍保持安全拦截）。

## 包信息与构建记录

- **未签名 IPA（iPhone / iPad 通用）**：`MarcoMovie-0.5.21-ios-iphone-ipad-unsigned.ipa`（更新兼容别名 `MarcoMovie-0.5.21-ios-unsigned.ipa`），SHA-256：`4b0bacde4326ef1ca082bfae4164da8f54ffa6c74fd84c7f7cc7d7f24ee93325`。
- **对应源码包**：`MarcoMovie-ios-v0.5.21-source.zip`，SHA-256：`c8a178a0fd97d6850c1dc7b182253aeafedc83e9c3f202754fa59e3fdfb42b7a`。
- **构建提交**：`6b2c7b7c0972d54c1159a5f941fc6c62c957b0a2`。[多端构建与门禁检查记录（43002694017）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43002694017)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Python / JS / CatPaw / Guard 启动器与无 ICU UTF-8 解码回归测试，以及全部 Flutter 自动化测试（覆盖 iOS 三级系统设置导航、关于与更新版本号展示、全屏切换片源与管理线路二级页、直播代理过滤与多线路回退、`T4` / `Appgz` / `AppTT` 插件配置隔离）。
- 未签名 IPA 支持巨魔（TrollStore）覆盖安装或自签工具签名安装；自动化构建与协议测试不替代所有第三方直播源与实机网络环境的长期可用性承诺。
