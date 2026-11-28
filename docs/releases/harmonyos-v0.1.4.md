# Marco Movie HarmonyOS NEXT 0.1.4

发布日期：2026-11-28。应用版本 `0.1.4`（构建号 `1000005`）；最低 HarmonyOS NEXT API 12（通用未签名 `.hap`）。

## 本次更新

- **「聚剧|四盘」及聚合盘搜源历史记录直连续播修复**：
  - 共享 `flutter/lib/core/cms_client.dart` 防止 `"0"` / `"1"` 占位 `vod_id` 覆盖真实分享标识，支持 `isSearchOnlySite` / `mode: 'pansou'` 与详情失效场景同站静默重搜并直接合并内联剧集；`DetailScreen` 就地迁移历史断点至可用片源 `id`。
- **Emby 空白 `Views` 兜底与资源库导入界面对比度优化**：
  - 补充 `Views` 空集合回退「全部媒体」分类视图；统一「添加资源库」按钮强调色与明暗模式错误提示框对比度。

## 包信息与构建记录

- 构建由 GitHub Actions `Build Multiplatform`（HarmonyOS NEXT Runner）产出通用未签名 `.hap`，详细资产 SHA-256 见对应 GitHub Release 发布页与 [platform-releases.md](../platform-releases.md)。
- 已知限制：未签名通用 `.hap`，安装前需通过 DevEco Studio 或 `hap-sign-tool` 签名后安装；因缺少物理鸿蒙真机，实机装机与播放仍待用户反馈。
