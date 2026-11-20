# 跨端转场着色器、极光背景与分级动效规范（`transitions-spec.md`）

> **适用里程碑**：M4（S41 Flutter 着色器转场与极光背景、S42 Android 手机/平板分级转场与极光视图、S43 Android 电视轻量动效）、R4 视觉与性能评审。  
> **参数引用**：所有动画时长（`transitionEnter = 420ms`、`transitionExit = 300ms`、`mobileSharedBounds = 280ms`、`tvPlayExit = 220ms`、`tvPageFade = 180ms`、`fast = 150ms`、`reducedHudFade = 120ms`）、曲线、弹簧频率与色彩常量均引用同目录 `motion-tokens.json`。

---

## 1. 原创视觉概念与净室设计原则

1. **「影院视窗（Cinema Portal）」进退场设计**：
   - 采用 Marco 原创的矩形影院幕布纵深过渡，**不仿照任何圆盘/光盘造型**：当用户在详情页点击播放时，当前详情页截图沿纵深方向轻微后退并伴随暗角收拢为纯黑影院底色（`#000000`），同时详情页圆角海报卡片保持等比裁剪（`BoxFit.cover` 无横向拉伸）平滑展开至视频目标视口，并在中后段（`uProgress: 0.45 -> 0.80`）柔和融入纯黑视窗，随后在 `0.68 -> 1.0` 无缝交接给底层正在起播的真实视频帧，消除生硬黑屏闪切。
2. **「四色低频流光（Marco Aurora）」背景设计**：
   - 仅用于新手引导页、关于页与空状态装饰（**播放中严禁运行**）；采用纯数学低频正弦波带叠加（零纹理采样），四色取自 `apple_theme.dart` 系统色板（`#0A84FF`、`#5AC8FA`、`#5E5CE6`、`#BF5AF2`）叠于 `#09090C` 深色画布之上。
3. **预乘 Alpha（Premultiplied Alpha）铁律**：
   - Flutter `FragmentShader`（Impeller / Skia）与 Android API 33+ AGSL `RuntimeShader` 的片元输出均为**预乘 Alpha** 格式。所有半透明混合必须严格按 `fragColor = vec4(rgb * alpha, alpha)` 及 `outPremul = fgPremul + bgPremul * (1.0 - fgPremul.a)` 计算，严禁直接输出未预乘 `vec4(rgb, alpha)`。

---

## 2. 着色器坐标系契约、Uniform 槽位表与数学方程

### 2.1 详情进入播放器着色器（`flutter/shaders/player_enter.frag`）

> **关键坐标系契约（`CustomPainter` 逻辑像素 vs Android `View` 像素）**：  
> 在 Flutter 3.38.9 中，通过 `CustomPainter.paint(Canvas canvas, Size size)` 调用 `canvas.drawRect(Offset.zero & size, Paint()..shader = fragmentShader)` 时，设备像素比（`dpr`）缩放发生在顶点矩阵中，片元着色器内的 **`FlutterFragCoord().xy` 始终处于画布局部逻辑像素（`lp`）空间 `[0..size.width, 0..size.height]`**！因此 Flutter 端传入 `uViewport`、`uPosterOrigin`、`uSafePadding`、`uPosterRadius` 时**必须统一使用逻辑像素（`lp`）**（严禁乘以 `devicePixelRatio`，否则在 `2x`/`3x` Retina 与高分屏上会出现坐标偏移与仅采样左上角故障）；Android `View.onDraw` 中则统一传入视图局部像素（`px`）。  
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
   *说明*：Impeller OpenGLES 后端中离屏渲染目标（`RepaintBoundary.toImage` 产生的 `uBackdropTex`）纹理 Y 轴翻转，而普通宿主解码位图（`uPosterTex`）保持标准朝向，S41 需对 `uBackdropTex` 使用上述宏保护。
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
   - 圆角矩形 SDF 抗锯齿遮罩：`q = abs(fragCoord - rectCenter) - rectHalfSize + r`，`sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r`，`mask = 1.0 - smoothstep(-0.75, 0.75, sdf)`；在 `uProgress` 从 `0.68 -> 1.0` 区间内，合成画布平滑过渡至纯黑底并在结束瞬间卸载遮罩层。

