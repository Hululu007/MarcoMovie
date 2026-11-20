# 跨端真机 A/B 验收、性能探针与合规审计清单（`acceptance-checklist.md` · v2 基线对齐修订版）

> **适用范围**：Wave 1（五线大并行）与 Wave 2（双端接线）门禁、外部跨型号复核（R1–R4）、Forensic Auditor 净室审计，以及最终 **8 类目标真机** A/B 对照验收。  
> **真实性红线**：代码编译通过、JVM 检查通过或模拟器截图**绝不等同于真机验收通过**；未在物理设备上实测的条目必须如实勾选为 `[ ] 未实测` 并注明原因，严禁伪造真机结果。

---

## 1. 真机 A/B 对照基线表（8 类物理设备全覆盖）

> **A/B 对照原则**：每台设备均先安装或保留 **GitHub Releases 最新正式版安装包（A 组对照包）**，与当前集成分支新构建包（B 组实验包）在同一网络与同一合法测试样本下对比。对于手机（`0.5.26`）、Lite（`0.5.7`）、Windows（`0.5.24`）、macOS（`0.5.19`）四端在基线 `aa0adb3acd` 中早已合入的 41 个历史提交行为差异，验收前先核对同目录 `baseline-delta.md` 第 3 节，避免误判为本轮回归。

| # | 物理设备目标 | A 组正式版对照包（Tag @ Commit） | 核心验收模块 | 性能与帧率硬指标 |
| :---: | :--- | :--- | :--- | :--- |
| 1 | **Android 电视盒子**（底线：Android 9 ARM32 低配盒子） | `android-tv-v0.5.29`（`@ 940ed502`） | V17 沉浸详情与 `HomeAmbient` 无退化、M1 大字号徽章与焦点态、M2 遥控长按加速快进预览与 3s 跳过倒计时/细进度条、M3 弹幕自适应降级、M4 焦点弹簧与淡入、M5 遥控版引导 | 动效、HUD 与弹幕全程 **`>= 50fps`**（P90 帧耗时 `<= 20ms`）；零着色器、零模糊 |
| 2 | **Android 手机**（ARM64/ARM32，含挖孔/刘海屏） | `android-mobile-v0.5.26`（`@ a3cbe546`） | M1 线路胶囊徽章、M2 **触控长按 2.0× 倍速→横滑调速→上滑锁定** / 原生细进度条复用 / 3s 跳过 / 定时关闭、M3 分片弹幕与字幕置顶 Z 轴、M4 分级转场（API 33+ AGSL / API 23–32 硬件缩放冻结模糊）与极光 + F8 丝带加载、M5 触控引导 | 交互与转场 **`>= 60fps`**（高刷屏跟随）；横竖屏切换与来电/后台复位正常 |
| 3 | **Android 平板**（横屏侧边栏 + 竖屏底栏） | `android-mobile-v0.5.26`（`@ a3cbe546`） | 平板宽屏详情页徽章换行、大屏手势三区比例、横竖屏旋转时转场与极光视图生命周期 | **`>= 60fps`**；`100% / 110% / 120%` 界面缩放无裁切 |
| 4 | **Lite 旧盒子**（Android 4.x / API 14 单 DEX） | `android-lite-v0.5.7`（`@ a3cbe546`） | **仅 M1（S12）**：`LiteActivity` 详情元数据行与线路胶囊纯文字标签（如 `4K · HDR10 · DD+ 5.1`） | 保持**单 DEX**；冷启动与焦点移动无卡顿、无 `NoSuchMethodError` |
| 5 | **Windows 桌面**（x64，Skia over ANGLE/D3D11） | `windows-v0.5.24`（`@ a3cbe546`） | `winFastGlass` 无模糊守卫、M1 线路徽章、M2 鼠标静止 `2.5s` 隐去/滚轮音量/`←`/`→` 快进预览/`S` 倍速键、M3 弹幕与 `D` 键、M4 `<= 16ms` 快速转场兜底、M5 宽屏引导、M6 Anime4K（开启切 `spline36`，关闭恢复 `bilinear`） | 播放与弹幕 **`>= 60fps`**；4K 窗口 300 条弹幕 UI 线程 `< 8ms/帧` |
| 6 | **macOS 桌面**（Apple Silicon / Intel，Impeller Metal） | `macos-v0.5.19`（`@ a3cbe546`） | M1–M6 全套桌面体验、Retina 高分屏截图降采样（`<= 1280px`）与纹理即时释放、Anime4K 热切换不重启播放 | **`>= 60fps`**；进退全屏与 `Cmd+W` 退出无残影或内存泄漏 |
| 7 | **iPhone**（含刘海 / 灵动岛机型，iOS 26 & 15–18 回退） | `ios-v0.5.34`（`@ 120cb3fc`） | **iOS 26 原生 Liquid Glass 全局统一与播放页重构**（40pt 同心顶栏 + 整合规格徽章条 + 56/76/56pt 折射圆钮 + 5pt→10pt 流体进度条 + 精简胶囊坞 + 原生 ActionSheet/UISheet 面板）、长按倍速→横滑→上滑锁定、无黑洞 `IosNativeRouteGate.runWithPlaceholders` 转场、M3 弹幕、M5 原生按钮引导 | **`>= 60fps`**（ProMotion 120fps 跟随）；活跃视频纹理无多 `UiKitView` 切片；侧滑边缘 `24lp` 零误触 |
| 8 | **iPad**（全屏 / 分屏多任务横竖屏） | `ios-v0.5.34`（`@ 120cb3fc`） | iPad 沉浸式播放状态栏协同（`MobilePlayerChrome`）、iOS 26 重构播放页宽屏自适应、宽屏双栏新手引导、分屏尺寸动态变化下弹幕轨道重算 | **`>= 60fps`**；动态字体缩放与降低透明度（`reduceTransparency`）下无溢出 |

