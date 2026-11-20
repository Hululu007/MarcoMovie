# 跨端转场着色器、极光背景、品牌加载动画与桌面画质增强规范（`transitions-spec.md` · v2 基线对齐修订版）

> **适用里程碑**：Wave 1 · M4a（独立着色器、动效组件与 **F8 品牌丝带 M 加载组件**，不碰详情页与播放器主文件）、Wave 2（M4b 跨端无黑洞转场与极光接线 + **F9 桌面端 Anime4K**）、Gate 2 · R4 视觉与性能终审。  
> **参数引用**：所有动画时长（`transitionEnter = 420ms`、`transitionExit = 300ms`、`mobileSharedBounds = 280ms`、`tvPlayExit = 220ms`、`tvPageFade = 180ms`、`fast = 150ms`、`reducedHudFade = 120ms`、`logoLoop = 1600ms`）、曲线、弹簧频率与色彩常量均引用同目录 `motion-tokens.json`。

---

## 1. 原创视觉概念、既有组件复用与净室设计原则

1. **「影院视窗（Cinema Portal）」进退场设计**：
   - 采用 Marco 原创的矩形影院幕布纵深过渡，**绝不仿照任何圆盘/光盘造型**：当用户在详情页点击播放时，当前详情页截图沿纵深方向轻微后退并伴随暗角收拢为纯黑影院底色（`#000000`），同时详情页圆角海报卡片保持等比裁剪（`BoxFit.cover` 无横向拉伸）平滑展开至视频目标视口，并在中后段（`uProgress: 0.45 -> 0.80`）柔和融入纯黑视窗，随后在 `0.68 -> 1.0` 无缝交接给底层正在起播的真实视频帧，消除生硬黑屏闪切。
2. **「四色低频流光（Marco Aurora）」背景与既有氛围系统融合**：
   - 仅用于新手引导页、关于页与空状态装饰（**播放中严禁运行**）；采用纯数学低频正弦波带叠加（零纹理采样），四色取自 `apple_theme.dart` 系统色板（`#0A84FF`、`#5AC8FA`、`#5E5CE6`、`#BF5AF2`）叠于 `#09090C` 深色画布之上。
   - **严禁重复造轮子**：Flutter 端已有 `AppleAmbientBackground`（`apple_theme.dart:2393` `'aurora'` 预设）与 Windows 专属高速静态 `WindowsBackdrop`；Android 电视与手机已有 `HomeAmbient.java`（含 `"极光青翠"` 等 6 档预设与封面取色）。Wave 1（M4a）先构建独立的 `aurora.frag` / `AuroraBackground` / `AuroraSurfaceView` 底层渲染器，Wave 2（M4b）将其按平台能力无感接入既有 `AppleAmbientBackground` 与引导/关于页，Android TV 端直接保留现有 `HomeAmbient.java` 与静态暗色渐变，不新建多余电视背景类。
3. **预乘 Alpha（Premultiplied Alpha）铁律**：
   - Flutter `FragmentShader`（Impeller / Skia）与 Android API 33+ AGSL `RuntimeShader` 的片元输出均为**预乘 Alpha** 格式。所有半透明混合必须严格按 `fragColor = vec4(rgb * alpha, alpha)` 及 `outPremul = fgPremul + bgPremul * (1.0 - fgPremul.a)` 计算，严禁直接输出未预乘 `vec4(rgb, alpha)`。

---

## 2. 着色器坐标系契约、Uniform 槽位表与数学方程

### 2.1 详情进入播放器着色器（`flutter/shaders/player_enter.frag`）

