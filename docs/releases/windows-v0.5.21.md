# Marco Movie Windows 0.5.21

发布日期：2026-11-15。应用版本：`0.5.21`（构建号 `71`）。本次更新同步上线 4K 网盘 6 路并发分片回环代理、玩偶系 / 四盘聚合源同站死链自动回捞、百度/夸克/UC 网盘子目录解析加固以及本机回环引擎探活自愈与并发 DoH 防污染能力。

## 更新内容

- **4K 网盘 6 路并发分片回环代理（`NetdiskRangeProxy`）**：默认启用 `6 路 × 1 MB` 滑动窗口并发预取（缓存上限 `24 MB`），支持 `HEAD`、`HTTP 206` 精确字节区间与 MKV / MP4 尾部索引跳转即时切换（自动中止旧偏移预取），并在上游网盘直链 `401` / `403` 过期时自动刷新续流。
- **玩偶系 4K 全站适配与同站死链回捞（`WoggNetdiskAdapter`）**：统一适配 20+ 套玩偶系 MacCMS 4K 站点与 PanSou 四盘轮询配额聚合，修复详情页下载容器定位，并在当前条目网盘分享失效或为空时自动并发回捞同站同名备用条目。
- **网盘子目录契约修复与本机脚本引擎防污染自愈**：修复百度分享子目录 `sekey` 透传契约、夸克/UC 临时转存空间回收及压缩包资源识别；内置 CatPaw / DRPY 回环引擎失活自愈、6 Worker 并发搜索隔离与并发 RFC 8484 DoH 清洁 IP 重连。

## 包信息与构建记录

- **安装版（推荐）**：`MarcoMovie-0.5.21-windows-x64-setup.exe`（更新兼容别名 `MarcoMovie-0.5.21-windows-setup.exe`），SHA-256：`2c70981fc3609bd5f8d11c05705119976b7eda1164f63d001a91b5b67741119c`。
- **绿色便携版**：`MarcoMovie-0.5.21-windows-x64-portable.zip`（兼容别名 `MarcoMovie-0.5.21-windows-x64.zip`），SHA-256：`e8ce3235f84b370680c029dbbe6331e3bfea126a7797bb5d2c6bd02c6b6938d3`。
- **对应源码包**：`MarcoMovie-windows-v0.5.21-source.zip`，SHA-256：`0b23a7c652f670543e22595964475256c88410cfe9a800c0bf52e770173455cd`。
- **构建提交**：`97f872dead7413120694bf73211b72967ffb4198`。[多端原生构建与校验记录（43729927928）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43729927928)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Windows x64 原生构建、`libmpv-2.dll` 媒体回放校验及全部 `948` 项 Flutter 自动化测试；更新前请先退出正在运行的旧版程序。