---

## 2. 分模块实测核查项清单

### 2.1 M1 媒体规格徽章（Android / Lite / Flutter）
- [ ] **跨端一致性**：同一组线路名与剧集文件名在 Android TV、Android 手机、Lite（纯文字序列）与 Flutter 四端输出的徽章文本及先后顺序 **100% 逐项一致**。
- [ ] **互斥与保 `+` 归一化**：`10bit` 无 HDR 片源不出 `HDR10`；`TvV17DetailScreen` 等含 `'+'` 或 `%2B` 的 URL 正确输出 `HDR10+` / `DD+`（不被 `URLDecoder` 吞掉 `+`）；`DV + Atmos` 合并为 `DV · ATMOS`；`[5.1GB]` 不误出 `5.1` 声道。
- [ ] **视觉与缩放**：iOS 26 采用同心圆角胶囊（`radius = height/2`）；Android TV 在 `100% / 110% / 120%` 缩放下焦点框不裁切；Lite 保持单 DEX。

### 2.2 M2 播放页重构、HUD 与手势/按键状态机
- [ ] **触控长按倍速全链路（Android 手机/平板、iPhone、iPad）**：
  - [ ] 静止长按 `>= 350ms` 激活 `2.0×` 临时倍速，左右横滑顺畅切换 `1.25× / 1.5× / 2.0× / 3.0×` 并带轻触觉反馈；
  - [ ] 按住向上滑过 `48dp` 提示松手锁定，松手进入锁定倍速并在顶部常驻 `"🔒 2.0× 锁定中 · 点击恢复"`，点击胶囊或切集/锁屏立即恢复长按前的 `userNormalSpeed`；
  - [ ] 未锁定时松手，或长按期间发生来电、切后台、双指触碰、打开面板、进入小窗/PiP 时，**100% 立即恢复 `userNormalSpeed`**，无高倍速残留。
- [ ] **iOS / iPadOS 26 统一液态玻璃播放页专项**：
  - [ ] 播放页顶栏、中央圆形播控、底部流体伸缩进度条（`5pt -> 10pt`）与 `<= 7` 项精简胶囊坞同首页/搜索/详情页的 iOS 26 Liquid Glass 美学完全统一，旧版右侧 16 项拥挤竖条已彻底移除；
  - [ ] 倍速、定时关闭、音字幕、策略菜单在 iOS 26+ 呼出原生 ActionSheet / UISheet 半屏面板；`ios_settings.dart` 新增开关使用 `IosNativeSwitch`；
  - [ ] `glasswork.frag` 在 HUD 隐藏后停止运行；开启系统「降低透明度」或运行在 iOS 15–18 时平滑回退。
