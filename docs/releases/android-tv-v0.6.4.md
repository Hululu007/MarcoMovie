# Marco Movie Android 电视 / 盒子 0.6.4

发布日期：2026-11-28。应用版本 `0.6.4`（版本代码 `101`）；最低 Android 6 / API 23（32 位 `armeabi-v7a`）。本次为 Android 电视 / 盒子端流畅度、剧集海报加载、多仓与脚本兼容性、盘搜弹幕体验及跨端 WebDAV / Emby 直连能力专项升级。

## 本次更新

- **大屏流畅度与海报加载优化**：
  - 优化首页加载与全局搜索并发调度及超时预算，消除首页大图海报在快速切换片名时的延迟切换问题并精简冗余 UI 调度；
  - 完善高画质 / 臻彩分类剧集海报的防盗链请求头、重定向与图片格式兼容，修复剧集海报无法显示的问题；
  - 新增播放器 `45 分钟` 定时关闭预设、工具栏快捷开关、右上角实时倒计时悬浮胶囊与到期安全停止退出。
- **多仓线路、脚本兼容与剧集刮削加固**：
  - 修复多仓导入与切换时的部分子仓线路及自定义分组丢失问题（多仓合并站点上限提升至 `2500`、批次上限提升至 `64`）；
  - 增强常见 JS / `.py` / CatVod 模块及本地代理兼容性；
  - 优化剧集刮削分词并保留年份与多音色关键词线索，降低无关联名误匹配与漏集概率。
- **盘搜与网盘聚合四项修复**：
  - **手动搜索匹配弹幕**：播放菜单新增「手动搜索匹配弹幕」双栏选集弹窗并按剧集记忆绑定分集 ID，兼容网盘加长文件名场景；
  - **盘搜网盘宽卡片展示**：全局搜索网盘条目采用宽卡片完整展示文件名以及 `4K` / `HDR` / 高码率等画质规格标签；
  - **同词二次搜索修复**：修复同一片名二次触发盘搜返回空结果问题；
  - **历史记录重开修复**：修复盘搜历史记录再次打开报错「原源已失效」问题，支持自动刷新详情接口地址重试。
- **局域网扫码直绑 WebDAV 与 Emby HTTP / DirectPlay 兼容**：
  - 新增 `marco-bind-box-v1`（HMAC-SHA256 CTR + Encrypt-then-MAC）端到端加密绑定与 `/bind` 端点，手机端扫码即可安全同步 WebDAV 服务器、账号与加密密码并触发云合并；
  - Emby 连接表单默认切换为 `HTTP（8096）` 并支持 HTTPS 切换与裸域名输入，登录自动兼容 `/emby` 与根路径 `/` 回退、标准 `X-Emby-Authorization` 头与 TLS 握手无凭据明确探测提示，`PlaybackInfo` 放行 4K HEVC / AV1 与多音轨 DirectPlay。

## 验证范围与实机证据

- **精确构建提交与云端双核复验**：`a9d5c8cb2bc5c083dc82639c3cbf7026c01882db`（`git_dirty: false`）。已通过 `check_public_content.py`（`2885` 文件）、`format_java --check`、`sync_readme_versions --check`、`run_api23_callback_checks.py`（`945` 应用类）、`run_guard_checks.py`（`170` 项）、`Build Multiplatform` Run [46096257329](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46096257329)（[Guardrails Job 140828164811](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46096257329/job/140828164811)、[Android TV & Lite Job 140830652662](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46096257329/job/140830652662)）及 Android TV 全套纯 JVM 回归。
- **物理电视真机升级验收**：在小米电视 Android 9（`MiTV-ASTP0`，`armeabi-v7a`）完成从 `0.6.3 (100)` 保留配置无损覆盖安装至 `0.6.4 (101)` 与冷启动拉起（零崩溃）。更多品牌电视与完整长片播放仍待继续覆盖。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（TV edition，`minSdk 23` / `targetSdk 28`；同字节兼容别名 `MarcoMovie-0.6.4-preview.apk`）。
- **TV APK SHA-256**：`MarcoMovie-0.6.4-android-tv.apk`（`56936646` B）— `d04df3eba20e728176bd79af3693d63b6e94ddc672a829d3e181f334e513dd3b`。
- **对应源码包 SHA-256**：`MarcoMovie-android-tv-v0.6.4-source.zip`（`23452700` B）— `8fd9380f5472886b1ed26b156f3514be4a7b966251901e655f094f535a51568a`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
