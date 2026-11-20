# 跨端真机 A/B 验收、性能探针与合规审计清单（`acceptance-checklist.md`）

> **适用范围**：M1–M7 各波次门禁、外部跨型号复核（R1–R4）、Forensic Auditor 净室审计，以及最终 **8 类目标真机** A/B 对照验收。  
> **真实性红线**：代码编译通过、JVM 检查通过或模拟器截图**绝不等同于真机验收通过**；未在物理设备上实测的条目必须如实勾选为 `[ ] 未实测` 并注明原因，严禁伪造真机结果。

---

## 1. 真机 A/B 对照基线表（8 类物理设备全覆盖）

> **A/B 对照原则**：每台设备均先安装或保留 **GitHub Releases 最新正式版安装包（A 组对照包）**，与当前集成分支新构建包（B 组实验包）在同一网络与同一合法测试样本下对比。对于手机（`0.5.26`）、Lite（`0.5.7`）、Windows（`0.5.24`）、macOS（`0.5.19`）四端在基线 `aa0adb3acd` 中早已合入的 41 个历史提交行为差异，验收前先核对同目录 `baseline-delta.md` 第 3 节，避免误判为本轮回归。

| # | 物理设备目标 | A 组正式版对照包（Tag @ Commit） | 核心验收模块 | 性能与帧率硬指标 |
| :---: | :--- | :--- | :--- | :--- |
| 1 | **Android 电视盒子**（底线：Android 9 ARM32 低配盒子） | `android-tv-v0.5.29`（`@ 940ed502`） | M1 大字号徽章与焦点态、M2 遥控倍速/锁定/跳过倒计时/细进度条、M3 弹幕自适应降级、M4 焦点弹簧与淡入、M5 遥控版引导 | 动效、HUD 与弹幕全程 **`>= 50fps`**（P90 帧耗时 `<= 20ms`）；零着色器、零模糊 |
| 2 | **Android 手机**（ARM64/ARM32，含挖孔/刘海屏） | `android-mobile-v0.5.26`（`@ a3cbe546`） | M1 线路胶囊与选集徽章、M2 触控状态机/安全区起播提示/跳过/定时关闭、M3 分片弹幕、M4 分级转场与 `AuroraView`（验证 API 33+ 与 API 23–32 路径）、M5 触控引导 | 交互与转场 **`>= 60fps`**（高刷屏跟随）；横竖屏切换与来电/后台恢复正常 |
| 3 | **Android 平板**（横屏侧边栏 + 竖屏底栏） | `android-mobile-v0.5.26`（`@ a3cbe546`） | 平板宽屏详情页徽章换行、大屏手势三区比例、横竖屏旋转时转场与极光视图生命周期 | **`>= 60fps`**；`100% / 110% / 120%` 界面缩放无裁切 |
| 4 | **Lite 旧盒子**（Android 4.x / API 14 单 DEX） | `android-lite-v0.5.7`（`@ a3cbe546`） | **仅 M1（S12）**：详情页线路与选集纯文字标签（如 `4K · HDR10 · DD+ · 5.1`），沿用 `LiteActivity` 蓝/白焦点配色 | 保持**单 DEX**；冷启动与焦点移动无卡顿、无 `NoSuchMethodError` |
| 5 | **Windows 桌面**（x64，Skia over ANGLE/D3D11） | `windows-v0.5.24`（`@ a3cbe546`） | M1 `WinButton` 线路徽章与悬停提示、M2 鼠标静止 `2.5s` 隐去/滚轮音量/`ArrowRight` 短按快进与长按倍速、M3 弹幕与 `D` 键、M4 `Paint.shader` 转场及 `> 16ms` 自动降级、M5 键鼠版引导、M6 Anime4K（若勾选） | 播放与弹幕 **`>= 60fps`**；4K 窗口 300 条弹幕 UI 线程 `< 8ms/帧`；窗口缩放起播提示位置稳定 |
| 6 | **macOS 桌面**（Apple Silicon / Intel，Impeller Metal） | `macos-v0.5.19`（`@ a3cbe546`） | M1–M6 全套桌面体验、Retina 高分屏截图降采样（`<= 1280px`）与纹理即时释放 | **`>= 60fps`**；进退全屏与 `Cmd+W` 退出无残影或内存泄漏 |
| 7 | **iPhone**（含刘海 / 灵动岛机型） | `ios-v0.5.34`（`@ 120cb3fc`） | M1 详情页与换源面板徽章（与 `IosNativeGlassButton` 协同）、M2 左/右横屏灵动岛安全区避让与侧滑返回互斥、M3 弹幕、M4 Impeller 着色器转场与 `IosNativeRouteGate` 门控、M5 触控引导 | **`>= 60fps`**（ProMotion 跟随）；侧滑边缘 `24lp` 不误触播放手势 |
| 8 | **iPad**（全屏 / 分屏多任务横竖屏） | `ios-v0.5.34`（`@ 120cb3fc`） | iPad 沉浸式播放状态栏协同（`MobilePlayerChrome`）、宽屏双栏新手引导、分屏尺寸动态变化下弹幕轨道重算 | **`>= 60fps`**；动态字体缩放下胶囊无溢出 |

