# Marco Movie Windows 0.7.0

发布日期：2026-11-23。应用版本 `0.7.0`（构建号 `77`）。本次大版本更新围绕 Windows x64 桌面端开展视听画质、片源生态与原盘流式播放全方位升级：解封 MPV 三档高画质缩放与 HDR 动态色调映射、新增 4 档人声对白响度增强、随包内置免安装官方 Python 3.11.9 运行时、接入零捆绑原生 Edge WebView2 动态网页嗅探与异步 JS 兜底引擎、上线默认 512 MB 分块落盘缓存与 HLS 点播去广告，并新增蓝光/DVD 原盘 `.iso` 2 KiB 按需 Range 流式直播。

## 更新内容

- **MPV 三档高画质解码、HDR 动态色调映射与 4 档人声响度增强（`WindowsVideoQualityController`）**：
  - 解除 Windows 端既往固定的 `bilinear` 缩放与关闭峰值检测限制，新增 **「省电兼容 / 高画质 HDR 映射（默认推荐：`spline36` + `mitchell` 缩放、`bt.2446a -> bt.2390 -> spline` 色调映射自动回退链、`hdr-compute-peak=yes` 动态峰值检测与 `gamut-mapping-mode=perceptual`）/ 旗舰超清锐利（`ewa_lanczossharp` + `deband` 去色带）」** 三档画质预设；
  - 智能硬解联动与超分解耦：常规播放优先零拷贝硬件解码，开启 `Anime4K v4.0.1` 或切换兼容内核时自动联动 `d3d11va-copy`，关闭 Anime4K 时自动恢复当前画质档位专属缩放器；
  - 新增 4 档 `dynaudnorm` **音频响度与人声对白增强**（关闭 / 轻度 / 标准 / 影院人声），桌面播放页 HUD 与设置页均可实时热切换。
- **随包内置免安装 Python 3.11.9 原生运行时（`DesktopPythonBridge`）**：
  - 构建期自动组装并经 SHA-256 严格校验的官方 Python `3.11.9` Embeddable（`win_amd64`）与 `requests`、`urllib3`、`certifi`、`idna`、`charset-normalizer`、`beautifulsoup4`、`soupsieve`、`typing-extensions`、`pyquery`、`cssselect`、`pycryptodome`、`lxml` 完整依赖，开箱即用免装系统 Python（`-I` 隔离模式防止宿主机环境变量干扰）；
  - 新增常驻 JSON-RPC 子进程池（`maxSessions = 4` LRU 复用、单次调用超时保护与退出自动回收）及 TVBox `Spider` 兼容垫片；Inno Setup 安装程序升级覆盖前自动清理旧 `{app}\data\python` 目录。
- **轻量原生 Edge WebView2 动态嗅探与异步 JS 插件（`MarcoWebview2Plugin`）**：
  - 零 NuGet 依赖、免捆绑百兆浏览器内核，动态加载系统 Evergreen Edge WebView2 Runtime（缺失 WebView2 的精简版系统自动安静降级，绝不崩溃）；
  - 实现静音离屏 **Stage-3 动态网页媒体嗅探**（`marco_movie/web_sniffer`：原生 204 广告域名拦截、自定义 `rules` 正则匹配、捕获真实请求头与 Cookie、`clickScript` 自动触发播放、超时销毁）及懒加载离屏 **异步 JS / DRPY2 兜底宿主**（`marco_movie/webview_js`：QuickJS 遇到 `DOMParser` / `crypto.subtle` 等浏览器 API 缺失时自动回退），并完整支持配置 `rules` 与 `ads` 解析持久化。
- **512 MB 分块落盘缓存（`DiskBlockCache`）、HLS 点播去广告与蓝光原盘 `.iso` 流式代理（`BlurayIsoProxy`）**：
  - `LocalMediaLease` 新增点播 `#EXT-X-DISCONTINUITY` 短广告片段启发式剥离（直播流不介入）与 `256 KiB` 对齐分块落盘缓存（Windows 默认 `512 MB`，支持 `关闭 / 256 MB / 512 MB / 1 GB / 2 GB` 档位调节与一键清空）；
  - 新增纯 Dart `BlurayIsoProxy`：仅按 `2 KiB` 扇区 HTTP Range / 文件偏移按需读取 ISO-9660 与 UDF 2.50 目录树及 `BDMV/PLAYLIST/*.mpls` 主播放列表（自动过滤循环假轨并提取章节时间点），将本地、SMB、WebDAV、AList 或网盘代理上的 `.iso` 镜像实时映射为支持任意 `HTTP 206` 拖动 Seek 的连续 `.m2ts` / `.vob` 媒体流，并在桌面播放器进度条展示章节打点；
  - 全程完整保留 Windows 专属 `winFastGlass` 无模糊高速渲染路径与 `185ms` 桌面平滑路由转场。

## 验证范围与已知限制

- **本地与云端自动化校验**：已在本地 Windows x64 环境与 GitHub Actions `windows-latest` 完成 Release 编译打包（Inno Setup 安装包与绿色便携包）、内置 Python `3.11.9` 运行时全依赖导入自检（`--verify`）、`scripts/check_public_content.py`、`scripts/sync_readme_versions.py --check`、`flutter analyze` 零告警、全量 Flutter 单元测试以及 `libmpv-2.dll` 原生解码回放校验。尚未宣称覆盖所有第三方加密蓝光原盘（如 AACS / BD+ 未解密镜像）或任意上游站点。
- **已知限制**：安装包与便携程序未购买商业代码签名证书，Windows SmartScreen 首次运行如提示未知发布者需手动确认运行；`BlurayIsoProxy` 面向未加密 ISO-9660 / UDF 原盘镜像，不包含绕过 AACS / BD+ 等商业 DRM 的解密功能；动态网页嗅探与 WebView2 异步 JS 需系统已安装 Microsoft Edge WebView2 Runtime。
