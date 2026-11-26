package com.pilipala.marcomovie;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * Searchable catalog of all mobile settings across the 3-cluster / 7-entry mobile setting
 * sub-pages, powering instant grouped keyword filtering, direct sub-page jump (including
 * auto-expanding collapsed advanced sections), and animated target row highlight flash.
 */
final class MobileSettingsIndex {
    static final int SUB_SOURCES = 1;
    static final int SUB_APPEARANCE = 2;
    static final int SUB_PLAYBACK = 3;
    static final int SUB_SUBTITLE = 4;
    static final int SUB_SERVICES = 5;
    static final int SUB_SYNC = 6;
    static final int SUB_STORAGE = 7;

    static final class Entry {
        final int subPage;
        final String key;
        final String groupName;
        final String title;
        final String keywords;

        Entry(int subPage, String key, String groupName, String title, String keywords) {
            this.subPage = subPage;
            this.key = key;
            this.groupName = groupName;
            this.title = title;
            this.keywords = keywords;
        }
    }

    private static final List<Entry> ALL = new ArrayList<>();

    static {
        // Cluster 1: 个性化 — 外观与导航 (subPage = 2)
        add(
                SUB_APPEARANCE,
                "ms-theme-mode",
                "外观与导航",
                "外观模式（跟随系统 / 浅色日间 / 深色夜间）",
                "深色 浅色 跟随系统 日夜 夜间 日间 主题 暗黑 亮色 theme dark light");
        add(SUB_APPEARANCE, "ms-accent", "外观与导航", "主题强调色", "配色 主题色 蔚蓝 绯红 翡翠 霓紫 琥珀 石墨 强调色");
        add(SUB_APPEARANCE, "ms-ui-scale", "外观与导航", "界面整体缩放", "字号 放大 缩小 比例 dpi 缩放");
        add(
                SUB_APPEARANCE,
                "ms-nav-style",
                "外观与导航",
                "底部导航栏形态（4+1 分离搜索 / 五栏一体）",
                "底栏 搜索按钮 分离 胶囊 导航");
        add(SUB_APPEARANCE, "ms-nav-scroll", "外观与导航", "滑动页面时底栏自动收起", "上滑 折叠 隐藏 常驻 滚动 导航");
        add(SUB_APPEARANCE, "ms-home-sections", "外观与导航", "首页专题显示与排序", "首页 专题 栏目 隐藏 显示 开关 排序 发现 模块");
        add(SUB_APPEARANCE, "ms-home-banner", "外观与导航", "首页精选大图横幅", "轮播 海报 头图 横幅");
        add(SUB_APPEARANCE, "ms-poster-density", "外观与导航", "海报墙排布密度", "海报 列数 紧凑 标准 宽敞 密度 网格");
        add(SUB_APPEARANCE, "ms-card-subtitle", "外观与导航", "海报下方信息显示", "副标题 角标 海报 标题 清晰度");
        add(SUB_APPEARANCE, "ms-show-history", "外观与导航", "首页显示继续观看", "继续观看 续播 历史 首页");
        add(SUB_APPEARANCE, "ms-cover-ambient", "外观与导航", "封面氛围柔光背景", "氛围 取色 背景 柔光 自适应");
        add(SUB_APPEARANCE, "ms-wallpaper", "外观与导航", "自定义背景壁纸与暗度", "壁纸 背景图 遮挡 压暗 相册");
        add(SUB_APPEARANCE, "ms-glass-toggle", "外观与导航", "关闭半透明毛玻璃（更省电）", "毛玻璃 透明 模糊 流畅 省电 性能");
        add(SUB_APPEARANCE, "ms-reduced-motion", "外观与导航", "减弱界面动态效果", "动画 动效 精简 流畅 减弱");

        // Cluster 2: 内容与观影 — 片源与直播 (subPage = 1)
        add(SUB_SOURCES, "ms-clip-import", "片源与直播", "剪贴板一键识别导入", "粘贴 订阅 网址 json js py zip 配置");
        add(SUB_SOURCES, "ms-url-import", "片源与直播", "通过网址或本地包导入片源", "多仓 zip 本地 文件 订阅源 导入 配置");
        add(SUB_SOURCES, "ms-switch-site", "片源与直播", "切换默认首页片源", "换源 站点 默认源 片源");
        add(SUB_SOURCES, "ms-saved-configs", "片源与直播", "订阅源与多仓管理", "多仓 子仓 仓库 订阅 历史配置 合并");
        add(SUB_SOURCES, "ms-sub-auto", "片源与直播", "每日后台自动更新订阅源", "自动更新 刷新 订阅 静默");
        add(SUB_SOURCES, "ms-sub-refresh-now", "片源与直播", "立即刷新当前订阅源", "刷新 拉取 更新 订阅");
        add(SUB_SOURCES, "ms-live-import", "片源与直播", "电视直播源管理", "直播 频道 iptv m3u txt json");
        add(SUB_SOURCES, "ms-live-epg", "片源与直播", "直播节目预告单 (EPG)", "epg xmltv 预告 回看 节目表 节目单");
        add(SUB_SOURCES, "ms-live-hq", "片源与直播", "直播优先高画质与 IPv6", "ipv6 4k 高清 画质 直播");
        add(SUB_SOURCES, "ms-live-merge", "片源与直播", "同名频道合并多线路切换", "同名 合并 多线路 聚合 直播");
        add(SUB_SOURCES, "ms-search-sidebar", "片源与直播", "搜索页左侧显示片源筛选栏", "侧边栏 顶部 搜索 平台");
        add(SUB_SOURCES, "ms-search-threads", "片源与直播", "聚合搜索同时查询片源数", "并发 线程 搜索 速度");
        add(
                SUB_SOURCES,
                "ms-live-udpxy",
                "片源与直播",
                "路由器组播转单播 (udpxy)",
                "udpxy rtp 组播 单播 路由器 代理 高级 调试");
        add(SUB_SOURCES, "ms-ext-csp", "片源与直播", "支持第三方 JAR 扩展源", "jar csp 插件 扩展 爬虫 高级 调试");
        add(
                SUB_SOURCES,
                "ms-ext-js",
                "片源与直播",
                "网页脚本源兼容兜底 (WebView JS)",
                "js webview 兜底 脚本 引擎 高级 调试");
        add(
                SUB_SOURCES,
                "ms-ext-py",
                "片源与直播",
                "内置 Python 扩展运行引擎",
                "python py cpython 3.11 脚本 爬虫 高级 调试");
        add(SUB_SOURCES, "ms-https-only", "片源与直播", "仅允许 HTTPS 安全插件", "https 安全 插件 限制 高级 调试");

        // Cluster 2: 内容与观影 — 播放与触控手势 (subPage = 3)
        add(SUB_PLAYBACK, "ms-detail-tap", "播放与触控手势", "点选剧集时的起播方式", "内嵌 小窗 全屏 竖屏 详情页 起播");
        add(SUB_PLAYBACK, "ms-ep-clean", "播放与触控手势", "自动整理清晰集名", "正则 净化 原名 乱码 集名 ai");
        add(SUB_PLAYBACK, "ms-auto-next", "播放与触控手势", "播完自动连播下一集", "连播 下一集 自动播放");
        add(SUB_PLAYBACK, "ms-repeat-mode", "播放与触控手势", "循环播放模式", "循环 单集循环 列表循环");
        add(
                SUB_PLAYBACK,
                "ms-player-engine",
                "播放与触控手势",
                "默认播放内核（Media3 / 系统 / IJK / MPV）",
                "mpv media3 exo ijk 系统 智能推荐 高画质影院 内核 播放器");
        add(SUB_PLAYBACK, "ms-auto-switch-kernel", "播放与触控手势", "起播失败自动切换备用内核", "切核 回退 备用 内核");
        add(SUB_PLAYBACK, "ms-decoder-mode", "播放与触控手势", "视频解码方式（硬解 / 软解）", "硬解 软解 hw sw 解码");
        add(
                SUB_PLAYBACK,
                "ms-hdr-tone",
                "播放与触控手势",
                "HDR 画面亮暗自适应优化 (MPV)",
                "hdr 色调映射 mpv libplacebo");
        add(SUB_PLAYBACK, "ms-anime4k", "播放与触控手势", "动漫画面实时超分增强 (Anime4K)", "anime4k 超分 动漫 mpv");
        add(SUB_PLAYBACK, "ms-letterbox", "播放与触控手势", "宽银幕上下黑边柔光填充", "黑边 虚化 氛围 宽银幕");
        add(SUB_PLAYBACK, "ms-loudness", "播放与触控手势", "音量响度增益", "响度 音量 增益 人声 db");
        add(SUB_PLAYBACK, "ms-picture-effect", "播放与触控手势", "画面色彩风格", "画质 色彩 明亮 影院 柔和");
        add(SUB_PLAYBACK, "ms-audio-effect", "播放与触控手势", "音频均衡音效", "音效 均衡器 低音 人声 影院");
        add(SUB_PLAYBACK, "ms-aspect", "播放与触控手势", "默认画面比例", "比例 铺满 16:9 4:3 裁切");
        add(SUB_PLAYBACK, "ms-play-speed", "播放与触控手势", "默认播放倍速", "默认速度 倍速 1.5x 2x");
        add(SUB_PLAYBACK, "ms-buffer-sec", "播放与触控手势", "网络预加载缓冲时长", "缓冲 卡顿 秒数 内存");
        add(SUB_PLAYBACK, "ms-swipe-swap", "播放与触控手势", "互换左右半屏亮度与音量手势", "手势 左手 右手 亮度 音量 互换");
        add(SUB_PLAYBACK, "ms-src-bright", "播放与触控手势", "按片源记住各自播放亮度", "亮度 记忆 屏幕");
        add(SUB_PLAYBACK, "ms-long-speed", "播放与触控手势", "长按画面临时加速倍速", "长按 倍速 2x 3x 4x 快进");
        add(SUB_PLAYBACK, "ms-vert-ep", "播放与触控手势", "上下滑动切换上下集", "双指 换集 上下滑 短剧 防误触");
        add(SUB_PLAYBACK, "ms-corner-hud", "播放与触控手势", "播放页右上角状态信息", "网速 电量 时间 分辨率 hud 角标");
        add(SUB_PLAYBACK, "ms-mini-bar", "播放与触控手势", "隐藏按钮后保留底部进度细线", "迷你进度条 底部 进度线");
        add(SUB_PLAYBACK, "ms-btn-order", "播放与触控手势", "自定义播放器按钮顺序", "按钮 排序 工具栏 自定义");
        add(SUB_PLAYBACK, "ms-skip-intro", "播放与触控手势", "自动识别并跳过剧集片头", "片头 theintrodb introdb 自动跳过");
        add(SUB_PLAYBACK, "ms-manual-skip", "播放与触控手势", "手动设置跳过片头 / 片尾秒数", "片头 片尾 秒数 跳过");
        add(SUB_PLAYBACK, "ms-pip-bg", "播放与触控手势", "返回桌面自动悬浮小窗播放", "小窗 画中画 pip home");
        add(SUB_PLAYBACK, "ms-bg-audio", "播放与触控手势", "锁屏或切后台继续听剧", "后台 锁屏 音频 听剧");
        add(
                SUB_PLAYBACK,
                "ms-tunneled",
                "播放与触控手势",
                "4K HDR 低功耗硬件直通",
                "隧道 4k hdr tunneled 直通 高级 调试");
        add(SUB_PLAYBACK, "ms-sw-audio", "播放与触控手势", "兼容音频软解码", "音频 软解 声音 无声 media3 高级 调试");
        add(SUB_PLAYBACK, "ms-prefer-aac", "播放与触控手势", "优先选择 AAC 兼容音轨", "aac 音轨 音频 高级 调试");
        add(
                SUB_PLAYBACK,
                "ms-video-output",
                "播放与触控手势",
                "画面渲染输出模式",
                "输出 保真 兼容 调色 surface texture 高级 调试");
        add(SUB_PLAYBACK, "ms-hls-proxy", "播放与触控手势", "自动修复防盗链视频流", "hls m3u8 代理 伪装头 防盗链 高级 调试");
        add(SUB_PLAYBACK, "ms-hls-ad", "播放与触控手势", "自动过滤切片插播广告 (HLS)", "去广告 广告 过滤 hls m3u8 高级 调试");

        // Cluster 2: 内容与观影 — 字幕与弹幕 (subPage = 4)
        add(SUB_SUBTITLE, "ms-sub-adjust", "字幕与弹幕", "全屏手势预览调校字幕", "字幕 字号 底距 缩放 拖拽 调校");
        add(SUB_SUBTITLE, "ms-sub-bilingual", "字幕与弹幕", "AI 双语对照同屏字幕", "双语 翻译 ai 字幕 对照");
        add(SUB_SUBTITLE, "ms-sub-style", "字幕与弹幕", "字幕配色与底衬样式", "字幕 颜色 描边 样式 底衬");
        add(SUB_SUBTITLE, "ms-sub-weight", "字幕与弹幕", "字幕字体粗细", "字重 加粗 描边 粗细 字幕");
        add(SUB_SUBTITLE, "ms-sub-offset", "字幕与弹幕", "字幕水平位置微调", "偏移 水平 居中 位置 字幕");
        add(
                SUB_SUBTITLE,
                "ms-online-sub",
                "字幕与弹幕",
                "在线字幕搜刮凭据（SubHD / 射手 / OpenSubtitles）",
                "在线字幕 subhd 射手网 assrt opensubtitles token");
        add(SUB_SUBTITLE, "ms-danmaku-def", "字幕与弹幕", "播放时默认开启弹幕", "弹幕 默认 自动开启");
        add(SUB_SUBTITLE, "ms-danmu-panel", "字幕与弹幕", "弹幕样式与关键词屏蔽", "弹幕 屏蔽词 样式 行数 字体 高级");
        add(SUB_SUBTITLE, "ms-danmaku-style", "字幕与弹幕", "弹幕显示画面区域", "弹幕 区域 半屏 全屏");
        add(SUB_SUBTITLE, "ms-danmaku-opacity", "字幕与弹幕", "弹幕文字透明度", "弹幕 不透明度 透明度");
        add(SUB_SUBTITLE, "ms-danmaku-speed", "字幕与弹幕", "弹幕飘屏速度", "弹幕 滚动 速度");
        add(SUB_SUBTITLE, "ms-danmaku-src", "字幕与弹幕", "弹幕源管理与一键测速", "弹弹play dandan logvar 测速 弹幕源");

        // Cluster 2: 内容与观影 — 网盘、追剧与 AI 助手 (subPage = 5)
        add(
                SUB_SERVICES,
                "ms-netdisk",
                "网盘、追剧与 AI 助手",
                "网盘扫码授权中心（夸克 / UC / 阿里 / 百度 / 115）",
                "夸克 阿里 百度 uc 115 网盘 扫码 账号 授权");
        add(SUB_SERVICES, "ms-alist", "网盘、追剧与 AI 助手", "挂载个人 AList 网盘目录", "alist webdav 挂载 网盘");
        add(SUB_SERVICES, "ms-emby", "网盘、追剧与 AI 助手", "连接 Emby 私有媒体库", "emby 媒体库 服务器 挂载");
        add(
                SUB_SERVICES,
                "ms-bgm-trakt",
                "网盘、追剧与 AI 助手",
                "绑定 Bangumi / 豆瓣追剧账号",
                "追剧 日历 bangumi 豆瓣 douban cookie");
        add(SUB_SERVICES, "ms-ai-enable", "网盘、追剧与 AI 助手", "启用 AI 观影助手", "ai 智能 开关 大模型");
        add(
                SUB_SERVICES,
                "ms-ai-cfg",
                "网盘、追剧与 AI 助手",
                "AI 服务商、端点与模型配置",
                "ai deepseek 通义千问 硅基流动 kimi glm ollama openai");
        add(SUB_SERVICES, "ms-ai-clean-search", "网盘、追剧与 AI 助手", "AI 净化搜索结果片名", "ai 搜索 净化 片名");
        add(SUB_SERVICES, "ms-ai-translate-sub", "网盘、追剧与 AI 助手", "AI 字幕实时双语翻译", "ai 字幕 翻译 双语");
        add(
                SUB_SERVICES,
                "ms-ai-py-audit",
                "网盘、追剧与 AI 助手",
                "导入 Python 脚本时进行安全扫描",
                "ai python 安全 审计 扫描");

        // Cluster 3: 互联与系统 — 云同步与隐私互联 (subPage = 6)
        add(SUB_SYNC, "ms-cloud-sync", "云同步与隐私互联", "云盘多端自动同步 (WebDAV)", "webdav 云同步 历史 收藏 增量 同步");
        add(SUB_SYNC, "ms-lan-sync", "云同步与隐私互联", "同 Wi-Fi 设备局域网互传同步", "局域网 lan 同步 互传 设备");
        add(SUB_SYNC, "ms-push-tv", "云同步与隐私互联", "扫码推送片源 / 辅助输入至电视", "电视 tv 扫码 推送 推源 辅助输入 互联");
        add(SUB_SYNC, "ms-cast-enable", "云同步与隐私互联", "局域网 DLNA 无线投屏", "dlna 投屏 电视 广播");
        add(SUB_SYNC, "ms-privacy", "云同步与隐私互联", "隐私空间与 4 位数字口令", "隐私 密码 pin 隐藏 加密 隔离");
        add(
                SUB_SYNC,
                "ms-spider-gw",
                "云同步与隐私互联",
                "局域网远程爬虫网关 (Spider)",
                "spider 网关 局域网 共享 扩展 高级 调试");

        // Cluster 3: 互联与系统 — 存储、备份与关于 (subPage = 7)
        add(SUB_STORAGE, "ms-backup-export", "存储、备份与关于", "导出手机端配置备份", "备份 导出 json");
        add(SUB_STORAGE, "ms-backup-restore", "存储、备份与关于", "从备份文件恢复配置", "备份 恢复 还原 导入");
        add(SUB_STORAGE, "ms-reset-mobile", "存储、备份与关于", "恢复外观与播放默认设置", "重置 恢复默认 偏好");
        add(SUB_STORAGE, "ms-disk-cache", "存储、备份与关于", "边播边存视频缓存上限", "缓存 空间 磁盘 视频 mb");
        add(
                SUB_STORAGE,
                "ms-clear-caches",
                "存储、备份与关于",
                "清理缓存与个人观看记录",
                "清理 图片缓存 推荐缓存 ai缓存 搜索历史 观看历史 崩溃 日志");
        add(
                SUB_STORAGE,
                "ms-author-social",
                "存储、备份与关于",
                "联系与反馈作者（各社媒账号名）",
                "作者 反馈 联系 社媒 PILIPALA来信 pilipala 小红书 B站 哔哩哔哩 抖音 公众号 视频号");
        add(
                SUB_STORAGE,
                "ms-official-group",
                "存储、备份与关于",
                "官网交流群",
                "交流群 QQ群 社区 反馈 讨论 官网 链接 group marcotv");
        add(
                SUB_STORAGE,
                "ms-official-site",
                "存储、备份与关于",
                "Marco 官网（marcotv.wlj9919.top）",
                "官网 官方 下载 防伪 网址 marcotv.wlj9919.top 安全 病毒");
        add(SUB_STORAGE, "ms-updates", "存储、备份与关于", "检查软件更新（手机端通道）", "更新 升级 版本 android-mobile");
        add(SUB_STORAGE, "ms-crash-reports", "存储、备份与关于", "查看历史异常退出报告", "闪退 崩溃 crash 报告");
        add(SUB_STORAGE, "ms-logs", "存储、备份与关于", "查看运行诊断日志", "日志 报错 调试 诊断");
        add(SUB_STORAGE, "ms-replay-onboarding", "存储、备份与关于", "重新查看新手引导", "新手引导 引导 导览 极光");
        add(SUB_STORAGE, "ms-licenses", "存储、备份与关于", "开源许可与版本信息", "开源 gpl 许可 关于 版本");
    }

    private MobileSettingsIndex() {}

    private static void add(int sub, String key, String grp, String title, String kw) {
        ALL.add(new Entry(sub, key, grp, title, kw));
    }

    static List<Entry> all() {
        return Collections.unmodifiableList(ALL);
    }

    static List<Entry> search(String rawQuery) {
        List<Entry> hits = new ArrayList<>();
        if (rawQuery == null) return hits;
        String q = rawQuery.trim().toLowerCase(Locale.ROOT);
        if (q.isEmpty()) return hits;
        for (Entry e : ALL) {
            if (e.title.toLowerCase(Locale.ROOT).contains(q)
                    || e.groupName.toLowerCase(Locale.ROOT).contains(q)
                    || e.keywords.toLowerCase(Locale.ROOT).contains(q)) {
                hits.add(e);
            }
        }
        return hits;
    }
}