---

## 2. 分端实测核查项清单

### 2.1 M1 媒体规格徽章（Android / Lite / Flutter）
- [ ] **跨端一致性**：同一组线路名与剧集文件名在 Android TV、Android 手机、Lite（纯文字文本序列）与 Flutter 四端输出的徽章文本及先后顺序 **100% 逐项一致**。
- [ ] **互斥与防误判实测**：`10bit` 无 HDR 片源不出 `HDR10`；`4K.Remastered.1080p` 只出 `1080p`；`BluRay.REMUX` 只出 `REMUX`；`DV + Atmos` 合并为 `DV · ATMOS` 且不重复出单枚 `DV` 或 `ATMOS`；`[5.1GB]` 文件大小不出 `5.1` 声道。
- [ ] **焦点与缩放**：Android TV 选集弹窗（`DetailScreen.renderEpisodes`）与 `TvV17DetailScreen` 徽章在 `100% / 110% / 120%` 缩放下文字清晰、焦点框不裁切；Lite 保持单 DEX 且 `COLOR_FOCUS`（`0xfff5f5f7`）/ `COLOR_ACCENT`（`0xff0a84ff`）对比度正常。

### 2.2 M2 播放页 HUD 与手势/按键状态机
- [ ] **触控全链路（Android 手机/平板、iPhone、iPad）**：
  - [ ] 单击显隐主控栏；锁屏态单击仅显隐解锁胶囊。
  - [ ] 左/中/右三区双击符合配置（移动端默认中区播/暂、左右侧连续快进快退累加）。
  - [ ] 长按 `>= 380ms` 进入 `2.0x` 倍速 -> 左右横滑在 `0.5x..3.0x` 间平滑跳档（无微颤抖动）-> 上滑 `>= 56dp` 松手锁定倍速 -> 点击锁定胶囊或切集自动恢复。
  - [ ] 长按期间接听电话、下拉通知栏、切后台或双指捏合时，倍速**立即恢复**，绝不卡死在高速状态。
  - [ ] 左右边缘 `24dp`/`24lp` 侧滑返回系统手势顺畅触发，不串入快进或亮度音量调节。
  - [ ] iPhone 左横屏与右横屏两种握持方向下，左上角起播规格提示均完全避开灵动岛/刘海挖孔。
- [ ] **Android 电视遥控器**：
  - [ ] 短按左右键保持 `15s` 快进/快退；`TV_HOLD_RIGHT_MODE = 0` 下按住右键逐级升速 `1.5x -> 2.0x -> 3.0x`，按住期间按上键锁定倍速，按返回键或确认键优先解锁而不误退播放页。
  - [ ] 未处于倍速按住态时，隐藏控制栏下按上键依然正常呼出 `TvMarkerHost` 片头片尾标记面板。
  - [ ] 跳过片头倒计时弹出时自动获焦，按确认键立即跳过，按任意方向键立即取消。
- [ ] **桌面端键鼠（Windows / macOS）**：
  - [ ] 鼠标移动唤醒 HUD，静止 `2.5s` 自动隐藏 HUD 与鼠标指针；滚轮调节音量每次 `±5%`。
  - [ ] 短按 `→`（`< 280ms`）松手立即快进 `+15s`；按住 `→`（`>= 280ms`）进入倍速模式，按 `↑` 锁定。
- [ ] **常驻细进度条与定时关闭**：主控栏展开时细进度条自动隐去，不遮挡字幕；定时关闭在 `15m / 30m / 播完本集` 到点前 `30s` 提示并准时暂停释放常亮锁。

### 2.3 M3 分片弹幕引擎与渲染层
- [ ] **按需窗口与容错**：拖动进度条触发 `180ms` 防抖，快速来回拖动期间旧窗口请求立即取消，不堆积网络队列；模拟 `HTTP 410` 时自动刷新目录并严格只重试 `1` 次，连续 `410` 不死循环。
- [ ] **防重叠与层级**：滚动、顶部、底部弹幕同屏密集出现时文字互不重叠；**字幕层（`SubtitleOverlayView` / Flutter 字幕）始终位于弹幕层上方**，不被弹幕盖住。
- [ ] **电视自适应与桌面快捷键**：Android 9 ARM32 盒子高密弹幕下自动下调行数维持 `>= 50fps`；桌面端按 `D` 键即时开关弹幕。

