# 跨端转场着色器、极光背景与分级动效规范（`transitions-spec.md`）

> **适用里程碑**：M4（S41 Flutter 着色器转场与极光背景、S42 Android 手机/平板分级转场与极光视图、S43 Android 电视轻量动效）、R4 视觉与性能评审。  
> **参数引用**：所有动画时长、曲线、弹簧频率与色彩常量均引用同目录 `motion-tokens.json`。

---

## 1. 原创视觉概念与净室设计原则

1. **「影院视窗（Cinema Portal）」进退场设计**：
   - 采用 Marco 原创的矩形影院幕布纵深过渡，**不仿照任何圆盘/光盘造型**：当用户在详情页点击播放时，当前详情页截图沿纵深方向轻微后退并伴随暗角收拢为纯黑影院底色（`#000000`），同时详情页圆角海报卡片平滑展开至视频目标视口比例，并在后半段（`progress: 0.68 -> 1.0`）柔和消隐，无缝交接给底层正在起播的真实视频帧，消除生硬黑屏闪切。
2. **「四色低频流光（Marco Aurora）」背景设计**：
   - 仅用于新手引导页、关于页与空状态装饰（**播放中严禁运行**）；采用纯数学低频正弦波带叠加（零纹理采样），四色取自 `apple_theme.dart` 系统色板（`#0A84FF`、`#5AC8FA`、`#5E5CE6`、`#BF5AF2`）叠于 `#09090C` 深色画布之上。
3. **预乘 Alpha（Premultiplied Alpha）铁律**：
   - Flutter `FragmentShader`（Impeller / Skia）与 Android API 33+ AGSL `RuntimeShader` 的片元输出均为**预乘 Alpha** 格式。所有半透明混合必须严格按 `fragColor = vec4(rgb * alpha, alpha)` 及 `outPremul = fgPremul + bgPremul * (1.0 - fgPremul.a)` 计算，严禁直接输出未预乘 `vec4(rgb, alpha)` 造成金属高光边缘白边或过曝伪影。

---

## 2. 着色器 Uniform 槽位表与数学方程

### 2.1 详情进入播放器着色器（`flutter/shaders/player_enter.frag`）

> **Flutter `FragmentShader` 绑定顺序说明**：`setFloat(slotIndex, value)` 按 GLSL 中非采样器 `uniform` 的声明顺序线性展开（`vec2` 占 2 槽、`vec4` 占 4 槽）；`setImageSampler(samplerIndex, image)` 独立从 `0` 编号。

| 槽位 / 索引 | GLSL 声明 | 类型 | 取值与物理含义 |
| :---: | :--- | :--- | :--- |
| Float `0..1` | `uniform vec2 uViewport;` | `vec2` | 渲染画布物理像素尺寸 `(widthPx, heightPx)` |
| Float `2` | `uniform float uProgress;` | `float` | 归一化转场进度 `[0.0, 1.0]`（进场 `0 -> 1`，退场 `1 -> 0`） |
| Float `3` | `uniform float uRecedeTilt;` | `float` | 背景页纵深俯仰系数 `0.10 * sin(3.14159265 * uProgress)` |
| Float `4..7` | `uniform vec4 uPosterOrigin;` | `vec4` | 海报起始屏幕物理像素矩形 `(leftPx, topPx, widthPx, heightPx)` |
| Float `8..11` | `uniform vec4 uSafePadding;` | `vec4` | 安全区内边距物理像素 `(leftPx, topPx, rightPx, bottomPx)`，避让刘海与灵动岛 |
| Float `12` | `uniform float uPosterRadius;` | `float` | 海报起始圆角物理像素（随进度插值至 `0.0`） |
| Float `13` | `uniform float uPosterAvailable;` | `float` | 海报纹理就绪标志（`1.0` = 已就绪，`0.0` = 使用深色占位底卡，防未加载闪黑） |
| Sampler `0` | `uniform sampler2D uBackdropTex;` | `sampler2D` | 降采样后的详情页 `RepaintBoundary` 截图纹理 |
| Sampler `1` | `uniform sampler2D uPosterTex;` | `sampler2D` | 海报 `ui.Image` 纹理（未就绪时绑定 `1x1` 透明单例纹理） |

**OpenGLES 纹理翻转与核心片元数学约束**：
1. **OpenGLES Y 轴翻转守卫（对齐 `flutter/shaders/glasswork.frag:10-12`）**：
   ```glsl
   #include <flutter/runtime_effect.glsl>
   // ... uniforms ...
   out vec4 fragColor;

   vec4 sampleBackdrop(vec2 normUv) {
       vec2 uv = clamp(normUv, vec2(0.0), vec2(1.0));
   #ifdef IMPELLER_TARGET_OPENGLES
       uv.y = 1.0 - uv.y;
   #endif
       return texture(uBackdropTex, uv);
   }
   ```
