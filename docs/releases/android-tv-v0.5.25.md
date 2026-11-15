# Marco Movie Android 电视 / 盒子 0.5.25

发布日期：2026-11-15。版本代码：`87`。本次更新全面升级电视与盒子端 4K 网盘原画并发分片代理、第三方 JAR / QuickJS 爬虫兼容层与并发 DoH 抗 DNS 污染能力，显著提升大屏播放高码率 4K / HDR 网盘原盘的起播速度、快进快退响应与源站连通率。

## 4K 网盘分片加速与片源引擎兼容升级

- **6 路并发分片回环代理与自适应缓冲（`LocalProxy` & `MoviePlayer`）**：本机回环流媒体代理升级为 `6 路 × 1 MB` 并发滑动窗口预取（最多缓存 `24 MB`），完整支持 `HEAD` 与 `HTTP 206` 字节区间请求、大跨度拖动即时取消旧偏移预取以及上游 `401` / `403` 签名过期回调重取；`ExoPlayer` 针对本机高吞吐分片流自动优化起播缓冲水位，实现 4K 大文件秒开与顺滑拖动。
- **CatVod JAR 爬虫与 QuickJS `//bb` 字节码深度兼容**：补齐 `Spider.client()`、`Spider.safeDns()`、`SpiderApi.multiReq` 并发请求、`CspEngine` 32/64 位 `.so` 安全提取（含目录写权限恢复与 Zip-Slip 防护）；`JsEngine` 新增 `//bb`（`CATOP`）预编译字节码版本动态适配与 `assets://js/lib/` 本地公共桥接库（`cat.js` / `utils.js` / `lodash` / `cheerio`）映射兜底。
- **抗 DNS 污染 DoH 重连与配置容错加固（`Cms`）**：内置阿里 / 腾讯并发 RFC 8484 DoH 清洁 IP 解析器，遇到 DNS 污染、连接重置或持续 `403` 时自动按多套 UA 回退并保持原始 `Host` 与 HTTPS SNI 重连；`MAX_JSON` 提升至 `16 MB` 并全面阻断 `"null"` 字面量污染请求头与解析地址。

## 包信息与构建记录

- **安装包（32 位电视 / 盒子专版）**：`MarcoMovie-0.5.25-android-tv.apk`（更新兼容别名 `MarcoMovie-0.5.25-preview.apk`），官方正式签名，支持应用内直接覆盖升级。
- **SHA-256**：`a16e3b89143281212093520fda2db7951f70b8fbc81e85167b1e808b583df7aa`。
- **对应源码包**：`MarcoMovie-android-tv-v0.5.25-source.zip`，SHA-256：`0b23a7c652f670543e22595964475256c88410cfe9a800c0bf52e770173455cd`。
- **构建提交**：`97f872dead7413120694bf73211b72967ffb4198`。[多端原生构建与校验记录（43729927928）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/43729927928)。

## 验证范围与已知限制

- 通过公共内容守卫检查、Java 格式检查、纯 JVM 全套离线回归（含新增 `LocalProxyRangeChecks` 6 路分片/Seek/403 刷新回归、80 项 `CompatChecks` Spider/QuickJS/DoH 检查与 `CmsChecks`）、API 23 字节码校验及官方正式签名校验。
