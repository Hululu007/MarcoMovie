# Marco Movie Apple TV 0.1.3

发布日期：2026-11-28。应用版本 `0.1.3`（构建号 `4`）；最低系统要求 `tvOS 16.0`（未签名 `.ipa`）。

## 本次更新

- **客厅 WebDAV 局域网扫码直绑**：引入 `WebdavBindCrypto`（AES/HMAC `marco-bind-box-v1`）与 `/bind` 端点，客厅电视展示加密绑定二维码后，移动设备扫码即可直接安全同步 WebDAV 服务器、账号与密码并触发合入。
- **同步合入近期 tvOS 稳定性与操控升级**：整合 `0.1.2` 以来大屏播放 HUD 操控、6 路流式网盘 Range 代理、焦点恢复及 Swift 单元测试校验改进。

## 包信息与构建记录

- **未签名 Apple TV IPA**：`MarcoMovie-0.1.3-tvos-appletv-unsigned.ipa`（`3451700` B，兼容别名 `MarcoMovie-0.1.3-appletv-unsigned.ipa`），SHA-256：`07cd22222f2701e6a8a3e4d42c5cc7c8a8c90544cc2e0b18ece83816a969d110`。
- **对应源码包**：`MarcoMovie-appletv-v0.1.3-source.zip`（`23476241` B），SHA-256：`91eb56bdabbc4e1119304c78b7e60756e684cb47c580fc73769269aafb49055c`。
- **构建提交与 CI 记录**：`4475ca1b22acefa3a282bbe0ce25186601f0d995`。[Build Apple TV (Job 140838786768 · Run 46098959246)](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46098959246/job/140838786768) / [Public Guardrails (Job 140836821198)](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46098959246/job/140836821198)。
- **已知限制**：发布包为未签名 `.ipa`，需自行签名安装；物理 Apple TV 真机完整长片验证仍待补充。
