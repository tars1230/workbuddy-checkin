# workbuddy-checkin

WorkBuddy 每日积分自动签到 —— **零凭据**实现（100 积分/天，连续第 7 天 1000 积分）。

原理、依赖、平台差异与排错详见 **[SKILL.md](SKILL.md)**；版本变更见 **[CHANGELOG.md](CHANGELOG.md)**。

## 为什么是「零凭据」

WorkBuddy 桌面端会把 `CODEBUDDY_SERVICE_PROXY_URL` 注入到每个 Bash / 钩子子进程，
这是官方提供给子进程的**服务调用代理**：由 App 自己把登录态的 `Authorization` 头
附加到请求上，再转发到云端。调用方只需声明 `X-Service-Id`，**全程不需要、也拿不到任何令牌**。

```
POST {CODEBUDDY_SERVICE_PROXY_URL}/..%2F..%2Fbilling%2Fmeter%2Fcheckin-activity-status
     X-Service-Id: auth
```

因此本 skill 不再依赖「解密本地登录态」——桌面端登录态已改为 at-rest 信封加密，
解封密钥只存在于运行中的 App 进程内存，离线解密不可能。这正是旧版脚本长期 401 的根因。
代理不可用时（如桌面端未运行），脚本会自动回退到原有的「读取本地令牌 → 直连官方接口」流程。

## 快速开始

```bash
# macOS / Linux / Git Bash
bash scripts/setup.sh     # 环境检查：优先验证零凭据路径
bash scripts/checkin.sh   # 立即签到一次
```

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
powershell -ExecutionPolicy Bypass -File scripts\checkin.ps1
```

## 特点

- **零凭据**：不读取、不持有、不外发任何令牌
- **零运行时依赖**：只要桌面端在运行，不需要 Node.js / Electron
- **幂等**：当日重复运行不会重复领取，也不会误报失败
- **跨平台**：macOS / Linux（bash）与 Windows（PowerShell 5.1）
- **自愈**：curl、Node、代理端口均自动探测；PATH 被裁剪（cron / 计划任务）也能跑
- **无后端**：全部在本机完成

## 许可

[MIT](LICENSE)