- [ ] **防遮挡、遥控器与键鼠**：
  - [ ] 起播规格提示与左上角返回按钮在任何状态下零重叠；`PlaybackController.java` 仅放宽第 1680 行单行门控复用手机细进度条；
  - [ ] Android TV 遥控短按 `15s`、长按 `SeekGesture` 加速预览、`TvMarkerHost` 上键标记及 3 秒可取消跳过倒计时焦点链 100% 正常（`InteractionProbe` 全绿）；
  - [ ] 桌面端鼠标静止 `2.5s` 隐去、滚轮音量、短按/长按 `←`/`→` 快进预览、`Esc` 抢占取消预览及 `S` / `[` `]` 倍速键正常。

### 2.3 M3 分片弹幕引擎与层级顺序
- [ ] **按需窗口、负偏移与容错**：负时间偏移（如 `-10s`）片头不冻结 `0.0s` 弹幕；跨越 `30s` 窗口交界处在途滚动弹幕不消失；并发 `HTTP 410` 单窗最多重试 `1` 次（全集 `<= 3` 次）；`180ms` Seek 防抖及时取消旧请求；恶意屏蔽词正则 `re:(a|aa)+$` 被静态拦截器直接拒绝。
- [ ] **字幕置顶 Z 轴顺序与性能**：Android `PlaybackControls.java` 与 Flutter 播放栈严格保证**字幕层始终压在弹幕层上方**；Android 9 ARM32 盒子自动降级行数维持 `>= 50fps`；桌面 `D` 键即时开关弹幕。

### 2.4 M4 着色器转场、极光、F8 品牌丝带加载与 F9 桌面 Anime4K
- [ ] **iOS 无黑洞截图与三重降级**：iPhone / iPad 从详情页进入播放器时，`IosNativeRouteGate.runWithPlaceholders` 单帧占位使截图纹理中原生玻璃按钮位置完整无黑洞，异常或取消时 `try/finally` 100% 恢复原生视图；减少动态效果、着色器异常、`toImage() > 16ms` 三条降级分支均实测可达且及时 `dispose()` 纹理。
- [ ] **Android 硬件加速与 F8 品牌丝带加载**：API 23–32 转场使用硬件 `RenderNode` 属性并冻结 `GlassworkSurface` 重采样；缓冲等待处显示 1.6s 丝带 M 描边扫光加载器（减少动态效果时切换为静态呼吸透明度）。
- [ ] **F9 桌面 Anime4K（Windows / macOS）**：切换「关闭 / 性能 / 均衡 / 画质」实时生效不中断播放；Windows 下开启预设时切换 `spline36`，切回「关闭」立即恢复默认 `bilinear`；移动端与鸿蒙完全隐藏。

### 2.5 M5 新手引导与示例素材
- [ ] 独立引导页 5 幕流程顺畅（第 4 幕准确展示触控长按倍速调速锁定与遥控/键鼠预览），初始配置地址保持 `""`，第 1/5 幕直连导入/同步回调；`scripts/generate_demo_art.py` 产出的 14 张 8-bit 索引 `.png`（`< 480 KB`）均带清晰「示例」角标；首次播放手势提示满 3 次或点「不再提示」后不再弹出。

---

## 3. 本机标准工具链、自动化检查与探针命令

