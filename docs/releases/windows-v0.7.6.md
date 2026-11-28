# Marco Movie Windows x64 0.7.6

发布日期：2026-11-28。应用版本 `0.7.6`（构建号 `83`）；支持 Windows 10 / 11（64 位安装包与绿色便携版）。

## 本次更新

- **「聚剧|四盘」及聚合盘搜源历史记录直连续播修复**：
  - `CmsClient.isGenericPlaceholderVodId` 与 `_mergeDetail` 禁止蜘蛛返回的 `"0"` / `"1"` 占位 `vod_id` 覆盖既有真实片源标识；`playableDetail` 支持仅搜索/内联线路型站点（`isSearchOnlySite` / `mode: 'pansou'`）在 `/api/detail` 失效或站点重启缓存清空后自动同站重搜匹配并直接合并内联剧集；`DetailScreen` 自动迁移原历史断点至新片源 `id`。
- **Emby 空白 `Views`「全部媒体」兜底与导入页色彩对比度修复**：
  - Emby `Views` 返回为空时自动提供「全部媒体」分类入口；「添加与管理资源库」界面统一主题强调色与浅色模式错误横幅对比度，并打通从媒体库卡片直接进入新版 Emby 编辑页。

## 包信息与构建记录

- 构建由 GitHub Actions `Build Multiplatform`（Windows x64 Runner）产出 Inno Setup `.exe` 安装包与便携版 `.zip`，详细校验值见对应 GitHub Release 发布页与 [platform-releases.md](../platform-releases.md)。
- 已知边界：安装包与便携程序未购买商业代码签名。