> **关键坐标系契约（`CustomPainter` 逻辑像素 vs Android `View` 像素）**：  
> 在 Flutter 3.38.9 中，通过 `CustomPainter.paint(Canvas canvas, Size size)` 调用 `canvas.drawRect(Offset.zero & size, Paint()..shader = fragmentShader)` 时，设备像素比（`dpr`）缩放发生在顶点矩阵中，片元着色器内的 **`FlutterFragCoord().xy` 始终处于画布局部逻辑像素（`lp`）空间 `[0..size.width, 0..size.height]`**！因此 Flutter 端传入 `uViewport`、`uPosterOrigin`、`uSafePadding`、`uPosterRadius` 时**必须统一使用逻辑像素（`lp`）**（严禁乘以 `devicePixelRatio`）；Android `View.onDraw` 中则统一传入视图局部像素（`px`）。  
> **Uniform 槽位统计**：共 **`15` 个浮点槽位（`Float 0..14`）** + **`2` 个采样器槽位（`Sampler 0..1`）**。

| 槽位 / 索引 | GLSL 声明 | 类型 | 取值与几何单位 |
| :---: | :--- | :--- | :--- |
| Float `0..1` | `uniform vec2 uViewport;` | `vec2` | 画布尺寸 `(width, height)`（Flutter 为逻辑像素 `lp`；Android 为视图 `px`） |
| Float `2` | `uniform float uProgress;` | `float` | 归一化转场进度 `[0.0, 1.0]`（进场 `0 -> 1`，退场 `1 -> 0`） |
| Float `3` | `uniform float uRecedeTilt;` | `float` | 背景页纵深俯仰系数 `0.10 * sin(3.14159265 * uProgress)` |
| Float `4..7` | `uniform vec4 uPosterOrigin;` | `vec4` | 海报起始画布矩形 `(left, top, width, height)`（单位与 `uViewport` 一致） |
| Float `8..11` | `uniform vec4 uSafePadding;` | `vec4` | 安全区内边距 `(left, top, right, bottom)`（单位与 `uViewport` 一致） |
| Float `12` | `uniform float uPosterRadius;` | `float` | 海报起始圆角半径（随进度插值至 `0.0`，单位与 `uViewport` 一致） |
| Float `13` | `uniform float uPosterAvailable;` | `float` | 海报纹理就绪标志（`1.0` = 已就绪，`0.0` = 使用深色占位底卡） |
| Float `14` | `uniform float uPosterAspect;` | `float` | 海报原始宽高比 `posterWidth / max(posterHeight, 1.0)`（默认竖版海报 `0.6667`） |
| Sampler `0` | `uniform sampler2D uBackdropTex;` | `sampler2D` | 降采样后的详情页 `RepaintBoundary` 截图纹理 |
| Sampler `1` | `uniform sampler2D uPosterTex;` | `sampler2D` | 海报 `ui.Image` 纹理（未就绪时绑定 `1x1` 透明单例纹理） |

**OpenGLES 纹理翻转与防拉伸核心片元方程**：
1. **OpenGLES Y 轴翻转守卫（对齐 `flutter/shaders/glasswork.frag:10-12`）**：
   ```glsl
   #include <flutter/runtime_effect.glsl>
   // ... 15 float slots (0..14) + 2 sampler2D slots (0..1) ...
   out vec4 fragColor;

   vec4 sampleBackdrop(vec2 normUv) {
       vec2 uv = clamp(normUv, vec2(0.0), vec2(1.0));
   #ifdef IMPELLER_TARGET_OPENGLES
       uv.y = 1.0 - uv.y;
   #endif
       return texture(uBackdropTex, uv);
   }
   ```
