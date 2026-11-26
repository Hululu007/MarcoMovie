# Marco Movie 统一跨端 AI 内测口令协议（Android 移动端 / iOS / Windows）

## 1. 设计目标

- **一套公钥、三端统一**：Android Mobile、iOS、Windows 三个客户端内置同一枚 65 字节非压缩 NIST P-256（`secp256r1`）公钥，**正式包内绝不包含私钥**。
- **完全离线验签、零服务器成本**：无需部署验证服务器，断网环境下依然可防伪造、校验适用平台、校验批次与到期时间。
- **支持作者手机端离线发码**：通过 [ai_beta_phone_keygen.html](../scripts/ai_beta_phone_keygen.html) + [gen_ai_beta_code.py](../scripts/gen_ai_beta_code.py) `export-mobile-vault` 生成主密码加密的本机发码器，可在 iPhone / 安卓手机浏览器断网签发并记录发码台账。

---

## 2. 二进制与编码规范（`MM-AI1-`）

- **口令字符串格式**：`MM-AI1-<Base64URL-no-padding(74 bytes)>`（总长 106 字符，验签前忽略所有空白与换行）。
- **74 字节布局（大端序 Big-Endian）**：
  - `bytes[0..9]`（10 字节 `payload`）：
    - `byte[0]` (`uint8`): `version = 1`
    - `byte[1]` (`uint8`): `flags` 权限与平台位掩码
    - `bytes[2..3]` (`uint16`): `batchId`（批次号 `1..65535`）
    - `bytes[4..5]` (`uint16`): `expireDay`（自 `2026-01-01 00:00:00 UTC` 起的天数；`0` 表示永久有效；有效至当日 `23:59:59.999 UTC`）
    - `bytes[6..7]` (`uint16`): `minAppVersionCode`（`0` 表示跨端通用不限制版本码；定向单端口令可填对应端最低版本码）
    - `bytes[8..9]` (`uint16`): `nonce`（随机 16 位随机数，确保同批生成多枚独立口令互不重复）
  - `bytes[10..41]`（32 字节）：ECDSA `r`（无符号大端序）
  - `bytes[42..73]`（32 字节）：ECDSA `s`（无符号大端序，规范化 low-S `s <= n/2`）
- **签名原文**：ASCII 域分隔前缀 `"MARCO-AI-BETA-V1:"`（17 字节）拼接 `payload`（10 字节），共 27 字节，使用 `ECDSA-SHA256`（曲线 `secp256r1` / NIST P-256）。

### `flags` 字节定义（向后兼容）

| 位掩码 | 常量名 | 含义 |
| --- | --- | --- |
| `0x01` | `FLAG_CORE_AI` | 开启 AI 观影实验室核心功能（必填） |
| `0x02` | `FLAG_EXPERIMENTAL_OAUTH` | 允许开启实验性 OpenAI OAuth 选项（仍需用户同意风险弹窗） |
| `0x04` | `FLAG_SHARED_CHANNEL` | 频道通用口令标记（否则显示为专属内测） |
| `0x10` | `FLAG_PLATFORM_ANDROID` | 允许 Android 移动端 |
| `0x20` | `FLAG_PLATFORM_IOS` | 允许 iOS 端 |
| `0x40` | `FLAG_PLATFORM_WINDOWS` | 允许 Windows 端 |

> **平台位兼容规则**：当 `(flags & 0x70) == 0` 时，表示 **三端通用（Android + iOS + Windows 均允许）**；当 `(flags & 0x70) != 0` 时，客户端必须检查 `(flags & CURRENT_PLATFORM_FLAG) != 0`。

---

## 3. 公钥与三端接入方式

- **当前正式公钥（65 字节非压缩点 `04 || X || Y`）**：
  `0456317d317a40913428b964ef557207cac459d89c37a2c9377c84caa5e94a7a8fb0c80cb3ac36b149d50de0c6a5324cca2afe33c95224a52ddb05e541d176eaf1`
- **Android 移动端**：已实现于 [AiBetaGate.java](../android-mobile/src/main/java/com/pilipala/marcomovie/AiBetaGate.java)（使用 JDK/Android API 23+ 原生 `SHA256withECDSA`）。
- **iOS + Windows（Flutter 公共层接入指引）**：
  - 在 `flutter/lib/core/ai_beta_gate.dart` 中内嵌同一枚 `DEFAULT_PUBLIC_KEY_HEX`，使用相同 74 字节解析与 `flags & 0x70` 校验逻辑（iOS 传 `0x20`，Windows 传 `0x40`）。
  - 验签可用纯 Dart `BigInt` P-256 验签（iOS 与 Windows 零原生桥接共用一套代码）或 `CryptoKit` / `BCrypt` 原生接口。

---

## 4. 作者手机端发码操作流程

1. 在电脑端执行一次导出（设置一个仅你自己知道的主密码）：
   ```powershell
   python -X utf8 scripts/gen_ai_beta_code.py export-mobile-vault
   ```
   将在被 `.gitignore` 保护的 `android-mobile/private/` 下生成：
   - `ai_beta_mobile_vault.json`（PBKDF2-HMAC-SHA256 100,000 次迭代 + Encrypt-then-MAC 加密私钥库）
   - `marco_phone_keygen_ready.html`（已内嵌上述**加密态**密钥库的单文件手机发码器）
2. 将 `marco_phone_keygen_ready.html` 传到你自己的手机（iPhone 存「文件」或 Safari 打开；安卓用浏览器打开），输入主密码解锁后即可离线选择「三端通用 / 单端」、「批次」、「天数」、「数量」，一键生成并复制口令。
