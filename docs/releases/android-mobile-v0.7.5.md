# Marco Movie Android 手机 / 平板 0.7.5

发布日期：2026-11-28。应用版本 `0.7.5`（版本代码 `105`）；最低 Android 6 / API 23（`arm64-v8a` + 16 KB 页面对齐 `armeabi-v7a` / `arm64-v8a` 双架构原生库）。

## 本次更新

- **聚合盘搜 / 四盘源（「聚剧|四盘」等）历史记录直连续播**：
  - 将 `juju` / `szps` / `s_zps` / `聚剧` / `四盘` / `pansearch` 纳入 `Cms.Site.isNetdiskSite()`，对聚合/网盘源跳过易失内存会话明细缓存并在保存历史条目时过滤 `"0"` / `"1"` 占位 `vod_id`。
  - `WatchHistory.Entry` 新增清洁 `shareUrl` 持久化（仅允许公网盘分享 ID/URL，自动拦截含签名凭证/临时参数的地址），从历史卡片重新进入时优先使用真实分享 ID。
  - 当旧历史记录仅有 `"0"` / `"1"` 占位 ID 或上游缓存/分享失效时，`MobileDetailScreen` 静默通过同站清洁剧名搜索（`HistoryResumeMatcher.cleanSearchTitle`）重新绑定新详情并在后台原地迁移历史键，保留「继续播放」断点进度而不弹窗强制用户重新搜索。
- **结构化 Emby 媒体库表单、4K `.strm` 播放与浅/深色主题视觉对齐**：
  - 重构 `MobileEmbyAccounts` 为自适应浅/深色主题底部弹窗，支持**名称**、**是否允许云端同步**、**HTTPS** 开关（默认 `HTTP / 8096`）、服务器地址粘贴自动拆解、选填路径、端口号、用户名与明/密文密码切换，并接入局域网与 WebDAV 双向同步。
  - `MobileEmbyLibrary` 支持 `/emby` 遇到 404/405 自动回退裸根路径、空白 `Views` 回退「全部媒体」以及 `.strm` DirectPlay。
- **横屏播放弹幕顶部间距与导入页对比度修复**：
  - 修复横屏播放器内置弹窗（如弹幕设置）顶栏与系统状态栏之间多余留白，贴顶精准对齐并对齐横竖屏对比度。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（Mobile edition，`minSdk 23` / `targetSdk 28`）。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
- 说明：最终构建提交哈希、APK / `.idsig` / 源码包字节大小与 SHA-256 以正式构建完成后的 GitHub Release 资产页及 [platform-releases.md](../platform-releases.md) 记录为准。