2. **纵深后退、圆角距离场（SDF）与等比无拉伸海报采样（`BoxFit.cover`）**：
   - 归一化片元坐标：`fragCoord = FlutterFragCoord().xy`，`p = fragCoord / max(uViewport, vec2(1.0))`；
   - 背景页透视后退：`scaleBg = mix(1.0, 0.91, smoothstep(0.0, 0.85, uProgress))`，垂直梯形透视 `perspX = (p.x - 0.5) / (1.0 - uRecedeTilt * (p.y - 0.5)) + 0.5`，背景压暗 `bgDim = 1.0 - smoothstep(0.10, 0.88, uProgress)`；
   - 视窗矩形与圆角插值：目标矩形 `targetRect` 为扣除 `uSafePadding` 后的居中 `16:9` 视口矩形；`curRect = mix(uPosterOrigin, targetRect, smoothstep(0.0, 0.82, uProgress))`，`r = mix(uPosterRadius, 0.0, smoothstep(0.15, 0.75, uProgress))`；
   - **海报等比居中裁剪（消除 `2:3 -> 16:9` 横向 `267%` 畸变）**：
     ```glsl
     vec2 localUv = (fragCoord - curRect.xy) / max(curRect.zw, vec2(1.0));
     float rectAspect = curRect.z / max(curRect.w, 1.0);
     float safePosterAspect = max(uPosterAspect, 0.0001);
     vec2 coverScale = rectAspect > safePosterAspect
         ? vec2(1.0, safePosterAspect / rectAspect)
         : vec2(rectAspect / safePosterAspect, 1.0);
     vec2 posterUv = clamp((localUv - 0.5) * coverScale + 0.5, vec2(0.0), vec2(1.0));
     float posterFade = 1.0 - smoothstep(0.45, 0.80, uProgress);
     vec3 posterRgb = uPosterAvailable > 0.5 ? texture(uPosterTex, posterUv).rgb * posterFade : vec3(0.0);
     ```
   - 圆角矩形 SDF 抗锯齿遮罩：`q = abs(fragCoord - rectCenter) - rectHalfSize + r`，`sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r`，`mask = 1.0 - smoothstep(-0.75, 0.75, sdf)`；在 `uProgress` 从 `0.68 -> 1.0` 区间内平滑过渡至纯黑底并在结束瞬间卸载遮罩层。

### 2.2 极光流动背景着色器（`flutter/shaders/aurora.frag`）

> **Uniform 槽位统计**：共 **`16` 个浮点槽位（`Float 0..15`）** + **`0` 个采样器槽位**。

| 槽位 | GLSL 声明 | 类型 | 默认值 / 说明 |
| :---: | :--- | :--- | :--- |
| Float `0..1` | `uniform vec2 uCanvasSize;` | `vec2` | 画布尺寸（Flutter 为 `CustomPainter` 逻辑像素 `lp`；Android 为视图 `px`） |
| Float `2` | `uniform float uElapsedSec;` | `float` | CPU 侧按 **`mod(rawSec, 6283.1853)`**（`2000 * pi`）取模后的秒数：与子谐波系数 `{0.45, 0.55, 0.65, 0.70, 0.85}` 乘积全为精确整数，回绕处相位跳变为 `0.0000 rad`，避免移动端 `mediump` 精度退化 |
| Float `3` | `uniform float uStrength;` | `float` | 极光混合强度（默认 `0.62`，范围 `0.0..1.0`） |
| Float `4..6` | `uniform vec3 uWaveBlue;` | `vec3` | `#0A84FF` -> `(0.039, 0.518, 1.000)` |
| Float `7..9` | `uniform vec3 uWaveTeal;` | `vec3` | `#5AC8FA` -> `(0.353, 0.784, 0.980)` |
| Float `10..12` | `uniform vec3 uWaveIndigo;` | `vec3` | `#5E5CE6` -> `(0.369, 0.361, 0.902)` |
| Float `13..15` | `uniform vec3 uWavePurple;` | `vec3` | `#BF5AF2` -> `(0.749, 0.353, 0.949)` |

**零纹理谐波方程**：
- 纵横比校正坐标：`uv = (FlutterFragCoord().xy - 0.5 * uCanvasSize) / max(uCanvasSize.y, 1.0)`，`t = uElapsedSec * 0.38`；
- 三道正交相位波带：
  - `w1 = exp(-3.4 * pow(uv.y + 0.22 * sin(uv.x * 2.1 + t) + 0.12 * cos(uv.x * 1.3 - t * 0.7), 2.0))`
  - `w2 = exp(-4.2 * pow(uv.y - 0.18 * cos(uv.x * 1.7 - t * 0.85) + 0.15 * sin(t * 0.45), 2.0))`
  - `w3 = exp(-3.8 * pow(length(uv - vec2(0.28 * sin(t * 0.55), -0.16 * cos(t * 0.65))) - 0.34, 2.0))`
