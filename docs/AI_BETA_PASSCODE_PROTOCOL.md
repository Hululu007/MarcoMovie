# Marco Movie 三端统一 AI 内测口令协议（Windows / iOS / Android 移动端）

## 1. 统一标准与唯一密钥

- **唯一签名算法**：RFC 8032 **Ed25519**（零第三方依赖，纯 Python / 纯 Dart / 纯 Java API 23+ / 纯 JS `BigInt` 全端实现）。
- **唯一正式公钥（32 字节 / 64 位十六进制）**：
  `1dbeaed851b873d7c327d30d718fca0ac1509ef5ac4061b9bd1aa90c841c6929`
  对应本地私钥文件：`private/ai-lab-ed25519.key`（已被 `.gitignore` 严格忽略，**绝不入库、绝不打进任何正式安装包**）。
- **统一口令格式**：`MMAILAB1.<payload_b64url_nopad>.<sig_b64url_nopad>`
  - 验签前自动从文案或换行文本中提取 `MMAILAB1.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)`。
  - **签名输入**：`UTF-8("marco-ai-lab-v1:") || decoded_payload_bytes`。
  - **签名输出**：64 字节标准 Ed25519 签名（Base64URL 无 `=` 填充）。

---

## 2. 规范 JSON 载荷字段（向后兼容）

载荷由键名按字典序排列的无空白紧凑 JSON 编码而成（`canonicalize_json`）：

| 字段 | 类型 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `v` | `int` | 是 | `1` | 协议版本，当前仅接受 `1` |
| `tag` | `string` | 否 | `""` | 批次或发放标签（如 `"channel-01"`） |
| `iat` | `int` | 否 | `0` | 签发 UTC Unix 时间戳（秒） |
| `exp` | `int` | 否 | `0` | 过期 UTC Unix 时间戳（秒）；`0` 表示永久有效；`nowSec > exp` 判定为过期 |
| `plat` | `string` | 否 | `"all"` | 适用平台：`"all"`（三端全通），单端 `"android"` / `"ios"` / `"windows"`，或逗号多选 `"ios,android"` |
| `shared` | `bool` | 否 | `false` | `true` 表示频道通用体验口令，`false` 表示专属测试口令 |
| `exp_oauth` | `bool` | 否 | `false` | `true` 时允许开启实验性 OpenAI OAuth 入口（客户端仍需用户二次确认风险提示） |
| `min_vc` | `int` | 否 | `0` | 可选最低版本码；跨端通用口令必须填 `0` |
| `n` | `string` | 否 | `""` | 随机短 nonce，保证同秒批量生成多枚独立口令互不重复 |

---

## 3. 三端客户端对齐清单

| 客户端 | 验签实现 | 目标 `targetPlatform` |
| --- | --- | --- |
| **Android 移动端** | `android-mobile/src/main/java/com/pilipala/marcomovie/AiBetaGate.java`（已落地） | `"android"` |
| **Windows** | `flutter/lib/core/ai_lab_passcode.dart`（已落地，建议补齐多平台逗号解析与 `shared`/`exp_oauth` 读取） | `"windows"` |
| **iOS** | 复用 `flutter/lib/core/ai_lab_passcode.dart`，在 `AiLabPasscodeStore` 按 `Platform.isIOS` 自动设置 `targetPlatform = 'ios'`，并接入 iOS 设置与 AI 入口 | `"ios"` |

---

## 4. 作者手机端离线发码操作

```powershell
# 导出已内嵌主密码加密 Ed25519 私钥库的单文件手机发码器（输出至被 gitignore 的 private/）
python -X utf8 scripts/gen_ai_beta_code.py export-mobile-vault
```

将生成的 `private/marco_phone_keygen_ready.html` 传至个人手机，iPhone（文件/Safari）或安卓浏览器断网打开、输入主密码解锁即可随时签发三端通用或单端 `MMAILAB1.` 口令并留存本机台账。
