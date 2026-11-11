# Marco Movie macOS 0.5.13

发布日期：2026-11-11。应用版本：`0.5.13`（构建号 `63`）。本次更新专门解决防盗链片源 `403` 拒绝访问、跨域重定向丢失动态 `Set-Cookie`、无后缀或图片伪装 HLS 分片无法播放，以及 `parse=1` / `jx=1` 二次解析与动态网页播放页无法起播的问题，新增内置本机 `127.0.0.1` 通用媒体流代理网关、三级播放解析器与 macOS 原生无界面 `WKWebView` 媒体嗅探兜底，并同步合入直播包装地址解包、`T4` / `Appgz` / `AppTT` 协议适配与全网盘 HLS 重写。

## 更新内容

- **内置 `127.0.0.1` 通用本地媒体流代理网关（`LocalMediaLease` / `PlayerLocalMediaSession`）**：在应用进程内部将远程点播与直播流统一转发至会话级 `127.0.0.1` 随机端口能力路径供内置 `Mpv.framework` 读取。由网关统一托管防盗链 `Referer`、`Origin`、`User-Agent` 与 RFC-6265 动态 `Set-Cookie` 会话；跨域 `301/302/303/307/308` CDN 跳转时保留防盗链来源头并严格剥离源站敏感凭据，拦截回环及局域网私有地址重定向与跨站浏览器请求，本机残留失效系统代理时自动回退直连。
- **无后缀 `#EXTM3U` 重写、伪装图片头剥离与分离音轨伴随代理**：自动识别无 `.m3u8` 后缀的 `#EXTM3U` 主从播放列表并重写子列表、分片、`#EXT-X-KEY`、`#EXT-X-MAP` 与 `#EXT-X-MEDIA`；自动剥离未加密 MPEG-TS 分片前拼接的伪装 PNG / JPEG / GIF 图片头（完整保留标准 fMP4 与 AES-128 加密分片字节）；支持将分离音轨（如 DASH `.m4s` `externalAudioUrl`）注册至同一本地代理会话并转发 `206 Partial Content` 分段定位。
- **三级二次解析与原生 `WKWebView` 媒体嗅探（`WebMediaResolver` / `HeadlessMediaWebSniffer`）**：对 `parse=1` / `jx=1` 及非直链网页播放地址依次执行：① 片源 `playUrl`、`site.playUrl` 与订阅级 `parses` 多解析器轮询（支持 `type` 1/2/3 JSON 接口、HTML 包装页及自定义 `ext.header`）；② 纯 Dart 网页媒体提取（MacCMS `player_aaaa` / `player_data` `encrypt` 0/1/2、`<video>` / `<source>`、DPlayer / ArtPlayer 及双层 `<iframe>`）；③ 当静态提取未命中时自动启用 macOS 原生非持久化静音 `WKWebView`（`marco_movie/web_sniffer`）捕获真实媒体流地址与域级 `Cookie` / `Referer` / `User-Agent` 后立即销毁视图。
- **片源拉取重定向 `Set-Cookie` 保持、全网盘 HLS 重写与片源协议同步**：修复 `CmsClient` 拉取片源遇到同域 `302` 跳转时丢失 `Set-Cookie` 的问题；扩展 `CloudMediaLease` 对夸克、UC、百度全部网盘 `.m3u8` 分片的重写与去 `Range` 保护；持久化保留订阅与离线下载的 `parses` 配置，并同步合入直播 `proxy://` 解包及 `csp_AppgzGuard` / `csp_AppTTGuard` 直连点播适配。

## 包信息与构建记录

- **macOS 桌面应用包（Apple Silicon / Intel）**：`MarcoMovie-0.5.13-macos-desktop.zip`（更新兼容别名 `MarcoMovie-0.5.13-macos.zip`），SHA-256：`9450c1396cf2240376c59502f51dc77f73a22d623e4fb8f6bc32840218d048d9`。
- **对应源码包**：`MarcoMovie-macos-v0.5.13-source.zip`，SHA-256：`49c884e739e147bc9817faac471cb21fafc1e3bfb5e9ec2a1789c29a15a3afcb`。
- **构建提交**：`738f650d744161e84bf8ba32964da98df65f4bf4`。[多端原生构建与解码校验记录（43023663465）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43023663465) · [跨平台片源回归（43023663411）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43023663411) · [公共内容守卫（43023663275）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43023663275)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Python / JS / CatPaw / T4 共享宿主检查、全部 `677` 项 Flutter 自动化测试，以及 macOS 原生 Release 构建与打包 `Mpv.framework` 合成鉴权及防盗链 HLS 回放回归。
- 应用压缩包（`MarcoMovie-0.5.13-macos-desktop.zip` 及兼容别名 `MarcoMovie-0.5.13-macos.zip`）未公证，首次打开请右键选择“打开”；自动化测试不代表已完成物理 Mac 设备及用户私人账号全片验收，涉及人机验证或 DRM 加密的流仍保持安全拦截。