2. **纵深后退与圆角距离场（SDF）核心公式**：
   - 归一化片元坐标：`p = FlutterFragCoord().xy / max(uViewport, vec2(1.0))`；
   - 背景页透视缩放与后退：`scaleBg = mix(1.0, 0.91, smoothstep(0.0, 0.85, uProgress))`，垂直梯形透视偏移 `perspX = (p.x - 0.5) / (1.0 - uRecedeTilt * (p.y - 0.5)) + 0.5`，背景压暗系数 `bgDim = 1.0 - smoothstep(0.10, 0.88, uProgress)`；
   - 海报矩形插值：目标矩形 `targetRect` 为扣除 `uSafePadding` 后的居中 `16:9` 视口矩形；当前矩形 `curRect = mix(uPosterOrigin, targetRect, smoothstep(0.0, 0.82, uProgress))`，当前圆角 `r = mix(uPosterRadius, 0.0, smoothstep(0.15, 0.75, uProgress))`；
   - 圆角矩形有向距离：`q = abs(fragPx - rectCenter) - rectHalfSize + r`，`sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r`，抗锯齿遮罩 `mask = 1.0 - smoothstep(-0.75, 0.75, sdf)`；
   - 收尾交接：在 `uProgress` 从 `0.68 -> 1.0` 区间内，合成画布平滑过渡至纯黑底（或退场时反向还原），转场结束瞬间卸载遮罩层直接露出底层播放器画面。

### 2.2 极光流动背景着色器（`flutter/shaders/aurora.frag`）

| 槽位 | GLSL 声明 | 类型 | 默认值 / 说明 |
| :---: | :--- | :--- | :--- |
| Float `0..1` | `uniform vec2 uCanvasSize;` | `vec2` | 画布物理像素宽高 |
| Float `2` | `uniform float uElapsedSec;` | `float` | CPU 侧按 `mod(rawSec, 628.3185)` 取模后的秒数（防止长时间挂机导致移动端 `mediump` 浮点三角函数精度退化） |
| Float `3` | `uniform float uStrength;` | `float` | 极光混合强度（默认 `0.62`，低对比/暗色环境可调 `0.0..1.0`） |
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
- 底色 `base = vec3(0.035, 0.035, 0.047)`（`#09090C`），叠加四色谐波后经柔和色调限制 `color = clamp(base + uStrength * (0.42 * w1 * mix(uWaveBlue, uWaveTeal, 0.5 + 0.5 * sin(t)) + 0.36 * w2 * uWaveIndigo + 0.30 * w3 * uWavePurple), 0.0, 1.0)`，输出 `vec4(color, 1.0)`。

---

## 3. 各平台分级实现与代码库约束

### 3.1 Flutter（Windows / macOS / iPhone / iPad）— S41

1. **Windows 渲染后端硬性事实与绘制方式约束**：
   - 基线仓库构建的 Windows 客户端运行在 **Skia over ANGLE / D3D11** 后端（未启用实验性 Windows Impeller），运行时 `ImageFilter.isShaderFilterSupported == false`（见 `apple_theme.dart:17, 333, 359`）。
   - **强制规范**：`PlayerEnterTransition` 与 `AuroraBackground` **严禁使用 `BackdropFilter` + `ImageFilter.shader(...)`**！必须统一通过 **`CustomPainter` + `Canvas.drawRect(rect, Paint()..shader = fragmentShader)`** 绘制，该路径在 Skia（ANGLE/D3D11）与 Impeller（macOS/iOS Metal）上均原生支持。
2. **截图降采样预算与纹理生命周期**：
   - 进入播放器前抓取详情页 `RepaintBoundary.toImage(pixelRatio: captureRatio)`，动态计算 `captureRatio` 使截图最长边 **`<= 1280px`**（将 4K 屏幕 RGBA 纹理峰值从 `33 MB` 压降至 `<= 6.5 MB`）。
   - 转场动画完成（`AnimationStatus.completed` / `dismissed`）或路由销毁（`dispose`）的**当帧必须显式调用 `capturedImage.dispose()`**，严禁在播放器存活期间滞留详情页截图纹理。
3. **三重自动降级机制（Challenger / R4 必测）**：
   - **降级 1（无障碍减少动态效果）**：`MediaQuery.disableAnimationsOf(context) == true` 时，跳过 `toImage` 截图与着色器，直接执行 **`150ms` 线性交叉淡入（`FadeTransition`）**。
   - **降级 2（着色器不可用或编译异常）**：`FragmentProgram.fromAsset` 抛错、尚未预热完成、或 `OhosRuntime.isOhos == true` 时，自动回退为 **`220ms` 缩放（`0.96 -> 1.0`）+ 淡入（`curves.decelerate`）**。
   - **降级 3（截图耗时超预算）**：用 `Stopwatch` 实测 `toImage()` 耗时；若单次超过 **`16ms`**（`transitionCaptureBudget`），本帧及当前会话后续进场自动标记 `preferFastTransition = true`，跳过截图改走缩放 + 淡入兜底，防止 ANGLE/D3D11 或旧款 iPad 读回卡顿。
