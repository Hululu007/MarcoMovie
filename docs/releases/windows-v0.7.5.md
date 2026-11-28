# Marco Movie Windows x64 0.7.5

发布日期：2026-11-28。应用版本 `0.7.5`（构建号 `82`）；支持 Windows 10 / 11（64 位安装版与绿色便携版）。

## 本次更新

- **桌面端 WebDAV 局域网扫码直绑**：在「云同步」面板生成携带 `marco-bind-box-v1`（HMAC-SHA256 CTR + Encrypt-then-MAC）端到端加密通道的局域网二维码；移动端扫码即可将 WebDAV 服务器地址与加密凭据安全推送至桌面端并自动触发合并同步。
- **Emby / Jellyfin HTTP 8096 与 4K DirectPlay 连接修复**：连接表单默认切换为 `HTTP + 8096` 并支持 HTTPS 切换、选填端口/路径/名称与裸域名直填（兼容 `/web/` 完整网址粘贴）；登录自动支持 `/emby` 与根路径 `/` 回退、标准 `X-Emby-Authorization` 头与 TLS 握手无凭据明确诊断；`PlaybackInfo` 放行 HEVC / AV1 与多音轨 DirectPlay。

## 包信息与构建记录

- **Windows 64 位安装版（Inno Setup）**：`MarcoMovie-0.7.5-windows-x64-setup.exe`（`72515651` B，兼容别名 `MarcoMovie-0.7.5-windows-setup.exe`），SHA-256：`afbafe63d229ff449a380feca4545fe56c8177526488c52a5cf471862f2fe189`。
- **Windows 64 位绿色便携版**：`MarcoMovie-0.7.5-windows-x64-portable.zip`（`103938323` B，兼容别名 `MarcoMovie-0.7.5-windows-x64.zip`），SHA-256：`c757ce175441300cea7997986031c233254b136b02e90e2758f595813c7e5f24`。
- **对应源码包**：`MarcoMovie-windows-v0.7.5-source.zip`（`23432930` B），SHA-256：`0ba85fc57fb21012705b04d2b6e153b4e7f7d58090617b3ecbc51d96535440e0`。
- **构建提交与 CI 记录**：`a9d5c8cb2bc5c083dc82639c3cbf7026c01882db`。[Build Windows Desktop (x64) (Job 140830652651 · Run 46096257329)](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46096257329/job/140830652651) / [Public Guardrails (Job 140828164811)](https://github.com/Pilipala9919/MarcoMovie/actions/runs/46096257329/job/140828164811)。
- **已知边界**：安装包与便携程序未购买商业代码签名；商业显卡与第三方站点穷尽播放仍待用户反馈。
