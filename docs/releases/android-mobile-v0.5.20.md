# Marco Movie Android 手机 / 平板 0.5.20

发布日期：2026-11-11。版本代码：78。

## 网盘中心与扩展配置弹窗 1:1 对齐 iOS 且消除越界裁切

- 将手机端“我的云盘”（`AccountPanel`）由悬浮弹窗重构为与 iOS 端 `netdisk_sheet.dart` 一致的全屏二级页面：采用黑曜石深灰背景、顶部圆形 `‹` 返回导航与面包屑标题，内置顶部“盘序优先：夸父 > 优汐 > 嘟嘟 > 阿狸”（支持一键切换盘序）、四大双层网盘卡片（我的夸父、我的优汐、我的嘟嘟、我的阿狸，含圆角图标、对应线路说明、登录/启用状态胶囊、细分割线与“扫码登录 / 配置 Token / Cookie”双胶囊按钮）及底部“更多网盘与检索设置”分组卡片，并在顶栏“网盘”胶囊同步展示云朵/扫码图标状态。
- 修复 `PluginDialogStyler` 美化第三方扩展弹窗（如“已登录+启用中”账号面板、扫码弹窗等）时因 `DecorView` 系统 9-patch 内边距叠加与容器正数像素定宽（`EXACTLY`）导致右侧按钮（“启用中 / 停用中 / 取消”）超出卡片右边界被截断的问题：清零窗口与框架面板默认水平内边距，将内部容器统一收敛为 `MATCH_PARENT`，归一化单按钮与多按钮横向工具栏宽度并清除 `Button` 最小宽度限制；同时将弹窗配色由墨绿底色切换为与 iOS 一致的黑曜石玻璃卡片与胶囊样式，实时同步扩展弹窗内的网盘登录与启用状态。

## 电视直播列表拉取与起播兼容修复

- 修复浏览独立扩展片源（如玩偶哥哥 `custom_spider.jar`）后覆盖全局 `CspEngine.activeProxyLoader`，导致切换至依赖主订阅 `spider`（如 `fan.txt`）的本地代理直播源（如“牛播一” `/proxy?do=cctva`）返回空响应并报错“读取直播源失败：直播列表没有可识别的频道”的问题：`CspEngine.proxy` 新增多扩展加载器自动回退与订阅切换重置机制，当前加载器未返回有效代理载荷时自动初始化并回退至主订阅 `spider` 代理。
- 修复 `LiveController.loadCatalog` 原地修改缓存 `Source.url` 导致本地代理重启后携带旧 `_mm_token` 鉴权失败的问题（改为 `Source.copy()` 副本重写），并在多仓子仓库下优先传入 `a.config.origin` 解析相对直播地址。
- 增强 `LiveCatalog` 与 `Cms.document` 直播列表解码与解析：自动识别无 `charset` 响应头的 GB18030 / GBK 中文 `#genre#` 直播源、gzip / UTF-16 / 图片载体及无 `#genre#` 的 `**Base64` 列表；保留位于 `#EXTINF:` 之前的 `#EXTVLCOPT:` 请求头（兼容 Kimentanm / APTV 格式），并在 `#EXTINF:` 逗号后频道名为空时自动回退至 `tvg-name`。
- 优化直播流起播与播放控制：透传直播源 `playerType` 并默认对直播流启用兼容 TS / FLV 解复用与扩展音频解码模式（`createIjk`），跳过无后缀直播流地址的 `Range: bytes=0-511` 预探测以保护单次防盗链令牌并支持 HLS 与直连 TS / FLV 双向自动回退，过滤不支持的 `rtmp://` 首选流以优先命中同频道 HTTP(S) 线路，屏蔽直播模式下的倍速继承与快进/快退按钮，并在手机横屏起播失败时保持状态提示可见。

## 内置 ARM64 原生音视频解码组件（FFmpeg / AV1 / VP9）

- 修复 64 位 Android 手机安装 `android-mobile` 安装包后“解码组件”页面全部显示“未能加载”（`FFmpeg 音频扩展 / AV1 视频软解码 / VP9 视频软解码`）的问题：从固定上游提交构建并随 `android/decoder-dependencies.json` 引入 16KB 页面对齐的 `arm64-v8a` 原生解码库（`libffmpegJNI.so`、`libgav1JNI.so`、`libvpxV2JNI.so`，发布标签 `decoders-1.5.1-arm64-v1`），仅打入手机/平板双架构安装包而不增大 32 位电视端包体积，同时将手机端解码说明文案修正为“默认优先使用设备硬件解码能力”。

## 验证范围与限制

- 通过公共内容守卫检查、Java 代码格式检查、离线纯 JVM 单元回归（含 GB18030 直播解码、前置 `#EXTVLCOPT` 解析、`**Base64` 解包、`Source.copy()` 隔离及双架构解码清单断言）、GitHub Actions 持续集成回归以及 Android 官方正式签名构建与 16KB ELF 对齐校验。
- 本版本仅发布 Android 手机 / 平板安装包（`MarcoMovie-0.5.20-android-mobile.apk` 及兼容别名 `MarcoMovie-0.5.20-mobile.apk`），使用官方正式签名，支持应用内直接覆盖安装升级；不变更电视端、Lite、Windows、macOS 或 iOS 已发布版本。
- 自动化构建与离线回归不代表特定实体手机型号、第三方直播源实时连通性或真实私人网盘账号已完成实机验收。
