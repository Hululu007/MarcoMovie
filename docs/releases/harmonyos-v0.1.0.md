# Marco Movie HarmonyOS NEXT 0.1.0

发布日期：2026-11-17。应用版本：`0.1.0`（构建号 `1000001`），最低系统要求：HarmonyOS NEXT API 12（5.0+）。本次发布为 Marco Movie 纯血鸿蒙（HarmonyOS NEXT）首发通用版本，单 `.hap` 安装包自适应鸿蒙手机、平板 / 2in1 与鸿蒙智慧屏，复用跨平台核心生态并接入原生 Stage 模型、ArkTS `AVPlayer` GPU 硬件纹理与系统 HUKS 安全存储。

## 更新内容

- **手机 / 平板 / 2in1 / 智慧屏单包自适应与 10 英尺遥控焦点 UI**：手机与平板端采用原生触控导航与手势交互；运行于鸿蒙智慧屏（TV）或大屏横屏设备时自动启用 10 英尺遥控器焦点边框、方向键/确认键/返回键导航、局域网手机扫码导入配对与大屏选集界面。
- **原生 ArkTS `AVPlayer` + `XComponent` GPU 硬件纹理播放**：通过 `OhosAvPlayerPlugin` 将鸿蒙系统 `media.AVPlayer` 直接绑定至 `XComponent` Surface 零拷贝渲染，支持 HTTP / HLS / MP4 / MKV 硬件解码、自定义防盗链请求头、倍速控制、HDR 视频色域识别以及流内多音轨与内封字幕轨枚举切换。
- **4K 网盘扫码登录与本机 6 路并发分片代理**：鸿蒙手机、平板与智慧屏设置内均提供夸克、UC、百度网盘、阿里云盘官方扫码授权（无需跳转第三方网页登录），配合内置 `NetdiskRangeProxy`（`6 × 1 MB` 滑动窗口并发分片预取、HTTP `206` 区间响应与尾部索引秒跳）流畅播放 4K 原盘分享。
- **本机 QuickJS-NG 脚本引擎、安全凭据存储与全平台同步互通**：CMake 原生编译 `libmarco_qjs.so` 提供 QuickJS-NG 脚本源与纯 Dart 规则源（`XBPQ` / `XYQ` / `AppYsV2` / `Wogg` 等）解析；通过 `@kit.UniversalKeystoreKit` / 加密首选项隔离保存敏感凭据；完整互通 `marco-movie-sync` v2（WebDAV 云同步与局域网点对点直连同步）及 `marco-movie-backup` 备份文件。

## 包信息与构建记录

- **未签名通用 HAP（手机 / 平板 / 2in1 / 智慧屏）**：`MarcoMovie-0.1.0-harmonyos-universal.hap`（更新兼容别名 `MarcoMovie-0.1.0-harmonyos.hap`），SHA-256：`705029b7ef0cdadc6e7eee7eb7e6b493b03594d4021576e14ca36c84ee6a8c55`。
- **对应源码包**：`MarcoMovie-harmonyos-v0.1.0-source.zip`，SHA-256：`9a03eec62b573dd52d9db54544c99945fd64567b63cb87d95f5d8887bdb7d251`。
- **构建提交**：`511f5b2daea0d7d604c73a6cfd518cc8b8afd707`。[多端原生构建与校验记录（44111559315）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44111559315) · [公共内容守卫检查（44111559279）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44111559279)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Flutter 跨平台与鸿蒙桥接自动化测试（含一致性测试套件与 `ohos_bridge_test`），以及 OpenHarmony Flutter `3.35.7` + HarmonyOS Command Line Tools SDK `26.0.0.821` 云端 Release 构建校验。
- 已知限制：发布包为未签名通用 `.hap`，安装前需通过 DevEco Studio 自动签名或 `hap-sign-tool` 签名后使用 `hdc install` 安装；受纯血鸿蒙系统架构限制不支持 Android APK / JAR 插件或外部 Node 子进程宿主；尚未宣称完成全型号物理鸿蒙手机、平板与智慧屏真机长片验收。
