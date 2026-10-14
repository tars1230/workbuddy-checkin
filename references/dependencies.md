# 依赖清单（Dependencies）

本 skill 运行链路（v1.1.0+，双路径）：

- **路径 A（首选，零凭据）**：调用桌面端注入的本地服务代理 `CODEBUDDY_SERVICE_PROXY_URL`
  → `/internal/hooks/services/invoke`，由 App 自行附加登录态转发云端 → 写日志。
  该路径**不需要 Node、不需要 Electron、不需要任何令牌**，只需要 curl + 运行中的桌面端。
- **路径 B（回退）**：读取本地令牌 → 调用官方 API → 写日志。仅当路径 A 不可用时才走。

> **路径 A 的存在使 Node.js / Electron 从「必需」降级为「仅路径 B 需要」。**
> 若你的 WorkBuddy 桌面端正在运行（正常使用场景），本 skill 可零依赖工作。

> v5.3.8+ 登录态改版说明：新版 WorkBuddy 桌面端把当前登录态写入 `workbuddy-desktop.info`，
> 且 `auth.accessToken` 已变为 **at-rest 信封加密**（`{$wbEncrypted:1, envelope:...}`），
> 解封密钥只存在于运行中的 App 进程内存 → **纯 Node / Electron 均无法离线解密**。
> 这正是 v1.0.x 在 v5.3.8+ 上长期 401 的根因；v1.1.0 用路径 A 绕过整个登录态读取，彻底解决。

## 核心依赖（必须有）

| 组件 | 作用 | 获取方式 | 说明 |
|---|---|---|---|
| **WorkBuddy 桌面端（已登录且正在运行）** | **路径 A：提供本地服务代理端点，代发请求（零凭据）** | 官网下载：https://www.codebuddy.cn/work/ | 路径 A 的唯一硬依赖。桌面端未运行时自动回退路径 B |
| curl（sh 版） / curl.exe（ps1 版） | 调用代理 / 签到 API | macOS/Linux 自带；Windows 10 1803+ 自带 curl.exe | 脚本内置绝对路径兜底（PATH 被裁剪也能找到） |

## 仅路径 B 回退时需要的依赖

| 组件 | 作用 | 获取方式 | 说明 |
|---|---|---|---|
| WorkBuddy 桌面端（已登录过） | 提供本地登录态（信封 / 明文 `workbuddy-desktop.info` / `state.vscdb`） | 同上 | 必须已登录过至少一次，否则没有可读的令牌 |
| Node.js（推荐 20+） | 读取登录态、解析 JSON（sh 版 JSON 取值亦用它跑 `jget.js`） | nodejs.org 下载 LTS；或系统包管理器 | 可用 `WB_CHECKIN_NODE=<path>` 指定；脚本会通配探测 `~/.workbuddy/binaries/node/versions/*/node[.exe]` |

## 仅旧版账户需要的依赖

| 组件 | 作用 | 获取方式 | 说明 |
|---|---|---|---|
| Electron 运行时（>= 30，推荐 37） | 仅旧版 `state.vscdb` 分支执行 `safeStorage.decryptString()` 解密令牌 | `scripts/setup.sh` / `setup.ps1`（npm install electron@37，约 100MB） | **绝大多数情况不需要**；仅旧版 CodeBuddy 用户需设 `WB_CHECKIN_APP_NAME=CodeBuddy` |

## 可选 / 回退依赖（缺了也能跑，只是走回退路径）

| 组件 | 作用 | 缺失时的行为 |
|---|---|---|
| Node.js 内置 `node:sqlite` | 仅旧版分支读取 state.vscdb | 旧版分支自动回退到 python3 |
| python3 | 回退读取 sqlite + 解析 API 响应 JSON（sh 版） | sh 版解析会降级为 unknown，签到仍会执行 |
| npm | 仅旧版 setup 自动下载 Electron | 手动放置 Electron 后通过环境变量/参数指定路径 |

> 说明：旧版分支的 decrypt-token.js 用 Node 内置 `node:sqlite` 读库（Electron 37 内置 Node 22 可用）；
> 若所用 Electron 版本较旧不支持 `node:sqlite`，会自动调用 `python3` 读取，无需额外安装 npm 包。
> 新版明文分支为纯 JSON 文件读取，不涉及 sqlite。

## 网络要求

- **仅需本机回环**：路径 A 请求发往 `http://127.0.0.1:<port>`，由桌面端代为出网，脚本自身零配置。
- **企业代理环境**：若设置了 `http_proxy` / `https_proxy` 环境变量，curl 会默认把**回环请求也交给代理**，
  导致路径 A 失效。v1.1.1 起所有回环调用已强制 `--noproxy '*'`，无需你再做配置；
  但回退路径发往 `copilot.tencent.com` 的请求仍会遵循系统代理（企业网络可能正需要它）。
- 路径 B 需可访问 `https://copilot.tencent.com`；仅旧版账户首次安装 Electron 时才需 `https://registry.npmjs.org`。
- 国内网络下载 Electron 慢时，配置镜像：
  ```bash
  npm config set registry https://registry.npmmirror.com
  # 并设置 Electron 镜像（可选）
  export ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"
  ```

## 平台差异速查

路径 A 与平台无关（只要有 curl + 运行中的桌面端）。下表为**路径 B 回退时**的登录态形态与运行时差异，均自动探测。

| 平台 | Shell | 新版明文登录态（v5.3.8+，主路径） | 旧版 state.vscdb（回退） | Electron 二进制（仅旧版） |
|---|---|---|---|---|
| macOS | `checkin.sh`（bash） | `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` | `~/Library/Application Support/WorkBuddy/User/globalStorage/state.vscdb` | `Electron.app/Contents/MacOS/Electron` |
| Windows | `checkin.ps1`（PowerShell）或 Git Bash 下 `checkin.sh` | `%APPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info` | `%APPDATA%\WorkBuddy\User\globalStorage\state.vscdb` | `electron.exe` |
| Linux | `checkin.sh`（bash） | `~/.config/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` | `~/.config/WorkBuddy/User/globalStorage/state.vscdb` | `electron`（无 .app 包裹） |

> ⚠️ Windows / Linux 的 `CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` 路径基于 v5.3.8 桌面端约定推导，已在 macOS 实测命中；其他平台如路径不一致，请以实际安装为准并反馈。

## 安装后的目录结构（示意）

```
workbuddy-checkin/
├── SKILL.md
├── CHANGELOG.md
├── LICENSE
├── references/dependencies.md
├── scripts/
│   ├── jget.js               # 零依赖 JSON 点号路径取值（sh 版解析代理响应）
│   ├── decrypt-token.js      # 仅路径 B：新版登录态 Node 读取 + 旧版 state.vscdb 解密
│   ├── checkin.sh            # macOS / Linux / Git Bash
│   ├── checkin.ps1           # Windows PowerShell
│   ├── setup.sh              # macOS / Linux 环境检查
│   └── setup.ps1             # Windows 环境检查
└── logs/                     # 签到日志（自动创建，不入版本库）
```