- 底色 `base = vec3(0.035, 0.035, 0.047)`（`#09090C`），叠加后 `color = clamp(base + uStrength * (0.42 * w1 * mix(uWaveBlue, uWaveTeal, 0.5 + 0.5 * sin(t)) + 0.36 * w2 * uWaveIndigo + 0.30 * w3 * uWavePurple), 0.0, 1.0)`，输出 `vec4(color, 1.0)`。

---

## 3. 各平台分级实现与 Wave 1 / Wave 2 边界契约

### 3.1 Flutter（Windows / macOS / iPhone / iPad）— M4a（组件）& M4b（接线）

1. **Windows 渲染后端硬性事实与绘制约束**：
   - 基线 Windows 客户端运行在 **Skia over ANGLE / D3D11** 后端，`ImageFilter.isShaderFilterSupported == false`（`apple_theme.dart:17, 333, 359`）。
   - `PlayerEnterTransition` 与 `AuroraBackground` **严禁使用 `BackdropFilter` + `ImageFilter.shader(...)`**，统一通过 **`CustomPainter` + `Canvas.drawRect(Offset.zero & size, Paint()..shader = fragmentShader)`** 绘制；Windows 下背景页继续保持静态 `WindowsBackdrop`（不常驻跑 `aurora.frag`），确保零核显负担。
2. **iOS 26 原生 `UiKitView` 无黑洞转场截图契约（Wave 2 · M4b 必遵）**：
   - 基线 `detail_screen.dart` 含有原生 iOS 26 `IosNativeGlassButton`（`UiKitView`），而 Flutter `RepaintBoundary.toImage()` 无法捕获系统合成器层的 `UiKitView`，直接截图会在按钮位置留下空白缺口。
   - **强制时序**：Wave 2 封装统一路由辅助函数 `pushPlayerRoute(...)`（覆盖 `detail_screen.dart`、`windows_detail.dart` 等播放入口），在 iOS 26+ 上调用 M2 提供的 **`IosNativeRouteGate.runWithPlaceholders(() async { await WidgetsBinding.instance.endOfFrame; return boundary.toImage(...); })`**（内部使用 `try / finally` 确保异常或取消时 100% 恢复原生视图），单帧切换为等尺寸 Flutter 玻璃占位符后再抓取截图（最长边 `<= 1280px`），转场完成或 `dispose` 的当帧立即调用 `capturedImage.dispose()`。
3. **三重自动降级机制（Challenger / R4 必测）**：
   - **降级 1（无障碍减少动态效果）**：`MediaQuery.disableAnimationsOf(context) == true` 时，跳过截图与着色器，直接执行 **`150ms`（`durationsMs.fast`）线性交叉淡入**。
   - **降级 2（着色器不可用或编译异常）**：`FragmentProgram.fromAsset` 抛错、尚未预热完成、或 `OhosRuntime.isOhos == true` 时，自动回退为 **`220ms`（`durationsMs.standard`）缩放（`0.96 -> 1.0`）+ 淡入（`curves.decelerate`）**（Windows 若用户开启快速模式亦直接走 `185ms` 零截图快速转场）。
   - **降级 3（截图耗时超预算）**：`Stopwatch` 实测 `toImage()` 超过 **`16ms`**（`hudTimersMs.transitionCaptureBudget`）时，标记会话 `preferFastTransition = true`，后续直接走零截图缩放 + 淡入兜底。
4. **`flutter/pubspec.yaml` 防冲突写入约定**：
   - Wave 1 中 M4a **仅允许在 `flutter/pubspec.yaml` 第 48 行 `shaders:` 段紧邻追加 `- shaders/player_enter.frag` 与 `- shaders/aurora.frag`**，严禁触碰末尾 `assets:` 段（与 M1 完全无重叠上下文）且严禁添加任何第三方 pub 依赖；`AuroraBackground` 仅用内置 `TickerMode`、`ModalRoute.of(context)?.isCurrent` 与 `AppLifecycleListener` 在不可见/后台时立即 `Ticker.stop()`。

