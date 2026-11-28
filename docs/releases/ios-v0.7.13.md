# Marco Movie iOS / iPadOS 0.7.13 (build 106)

> 仅包含 `iOS / iPadOS` 独立版本变更；其他各端保持各自独立版本号与发布包。

## 本次更新

1. **「聚剧|四盘」及同类聚合盘搜源历史记录直连续播修复**
   - `CmsClient.isGenericPlaceholderVodId` 与 `_mergeDetail` 保护真实分享/片源 `id` 不被蜘蛛详情返回的 `"0"` / `"1"` 占位 `vod_id` 覆盖。
   - 放宽 `CmsClient.playableDetail` 同站恢复条件：支持 `CspBridge.isSearchOnlySite`（如 `csp_S_zps` / `szps-v1` 等聚合四盘源）、`vod_id` 为 `"0"`/`"1"` 占位值，以及内联选集 `/api/detail` 返回 404/报错的场景；搜索候选优先采用内联选集结果并直接合并可用线路，避免无意义二次请求导致失败。
   - 详情页 `_findBookmark` 在身份迁移后回退匹配原历史记录 ID，同时在后台自动迁移并重绑 `WatchHistoryEntry` 至新片源 `id`，实现从历史卡片直接续播。
2. **Emby 空媒体库视图回退与导入界面浅/深色主题对比度修复**
   - 当 Emby `Views` 接口返回空集合时，自动合成「全部媒体」分类视图，确保资源库可完整挂载与浏览。
   - `AddResourceLibraryView` 统一使用主题强调色 `palette.accent` 与适配明暗模式的错误横幅/按钮禁用配色；支持从「网盘与资源库」管理页直接打开新版 Emby 结构化编辑页。

## 构建与校验

- 构建完成后由 GitHub Actions `Build Multiplatform` 并行产出主包（iOS 15.0+）与兼容包（iOS 14.0+）未签名 `.ipa`，资产哈希详见对应 GitHub Release 发布页与 [platform-releases.md](../platform-releases.md)。
