# Marco Movie macOS 0.6.1

发布日期：2026-11-25。应用版本 `0.6.1`（构建号 `73`），架构支持 Apple Silicon（`arm64`）与 Intel（`x86_64`）通用桌面应用。本次更新为 macOS 端专属新增安装/升级后首次启动官方渠道与安全防伪提示弹窗，以及设置页「联系与反馈作者」与「官网交流群链接」入口，完整保留 `0.6.0` 本地订阅、收藏、观看进度与设置数据无损覆盖升级。

## 更新内容

- **安装 / 升级后首次启动官方渠道与安全防伪弹窗（仅 macOS 端）**：应用启动后最先弹出居中模态提示（需显式点击「我知道了」确认，屏蔽背景误触与 Esc 跳过），展示作者各社媒统一账号名 **`PILIPALA来信`**（小红书、B站、抖音、公众号、视频号，支持一键复制）、Marco 官网 **`marcotv.wlj9919.top`**（支持直接访问与一键复制）以及防伪提醒：**「下载软件请认准官网地址，以防不明渠道软件添加病毒等不良内容。」**；确认状态仅记录于本机偏好（不纳入跨端同步/备份），全新安装确认后继续进入 5 幕新手引导，老用户覆盖升级后弹一次即直接进入主页，后续启动不再重复弹出。
- **设置页「联系与反馈作者」与「官网交流群链接」（仅 macOS 端）**：在 macOS 设置页新增独立「联系与反馈作者」分组（底部附官网防伪安全提醒），直出作者各社媒账号名 `PILIPALA来信`（小红书、B站、抖音、公众号、视频号，全平台同名）与 `Marco 官网：marcotv.wlj9919.top`；点击「联系反馈作者」弹出适配最小窗口尺寸（`720×520`）的联系面板支持一键复制社媒账号名与访问官网，点击「官网交流群链接」直接打开系统浏览器访问 `https://marcotv.wlj9919.top`（浏览器不可用时自动复制链接并提示）。

## 包信息与构建记录

- **macOS 桌面应用包（Apple Silicon / Intel 通用）**：`MarcoMovie-0.6.1-macos-desktop.zip`（`136878750` B，更新兼容别名 `MarcoMovie-0.6.1-macos.zip`），SHA-256：`238707648e4e12ab6f3ae3d5bfd9ced43e8773c0688bd21c7a0c11849f8dbfb7`。
- **对应源码包**：`MarcoMovie-macos-v0.6.1-source.zip`（`17286699` B），SHA-256：`1c3935f1a0cdc1dc1975923e8ea9534da2957a1365a946361c48eca574afb511`。
- **构建提交与 CI 记录**：`b310bef6370d9d6824f1149907edc19f368b952c`（已合入 `main`）。[macOS 正式构建与全量校验（Job 139299061113 · Run 45640259558）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45640259558/job/139299061113) / [公开守卫与离线校验（Job 139296632865）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/45640259558/job/139296632865)。

## 验证范围与已知限制

- **已完成自动化构建与云端 macOS 校验**：在 `b310bef6370d9d6824f1149907edc19f368b952c` 上于 macOS 云端 Runner 完成 `flutter analyze`、`flutter test -j 2`（`1437` 项通过、`15` 项非桌面平台专属跳过，含新增 macOS 首次启动顺序/老用户升级/多平台隔离/最小窗口 `720×520` 设置页专项测试 `5/5` 通过）、未修改 `.app` 包内 `Mpv.framework/Mpv` 原生回放与 macOS 专项套件（`82/82` 项通过）、`codesign --verify --deep --strict`（无 `get-task-allow`）、Universal `arm64 + x86_64` 双架构切片核验、`Avcodec` `pgssub` 符号校验、Intel 未修改 `.app` 启动冒烟（`ALIVE_3S`）以及 `2215` 个追踪文件公开内容守卫与 README 版本一致性校验。
- 已知限制：应用压缩包未进行 Apple 公证（Notarization），首次打开需按 macOS 提示右键选择“打开”。
- 注意事项：本版本尚未在物理 Apple Silicon / Intel Mac 上完成真机手工 GUI 抽检与真机覆盖升级实测，欢迎通过社媒账号或官网交流群反馈实机体验。
