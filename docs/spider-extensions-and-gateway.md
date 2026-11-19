# 跨平台蜘蛛扩展包与自建蜘蛛网关规范

> **零官方服务器原则**：Marco Movie **不内置、不提供、不托管**任何片源或中转服务器。所有解析默认完全在用户本机执行；自建网关功能默认关闭，仅在用户主动填写自己的局域网设备或私有 NAS / Docker 地址时才会启用。

## 一、本机优先三级解析架构（Local-First）

为了在 iOS、iPadOS、macOS、Windows、鸿蒙等非 Android 系统上逐步覆盖原本依赖 Android 原生加密库（`.so`）的 `csp_*` 线路，Marco Movie 采用严格的**本机优先**三级解析顺序：

1. **本机内置跨平台适配（默认优先）**
   - 直接运行内置 Dart 适配器、QuickJS（JS / CatVod ES 模块）、DRPY2、Python 与 HTTP T4。
   - **已在本机适配的线路永不经过任何外部网关**。
2. **短期方案：热插拔脚本扩展包（`marco-adapter-pack-v1`）**
   - 用户或社区无需等待 App 重新编译发版，即可通过 URL 或 JSON 导入纯脚本扩展包，将未适配的 `csp_*` 标识映射到纯本地运行的 JS / DRPY2 / Python / T4 脚本。
   - 一次编写，iOS / macOS / Windows / 鸿蒙全平台通用。
3. **中期方案：可选自建蜘蛛网关兜底（`marco-spider-gateway-v1`，默认关闭）**
   - 面向拥有局域网 Android 设备或私有 NAS / Docker 的进阶用户，用于兜底仍依赖闭源 `.so` 的长尾线路。
   - 网关**只负责解析轻量 JSON 元数据**（首页/分类/搜索/详情/播放地址），实际视频流仍由本机直连上游 CDN 或网盘播放，不消耗网关视频带宽。

---

## 二、热插拔脚本扩展包规范（`marco-adapter-pack-v1`）

在 App 中进入 **设置 → 蜘蛛扩展与网关 → 导入脚本扩展包**，支持直接粘贴 JSON 或填入 `https://` 链接（单包上限 2 MB，最多 256 条规则）：

```json
{
  "schema": "marco-adapter-pack-v1",
  "id": "community-sample-pack",
  "name": "跨平台脚本扩展包示例",
  "version": "1.0.0",
  "author": "YourName",
  "description": "将依赖 Android .so 的 csp_* 线路映射为跨平台本地脚本",
  "rules": [
    {
      "id": "example-js",
      "matchApis": ["csp_ExampleSpider", "csp_ExampleSpiderGuard"],
      "kind": "js",
      "scriptUrl": "https://plugins.example/adapters/example_spider.js",
      "description": "使用纯 JavaScript 替代原 .so 蜘蛛"
    },
    {
      "id": "example-drpy",
      "matchApis": ["csp_ExampleDrpy*"],
      "kind": "drpy",
      "scriptUrl": "https://plugins.example/drpy/example_rule.js"
    },
    {
      "id": "example-python",
      "matchApis": ["csp_ExamplePy"],
      "kind": "python",
      "scriptUrl": "https://plugins.example/py/example_spider.py"
    },
    {
      "id": "example-t4",
      "matchApis": ["csp_ExampleT4"],
      "kind": "t4",
      "scriptUrl": "https://plugins.example/t4/example"
    }
  ]
}
```

### 字段说明

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `schema` | 是 | 固定为 `marco-adapter-pack-v1` |
| `id` / `name` | 是 | 扩展包唯一标识与显示名称（同 `id` 重复导入自动覆盖更新） |
| `rules[].matchApis` | 至少其一 | 匹配的 `csp_*` 接口名列表，大小写不敏感，支持末尾通配符 `*`（如 `csp_manjuai*`） |
| `rules[].matchNamePattern` | 至少其一 | 可选的片源名称正则/关键字匹配 |
| `rules[].kind` | 是 | 执行引擎：`js`、`drpy`、`python`、`t4` |
| `rules[].scriptUrl` | 与 `inlineScript` 二选一 | 远程 `http://` 或 `https://` 脚本或 T4 地址 |
| `rules[].inlineScript` | 与 `scriptUrl` 二选一 | 直接内嵌在包内的纯文本脚本源码（`t4` 不适用） |
| `rules[].extOverride` | 否 | 覆盖原站点的 `ext` 参数；省略则透传订阅原 `ext` |

---

## 三、自建蜘蛛网关协议（`marco-spider-gateway-v1`）

### 1. 鉴权要求
所有 HTTP 请求均需在 Header 中携带用户自己配置的令牌：
```http
Authorization: Bearer <your-token>
X-Marco-Gateway-Protocol: marco-spider-gateway-v1
```

### 2. 健康探测：`GET /marco-gateway/v1/health`
响应示例：
```json
{
  "ok": true,
  "protocol": "marco-spider-gateway-v1",
  "deviceName": "家庭 NAS 蜘蛛网关",
  "engine": "self-hosted-python",
  "supportsNativeSo": true
}
```

### 3. 蜘蛛调用：`POST /marco-gateway/v1/invoke`
请求体：
```json
{
  "protocol": "marco-spider-gateway-v1",
  "action": "home | homeVod | category | search | detail | play",
  "site": {
    "key": "site_key",
    "name": "片源名",
    "api": "csp_Example",
    "type": 3,
    "ext": "...",
    "jar": "...",
    "spider": "...",
    "playUrl": ""
  },
  "params": {
    "tid": "1",
    "pg": 1,
    "wd": "关键词",
    "id": "vod_id",
    "flag": "线路名",
    "filter": {}
  }
}
```
响应体：
```json
{
  "ok": true,
  "data": { "class": [], "list": [] }
}
```

### 4. 局域网自动发现（UDP 41978）
- 客户端向局域网 UDP 端口 `41978` 广播：`MARCO_SPIDER_GATEWAY_PROBE_V1`
- 网关回复 JSON：`{"protocol":"marco-spider-gateway-v1","port":9981,"deviceName":"...","engine":"...","supportsNativeSo":true,"requiresToken":true}`
- **安全约束**：发现响应绝不包含 Bearer Token，用户仍需手动输入或核对设备令牌。

### 5. 一键自托管部署示例（Docker / Python）
仓库 [`gateway/`](../gateway/) 目录内置了零依赖参考实现与 Docker Compose 模板：
```bash
cd gateway
MARCO_GATEWAY_TOKEN="your-random-token" python3 spider_gateway_server.py
```
然后在 Marco Movie 中打开 **设置 → 蜘蛛扩展与网关**，填入 `http://127.0.0.1:9981`（或您的局域网设备地址）与令牌，点击「测试网关连接」并启用即可。