### 2.2 极光流动背景着色器（`flutter/shaders/aurora.frag`）

> **Uniform 槽位统计**：共 **`16` 个浮点槽位（`Float 0..15`）** + **`0` 个采样器槽位**。

| 槽位 | GLSL 声明 | 类型 | 默认值 / 说明 |
| :---: | :--- | :--- | :--- |
| Float `0..1` | `uniform vec2 uCanvasSize;` | `vec2` | 画布尺寸（Flutter 为 `CustomPainter` 逻辑像素 `lp`；Android 为视图 `px`） |
| Float `2` | `uniform float uElapsedSec;` | `float` | CPU 侧按 **`mod(rawSec, 6283.1853)`**（`2000 * pi`）取模后的秒数：此时 `t = uElapsedSec * 0.38` 周期为 `380 * 2 * pi`，与子谐波系数 `{0.45, 0.55, 0.65, 0.70, 0.85}` 乘积全为精确整数（`171, 209, 247, 266, 323`），回绕处相位跳变为 **`0.0000 rad`**，同时避免长时间运行后移动端 `mediump` 精度退化 |
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

## 3. 各平台分级实现与代码库约束

### 3.1 Flutter（Windows / macOS / iPhone / iPad）— S41

1. **Windows 渲染后端硬性事实与绘制方式约束**：
   - 基线 Windows 客户端运行在 **Skia over ANGLE / D3D11** 后端，`ImageFilter.isShaderFilterSupported == false`（`apple_theme.dart:17, 333, 359`）。
   - **强制规范**：`PlayerEnterTransition` 与 `AuroraBackground` **严禁使用 `BackdropFilter` + `ImageFilter.shader(...)`**，必须统一通过 **`CustomPainter` + `Canvas.drawRect(Offset.zero & size, Paint()..shader = fragmentShader)`** 绘制。
2. **截图降采样预算与纹理即时销毁**：
   - 进入播放器前抓取详情页 `RepaintBoundary.toImage(pixelRatio: captureRatio)`，动态限制截图最长边 **`<= 1280px`**。
   - 转场完成（`AnimationStatus.completed` / `dismissed`）或路由销毁（`dispose`）的**当帧必须显式调用 `capturedImage.dispose()`**。
3. **三重自动降级机制（Challenger / R4 必测）**：
   - **降级 1（无障碍减少动态效果）**：`MediaQuery.disableAnimationsOf(context) == true` 时，跳过截图与着色器，直接执行 **`150ms`（`durationsMs.fast`）线性交叉淡入**。
   - **降级 2（着色器不可用或编译异常）**：`FragmentProgram.fromAsset` 抛错、尚未预热完成、或 `OhosRuntime.isOhos == true` 时，自动回退为 **`220ms`（`durationsMs.standard`）缩放（`0.96 -> 1.0`）+ 淡入（`curves.decelerate`）**。
   - **降级 3（截图耗时超预算）**：`Stopwatch` 实测 `toImage()` 超过 **`16ms`**（`hudTimersMs.transitionCaptureBudget`）时，标记会话 `preferFastTransition = true`，跳过截图改走缩放 + 淡入兜底。
4. **iOS `apple_theme.dart` 与 `IosNativeRouteGate` 协同**：
   - 封装在 `flutter/lib/ui/motion/player_enter_transition.dart`，接入 `detail_screen.dart` `_openPlayer`（`:922-933`），兼容 `IosNativeRouteGate` 在 `route.isCurrent == false` 时正常门控底层 `UiKitView`。
5. **`AuroraBackground` 零外部依赖生命周期门控**：
   - 严禁向 `flutter/pubspec.yaml` 添加任何新依赖包（M4 仅允许编辑 `shaders` 段）；仅使用 Flutter SDK 内置的 **`TickerMode.of(context)`**、**`RouteAware`（`RouteObserver`）/ `ModalRoute.of(context)?.isCurrent`** 与 **`AppLifecycleListener`**：当页面被压入路由栈底、不可见、窗口后台化或开启「减少动态效果」时立即 `Ticker.stop()`。

### 3.2 Android 手机 / 平板（`minSdk 23`）— S42