4. **iOS `apple_theme.dart` 与 `IosNativeRouteGate` 协同**：
   - 新转场路由封装在 `flutter/lib/ui/motion/player_enter_transition.dart`，通过可替换构建函数接入 `detail_screen.dart` 的 `_openPlayer`（`L922-933`），保持 `IosNativeRouteGate` 在 `route.isCurrent == false` 时正常隐藏底层原生 `UiKitView`，不引入未发布的外部样式依赖。
5. **`AuroraBackground` 生命周期**：
   - 结合 `TickerMode.of(context)`、`VisibilityDetector`/路由可见性与 `AppLifecycleListener`：页面不可见、被播放器压入栈底、窗口最小化或开启「减少动态效果」时**立即 `Ticker.stop()`**，后台零 GPU 占用。

### 3.2 Android 手机 / 平板（`minSdk 23`）— S42

1. **海报 -> 详情页转场（`MobileDetailScreen.java`）**：
   - 鉴于 `MainActivity` 采用**单 Activity 内部视图切换架构**（非多 Activity 跳转），不使用 `ActivityOptions.makeSceneTransitionAnimation`，而是在点击海报卡片时读取卡片屏幕 `Rect`，在 `MobileDetailScreen` 首帧对目标封面视图执行 `280ms`（`curves.decelerate`）坐标/尺寸插值与内容淡入。
2. **详情页 -> 播放器分级转场**：
   - **API 33+（Android 13+）**：使用 `android.graphics.RuntimeShader`（AGSL，Uniform 语义与 2.1 节完全对齐，采样最长边 `<= 1080px` 的降采样 Bitmap），动画结束立即 `bitmap.recycle()` / 释放引用。
   - **API 23–32（Android 6.0–12L）**：使用 `ValueAnimator`（`420ms`）配合预分配的 `android.graphics.Camera` + `Matrix` 对详情层执行轻量 3D 纵深后退缩放，同时驱动封面副本平滑放大并淡入黑底播放器（`onAnimationUpdate` 内严禁分配对象）。
   - **开启 `Prefs.REDUCED`**：统一降级为 `150ms` 纯透明度淡入淡出。
3. **`AuroraView` 分级实现**：
   - **API 33+**：使用 AGSL `RuntimeShader` 运行 2.2 节同款四色谐波公式。
   - **API 23–32**：构造时一次性创建 `LinearGradient` 与 `Matrix` 实例，每帧仅通过 `matrix.setTranslate(...)` + `matrix.postRotate(...)` + `gradient.setLocalMatrix(matrix)` 驱动平滑色带流动，**每帧 `0` 堆内存分配**。
   - **可见性门控**：在 `onDetachedFromWindow()`、`onWindowVisibilityChanged( != VISIBLE )`、`onVisibilityChanged( != VISIBLE )` 及 `a.reduced == true` 时立即取消帧回调。

### 3.3 Android 电视（ARM32 Android 9 性能底线）— S43

- **硬性禁令**：电视端**全面禁止**运行任何 `RuntimeShader`、`RenderEffect`、`BlurMaskFilter` 或全屏截图纹理转场。
- **仅保留三项纯硬件属性（RenderNode）轻量动效**：
  1. **焦点弹簧缩放**：复用/对齐 `FocusMotion.java` 与 `MotionSpring(0, 30, 0.0025f)`（`tvFocus`：海报 `1.05x`、胶囊按钮 `1.06x` + `2dp` `#FFF5F5F7` 描边）。
  2. **页面切换**：`180ms` 纯 `alpha` 淡入淡出。
  3. **进入播放器（`TvDetailHost` / 选集点击）**：仅对封面视图做 `220ms` 放大（`1.0 -> 1.08`）伴随整体淡出至黑色播放层；极光背景位在电视端固定渲染**静态暗色渐变**。
- **性能红线**：在 Android 9 ARM32 盒子上通过 `adb shell dumpsys gfxinfo com.pilipala.marcomovie` 采样，动效期间帧率不得低于 **`50fps`**（P90 帧耗时 `<= 20ms`）；`Prefs.REDUCED` 开启时缩放固定 `1.0x`。

---

## 4. 不在范围内（Out of Scope）

1. **Android Lite（API 14）动效改造**：Lite 不引入任何转场动画或极光视图。
2. **Apple TV（`tvos/`）与 HarmonyOS NEXT（`flutter/ohos/`、`flutter/lib/ui/tv/**`）**：只读不改；`OhosRuntime.isOhos` 下自动走静态/无着色器兜底分支。
3. **播放器解码色彩空间自定义 HDR/杜比视界色调映射着色器**：视频色彩映射完全交由 `Media3` 与 `media_kit`（`libmpv`）底层处理。
4. **任何光盘/碟片几何造型或第三方闭源应用纹理资源**。