### 2.4 M4 转场着色器、极光背景与轻量动效
- [ ] **三重降级必测（Flutter & Android）**：
  - [ ] 系统或应用开启「减少动态效果」时，进出播放器立即切换为 `150ms` 纯淡入淡出，极光背景静止在 `t = 0` 帧且 `Ticker` 不运行。
  - [ ] 人为注入着色器加载失败或模拟 `toImage()` 耗时 `> 16ms` 时，无崩溃、无黑屏卡死，自动回退为缩放 + 淡入。
  - [ ] 转场结束后详情页截图纹理立即 `dispose()` / 释放，连续进出播放页 20 次内存无阶梯上涨。
- [ ] **Windows ANGLE/D3D11 验证**：确认使用 `CustomPainter` + `Paint.shader` 正常绘制（未误用不支持的 `BackdropFilter` + `ImageFilter.shader`）。
- [ ] **电视端禁令核查**：确认 TV 端代码路径未创建任何着色器或模糊滤镜，海报焦点缩放与播放淡出流畅。

### 2.5 M5 新手引导与示例素材
- [ ] 首次安装冷启动展示 5 幕引导，初始配置地址仍为空串 `""`，显著展示不提供影视内容声明。
- [ ] 示例海报全部带有清晰「示例」角标，无任何真实片名或海报；设置内可随时重新打开引导；首次播放手势提示满 3 次或点「不再提示」后不再弹出。

---

## 3. 标准自动化检查、性能采集与探针命令

```powershell
# 1) 公开内容、默认空地址、保留域名与二进制守卫（每次提交前必跑，必须 PASS）
python -X utf8 scripts/check_public_content.py

# 2) Android Java 格式检查与全量离线 JVM 套件
$env:MARCOMOVIE_JDK = 'C:\Tools\jdk-17'
$env:MARCOMOVIE_BUILD_TOOLS = 'C:\Android\Sdk\build-tools\35.0.0'
python -X utf8 scripts/format_java.py --check
python -X utf8 android/tests/run_checks.py
python -X utf8 android/tests/run_seek_checks.py
python -X utf8 android/tests/run_review_fix_checks.py
python -X utf8 android/tests/run_compat_checks.py

# 3) Lite API 14 单 DEX 构建与 194+ 项 JVM 检查
python -X utf8 scripts/build_lite.py
python -X utf8 scripts/test_lite_jvm.py

# 4) Android TV / 手机真机帧耗时采集与截图命令
adb shell dumpsys gfxinfo com.pilipala.marcomovie reset
# （在真机执行播放 HUD 显隐、弹幕滚动或焦点快速移动 15 秒后采集）
adb shell dumpsys gfxinfo com.pilipala.marcomovie framestats
adb exec-out screencap -p > build/device-screen.png

# 5) Android TV 遥控器仪器探针（仅在专用测试机执行）
python -X utf8 scripts/build_android.py
python -X utf8 scripts/build_device_probe.py InteractionProbe
adb reverse tcp:18765 tcp:18765
adb shell am instrument -w -e base http://127.0.0.1:18765/ com.pilipala.marcomovie.test/com.pilipala.marcomovie.InteractionProbe

# 6) Flutter 单元测试与桌面 Profile 帧耗时实测
# （注：基线已知 history_shelf / home_loading / dock_notice / detail_loading 4 个历史测试会卡死，可单独跳过并如实说明）
cd flutter
flutter test test/media_badges_test.dart
flutter run --profile -d windows
```

---

## 4. 正则跨语言兼容性自检说明（M0 实测验证记录）

为确保 `shared/ui-spec/badge-rules.json` 在 **Android API 14（Lite ICU 正则）**、**Android / JVM JDK 17（`java.util.regex.Pattern`）** 与 **Flutter Dart 3.10.8（ECMA-262 `RegExp`）** 三套引擎上输出 100% 逐字节一致，M0 制定并实测验证了以下五条兼容准则：

