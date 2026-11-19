# Marco Movie HarmonyOS NEXT 0.1.1

发布日期：2026-11-19。应用版本：`0.1.1`（构建号 `1000002`），最低系统要求：HarmonyOS NEXT API 12（5.0+）。本次更新彻底修复纯血鸿蒙端“安装包缺少 CatPaw 本机运行组件”问题，将鸿蒙智慧屏大屏端 UI 全面拉齐至 Apple TV 客厅视觉规范（含 6 套渐变柔光主题、居中悬浮玻璃顶栏、双栏设置工坊与沉浸式剧集详情/选集页），并同步最新 WEX / FTY 片源连通性增强。

## 更新内容

- **彻底修复“缺少 CatPaw 本机运行组件”问题（零外部 Node 依赖的本机嵌入式 QuickJS-NG 运行时）**：新增纯 Dart + QuickJS-NG 嵌入式执行引擎（`catpaw_embedded_engine.dart` 与 `catpaw_crypto.dart`），在 `catpaw_host.dart` 中优先识别纯血鸿蒙环境并在进程内直接通过 `libquickjs_c_bridge_plugin.so` 加载包内 `37` 项 `assets/catpaw/` 脚本资产，完整支持 CatPaw 加密源、DRPY2 与 60+ 套 Guard 数据适配器及最新 WEX / FTY DoH 防污染改进，不再依赖外部 `node` 可执行文件。
- **鸿蒙智慧屏大屏 UI 全面对齐 Apple TV 客厅视觉体系**：
  - **全局 6 套渐变柔光主题与外观工坊**：新增 `TvAmbientSoftGlowBackground`（面向智慧屏 GPU 优化的 60fps 多层径向柔光绘制，无重度模糊掉帧），完整内置 `极光青翠`、`暮色流光`、`深海晨雾`、`暖金影院`、`星云紫夜`、`冰川银雾` 6 套配色、3 档柔光浓度（柔和微光 / 标准柔光 / 浓郁流光）与海报色彩氛围联动，持久化保存。
  - **居中悬浮毛玻璃顶栏与发现页升级**：左上角 `Marco Movie` 标识配合正中悬浮胶囊导航栏（`发现` / `直播` / `搜索` / `片库` / `设置`）；继续观看升级为 16:9 宽屏影院卡片并优先获焦（修复存在观看记录时顶部分类胶囊被滚动遮挡的问题）；精选片库升级为 6 列舒展 2:3 海报墙，配年份/类型副标题与扫码快传入口。
  - **直播、搜索、片库与双栏系统设置统一玻璃语言**：直播页重构为左侧分组栏 + 右侧 3 列玻璃频道卡；搜索页新增 `ABC 拼音` / `123 数字` 切换与按站点命中筛选胶囊；片库新增单卡移除/取消收藏按钮；设置页重构为 Apple TV 同款左导航 + 右卡片双栏布局（`外观与柔光`、`订阅与片源`、`4K 网盘加速`、`WebDAV 云同步`、`播放与跳过`、`备份与存储`）。
- **鸿蒙智慧屏、平板与手机全形态沉浸式剧集详情页与全屏选集面板**：智慧屏新增全屏剧照渐变背景 + 底部磨砂选集坞 + `4K 云盘`/`HLS` 线路徽标及 5×4 分页全屏选集弹窗，并与所选客厅柔光主题自动协调；平板与手机端延续全屏沉浸式海报渐隐排版。

## 包信息与构建记录

- **未签名通用 HAP（手机 / 平板 / 2in1 / 智慧屏）**：`MarcoMovie-0.1.1-harmonyos-universal.hap`（更新兼容别名 `MarcoMovie-0.1.1-harmonyos.hap`），SHA-256：`3df10bc519eeda366c9b5f15ecb92cd3df2cf92148191dfca42d034f4b554bae`。
- **对应源码包**：`MarcoMovie-harmonyos-v0.1.1-source.zip`，SHA-256：`a8b7c36bb9097103a6750fef608dde0b387ec62b8a454f54dde9ed75b19baef2`。
- **构建提交**：`7b7239320e50e9c7f42eadca90be297b89e4b696`。[多端原生构建与校验记录（44516706715）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44516706715) · [公共内容守卫检查（44516706686）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44516706686)。

## 验证范围与已知限制

- 通过公共内容守卫检查、`60` 项本地 Flutter CatPaw / DRPY / Guard 嵌入式引擎与鸿蒙智慧屏 UI 回归测试（含 `harmonyos_and_tv_ui_test.dart` 全部 `13` 项与 `catpaw_embedded_engine_test.dart`）、`5` 项 `test_prepare_ohos.py` 构建脚本校验、OpenHarmony Flutter `3.35.7` + HarmonyOS Command Line Tools SDK `26.0.0.821` 云端 Release 构建，以及 `.hap` 解包自检（确认 `module.json` 版本 `0.1.1` / `1000002`、`libs/arm64-v8a` & `libs/x86_64` 下的 `libquickjs_c_bridge_plugin.so` 与 `37` 项 `assets/catpaw/` 脚本资产完整打包）。
- 已知限制：发布包为未签名通用 `.hap`，安装前需通过 DevEco Studio 自动签名或 `hap-sign-tool` 签名后使用 `hdc install` 安装；受纯血鸿蒙系统架构限制不支持 Android APK / JAR 插件或外部 Node 子进程宿主；自动化渲染与云端构建校验不代表全型号物理鸿蒙手机、平板与智慧屏真机长片验收。
