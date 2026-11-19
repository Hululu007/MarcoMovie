# Marco Movie iOS / iPadOS 0.5.33

发布日期：2026-11-19。应用版本：`0.5.33`（构建号 `83`），最低系统要求：iOS / iPadOS 14.0。本次更新围绕用户反馈修复 iPad 全屏播放顶栏与底部 Home Indicator 自动隐藏、升级 iOS 设置页卡片呼吸感与排版、实现首页秒开快照缓存、收敛全站搜索片源提示日志为 3 行滚动框，并全面增强王二小（WEX）/ 饭太硬（FTY）片源在移动网络下的 DoH 连通率及详情页标题与海报准确性。

## 更新内容

- **iPad / iPhone 全屏播放自动隐藏系统顶栏与底部小横条**：开启 `UIViewControllerBasedStatusBarAppearance` 并通过原生 `MarcoFlutterViewController` 接管 `prefersStatusBarHidden`、`prefersHomeIndicatorAutoHidden` 与屏幕边缘系统手势延后响应；进入播放页（含 iPad 横竖屏）、控制条自动收起、锁屏及切回前台时自动同步沉浸式隐藏状态，退出播放页立即恢复系统状态栏。
- **iOS 设置页卡片排版与呼吸感升级**：重构一级与二级设置卡片尺寸层级（`16pt` 圆角、单行 `54pt` / 双行 `62pt` 行高、`34×34` 渐变图标徽章、`16.5pt` 主标题、精炼副标题与分区小标题），拉大分组与滑块控件间距，兼顾舒展呼吸感与 iPhone 首屏完整呈现。
- **首页秒开快照缓存与运行时加速**：新增站点首页分类与推荐列表快照持久化（Stale-While-Revalidate），冷启动或切换片源首帧即刻展示上次成功加载的资源并在后台静默刷新；已校验一致的 DRPY 运行时脚本跳过重复写盘，并为远程爬虫 `.jar` 增加 24 小时磁盘缓存与离线回退。
- **全站搜索片源日志固定 3 行可滑动**：将全站搜索顶部的片源异常/验证提示日志收敛至固定最大高度（约 3 行文字），内置独立 `ScrollController` 与滚动条支持上下滑动查阅，不再无限增高挤压下方影视结果卡片。
- **WEX / FTY 线路连通率提升与 DoH 防污染对齐**：为本机 Node `drpy-http` 启用 `gzip / deflate` 透明解压，并在系统 DNS 返回保留/FakeIP 地址或建连失败时自动回退阿里 / 腾讯 DoH（严格保留 HTTPS SNI 与证书域名校验）；复用常驻 `drpy-bootstrap-worker` 与 `Dex` 缓存消除多源并发搜索冷启动超时；优化 WEX 远程配置拉取与镜像优先级，切换玩偶 / 七味 / MacCMS 网盘源至免验证快速搜索路径，恢复木偶、蜡笔、花卷、剧透、快影、闪电、原盘、小枫、奥特、巴士、盘搜、易搜、优汐等线路拉取稳定性。
- **修复详情页封面错配（如《兰香如故》误显《主角》横幅）与标题后缀污染**：移除详情页无作用域 `img&&src` 兜底规则，严格限定详情海报容器内的懒加载属性（`data-original` / `data-src` / `src`）与 `og:image`，过滤 `loading.gif` 等占位图；剥离详情 `<h1>` 内嵌的 `更新至第XX集` 状态副标签转入备注，修复中文剧名清洗正则单词边界缺陷，杜绝误取顶部推广横幅图或错误剧照。

## 包信息与构建记录

- **未签名 IPA（iPhone / iPad 通用）**：`MarcoMovie-0.5.33-ios-iphone-ipad-unsigned.ipa`（更新兼容别名 `MarcoMovie-0.5.33-ios-unsigned.ipa`），SHA-256：`baebfe4409b78f15390d22ba717b78828809a16537dbbda4b9e316619cd66a09`。
- **对应源码包**：`MarcoMovie-ios-v0.5.33-source.zip`，SHA-256：`ce8b50ca5ee6e6789f09747b6fdc229f436c1234fa3b6c2f1f173b21525ad9b1`。
- **构建提交**：`1342e4c9f731db6621f4b286d9ae3f3563766bda`。[iOS / iPadOS 原生构建与全量校验记录（44349281542）](https://github.com/Pilipala9919/MarcoMovie/actions/runs/44349281542)。

## 验证范围与已知限制

- 通过公共内容守卫检查、iOS Xcode 原生 Release 构建及全部 `990` 项 Flutter 自动化测试与 `65` 项 CatPaw / Guard / DRPY 运行时回归校验；未签名 IPA 支持巨魔（TrollStore）直接覆盖更新或自签工具安装。自动化与云端构建校验不代表物理真机或第三方源站实时在线可用性的全量人工验收；当源站全站强制人机验证时仍需按提示完成验证或切换其他可用片源。
