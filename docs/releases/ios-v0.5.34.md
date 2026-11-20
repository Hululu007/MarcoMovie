# Marco Movie iOS / iPadOS 0.5.34

发布日期：2026-11-20。应用版本：`0.5.34`（构建号 `84`），基于 Xcode 26.6 / iOS 26 SDK 编译（最低系统要求仍为 iOS / iPadOS 14.0，iOS 14–18 自动无缝回退至高保真磨砂玻璃组件）。本次更新全面升级原生 **iOS 26 Liquid Glass（液态玻璃）** 交互体验，重构全屏影院级液态玻璃全局搜索（底部悬浮搜索栏 + 智能同名多源聚合 + 零态热播），重塑系统级 iOS 26 设置页与原生隐私空间密码弹窗，解决跨页转场黑屏遮挡与图标闪烁跳动，并落地「本地优先」脚本扩展包与可选自建蜘蛛网关（含内置零基础中文图文教程），显著拓展跨平台 `.so` 加密线路兼容能力。

## 更新内容

- **原生 iOS 26 Liquid Glass 交互系统与零跳动转场**：
  - 接入原生 `UIGlassEffect`、`UITabBar` / 62pt 悬浮 4+1 液态玻璃 Dock 栏（下滑自动折叠为右下角品牌标志圆形玻璃球并弹出原生 `UIMenu` 快捷导航）、首页顶部不限条数分组 `UIMenu` 片源/仓库切换与云盘按钮、原生 `UISegmentedControl` 分类切换及原生 `UISheetPresentationController` 筛选弹层。
  - 引入 `MarcoInteractiveCircleGlassControl` 与预尺寸创建参数（`initialWidth` / `initialHeight` + `UIView.performWithoutAnimation` + `CATransaction.setDisableActions(true)`）配合 `IosNativeRouteGate` 路由切换即时接管，彻底消除进入「切换片源」「我的云盘」及返回首页时的跨路由黑色遮挡、暗到明闪烁及图标缩放跳动。
  - 隐私空间解锁密码弹窗全面重构为居中原生 iOS 26 Liquid Glass 面板；优化「观看历史记录」列表滚动流畅度与上下边界渐隐过渡，消除掉帧与卡片硬裁剪。
- **全屏液态玻璃影院搜索重构（底部悬浮搜索 + 智能聚合 + 零态热播）**：
  - 取消旧版 75% 半高弹窗与左侧拥挤的 106pt 线路侧栏，升级为深色影院环境光画布（隐私空间自动切换紫调并严格数据隔离）；底部悬浮单手液态玻璃搜索胶囊（随键盘弹出/收起平滑贴合）+ 原生圆形液态玻璃关闭按钮（`xmark`）。
  - 零态界面展示可单条删除/一键清空的液态玻璃「最近搜索」胶囊，并零额外网络请求直接复用首页已加载片单呈现 3 列「本源热播」海报网格。
  - 搜索结果顶部提供原生 `UISegmentedControl` 在 **「智能聚合」**（自动清洗 `【4K】`/`（臻彩）`/`更新至XX集` 噪声并精准保留续集序号与衍生作，合并多源同名影片为影院信息卡与一键直达片源胶囊）与 **「全部海报」**（全宽 3 列海报墙）之间自由切换；横向液态玻璃片源筛选条仅展示有命中结果的片源并按命中数倒序排列。
- **原生 iOS 26 系统风格设置页**：重构一二级设置页面为 `22pt` 圆角内嵌分组卡片（`#1C1C1E`）、折叠式大标题栏与页内实时搜索胶囊，并接入原生 iOS 26 `UISwitch` 液态晶格开关与 `UISlider` 滑块控件。
- **「本地优先」爬虫扩展包与可选自建蜘蛛网关（`.so` 线路兼容优化 + 内置新手教程）**：
  - 过滤并有序归类依赖 Android `.so` 原生加密组件的线路；新增热插拔 `marco-adapter-pack-v1` 脚本扩展包机制（纯本地在设备端直接运行 JS / DRPY2 / Python / T4 适配器，无需任何外部服务器）与可选个人自建 `marco-spider-gateway-v1` 局域网/远程网关客户端（支持 UDP `41978` 局域网自动发现与安全凭据隔离，并随仓库提供零依赖自建网关模板 `gateway/`）。
  - 在「设置 → 扩展与兼容」内置通俗易懂的 **「新手必看 → 使用教程与常见疑问」** 图文引导页，附带 AI 生成扩展包提示词、JSON 模板、Python 启动命令与 Docker Compose 一键复制按钮。

## 包信息与构建记录

- **未签名 IPA（iPhone / iPad 通用）**：`MarcoMovie-0.5.34-ios-iphone-ipad-unsigned.ipa`（更新兼容别名 `MarcoMovie-0.5.34-ios-unsigned.ipa`），SHA-256：`930a5826f8388b65fbafc4e2721c31da8c0a6855abeede3941bf18679776217b`。
- **对应源码包**：`MarcoMovie-ios-v0.5.34-source.zip`，SHA-256：`172a10d021ec17a2d1240d8d84ad74c9863a231a0061e36956ca0f31b1a0c0d0`。
- **构建提交**：`120cb3fccab350ebbd04aab39cc0ec9a050c9ba7`。[iOS / iPadOS 原生构建与全量校验记录（44647960899）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44647960899)。

## 验证范围与已知限制

- 通过公开内容守卫检查、README 版本对齐校验、离线 JVM / Python / CatPaw / Guard 运行时回归检查、`1020` 项 Flutter 自动化测试（含新增 iOS 26 Liquid Glass、全屏聚合搜索与脚本扩展包/网关测试套件，9 项平台专属跳过）以及 Xcode `26.6` 原生 Release IPA 打包与二进制/签名结构校验；未签名 IPA 支持巨魔（TrollStore）直接覆盖安装或个人自签工具安装。
- 物理真机体验已结合测试版迭代反馈验证原生 iOS 26 液态玻璃按钮、转场防闪烁、隐私密码弹窗与全屏搜索流程；自动化与云端构建校验不代表覆盖全部历史 iOS 版本设备或第三方源站实时在线可用性。依赖 Android `.so` 加密组件的线路在未导入对应本地脚本扩展包或未连接用户自建网关时仍会保持明确提示与折叠归类。
