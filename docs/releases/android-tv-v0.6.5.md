# Marco Movie Android 电视 / 盒子 0.6.5

发布日期：2026-11-28。应用版本 `0.6.5`（版本代码 `102`）；最低 Android 6 / API 23（32 位 `armeabi-v7a`）。本次为电视端背景视觉专项修复版本，彻底消除 `0.6.4` 大屏动态柔光背景出现的菱形噪点纹，并完整保留 `0.6.4` 全部功能与稳定性改进。

## 本次更新

- **修复电视端背景出现菱形网格纹问题**：将 `HomeAmbient.acquireTvScratchBitmap()` 缓存位图色彩格式由 16 位 `Bitmap.Config.RGB_565` 恢复为 32 位 `Bitmap.Config.ARGB_8888`（保留双缓冲复用与绘图前 `eraseColor` 底色擦除，消除有序抖动矩阵在 `192×108` 放大至 `1920×1080` 大屏时造成的菱形棋盘纹），恢复纯净平滑的影院柔光渐变背景；并在 `TvUxOptimizationChecks` 中补充防回退守护校验。

## 验证范围与实机证据

- **精确构建提交与校验**：`79d63024ce6fedd872b6748b9de208ad08d81c2f`（`git_dirty: false`）。已通过 `check_public_content.py`（`2896` 文件）、`format_java --check`（`645` 文件）、`sync_readme_versions --check`、`run_tv_ux_optimization_checks.py`（含 `HomeAmbient` 32 位 `ARGB_8888` 回归校验）、`run_checks.py` 全套回归、`run_api23_callback_checks.py`（`945` 应用类）与 `run_guard_checks.py`（`170` 项）。
- **物理电视真机升级与视觉验收**：在小米电视 Android 9（`MiTV-ASTP0`，`armeabi-v7a`）完成从 `0.6.4 (101)` 保留配置无损覆盖安装至 `0.6.5 (102)`、冷启动拉起（`2943ms`，零崩溃）以及首页截屏对比核验，确认首页深色柔光渐变区域菱形纹已完全消除。更多品牌电视与完整长片播放仍待继续覆盖。

## 安装与校验

- **正式包名**：`com.pilipala.marcomovie`（TV edition，`minSdk 23` / `targetSdk 28`；同字节兼容别名 `MarcoMovie-0.6.5-preview.apk`）。
- **TV APK SHA-256**：`MarcoMovie-0.6.5-android-tv.apk`（`56936646` B）— `ca077300759218e262aa4fe46425ca83019d10c72b1b367c6f5834145fef011d`。
- **对应源码包 SHA-256**：`MarcoMovie-android-tv-v0.6.5-source.zip`（`23509378` B）— `e1d85c51df2bb8e4f07ebb951549f3b904329baa59756bf6c8d57d895161bc90`。
- **官方签名证书 SHA-256**：`2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de`。
