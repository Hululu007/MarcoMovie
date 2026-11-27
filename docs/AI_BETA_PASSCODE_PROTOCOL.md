# Marco Movie 三端统一 AI 内测口令协议（Windows / iOS / Android 移动端）

## 1. 统一标准与唯一密钥

- **唯一签名算法**：RFC 8032 **Ed25519**（零第三方依赖，纯 Python / 纯 Dart / 纯 Java API 23+ / 纯 JS `BigInt` 全端实现）。
- **唯一正式公钥（32 字节 / 64 位十六进制）**：
  `1dbeaed851b873d7c327d30d718fca0ac1509ef5ac4061b9bd1aa90c841c6929`
  对应本地私钥文件：`private/ai-lab-ed25519.key`（已被 `.gitignore` 严格忽略，**绝不入库、绝不打进任何正式安装包**）。
- **统一口令格式**：`MMAILAB1.<payload_b64url_nopad>.<sig_b64url_nopad>`
  - 验签前自动从文案或折行文本中提取完整 `MMAILAB1.<payload>.<86字符签名>`（支持载荷与签名段内换行，不会在签名段换行处截断，也不会吞并尾随说明文字）。
  - **签名输入**：`UTF-8("marco-ai-lab-v1:") || decoded_payload_bytes`。
  - **签名输出**：64 字节标准 Ed25519 签名（86 字符 Base64URL 无 `=` 填充）。

---

## 2. 规范 JSON 载荷字段与已发布客户端兼容性约束

载荷由键名按字典序排列的无空白紧凑 JSON 编码而成（`canonicalize_json`）：

| 字段 | 类型 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `v` | `int` | 是 | `1` | 协议版本，当前仅接受 `1` |
| `tag` | `string` | 否 | `""` | 批次或发放标签（如 `"channel-01"`，非空且 ≤ 48 字符） |
| `iat` | `int` | 否 | `0` | 签发 UTC Unix 时间戳（秒） |
| `exp` | `int` | 否 | `0` | 过期 UTC Unix 时间戳（秒）；`0` 仅在显式勾选/传入「永久有效」时签发；`nowSec > exp` 判定为过期 |
| `plat` | `string` | 否 | `"all"` | **正式签发仅允许单值**：`"all"`（三端通用）或单端 `"android"` / `"ios"` / `"windows"` |
| `shared` | `bool` | 否 | `false` | `true` 表示频道通用体验口令，`false` 表示专属测试口令 |
| `exp_oauth` | `bool` | 否 | `false` | 协议保留字段（Android 0.7.3 已撤下未实测的实验性 OpenAI / Kimi 订阅直连入口，默认 `false`） |
| `min_vc` | `int` | 否 | `0` | 可选最低版本码；**仅单端 `plat="android"` 允许设置 `> 0`**，`all` / `windows` / `ios` 必须为 `0` |
| `n` | `string` | 否 | `""` | CSPRNG 随机 nonce，保证同秒批量生成多枚独立口令批内严格不重 |

> **关键兼容约束与实证边界**：
> 已发布的 Windows 0.7.3 客户端（`a11deb29:flutter/lib/core/ai_lab_passcode.dart`）仅执行 `plat == "" || plat == "all" || plat == targetPlatform` 精确单值匹配，且不校验 `min_vc`。因此两种发码器（`scripts/gen_ai_beta_code.py` 与 `scripts/ai_beta_phone_keygen.html`）强制执行：
> 1. **禁止签出逗号组合码**（如 `android,windows`），亦**禁止以 `all` 扩大授权来替代局部组合**；当需要同时发给多个指定端时，自动拆分为各端独立定向口令。
> 2. **禁止为 `all` / `windows` / `ios` 签出 `min_vc > 0`**，仅单端 `android` 定向码允许设置最低版本码。
> 3. **缺少目标版本码时不得直报「可激活」**：验签器面对 `min_vc > 0` 的 Android 口令，若未提供目标 `appVersionCode`（`--app-version-code` / 网页目标版本码输入框），必须返回 `status="unknown_version"`（`ok=false`），不能直接报告「可激活」。
> 4. **Windows 0.7.3 签名段折行限制**：已发布 Windows 0.7.3 的 `extractToken()` 会先对原文执行直接正则 `MMAILAB1\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)`，若 **86 字符签名段内部出现换行或空格**，直接正则会在折行处截断签名导致验签失败（且去空白回退若紧邻英文文案也可能吞并尾部 ASCII 字符）。因此面向 Windows 0.7.3 发放口令时，**必须保持整条 `MMAILAB1...` 单行无换行，且与前后说明文案之间留空行或用中文隔开**；折行容错提取仅适用于 Android 移动端与作者发码器离线验签。
> 5. **iOS 实证范围声明**：本仓库当前尚未包含已发布的独立 iOS AI 口令验签构建；本文档与发码器中关于 iOS 的激活规则基于「复用 `flutter/lib/core/ai_lab_passcode.dart` 并传 `targetPlatform='ios'`」的设计约定，待 iOS 端实际落地构建后须另行做实测验收。

---

## 3. 三端客户端对齐清单

| 客户端 | 验签实现 | 目标 `targetPlatform` | 当前实证状态 |
| --- | --- | --- | --- |
| **Android 移动端** | `android-mobile/src/main/java/com/pilipala/marcomovie/AiBetaGate.java` | `"android"` | 已落库并通过本轮 0.7.3 单测实证（支持折行提取与 `min_vc`） |
| **Windows** | `flutter/lib/core/ai_lab_passcode.dart`（已发布 0.7.3 `a11deb29`） | `"windows"` | 已对照 `a11deb29` 源码实证（单值 `plat`、无 `min_vc`、需单行无签名段折行） |
| **iOS** | 规划复用 `flutter/lib/core/ai_lab_passcode.dart` | `"ios"` | **设计约定范围**（本仓库尚无已发布 iOS 验签构建，落地后需独立复测） |

---

## 4. 作者手机端离线发码器安全约束

```powershell
# 导出已内嵌主密码加密 Ed25519 私钥库的单文件手机发码器（输出至被 gitignore 的 private/）
python -X utf8 scripts/gen_ai_beta_code.py export-mobile-vault
```

- **公钥钉住核对**：解锁后自动比对 `DEFAULT_PUB_HEX`；非正式密钥无法显示「官方公钥就绪」，须显式勾选测试确认后方可签发测试码。
- **零明文台账留存**：本机 `localStorage` 与导出文件仅记录时间、标签、平台与脱敏摘要（SHA-256 前缀 + 尾 6 位），绝不保存完整可用口令；锁定密钥库时立即覆写清零内存私钥、清除待处理原始种子、释放文件控件选择（`FileList.length === 0`）、隐藏台账并清空界面口令。
- **文件选择立即释放**：导入 `.key` / `.json` 后立即清空 `<input type="file">` 的 `value`/`files`，取消或读取失败同样清零待处理种子与输出。
- **DOM 文本节点渲染**：台账全面使用 `createElement` + `textContent`，杜绝标签/备注注入 `innerHTML`。
