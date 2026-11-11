# Marco Movie iOS / iPadOS 0.5.22

发布日期：2026-11-11。应用版本：`0.5.22`（构建号 `72`），最低系统要求：iOS / iPadOS 14.0。本次更新集中解决点播与直播防盗链 `403` 拒绝访问、跨域 CDN 跳转丢失动态 `Set-Cookie`、无后缀或图片伪装 HLS 分片无法起播，以及 `parse=1` / `jx=1` 二次解析与动态网页播放页无法提取真实视频流的问题，新增内置本机 `127.0.0.1` 通用媒体流代理网关、三级播放解析器与 iOS 原生无界面 `WKWebView` 媒体嗅探兜底，并补齐 UC / 百度网盘 HLS 改写。

## 核心修复与优化

1. **内置 `127.0.0.1` 通用本地媒体流代理网关（`LocalMediaLease` / `PlayerLocalMediaSession`）**
- 在应用进程内部将远程 HTTP/HTTPS 点播与直播媒体流统一收敛至会话级 `127.0.0.1` 随机端口能力路径供内置播放器读取，由本机网关统一接管防盗链 `Referer`、`Origin`、`User-Agent` 与 RFC-6265 动态 `Set-Cookie` 会话罐。
- 遇到跨域 `301/302/303/307/308` CDN 重定向时自动保留防盗链来源头并严格剥离源站专属敏感凭据（`Authorization`、初始 `Cookie` 等），拦截回环与局域网私有网段重定向及跨站请求；本机系统残留失效代理时自动回退直连。

2. **无后缀 `#EXTM3U` 重写、伪装图片头剥离与分离音轨伴随代理**
- 自动识别 `text/plain` 或无 `.m3u8` 后缀返回的 `#EXTM3U` 主从播放列表，将多码率子列表、媒体分片、`#EXT-X-KEY` 密钥、`#EXT-X-MAP` 初始化段及 `#EXT-X-MEDIA` 独立音轨统一改写至本机代理会话。
- 自动检测并剥离未加密 MPEG-TS 分片头部拼接的伪装 PNG / JPEG / GIF 图片字节，同时完整保留标准 fMP4 与 AES-128 加密分片原始数据；支持将音视频分离伴随音轨（如 DASH `.m4s` `externalAudioUrl`）一并注册至同一网关会话并转发 `206 Partial Content` 分段请求。

3. **三级二次解析与 iOS 原生无界面 `WKWebView` 媒体嗅探（`WebMediaResolver` / `HeadlessMediaWebSniffer`）**
- 重构 `parse=1` / `jx=1` 与非直链播放页解析流程：① 依次轮询片源 `playUrl`、`site.playUrl` 与订阅级 `parses` 解析器列表（支持 `type` 1/2/3 JSON 接口、HTML 包装页及自定义 `ext.header`）；② 纯 Dart 网页直链提取（支持 MacCMS `player_aaaa` / `player_data` `encrypt` 0/1/2、`<video>` / `<source>`、DPlayer / ArtPlayer 配置及双层 `<iframe>` 跟踪）；③ 当静态提取未命中时，自动调用 iOS 原生非持久化静音 `WKWebView`（`marco_movie/web_sniffer`）在后台拦截真实 `.m3u8` / `.mp4` / `.flv` 媒体地址并提取对应域级 `Cookie`、`Referer` 与 `User-Agent`，捕获或超时后立即销毁实例。

4. **片源拉取重定向 `Set-Cookie` 保持、全网盘 HLS 改写与下载解析同步**
- 修复 `CmsClient` 请求订阅与片源接口遇到同域 `302` 重定向时丢失 `Set-Cookie` 的问题；将 `CloudMediaLease` 的 `.m3u8` 播放列表改写与去 `Range` 保护覆盖至夸克、UC、百度全部网盘通道；在本地配置缓存与 `DownloadService` 离线下载任务中完整保留 `parses` 解析器列表。

## 包信息与构建记录

- **未签名 IPA（iPhone / iPad 通用）**：`MarcoMovie-0.5.22-ios-iphone-ipad-unsigned.ipa`（更新兼容别名 `MarcoMovie-0.5.22-ios-unsigned.ipa`），SHA-256：`cd2549c69f3e0dc090c65675d4fd380ad7545cd7d68d4ea6a9d6634b143e600b`。
- **对应源码包**：`MarcoMovie-ios-v0.5.22-source.zip`，SHA-256：`49c884e739e147bc9817faac471cb21fafc1e3bfb5e9ec2a1789c29a15a3afcb`。
- **构建提交**：`738f650d744161e84bf8ba32964da98df65f4bf4`。[多端原生构建与解码校验记录（43023663465）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43023663465) · [跨平台片源回归（43023663411）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43023663411) · [公共内容守卫（43023663275）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43023663275)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Python / JS / CatPaw / T4 共享宿主检查、iOS Xcode 原生 Release 构建及全部 Flutter 自动化测试（覆盖本地媒体代理网关、`parses` 多解析器轮询、MacCMS 播放页提取、`WKWebView` 嗅探通道回退、同域重定向 `Set-Cookie` 保持及全网盘 HLS 重写）。
- 未签名 IPA 支持巨魔（TrollStore）覆盖安装或自签工具签名安装；自动化构建与协议回归不代表已完成 iPhone / iPad 实机及用户私人账号全片验收，涉及站点人机验证、算力验证、图形验证码或 DRM 加密的流仍保持安全拦截。