### 3.2 Android 手机 / 平板（`minSdk 23`）— M4a（辅助类）& M4b（接线）

1. **海报 -> 详情页转场（`MobileDetailScreen.java`）**：
   - 点击海报卡片时读取其视图 `Rect`，在 `MobileDetailScreen` 首帧执行 **`280ms`（`durationsMs.mobileSharedBounds`，`curves.decelerate`）** 坐标/尺寸插值与内容淡入。
2. **详情页 -> 播放器分级转场（硬件加速零模糊抖动）**：
   - **API 33+（Android 13+）**：使用 `android.graphics.RuntimeShader`（AGSL，`420ms` `transitionEnter`）。**重要 AGSL 坐标约束**：`uBackdropTex.eval(coord)` 接收未归一化的 Bitmap 物理像素坐标 `[0..bitmapW, 0..bitmapH]`，因截图已降采样至最长边 `<= 1080px`，必须传入 `uBackdropTexSize` 并调用 `uBackdropTex.eval(normUv * uBackdropTexSize)`，动画结束立即释放 Bitmap。
   - **API 23–32（Android 6.0–12L）**：**禁用软件 `Camera + Matrix` 重绘**，改用纯硬件加速 `RenderNode` 视图属性（`scaleX`、`scaleY`、`alpha`、`translationY`，`320ms` `durationsMs.emphasized`）驱动详情层后退缩放与封面等比放大淡入黑底播放层，并在动画期间**临时冻结 `GlassworkSurface` 模糊重采样**（`onAnimationUpdate` 内零堆内存分配，彻底消除中低端机滚动/缩放重抓帧掉帧）。
   - **开启 `Prefs.REDUCED`**：降级为 `150ms`（`durationsMs.fast`）纯透明度淡入淡出。
3. **`AuroraSurfaceView` 分级实现**：
   - **API 33+**：使用 AGSL `RuntimeShader` 运行 2.2 节四色谐波公式。
   - **API 23–32**：构造时预分配 `LinearGradient` 与 `Matrix`，每帧仅通过 `Shader.setLocalMatrix(matrix)` 驱动色带平移（每帧 `0` 堆分配）；不可见、`onDetachedFromWindow()` 或 `a.reduced == true` 时立即停止回调。

### 3.3 Android 电视（ARM32 Android 9 性能底线）— 守护 V17 既有体验

- **硬性禁令**：电视端**全面禁止**运行任何 `RuntimeShader`、`RenderEffect`、`BlurMaskFilter` 或全屏截图纹理转场，且不新建重复极光背景类（保留既有 `HomeAmbient.java`）。
- **轻量硬件属性动效**：
  1. **焦点弹簧缩放**：完整保留 `FocusMotion.java`（Wave 2 在其中补齐 `Prefs.REDUCED` 守卫：开启减少动态效果时焦点缩放固定 `1.0x`，保留高对比焦点描边）。
  2. **页面切换与进入播放器**：页面切换采用 `180ms` 纯 `alpha` 淡入淡出；进入播放器时封面视图做 `220ms` 等比放大（`1.0 -> 1.08`）伴随整体淡出至黑色播放层；Android 9 ARM32 盒子 `gfxinfo` 帧率 **`>= 50fps`**（P90 `<= 20ms`）。

---

## 4. 品牌丝带 M 加载动画（F8）与桌面端 Anime4K（F9）规范

