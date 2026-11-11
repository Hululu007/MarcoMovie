# Marco Movie macOS 0.5.12

发布日期：2026-11-11。应用版本：`0.5.12`（构建号 `62`）。本次更新同步修复阿里云盘扫码确认后中文昵称 GBK 解码失败、百度网盘带提取码分享播放签名与区域 CDN 跳转、高码率网盘原画起播缓冲超时自动降档、选集详情页备用网盘失效提示折叠与夸克目录误报，以及全站搜索并发读取失败问题。

## 更新内容

- **阿里云盘扫码登录修复与轮询保活**：修复阿里云盘 `bizExt` 内置 GBK 中文昵称导致扫码确认后报“网盘账号验证未完成”的问题，并保持点击跳转授权后的后台二维码状态轮询。
- **百度分享直链与高码率网盘播放加固**：修复带提取码百度分享 `sekey` 二次编码与签名问题，支持 `d.pcs.baidu.com` 区域 CDN 跳转并剥离跨域 `Cookie`；同步合入 `CloudMediaProxy` 探测断连及时回收与首帧起播缓冲超时自动清晰度降档保护。
- **详情页告警折叠与并发搜索优化**：修正夸克分享目录末页误报“目录返回不完整”，已有可用线路时自动折叠跳过的失效备用分享；共享插件包并发单次下载去重与宿主串行解包，消除全站搜索批量“暂时无法读取”。

## 包信息与构建记录

- **macOS 桌面应用包（Apple Silicon / Intel）**：`MarcoMovie-0.5.12-macos-desktop.zip`（更新兼容别名 `MarcoMovie-0.5.12-macos.zip`），SHA-256：`bf1431eba87e317b4379a6921b99bafb809b05e5d148b41e9f27c6b9ce1cd9dd`。
- **对应源码包**：`MarcoMovie-macos-v0.5.12-source.zip`，SHA-256：`a0cc28dddde75b554d332dd96ed6799279dbafaf79e7aeb6db468350469a17de`。
- **构建提交**：`ba5e9a0240af0d2b8dd4a770e65430e4ac861a4a`。[多端构建与门禁检查记录（42967305556）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/42967305556)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Python / JS / CatPaw 共享宿主检查、全部 `658` 项 Flutter 自动化测试及 macOS 原生 `Mpv.framework` 合成鉴权回放回归。
- 应用压缩包（`MarcoMovie-0.5.12-macos-desktop.zip` 及兼容别名 `MarcoMovie-0.5.12-macos.zip`）未公证，首次打开请右键选择“打开”；自动化测试不代表已完成用户私人网盘账号实机全片验收。
