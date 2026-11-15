# Marco Movie Android 手机 / 平板 0.5.25

发布日期：2026-11-15。版本代码：`88`。本次更新为 Android 手机与平板端同步升级 4K 网盘 6 路并发分片回环代理、CatVod JAR / QuickJS `//bb` 字节码兼容层与并发 DoH 抗 DNS 污染重连机制，大幅改善高码率 4K 网盘原画起播与拖动流畅度。

## 4K 网盘分片加速与片源引擎兼容升级

- **6 路并发分片回环代理与自适应缓冲（`LocalProxy` & `MoviePlayer`）**：本机回环流媒体代理升级为 `6 路 × 1 MB` 并发滑动窗口预取（最多缓存 `24 MB`），支持 `HEAD` 与 `HTTP 206` 精确字节区间响应、拖动进度条即时切换预取窗口及网盘直链 `401` / `403` 过期自动刷新重连，配合 `ExoPlayer` 自适应起播水位显著减少 4K 原盘缓冲等待。
- **CatVod JAR 爬虫与 QuickJS `//bb` 字节码深度兼容**：补齐 `Spider.client()`、`Spider.safeDns()`、`SpiderApi.multiReq` 并发请求及 `CspEngine` 双架构 `.so` 提取与安全校验；`JsEngine` 支持识别加载 `//bb`（`CATOP`）QuickJS 字节码爬虫并提供本地 `js-host` 公共依赖桥接兜底。
- **抗 DNS 污染 DoH 重连与配置容错加固（`Cms`）**：内置并发 RFC 8484 DoH 清洁 IP 解析与 HTTPS SNI 保持重连，遇到 `403` 或连接异常自动执行多级 UA 回退，全面消除 `"null"` 字符串对订阅配置与请求头的污染。

## 包信息与构建记录

- **安装包（ARM64 + ARMv7 双架构）**：`MarcoMovie-0.5.25-android-mobile.apk`（更新兼容别名 `MarcoMovie-0.5.25-mobile.apk`），官方正式签名，支持应用内直接覆盖升级。
- **SHA-256**：`a390251725ab2126716fda348f707ad5c5a81837729d8bfdaadea4079e70a96e`。
- **对应源码包**：`MarcoMovie-android-mobile-v0.5.25-source.zip`，SHA-256：`0b23a7c652f670543e22595964475256c88410cfe9a800c0bf52e770173455cd`。
- **构建提交**：`97f872dead7413120694bf73211b72967ffb4198`。[多端原生构建与校验记录（43729927928）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43729927928)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Java 格式检查、纯 JVM 全套离线回归、16KB 页对齐双架构原生构建及官方正式签名校验。