### 4.1 品牌金属胶片丝带 M 加载组件（F8 — Wave 1 · M4a 实现，Wave 2 挂载）
1. **既有几何资产复用**：直接复用 Android `StartupIntro.BrandView` 与 Flutter `MarcoBrandLogo`（`apple_theme.dart`）既有的「金属胶片丝带 M」矢量轮廓，**严禁参考任何外部吉祥物形象**。
2. **动画节奏与降级**：
   - 新建 `BrandLogoLoaderView.java`（Android 自定义轻量矢量绘制 View，零每帧对象分配）与 `flutter/lib/ui/motion/brand_logo_loader.dart`（Flutter `CustomPainter`）：周期固定为 **`1600ms`（`durationsMs.logoLoop`）**，前半段做丝带连续路径描边延伸，后半段叠加一道斜向金属高光扫过，用于播放器起播缓冲等待与详情加载态（替代生硬的系统默认菊花转圈）；
   - 当开启「减少动态效果」（`Prefs.REDUCED` / `MediaQuery.disableAnimationsOf(context)`）或处于不可见后台时，自动切换为 `accessibilitySubstitutions.reduceMotion.rules.brandLogoLoader` 定义的静态丝带 + 柔和透明度呼吸（`0.72 .. 1.0`），后台时完全停止计时器。

### 4.2 桌面端 Anime4K 实时画质增强（F9 — Wave 2 · 线 B 实现，仅限 Windows / macOS）
1. **开源合规与着色器来源锁定**：
   - 仅从官方开源仓库 `bloc97/Anime4K`（**MIT License**）引入固定版本 `v4.0.1` 的轻量 GLSL 着色器文件（存放于 `flutter/assets/shaders/anime4k/`），在同目录清单中记录上游版本号与每个文件的精确 SHA-256 校验值，并将完整 MIT 版权与许可声明追加写入仓库根目录 `THIRD_PARTY_NOTICES.md`。
2. **四档预设与 `libmpv` 无缝热切换**：
   - 在桌面端播放设置中提供 **`关闭`（默认）**、**`性能`（Clamp + Restore_CNN_S）**、**`均衡`（Clamp + Restore_CNN_M / Upscale_CNN_x2_S）**、**`画质`（Clamp + Restore_CNN_VL + Upscale_CNN_x2_M）** 四档会话/本机可选预设；
   - 运行时先将所需资产解压或同步至应用缓存目录，通过 `media_kit` 底层 `(player.platform as NativePlayer).setProperty('glsl-shaders', joinedPaths)`（关闭时传 `""`）**在不中断、不重启当前播放进度的前提下实时热切换**（若当前平台 `player.platform` 非 `NativePlayer` 则优雅隐藏入口，绝不抛异常）；
   - 当检测到当前视频高度 `> 1080`（如原生 4K 流）时，在界面显示轻量提示 `"当前已是超清分辨率，开启 Anime4K 会显著增加显卡负载"`。
3. **Windows `bilinear` 采样器条件释放与恢复契约（关键协同点）**：
   - 基线 `player_screen.dart:1499-1522` 为兼顾核显负载在 Windows 上默认设置了 `scale=bilinear` / `cscale=bilinear`；
   - **强制联动规则**：在 Windows 上，**仅当用户主动将 Anime4K 切换为非「关闭」档位时**，同步将 `NativePlayer` 的 `scale` / `cscale` 切换为 `'spline36'` 以发挥超分着色器效果；一旦用户切回 **`关闭`**，必须**立即恢复 Windows 默认的 `'bilinear'`**！iOS、iPadOS、Android 全端与 `OhosRuntime.isOhos` 严禁展示或启用 Anime4K。

---

## 5. 不在范围内（Out of Scope）

1. **Android Lite（API 14）动效或加载器改造**。
2. **Apple TV（`tvos/`）与 HarmonyOS NEXT（`flutter/ohos/`、`flutter/lib/ui/tv/**`）**：只读不改；`OhosRuntime.isOhos` 下自动走无着色器静态兜底且隐藏 Anime4K。
3. **移动端 / 电视端 Anime4K，以及播放器解码色彩空间自定义 HDR/杜比视界色调映射着色器**。
4. **任何光盘/碟片几何造型或新增外部动画依赖库（如 `androidx.dynamicanimation`、`visibility_detector`、Lottie、Rive）**。
