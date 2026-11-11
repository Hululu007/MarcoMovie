# Marco Movie Windows 0.5.16

发布日期：2026-11-11。应用版本：`0.5.16`（构建号 `66`）。本次更新专门针对用户反馈的 Windows 端播放 4K 资源“放一秒卡一秒”、同名剧集（如 2026 年《谷雨》）误拉取人物/主播自拍头像，以及全局页面切换与滚动动画掉帧卡顿问题，重构本地代理连续推流与 `libmpv` 4K 硬解缓冲管线、补齐海报人物过滤与年份隔离，并引入 Windows 专属轻量级渲染与过渡快路径。

## 更新内容

- **Windows 4K 连续推流与硬解缓冲重构（消除“放一秒卡一秒”）**：在 `CloudMediaLease`（及夸克、UC、百度网盘流式客户端）与 `LocalMediaLease` 中将单域名连接池提升至 `12`、并发上限提升至 `24`、流式刷写阈值提升至 `4 MiB` 并关闭 `autoCompress` / `bufferOutput`，将 `LocalMediaLease._serveWithPrefixInspection` 从逐分片暂停套接字的 `StreamIterator` 改为单次订阅零停顿直通状态机；在 `PlayerScreen` 中将桌面端 `libmpv` 点播 `demuxer-max-bytes` 提升至 `256 MiB`（`mpv` 内核 `512 MiB`）、预读提升至 `45s–90s`、`cache-pause-wait` 提升至 `4s–5s`（消除缓冲 1 秒即恢复、1 秒即耗尽的锯齿循环），移除默认内核冗余 `+genpts` 开销，启用 Windows `auto-safe` / `d3d11va-copy` 硬解与 `bilinear` 轻量缩放管线，并支持未手动锁定画质时在持续反复缓冲场景下自动平滑降档。
- **海报与剧照精准匹配、人物头像拦截及年份缓存隔离**：修复豆瓣 `subject_suggest` 未过滤 `celebrity` 人物词条导致《谷雨》（2026）等剧集误拉取同名人物/主播自拍（`/view/personage/`、`/celebrity/`、`/avatar/` 等）的问题；新增影视词条类型与年份偏差校验（精确年份优先，剔除偏差 `>= 2` 年的旧同名条目），增强百科人物传记/节气/非影视词条识别并兼容以年代背景开头的剧情简介；全链路透传 `year`（`title@year` 隔离缓存）且禁止仅标题缓存覆盖有效源站海报地址，同时将本地海报磁盘缓存升级至 `marco_poster_cache_v5` 并自动清理旧版污染缓存。
- **Windows 全局 UI 切换动画与滚动高帧率优化**：新增 Windows 桌面渲染快路径，关闭同屏 20–35 处 `GlassworkBackdrop` 的逐帧离屏 `BackdropFilter` 拷贝并替换为感知通透度的深色高光半透明玻璃绘制；新增 `WindowsSmoothPageTransitionsBuilder` 与 `buildApplePageRoute`（185ms 单层 `RepaintBoundary` 轻量过渡）替代高开销双页视差 `CupertinoPageRoute`；将 `AdaptiveShell` 改为按需构建当前激活标签页、消除切页时全屏双层高斯模糊交叉重绘及首页滚动外层全视口 `ShaderMask` `saveLayer`，将详情页桌面端滚动动态模糊改为静态缓存降采样海报 + 轻量遮罩渐变，并将 `PosterLoader` 改为按键精准通知。

## 验证范围与已知限制

- 通过公共内容守卫检查、Python / JS / CatPaw / T4 共享宿主检查，以及全部 `686` 项 Flutter 自动化测试与打包 `libmpv-2.dll` 原生解码回放回归（覆盖 5 MiB 分片零停顿 Range 推流、《谷雨》2026 人物自拍拦截与年份筛选、源站海报保留及 Windows `BackdropFilter` 与路由过渡快路径）。
- 本版本仅发布 Windows x64 安装版与绿色便携版，不变更 Android、macOS 或 iOS 已发布版本。更新前请先退出正在运行的旧版程序；自动化与合成媒体回归不代表已使用用户私人网盘账号对特定第三方原片完成全片实机验收。
