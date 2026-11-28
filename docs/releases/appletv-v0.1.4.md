# Marco Movie Apple TV 0.1.4

发布日期：2026-11-28。应用版本 `0.1.4`（构建号 `5`）；最低系统要求 `tvOS 16.0`（未签名 `.ipa`）。

## 本次更新

- **「聚剧|四盘」及网盘聚合源历史记录直连续播修复**：
  - `CmsClient` 新增 `isGenericPlaceholderVodId` 与 `isNetdiskOrAggregatedSearchSite`，在 `fetchDetail` 与 `mergeVideoDetail` 中保留真实片源 ID 不被 `"0"` / `"1"` 占位值覆盖。
  - 新增 `fetchDetailWithSameSiteRecovery(site:video:)`，对网盘/聚合搜索源及 `"0"`/`"1"` 占位 ID 历史条目支持同站洁净片名搜索自动重连与内联线路合并（常规 CMS 站点保持严格 ID 校验不误匹配）。
  - `MediaEntryResolver.resolveWatchHistoryEntry`、`AppViewModel.migrateWatchHistoryIdIfNeeded` 与 `DetailView` 联动实现历史记录就地迁移重绑与断点续播。

## 包信息与构建记录

- 构建由 GitHub Actions `Build Multiplatform` 与 `Apple TV Verify` 产出未签名 `.ipa`，详细资产 SHA-256 见对应 GitHub Release 发布页与 [platform-releases.md](../platform-releases.md)。
- 已知限制：发布包为未签名 `.ipa`，需自行签名安装。
