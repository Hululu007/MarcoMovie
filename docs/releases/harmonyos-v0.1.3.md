# Marco Movie HarmonyOS NEXT 0.1.3

发布日期：2026-11-28。应用版本 `0.1.3`（构建号 `1000004`）；最低 HarmonyOS NEXT API 12（通用未签名 `.hap`）。

## 本次更新

- **HarmonyOS NEXT 局域网扫码直绑 WebDAV**：同时覆盖触屏端扫码推/拉绑定与智慧屏端展示 `marco-bind-box-v1` 加密绑定二维码，实现鸿蒙设备与全平台间快速安全绑定 WebDAV 与双向合并。
- **Emby / Jellyfin HTTP 8096 与 4K DirectPlay 修复**：连接弹窗默认使用 `HTTP + 8096` 并支持 HTTPS 切换与裸域名输入，登录兼容 `/emby` 与根路径 `/` 回退、标准 `X-Emby-Authorization` 头与 TLS 握手无凭据诊断引导，默认放行 DirectPlay。

## 包信息与构建记录

- **未签名通用 HAP（手机 / 平板 / 2in1 / 智慧屏）**：`MarcoMovie-0.1.3-harmonyos-universal.hap`（`54626398` B，兼容别名 `MarcoMovie-0.1.3-harmonyos.hap`），SHA-256：`95efa6160b691557a4812f21ffbf27a5a49382525b698e0367709687f69d9477`。
- **对应源码包**：`MarcoMovie-harmonyos-v0.1.3-source.zip`（`23489437` B），SHA-256：`afc3ab1bfc8bd27c61959fbf37e52f2e1581356bf1ef59cb689298f43470de3e`。
- **构建提交与 CI 记录**：`4475ca1b22acefa3a282bbe0ce25186601f0d995`。[Build HarmonyOS NEXT Universal HAP (Job 140838786751 · Run 46098959246)](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46098959246/job/140838786751) / [Public Guardrails (Job 140836821198)](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46098959246/job/140836821198)。
- **已知限制**：未签名通用 `.hap`，安装前需通过 DevEco Studio 或 `hap-sign-tool` 签名后安装；因缺少物理鸿蒙真机，实机装机与播放仍待用户反馈。