1. **全面禁用 `\b` / `\B` 词边界**：
   - 在 Android 真机 ICU 正则引擎中，中文汉字（`\p{Lo}`）属于单词字符（`\w`），导致 `\b4K\b` 面对 `"蓝光4K原盘"` 在 Android 真机上**不匹配**，而在桌面 OpenJDK 与 Dart `RegExp` 上**匹配**！同时下划线 `_` 属于 `\w`，会导致 `Sample_2160p_HEVC` 匹配失败。
   - **解决方案**：所有英文/数字词元统一使用显式 ASCII 边界 `(?:^|.*[^a-z0-9])` 与 `(?![a-z0-9])`；纯中文词组（如 `杜比视界`、`臻彩`、`蓝光原盘`、`立体声`）直接无边界匹配，`B站` 写作 `(?:^|.*[^a-z0-9])b站(?!点)` 兼顾 `"B站4K"` 命中与 `"Web站点"` 排除。
2. **严禁单端私有语法**：
   - 顶层统一声明 `"caseInsensitive": true`（Java `Pattern.CASE_INSENSITIVE` / Dart `caseSensitive: false`）；全包 **0 处** `(?i)`、**0 处**后行断言 `(?<=...)` / `(?<!...)`、**0 处**占有量词 `*+` / `++`、**0 处**原子组 `(?>...)`、**0 处** `\K` 或 `\p{...}`。
3. **输入百分号解码保 `+` 契约**：
   - 严禁调用 `URLDecoder.decode`（会把 `"HDR10+"` 与 `"DD+"` 中的字面量 `'+'` 破坏为空格 `' '`！）。两端统一仅将合法的 `%XX` 十六进制字节序列按 UTF-8 解码（非法字节替换为 `U+FFFD`），完整保留字面量 `'+'`。
4. **Android API 14 `org.json.JSONException` 受检异常与 Java 7 语法提示（供 S11 / S12 复用）**：
   - 在桌面测试库 `json-20240303.jar` 中 `JSONException` 为非受检 `RuntimeException`，而在 Android `android.jar`（API 14–35）中 `JSONException` 为**受检 `Exception`**！因此共享纯 Java `MediaBadges.java` 解析 JSON 时必须显式声明 `throws JSONException`（或使用 `opt*` 方法），且不得使用 Lambda、`Stream`、`Optional`、`StandardCharsets`，确保 `javac -bootclasspath android-14/android.jar` 与 `D8 --min-api 14` 零错误通过。
5. **M0 跨语言实测基准结果**：
   - 针对 `badge-golden.json` 全部 **146 条**匿名化测试样例（含组合徽章、负向陷阱、中文混排、`mmcloud://` 与 `%20`/`%2B` WebDAV 地址、1024 字符截断边界）：
     - **JDK 17**：`146 / 146` 全部通过，预热后 200 条批量匹配单条平均耗时 **`0.0706 ms`**（远优于 `< 0.20 ms` 指标）；
     - **Dart 3.10.8**：`146 / 146` 全部通过，与 Java 输出差异数为 **`0`**；
     - **Android API 14 编译与 DEX 验证**：`-source 8 -target 8 -bootclasspath android-14/android.jar` 编译 0 错误，`D8 --min-api 14` 单 DEX 生成通过。

---

## 5. 净室与公开合规审计表（Forensic Auditor 必查）

- [ ] 全仓变更内容及提交信息不区分大小写扫描，确认**零处**闭源参考软件名称或域名标识。
- [ ] 确认**零处**逐字拷贝的外部正则表达式、外部着色器入口/结构体/字段名、外部短分组代号或外部专用分隔符常量。
- [ ] 确认**零处**真实电影/剧集/番剧名称、**零处**真实海报图片、**零处**外部公共影视数据库域名或接口调用。
- [ ] 确认**零处**第三方商业影音或流媒体品牌矢量/位图商标图形，所有徽章 100% 为纯文字胶囊。
- [ ] 确认无新增硬编码弹幕/内容服务器地址或密钥，无新增遥测上报；`scripts/check_public_content.py` 返回 `0`。
- [ ] 确认只读目录（`tvos/`、`flutter/ohos/`、`flutter/lib/ui/tv/**`、`gateway/`）零改动，且新增 Flutter 逻辑均已使用 `!OhosRuntime.isOhos` 默认关闭保护。

---

## 6. 不在范围内（Out of Scope）

1. **Apple TV（`tvos/`）物理真机与 HarmonyOS NEXT（`flutter/ohos/`）物理真机的本轮新特性验收**：两平台在本轮维持只读不改（本机亦无 HarmonyOS `hvigorw` / DevEco 编译工具链，鸿蒙编译仅在云端 CI 或后续 M8 阶段验证，各里程碑交付需如实标注「未在本机验证鸿蒙 HAP 编译」）。
2. **非授权第三方真实盗版源或私有账号样本的入库测试**：所有自动化测试必须使用本地回环模拟服务（`127.0.0.1`）或 `.test` / `.example` 合成样本。
