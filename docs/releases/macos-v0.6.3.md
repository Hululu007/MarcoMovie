# Marco Movie macOS 0.6.3

发布日期：2026-11-28。应用版本 `0.6.3`（构建号 `75`）；Apple Silicon（`arm64`）与 Intel（`x86_64`）通用桌面应用。

## 本次更新

- **「聚剧|四盘」及同类聚合盘搜源历史记录直连续播修复**：
  - 同步更新 `macos/lib/core/cms_client.dart`（`isGenericPlaceholderVodId`、`_mergeDetail` 真 ID 保留、`playableDetail` 支持 `isSearchOnlySite` / 内联选集回退与 `/api/detail` 报错同站静默重搜恢复）以及 `macos/lib/ui/detail_screen.dart`（`_findBookmark` 旧键回退与 `WatchHistoryEntry` 原地键迁移）。
  - 从历史记录重新进入「聚剧|四盘」等聚合盘搜卡片时，无需弹出手动重搜即可直接衔接上次线路与进度播放。

## 包信息与构建记录

- 构建由 GitHub Actions `Build Multiplatform`（macOS Runner）产出通用桌面应用包，详细 SHA-256 校验值见对应 GitHub Release 发布页与 [platform-releases.md](../platform-releases.md)。
- 已知限制：应用采用 ad-hoc 签名未做 Apple 公证，首次运行如遇拦截需右键选择“打开”。
