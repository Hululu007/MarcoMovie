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
| `exp_oauth` | `bool` | 否 | `false` | `true` 时允许开启实验性 OpenAI OAuth 入口（客户端仍需用户二次确认风险提示） |
| `min_vc` | `int` | 否 | `0` | 可选最低版本码；**仅单端 `plat="android"` 允许设置 `> 0`**，`all` / `windows` / `ios` 必须为 `0` |
| `n` | `string` | 否 | `""` | CSPRNG 随机 nonce，保证同秒批量生成多枚独立口令批内严格不重 |

> **关键兼容约束（对齐已发布 Windows 0.7.3 客户端）**：
> 已发布的 Windows 0.7.3 客户端（`flutter/lib/core/ai_lab_passcode.dart`）仅执行 `plat == "" || plat == "all" || plat == targetPlatform` 精确单值匹配，且不校验 `min_vc`。因此两种发码器（`scripts/gen_ai_beta_code.py` 与 `scripts/ai_beta_phone_keygen.html`）强制执行：
> 1. **禁止签出逗号组合码**（如 `android,windows`），亦**禁止以 `all` 扩大授权来替代局部组合**；当需要同时发给多个指定端时，自动拆分为各端独立定向口令。
> 2. **禁止为 `all` / `windows` / `ios` 签出 `min_vc > 0`**，仅单端 `android` 定向码允许设置最低版本码。
> 3. **验签输出明确区分「签名有效」与「各端可激活」**：分别按 Android、iOS、Windows 客户端的实际校验规则给出结果。

---

## 3. 三端客户端对齐清单

| 客户端 | 验签实现 | 目标 `targetPlatform` |
| --- | --- | --- |
| **Android 移动端** | `android-mobile/src/main/java/com/pilipala/marcomovie/AiBetaGate.java`（已落地） | `"android"` |
| **Windows** | `flutter/lib/core/ai_lab_passcode.dart`（已发布 0.7.3，接受 `all` 或 `"windows"`） | `"windows"` |
| **iOS** | 复用 `flutter/lib/core/ai_lab_passcode.dart`，设置 `targetPlatform = 'ios'`（接受 `all` 或 `"ios"`） | `"ios"` |

---

## 4. 作者手机端离线发码器安全约束

```powershell
# 导出已内嵌主密码加密 Ed25519 私钥库的单文件手机发码器（输出至被 gitignore 的 private/）
python -X utf8 scripts/gen_ai_beta_code.py export-mobile-vault
```

- **公钥钉住核对**：解锁后自动比对 `DEFAULT_PUB_HEX`；非正式密钥无法显示「官方公钥就绪」，须显式勾选测试确认后方可签发测试码。
- **零明文台账留存**：本机 `localStorage` 与导出文件仅记录时间、标签、平台与脱敏摘要（SHA-256 前缀 + 尾 6 位），绝不保存完整可用口令；锁定密钥库时立即覆写清零内存私钥、隐藏台账并清空界面口令。
- **DOM 文本节点渲染**：台账全面使用 `createElement` + `textContent`，杜绝标签/备注注入 `innerHTML`。
