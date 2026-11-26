# Marco Movie HarmonyOS NEXT 0.1.2

发布日期：2026-11-24。应用版本：`0.1.2`（构建号 `1000003`），最低系统要求：HarmonyOS NEXT API 12（5.0+）。本次更新全面恢复 API 12 最低系统兼容，修复凭据安全存储、独立更新通道、直播同台换源与暂停防误重开、带请求头首播与倍速回显，并统一本地文件导入、备份往返和全站搜索体验。

## 更新内容

- **恢复 API 12 最低系统兼容**：修复 CI 模板重建导致包内 `minAPIVersion` / `targetAPIVersion` 被抬升至 `5.0.5(17)` 的问题，锁定 OpenHarmony Flutter 引擎并在打包后自动校验 `minAPIVersion = 50000012`、`arm64-v8a` 与 `37` 项 CatPaw 资产。
- **凭据安全存储与无损迁移注销**：WebDAV 密码与长网盘 Cookie 写入系统 Asset Store（支持分片存储）且异常不再静默回落明文 Preferences；从 `0.1.1` 升级保留两处异值保护，注销中断后由墓碑记录防止冷启动迁回已删凭据。
- **鸿蒙独立更新通道与版本比较**：显式识别 HarmonyOS 并读取 `/movie/updates/harmonyos.json` 与对应 GitHub Release，校验平台、版本、文件名、大小与 SHA-256；手机与智慧屏均区分远端较新、同版与远端较旧，提供未签名包签名安装指引。
- **智慧屏直播同台换源与首帧检测**：将“手动换频道”与“自动换同台备用信号”分离，同台信号耗尽后停留在当前频道提示重试不再误跳台；仅在拿到真实渲染首帧或有效播放进度后解除首播超时计时，兼顾无进度回报的健康直播。
- **修复直播暂停后迟到状态导致自动重开**：直播主动暂停后收到迟到 `playing=true` 与断流 `error` 时保持暂停意图并压制原生回播，等待期间持续显示“已暂停”提示，仅在用户主动点击继续后重新连接原频道。
- **修复带请求头首播与倍速回显**：原生 `AVPlayer` 在 `setMediaSource` 失败时不再剥离 `Referer` 等请求头回退裸 URL，改为上报可重试错误；界面倍速仅提供当前引擎可执行的档位，切集后显示值与实际速率一致。
- **统一触屏与智慧屏本地导入、备份往返及换仓搜索**：手机、平板与智慧屏的订阅、直播与配置备份导入导出统一接入鸿蒙原生文档选择器，统一鸿蒙本地备份 `32 MiB` 限制（WebDAV 保持 `8 MiB`）且损坏文件恢复失败保留原配置；智慧屏搜索突破 16 站上限，切仓或换词立即失效并取消旧请求。

## 包信息与构建记录

- **未签名通用 HAP（手机 / 平板 / 2in1 / 智慧屏）**：`MarcoMovie-0.1.2-harmonyos-universal.hap`（`52194925` B，更新兼容别名 `MarcoMovie-0.1.2-harmonyos.hap`），SHA-256：`22fcc43e12a912b994309da06c4ab17726246ca1d3dfd14ea23dc3d51ddf3979`。
- **对应源码包**：`MarcoMovie-harmonyos-v0.1.2-source.zip`（`16564672` B），SHA-256：`6e49d63845afa5fa8344a6825d0eb56f73575cf810134aaaa890033e7e63a2a8`。
- **构建提交与 CI 记录**：`0a1e07d53c5ea91defd7e6b9a3eaad6451443e74`。[HarmonyOS NEXT Release 构建与校验（Job 138167806675 · Run 45310961797）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45310961797/job/138167806675) · [公共守卫与离线校验（Job 138166288101）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45310961797/job/138166288101)。

## 验证范围与已知限制

- **自动化与云端构建校验**：已通过 `scripts/check_public_content.py`（`2164` 文件）、`scripts/sync_readme_versions.py --check`、`115/115` 项本地 Flutter 单元测试（覆盖 `harmonyos_and_tv_ui_test`、`harmonyos_candidate_review_test`、`ohos_metadata_stall_review_test`、`shared_backup_roundtrip_review_test`、`app_update_test`、`playback_startup_test`、`catpaw_embedded_engine_test` 等）、`7/7` 项 `test_prepare_ohos.py`（含真实 Node TypeScript 凭据迁移与注销测试及 ArkTS 守卫）、OpenHarmony Flutter `3.35.7` + HarmonyOS Command Line Tools SDK `26.0.0.821` 云端 Release 打包，以及 `prepare_ohos.py --verify-hap` 解包核验（`minAPIVersion = 50000012`、`versionName = 0.1.2`、`versionCode = 1000003`、`arm64-v8a`、`37` 项 CatPaw 资产）。
- 已知限制：发布包为未签名通用 `.hap`，安装前需通过 DevEco Studio 自动签名或 `hap-sign-tool` 签名后使用 `hdc install` 安装，受纯血鸿蒙架构限制不支持 Android APK / JAR 插件或外部 Node 子进程宿主。
- 注意事项：本版本因缺少物理鸿蒙真机尚未执行 API 12 新装与 API 17+ 从 `0.1.1` 覆盖升级实测（`device_install_tested: false`，`device_upgrade_tested: false`），欢迎提交 Issue 反馈实机体验。