1. **海报 -> 详情页转场（`MobileDetailScreen.java`）**：
   - 针对 `MainActivity` 单 Activity 内部视图切换架构，点击海报卡片时读取其视图 `Rect`，在 `MobileDetailScreen` 首帧执行 **`280ms`（`durationsMs.mobileSharedBounds`，`curves.decelerate`）** 坐标/尺寸插值与内容淡入。
2. **详情页 -> 播放器分级转场与 AGSL 像素坐标映射**：
   - **API 33+（Android 13+）**：使用 `android.graphics.RuntimeShader`（AGSL，`420ms` `transitionEnter`）。**重要 AGSL 坐标约束**：与 GLSL `texture(sampler2D, uv)` 归一化 `[0..1]` 采样不同，Android AGSL 的 `uniform shader uBackdropTex; uBackdropTex.eval(coord)` 接收的是**未归一化的 Bitmap 物理像素坐标 `[0..bitmapW, 0..bitmapH]`**！因截图 Bitmap 已降采样至最长边 `<= 1080px`（小于全屏 View 尺寸），S42 必须显式传入 `uniform float2 uBackdropTexSize; uniform float2 uPosterTexSize;` 并调用 `uBackdropTex.eval(normUv * uBackdropTexSize)`（或为 `BitmapShader` 配置缩放 `Matrix`），动画结束立即释放 Bitmap。
   - **API 23–32（Android 6.0–12L）**：使用 `ValueAnimator`（`420ms`）配合预分配的 `android.graphics.Camera` + `Matrix` 对详情层执行纵深后退缩放，驱动封面等比放大并淡入黑底播放器（`onAnimationUpdate` 内零对象分配）。
   - **开启 `Prefs.REDUCED`**：降级为 `150ms`（`durationsMs.fast`）纯透明度淡入淡出。
3. **`AuroraView` 分级实现**：
   - **API 33+**：使用 AGSL `RuntimeShader` 运行 2.2 节同款四色谐波公式。
   - **API 23–32**：构造时预分配 `LinearGradient` 与 `Matrix`，每帧仅通过 `Shader.setLocalMatrix(matrix)` 驱动色带位移，**每帧 `0` 堆内存分配**；在 `onDetachedFromWindow()`、不可见或 `a.reduced == true` 时立即停止回调。

### 3.3 Android 电视（ARM32 Android 9 性能底线）— S43

- **硬性禁令**：电视端**全面禁止**运行任何 `RuntimeShader`、`RenderEffect`、`BlurMaskFilter` 或全屏截图纹理转场。
- **仅保留三项纯硬件属性轻量动效**：
  1. **焦点弹簧缩放**：对齐 `FocusMotion.java` 与 `MotionSpring(0, 30, 0.0025f)`（`tvFocus`：海报 `1.05x`、胶囊按钮 `1.06x` + `2dp` `#FFF5F5F7` 描边）。
  2. **页面切换**：**`180ms`（`durationsMs.tvPageFade`）** 纯 `alpha` 淡入淡出。
  3. **进入播放器**：封面视图做 **`220ms`（`durationsMs.tvPlayExit`）** 等比放大（`1.0 -> 1.08`）伴随整体淡出至黑色播放层；极光背景位固定为静态暗色渐变。
- **性能红线**：Android 9 ARM32 盒子上 `gfxinfo` 采样帧率 **`>= 50fps`**（P90 `<= 20ms`）；`Prefs.REDUCED` 开启时焦点缩放固定 `1.0x`，页面/播放淡入缩短至 `120ms`（`durationsMs.reducedHudFade`）。

---

## 4. 不在范围内（Out of Scope）

1. **Android Lite（API 14）动效改造**：Lite 不引入任何转场动画或极光视图。
2. **Apple TV（`tvos/`）与 HarmonyOS NEXT（`flutter/ohos/`、`flutter/lib/ui/tv/**`）**：只读不改；`OhosRuntime.isOhos` 下自动走无着色器兜底分支。
3. **播放器解码色彩空间自定义 HDR/杜比视界色调映射着色器**。
4. **任何光盘/碟片几何造型或新增外部动画依赖库（如 `androidx.dynamicanimation`、`visibility_detector`、Lottie、Rive）**。
