# Marco Movie Windows 0.5.15

发布日期：2026-11-11。应用版本：`0.5.15`（构建号 `65`）。本次更新专门针对用户反馈的防盗链 `403` 拒绝访问、跨域重定向丢失动态 `Set-Cookie`、无后缀或图片伪装 HLS 分片解码失败，以及 `parse=1` / `jx=1` 二次解析与网页播放页无法起播等问题，新增内置本机 `127.0.0.1` 通用媒体流代理网关与多阶段播放直链解析器，同时补齐 UC / 百度网盘 HLS 播放列表重写与离线下载解析器配置持久化。

## 更新内容

- **内置 `127.0.0.1` 通用本地媒体流代理网关（`LocalMediaLease` / `PlayerLocalMediaSession`）**：在应用内部将远程点播与直播 HTTP/HTTPS 媒体流统一收敛至会话级 `127.0.0.1` 随机端口能力路径供内置 `libmpv` 读取。由网关在进程内统一接管防盗链 `Referer`、`Origin`、`User-Agent` 与 RFC-6265 动态 `Set-Cookie` 会话罐；遇到跨域 `301/302/303/307/308` CDN 跳转时自动保留防盗链来源头并严格剥离源站专属凭据（`Authorization`、初始 `Cookie` 等），同时拦截跳往本机回环或局域网私有网段的异常重定向及跨站请求。
- **无后缀 `#EXTM3U` 重写、伪装图片头剥离与音视频分离伴随流代理**：自动探测 `text/plain` 或 `application/octet-stream` 下返回的无后缀 `#EXTM3U` 主从播放列表，将子播放列表、媒体分片、`#EXT-X-KEY` 密钥、`#EXT-X-MAP` 初始化段及 `#EXT-X-MEDIA` 音轨统一改写至本机代理；自动识别并剥离未加密 MPEG-TS 分片前拼接的伪装 PNG / JPEG / GIF 图片头（完整保留标准 fMP4 与 AES-128 加密分片字节）；支持将分离音轨（如 DASH `.m4s` `externalAudioUrl`）一并注册至同一网关会话并支持 `206 Partial Content` 分段定位，本机残留失效系统代理时自动回退直连。
- **多阶段二次解析与网页直链提取器（`WebMediaResolver`）**：重构 `parse=1` / `jx=1` 及非直链播放页解析链路，支持按顺序轮询片源自带 `playUrl`、`site.playUrl` 与订阅级 `parses` 解析器列表（兼容 `type` 1/2/3 JSON 接口、HTML 包装页及自定义 `ext.header` 请求头），并内置纯 Dart 网页媒体提取（支持 MacCMS `player_aaaa` / `player_data` 的 `encrypt` 0/1/2 解码、`<video>` / `<source>`、DPlayer / ArtPlayer 配置提取及双层 `<iframe>` 跟踪）。
- **片源拉取重定向 `Set-Cookie` 保持、全网盘 HLS 重写与下载解析同步**：修复 `CmsClient` 拉取订阅与片源接口遇到同域 `302` 重定向时丢失 `Set-Cookie` 防护凭证的问题；将 `CloudMediaLease` 的 `.m3u8` 分片改写与去 `Range` 保护从夸克扩展至夸克、UC、百度全部网盘通道；在订阅缓存与 `DownloadService` 离线任务中持久化保留 `parses` 解析配置。

## 包信息与构建记录

- **安装版（推荐）**：`MarcoMovie-0.5.15-windows-x64-setup.exe`（更新兼容别名 `MarcoMovie-0.5.15-windows-setup.exe`），SHA-256：`3714fadaf6113f6c4966af972eae6e10f89addfde1e73b52e06d32001ad48575`。
- **绿色便携版**：`MarcoMovie-0.5.15-windows-x64-portable.zip`（兼容别名 `MarcoMovie-0.5.15-windows-x64.zip`），SHA-256：`6de8c3dcf6b5a9c69b9ccfd2ebcf75079424f7433965e6ddd14448ffefb009aa`。
- **对应源码包**：`MarcoMovie-windows-v0.5.15-source.zip`，SHA-256：`49c884e739e147bc9817faac471cb21fafc1e3bfb5e9ec2a1789c29a15a3afcb`。
- **构建提交**：`738f650d744161e84bf8ba32964da98df65f4bf4`。[多端原生构建与解码校验记录（43023663465）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43023663465) · [跨平台片源回归（43023663411）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43023663411) · [公共内容守卫（43023663275）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43023663275)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Python / JS / CatPaw / T4 共享宿主检查，以及全部 `677` 项 Flutter 自动化测试与打包 `libmpv-2.dll` 合成媒体回放回归（覆盖跨域 `302` 防盗链与凭据隔离、无后缀 `#EXTM3U` 与动态 `Set-Cookie` 原生回放、伪装 PNG 头 TS 剥离、分离音频 `Range` 转发、`parses` 多解析器轮询、MacCMS `player_aaaa` 解码及 UC / 百度 HLS 重写）。
- 更新前请先退出正在运行的旧版程序。自动化与合成媒体回归不代表已使用用户私人账号或特定第三方加密站点完成全片实机验收；涉及站点人机验证、算力验证、图形验证码或 DRM 加密的流仍保持安全拦截并按实际状态提示。