```powershell
# 0) 配置 JDK 17、Android Build-Tools 与 Flutter 3.38 工具链环境
$env:JAVA_HOME = "C:\Tools\jdk-17"
$env:MARCOMOVIE_JDK = $env:JAVA_HOME
$env:MARCOMOVIE_BUILD_TOOLS = "C:\Android\Sdk\build-tools\35.0.0"
$env:PATH = "$env:JAVA_HOME\bin;C:\Tools\flutter\bin;$env:PATH"

# 1) 公开内容、默认空地址、保留域名与二进制守卫（每次提交前必跑，必须 PASS）
python -X utf8 scripts/check_public_content.py

# 2) Android Java 格式检查与全量离线 JVM 套件
python -X utf8 scripts/format_java.py --check
python -X utf8 android/tests/run_checks.py
python -X utf8 android/tests/run_seek_checks.py
python -X utf8 android/tests/run_review_fix_checks.py
python -X utf8 android/tests/run_compat_checks.py

# 3) Lite API 14 单 DEX 构建与 JVM 检查
python -X utf8 scripts/build_lite.py
python -X utf8 scripts/test_lite_jvm.py

# 4) Android TV / 手机真机帧耗时采集与遥控器探针
adb shell dumpsys gfxinfo com.pilipala.marcomovie reset
adb shell dumpsys gfxinfo com.pilipala.marcomovie framestats

# 5) Flutter 单元测试（注：已知 history_shelf / home_loading / dock_notice / detail_loading 4 个遗留测试会卡死，跳过并如实注明）
cd flutter
flutter test test/media_badges_test.dart
```

---

## 4. 正则跨语言兼容性自检说明（M0 实测验证记录 — 保持不变）

`shared/ui-spec/badge-rules.json`（45 条规则 + `comboRules`）与 `badge-golden.json`（165 条样例）已在 M0 完成跨引擎实测锁定：
1. **全面禁用 `\b` / `\B` 词边界**：统一采用显式 ASCII 边界 `(?:^|.*[^a-z0-9])` 与 `(?![a-z0-9])`，消除 Android ICU 正则将汉字归为 `\w` 的跨端分叉。
2. **零单端私有语法**：顶层 `"caseInsensitive": true`，全包 0 处 `(?i)`、0 处后行断言、0 处占有量词或 `\p{...}`。
3. **保 `+` 百分号解码与空白折叠**：禁用破坏 `"HDR10+"` / `"DD+"` 的 `URLDecoder.decode`，统一仅解码合法 `%XX` UTF-8 序列并保留字面量 `'+'`，折叠全角/控制空白并在 `1024` UTF-16 码元处做代理对安全截断。
4. **Android API 14 兼容**：共享纯 Java `MediaBadges.java` 必须使用 `Charset.forName("UTF-8")`、处理受检 `org.json.JSONException`、禁用 Java 8+ API，已实测通过 `android-14/android.jar` 编译与 `D8 --min-api 14`。
5. **实测基准**：JDK 17 与 Dart 3.10.8 跑完 165 条样例 **0 差异**（单条 `< 0.12 ms`），核心互斥变异击杀率 **100%**。

---

## 5. 净室与公开合规审计表（Forensic Auditor 必查）

- [ ] 全仓变更内容、分支名及提交信息不区分大小写扫描，确认**零处**闭源参考软件名称或域名标识。
- [ ] 确认**零处**逐字拷贝的外部正则表达式、外部着色器入口/结构体/字段名或外部专用文案。
- [ ] 确认**零处**真实电影/剧集/番剧名称、**零处**真实海报图片、**零处**外部公共影视数据库域名或接口调用。
- [ ] 确认**零处**第三方商业影音或流媒体品牌矢量/位图商标图形，所有徽章 100% 为纯文字胶囊。
- [ ] 确认无新增硬编码弹幕/内容服务器地址或密钥，无新增遥测上报；`scripts/check_public_content.py` 返回 `0`。
- [ ] 确认只读目录（`tvos/`、`flutter/ohos/`、`flutter/lib/ui/tv/**`、`gateway/`）与 `Prefs.KEYS`（长度 46）零改动，且新增 Flutter 逻辑均含 `!OhosRuntime.isOhos` 默认关闭保护。

---

## 6. 不在范围内（Out of Scope）

1. **Apple TV（`tvos/`）物理真机与 HarmonyOS NEXT（`flutter/ohos/`）物理真机的本轮新特性验收**：两平台在本轮维持只读不改（本机无 HarmonyOS `hvigorw` 编译工具链，各里程碑交付需如实标注「未在本机验证鸿蒙 HAP 编译」）。
2. **非授权第三方真实源或私有账号样本的入库测试**：所有自动化测试必须使用本地回环模拟服务（`127.0.0.1`）或 `.test` / `.example` 合成样本。
