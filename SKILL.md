---
name: workbuddy-checkin
description: WorkBuddy 每日积分自动签到。首选走桌面端本地服务代理（零凭据，由 App 自行附加登录态），失败才回退读取本机登录令牌（信封加密 / state.vscdb），调用官方签到 API 完成每日积分领取（100 积分/天，连续第 7 天 1000 积分），并支持配置定时任务。触发词：WorkBuddy 签到、每日积分、check-in、credits。
version: "1.1.1"
license: MIT
---

# WorkBuddy 每日积分签到

自动领取 WorkBuddy 每日积分（100 积分/天，连续第 7 天 1000 积分）。
全流程在本机完成：**首选由桌面端代发请求（零凭据）**，回退时读取本地登录态。无后端服务。

## ⚠️ 前置条件（最重要的一条）

**路径 A 要求 WorkBuddy 桌面端正在运行。** 这不是可选项：

- 桌面端在跑 → 它把 `CODEBUDDY_SERVICE_PROXY_URL` 注入子进程，脚本零凭据完成签到。
- 桌面端没在跑 → 回退路径 B 只能在**登录态仍是可离线解密的形态**时成功；
  当前主流登录态是 at-rest 信封加密（解封密钥只在 App 进程内存），此时回退路径
  拿到的多是 `state.vscdb` 里的**旧令牌**，签到会以 401 告终。

所以：**定时任务必须保证执行时刻桌面端在运行**（见下方「设置定时任务」的两种做法）。
签到本身不需要窗口在前台，后台运行即可。

## 环境支持矩阵（诚实版）

| 环境 | 路径 A（零凭据） | 路径 B（回退） | 实测状态 |
|------|------------------|----------------|----------|
| Windows 10/11 + Git Bash | ✅ | ✅ | **已实测**（含企业代理污染、精简 PATH、失效代理地址） |
| Windows 10/11 + PowerShell 5.1 | ✅ | ✅ | **已实测**（解析 0 错误、BOM 完整） |
| macOS（Apple Silicon / Intel） | ✅ | ⚠️ 依赖钥匙串 | **已实测支持**（macOS 原生 netstat + pgrep 毫秒级自探测，免疫 lsof 内核挂起） |
| Linux | ⚠️ 未实测 | ⚠️ 未实测 | **未验证**：同上；路径 B 的旧库分支还需桌面会话 + keyring |
| 企业代理环境（设了 `http_proxy`） | ✅ | ⚠️ 取决于代理 | **已实测修复**（回环请求强制 `--noproxy '*'`） |
| 桌面端未运行 | ❌ | ⚠️ 多数情况下 401 | **已实测**（会打印明确指路，而不是让人去装 Node） |

> 上表里标「未实测」的格子是真实缺口，不要当成可用。macOS / Linux 首次运行请先跑 `bash scripts/setup.sh`
> 并跑一次 `bash scripts/checkin.sh`，把输出反馈回来。

## 原理

### 路径 A（首选，v1.1.0+）：桌面端本地服务代理 —— 零凭据

WorkBuddy 桌面端会把 `CODEBUDDY_SERVICE_PROXY_URL` 注入到每个 Bash / 钩子子进程，
形如 `http://127.0.0.1:<port>/internal/hooks/services/invoke`。这是官方设计的
「服务调用代理」：**由 App 自己把登录态的 `Authorization` 头附加到请求上**，再转发到云端。
调用方只需声明 `X-Service-Id`（签到用 `auth`），**全程不需要、也拿不到任何令牌**。

```
POST {CODEBUDDY_SERVICE_PROXY_URL}/..%2F..%2Fbilling%2Fmeter%2Fcheckin-activity-status
     X-Service-Id: auth
```

- 有效活动接口是 `billing/meter/checkin-activity-status`，字段 `data.today_checked_in` 可靠。
  ⚠️ `billing/meter/checkin-status` 是**废弃接口**，`active` / `today_checked_in` 恒为 false，不可用于判定。
- 代理地址优先取自环境变量；缺失时反查本机 WorkBuddy 进程的监听端口自动探测。
- 优点：**免疫 at-rest 信封加密 / keyblob protector 变更导致的 401**——这正是旧版脚本连续 401 的根因。

### 路径 B（回退）：读取本机登录态 → 直连云端

路径 A 不可用时（桌面端未运行、代理拒绝、环境变量与端口探测均失败），自动回退：

1. WorkBuddy 桌面端登录后，会在本地保存登录态。存在三种形态，脚本按序自动探测：
   - **新版信封加密（当前主流，Windows/macOS 均见此形态）**：文件
     `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info`
     （macOS 为 `~/Library/Application Support/...`），`auth.accessToken` 不再是明文字符串，而是
     `{ $wbEncrypted: 1, envelope: base64({ suite:1, keyId, nonce, authTag, ciphertext }) }`；
     `refreshToken`、`account.nickname`、`account.phoneNumber` 同样是信封字段。
     密钥托管在 `~/.workbuddy/keyblob`（`slots[0].wrapped` 由桌面端 protecter 保护），
     **纯 Node 无 protector 时无法解密**（密钥只在运行中的 App 进程内存里）。
   - **新版明文（v5.3.8 早期）**：同文件，`auth.accessToken` 为明文字符串，纯 Node 直接读。
   - **旧版 `state.vscdb`（实测仍可用，Windows 主要回退路径）**：`%APPDATA%\WorkBuddy\User\globalStorage\state.vscdb`，
     凭据条目 `secret://{...key:planning-genie.new.accessTokencn}`，值为
     Chromium OS-Crypt 格式 `v10 || 12B nonce || ciphertext || 16B tag`（AES-256-GCM），
     主密钥在 `%APPDATA%\WorkBuddy\Local State` 的 `os_crypt.encrypted_key`
     （`DPAPI` 前缀 + DPAPI 密文）。**纯 Node 可解**：调 PowerShell `ProtectedData.Unprotect`
     解封主密钥后本地 AES-GCM 解密，无需 Electron。
2. 运行时策略：**Node 优先**；信封路径无 protector 时静默回退旧版库；仍失败则用 Electron（若可用）。
3. 调用腾讯官方签到 API：
   - 查状态：`POST https://copilot.tencent.com/billing/meter/checkin-status`
     （⚠️ 该接口已废弃，`data.today_checked_in` 恒为 `false`；此处仅用于快速短路探测 401，
      **不得**作为「今日已签到」的判定依据）
   - 执行签到：`POST https://copilot.tencent.com/billing/meter/daily-checkin`
   - 认证：`Authorization: Bearer <accessToken>`
4. 脚本幂等：先查状态（命中即跳过）；`daily-checkin` 返回 `code=10001`（今天已签到）同样视为成功，避免重复请求被误报为失败。

> ⚠️ v5.3.8 实测 `checkin-status` 的 `today_checked_in` 字段不可靠（签到成功后仍可能为 `false`）。因此路径 B 的幂等性主要靠 `daily-checkin` 的 `code=10001` 兜底；路径 A 则直接用可靠的 `checkin-activity-status`。

兼容旧版应用名 `CodeBuddy`（仅旧版 `state.vscdb` 分支需要，macOS 需设环境变量 `WB_CHECKIN_APP_NAME=CodeBuddy`）。

## 文件结构

```
workbuddy-checkin/
├── SKILL.md
├── README.md                   # 仓库首页简介（发布用）
├── CHANGELOG.md
├── LICENSE                     # MIT
├── .gitignore                  # 排除 logs/ 与 .runtime/
├── .gitattributes              # 行尾约定：仓库内一律 LF，.ps1 检出为 CRLF
├── references/
│   └── dependencies.md         # 依赖清单与平台差异
└── scripts/
    ├── jget.js                 # JSON 点号路径取值（sh 版用于解析代理响应）
    ├── decrypt-token.js        # 解密令牌（仅路径 B 回退用）
    ├── checkin.sh              # macOS / Linux / Git Bash
    ├── checkin.ps1             # Windows PowerShell
    ├── setup.sh                # macOS / Linux 环境检查
    └── setup.ps1               # Windows 环境检查
```

`logs/` 目录运行后自动创建，存放签到日志；`.runtime/` 仅在旧版账户安装 Electron 时出现。二者都不入版本库。

## 依赖

### 系统依赖

| 依赖 | 用途 | 安装方式 |
|------|------|----------|
| WorkBuddy 桌面端（已登录，**且正在运行**） | 路径 A：提供本地服务代理，代发请求（零凭据） | 官网下载，必须登录过至少一次 |
| curl（macOS/Linux 自带）/ curl.exe | 调用代理 / 签到 API | Windows 10 1803+ 自带 |
| Node.js（推荐 20+，**仅路径 B 需要**） | 读取本地登录态、解析 JSON | nodejs.org 下载，或系统包管理器 |
| PowerShell 5.1+（仅 Windows） | 旧版库路径用 `ProtectedData.Unprotect` 解封 OS-Crypt 主密钥；sh 版端口自探测 | 系统自带 |
| Electron 运行时（≥ 30，推荐 37） | **仅**路径 A、Node 明文路径都失败时的最后回退 | 非必需，运行 `scripts/setup.sh` / `setup.ps1` |

> **路径 A 是零依赖路径**：只要 WorkBuddy 桌面端在运行，脚本由 App 代发请求，不需要 Node.js、不需要 Electron、
> 也不读取任何登录态文件。Node / Electron 仅在路径 A 不可用（如桌面端未运行）时才派上用场。

### 开箱即用 vs 需安装

- **开箱即用（推荐路径 A）**：WorkBuddy 桌面端在运行并已登录 → 直接运行签到脚本，**零运行时依赖**（只用到系统自带 curl）。
- **桌面端没在运行时**：才需要路径 B —— 已装 WorkBuddy 桌面端并登录 + 系统已有 Node.js → 直接运行脚本。
- **需安装 Node.js**：提示「未找到 Node」时，到 nodejs.org 安装，或用 `WB_CHECKIN_NODE=<path>` 指定。
- **旧版账户需 Electron**：使用旧版 WorkBuddy/CodeBuddy（`state.vscdb`）且提示「未找到 Electron」时，执行：

  ```bash
  # macOS / Linux
  bash scripts/setup.sh
  # Windows（PowerShell）
  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
  ```

### 可选 / 回退依赖

| 依赖 | 缺失时行为 |
|------|------------|
| Electron 运行时 | 仅旧版 `state.vscdb` 账户需要；v5.3.8+ 新版明文路径不需要 |
| Node.js 内置 `node:sqlite`（Electron 37 / Node 22+ 自带） | 旧版分支自动回退到 `python3` 读取 sqlite |
| `python3` | sh 版 JSON 解析降级为 `unknown`，签到请求仍会执行 |
| `npm`（仅旧版 setup 首次安装 Electron 用） | 手动放置 Electron 后用 `WB_CHECKIN_ELECTRON=<path>`（sh）/ `-ElectronPath <path>`（ps1）指定 |

完整依赖说明见 `references/dependencies.md`。

## 快速开始

macOS / Linux：
```bash
bash scripts/setup.sh     # 环境检查：优先验证路径 A（零凭据），不可用才回退检查 Node/Electron
bash scripts/checkin.sh   # 立即签到一次（验证）
```

Windows（PowerShell）：
```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
powershell -ExecutionPolicy Bypass -File scripts\checkin.ps1
```

前提（路径 A）：本机已安装、已**登录**、且**正在运行** WorkBuddy 桌面端。
若桌面端没在运行，脚本会自动回退路径 B，那时才需要已登录过的桌面端 + Node.js。

## 设置定时任务

电脑非全天开机时，建议配置多个时间点补签（脚本幂等，重复运行无副作用）。推荐 `09:00 / 12:00 / 15:00 / 18:00 / 21:00` 各尝试一次，只要电脑在任一时间点开机就能签上。

> **先确保桌面端会自启**（否则路径 A 用不上，见文首「前置条件」）。三种做法任选：
> - **Windows**：把 WorkBuddy 加进启动项。安装时通常已自动加好，可用
>   `reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"` 确认。
> - **macOS**：系统设置 → 通用 → 登录项，加入 WorkBuddy；或在下面的 launchd 任务里
>   先执行 `open -a WorkBuddy` 再跑脚本（中间留 15 秒）。
> - **通用兜底**：定时脚本里先尝试启动应用，`sleep 15` 后重试一次签到。
>
> 若桌面端确实无法常驻，请把定时任务安排在你**通常开机的时段**，并接受「没开机就没签到」。

### macOS / Linux（crontab）
```bash
crontab -e
0 9,12,15,18,21 * * * /path/to/scripts/checkin.sh >> /path/to/logs/checkin.log 2>&1
```

### Windows（任务计划程序）
```powershell
schtasks /Create /TN WorkBuddyDailyCheckin /TR "powershell -ExecutionPolicy Bypass -File C:\path\checkin.ps1" /SC DAILY /ST 09:00 /F
schtasks /Create /TN WorkBuddyDailyCheckin2 /TR "powershell -ExecutionPolicy Bypass -File C:\path\checkin.ps1" /SC DAILY /ST 12:00 /F
# （schtasks 单任务只支持一个 /ST，多时间点需建多个任务）
```

### macOS launchd（长期后台）

创建 `~/Library/LaunchAgents/com.user.workbuddy-checkin.plist`，`StartCalendarInterval` 用数组配置多时间点：
```xml
<key>StartCalendarInterval</key>
<array>
  <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>15</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>18</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>21</integer><key>Minute</key><integer>0</integer></dict>
</array>
```
然后 `launchctl load ~/Library/LaunchAgents/com.user.workbuddy-checkin.plist`。

### 在 WorkBuddy 内（Agent 自动化）

WorkBuddy 环境下可调用自动化任务工具（`automation_update`，recurring 类型），RRULE 多值 `BYHOUR` 实测生效：
```jsonc
{
  "name": "WorkBuddy 每日积分签到",
  "scheduleType": "recurring",
  "rrule": "FREQ=DAILY;BYHOUR=9,12,15,18,21;BYMINUTE=0;BYSECOND=0",
  "cwds": ["<用户工作目录>"],
  "status": "ACTIVE",
  "prompt": "运行 Bash 脚本 scripts/checkin.sh（Windows 用 checkin.ps1）。该脚本幂等：今日已签到会直接跳过。读取输出并汇报：签到成功领取多少积分 / 今日已签到 / 令牌失效需打开 WorkBuddy 刷新。"
}
```
> 注意：`update` 已有任务时必须显式传 `rrule`，否则可能被重置；`cwds` 不能用 Claw 工作区。

## 平台说明

**路径 A 与平台无关**：只要有 curl + 运行中的桌面端即可，macOS / Windows / Linux 行为一致。
下表列出的是**路径 B 回退时**的登录态形态（三者均自动探测，无需手工选择）。

| 平台 | 脚本 | 新版登录态（信封/明文，主路径） | 旧版 state.vscdb（回退，纯 Node 可解） |
|---|---|---|---|
| macOS | `checkin.sh` | `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` | `~/Library/Application Support/WorkBuddy/User/globalStorage/state.vscdb` |
| Windows | `checkin.ps1`（或 Git Bash 跑 `checkin.sh`） | `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info`（旧路径 `%APPDATA%` 亦探测） | `%APPDATA%\WorkBuddy\User\globalStorage\state.vscdb`（主密钥在 `%APPDATA%\WorkBuddy\Local State`） |
| Linux | `checkin.sh` | `~/.config/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` | `~/.config/WorkBuddy/User/globalStorage/state.vscdb` |

Windows PowerShell 执行策略用 `-ExecutionPolicy Bypass`；需 `curl.exe`（Win10 1803+ 自带）。
旧版 `state.vscdb` 分支在 Linux 需桌面会话 + 系统 keyring（GNOME Keyring / KWallet）；新版明文分支无此要求。

## 环境变量

| 变量 | 作用 |
|------|------|
| `WB_CHECKIN_NODE=<path>` | 指定 Node 二进制路径（v5.3.8+ 主路径用，sh/ps1 通用） |
| `WB_CHECKIN_ELECTRON=<path>` | 指定 Electron 二进制路径（仅旧版 state.vscdb 回退用，sh 版） |
| `-ElectronPath <path>` | 同上（ps1 版参数） |
| `WB_CHECKIN_APP_NAME=CodeBuddy` | 兼容旧版应用名（仅旧版 state.vscdb 分支的 macOS 钥匙串密钥） |
| `WB_CHECKIN_JITTER=<秒>` | 启动前随机等待 0~N 秒，避免整点风暴 |
| `WB_CHECKIN_SERVICE_ID=<id>` | 路径 A 使用的服务标识，默认 `auth`（一般无需修改） |
| `CODEBUDDY_SERVICE_PROXY_URL` | **由 WorkBuddy 桌面端自动注入**，路径 A 的代理入口；脚本只在读不到时才自行探测端口 |

## 排错

- **连续多天报 401（令牌已过期）**：这是 v1.0.x 的已知死结——登录态改成 at-rest 信封加密后，
  解封密钥只存在于运行中的 App 进程内存，外部脚本拿不到，`decrypt-token.js` 只能退回 2026-06-04 的旧库。
  **v1.1.0 已用「路径 A：本地服务代理」根治**（不再需要令牌）。若仍见 401，说明路径 A 也没跑通，
  请检查桌面端是否在运行（`Get-Process WorkBuddy`）、代理端口是否可达，或临时设
  `WB_CHECKIN_SERVICE_ID=auth` 重试。
- **路径 A 报「未完成签到，回退令牌路径重试」**：说明代理调用没拿到 `code=0`。
  先用 `curl -s -X POST "$CODEBUDDY_SERVICE_PROXY_URL/..%2F..%2Fbilling%2Fmeter%2Fcheckin-activity-status" -H "X-Service-Id: auth" -H "Content-Type: application/json" -d '{}'` 自测。
- **脚本卡十几秒才出结果（v1.1.0 之前）**：旧版用 `Get-NetTCPConnection -OwningProcess <pid>` 逐进程枚举端口，
  实测单次 7.5s，且**即使 `CODEBUDDY_SERVICE_PROXY_URL` 已给出地址也会白跑一遍**（冷启动 ~11s）。
  v1.1.0 已改为「快慢两轮 + netstat 取端口」：环境变量存在时不再枚举端口，冷启动降到 ~1.8s。
- **精简 PATH（cron / 计划任务 / Git Bash）下探测不到端口**：`netstat` 用相对命令名时，
  Git Bash 会把 `PATH` 翻译成 Git 自己的目录（System32 丢失），裸 `netstat` 直接解析不到。
  v1.1.0 已改为绝对路径 `%SystemRoot%\System32\netstat.exe`，该场景实测通过。
- **企业环境设了 `http_proxy` / `https_proxy`，签到整体失败**（v1.1.0 之前的真实缺陷）：
  curl 会把发往 `127.0.0.1` 的回环请求也丢给代理，实测整轮 **42s 后 exit 1**。
  v1.1.1 起所有回环请求强制 `--noproxy '*'`，同一场景 **1.9s 成功**。
  注意：回退路径发往 `copilot.tencent.com` 的请求**不**绕过代理（企业网络可能正需要它）。
- **代理地址失效（桌面端重启换了端口）**：v1.1.1 起 fast 轮失败后会做端口枚举，
  且不会重复试已经失败的地址；同时 `--connect-timeout 5` 兜住端口静默丢包的最坏情况。
- **收到 401 且脚本提示「首选路径没生效」**：说明桌面端当时没在运行，这个 401 是回退路径
  读到的 `state.vscdb` 旧令牌造成的。启动桌面端再跑即可，**不需要**去刷登录态或装任何运行时。
- **签到必须桌面端在运行**：这是设计使然（信封密钥只在 App 进程内存）。见文首「前置条件」。
- **PowerShell 版报「传入的对象无效，应为…」**：PS 5.1 用 OEM 代码页解码 `curl.exe` 的 UTF-8 输出，
  中文乱码会破坏 JSON。v1.1.0 已在脚本内临时切 `[Console]::OutputEncoding` 为 UTF-8 修复。
- **「获取令牌失败（未知原因）」/ 未找到本地登录态**：先确认 WorkBuddy 桌面端已登录并打开过至少一次。检查 Node.js 是否安装（`node -v`），或用 `WB_CHECKIN_NODE` 指定。
- **运行 `setup.sh` / `setup.ps1` 报环境不满足，但签到其实能成功（v1.1.0 之前）**：旧版 setup 只验证「令牌读取链路」，
  而信封加密登录态下该链路必然失败 → 误报 exit 1。v1.1.0 的 setup 已改为**优先探测路径 A**，代理可达即判成功。
- **登录态已是信封加密（`accessToken` 是 `{$wbEncrypted:1, envelope:...}`）**：`~/.workbuddy/keyblob` 的密钥由桌面端 protector 托管，纯 Node 无法解封属**预期行为**；脚本会先尝试路径 A，再回退旧版 `state.vscdb`，无需额外操作。
- **旧版库路径报「无法取得本机 OS-Crypt 主密钥」**：确认 `%APPDATA%\WorkBuddy\Local State` 存在且含 `os_crypt.encrypted_key`，以及 PowerShell 可正常执行（`Add-Type -AssemblyName System.Security`）。
- **当日重跑提示「签到未成功 / code=10001」**：旧版本（< 1.0.2）未把 `code=10001` 识别为「已签到」；1.0.2+ 会正确报告「今日已签到」。
- **macOS 解密报错但已登录（旧版账户）**：旧版迁移应用名仍是 `CodeBuddy`，设 `export WB_CHECKIN_APP_NAME=CodeBuddy` 后重试（仅走 state.vscdb 分支时生效）。
- **Electron 下载慢/失败（旧版账户）**：配置 npm 镜像（见 `references/dependencies.md`）后重跑 setup；或手动放置 Electron 后用环境变量/参数指定。v5.3.8+ 新版账户无需 Electron。
- **Windows 提示不是内部或外部命令**：用 `powershell -ExecutionPolicy Bypass -File …` 运行；确认 `curl.exe` 存在（脚本也会试 `%SYSTEMROOT%\System32\curl.exe`、`/mingw64/bin/curl` 等绝对路径）。
- **沙箱里 `require('electron')` 报错**：Agent 沙箱默认设 `ELECTRON_RUN_AS_NODE=1`，脚本已用 `env -u`（sh）/ `Remove-Item Env:`（ps1）处理；v5.3.8+ 主路径用纯 Node，不受此影响。

## 安全说明

> ✅ **路径 A 完全不接触凭据**：首选路径由桌面端自己附加登录态，脚本只向本机回环地址
> （`127.0.0.1`）发一个声明「要调哪个后端接口」的请求，**既不读取、也不持有、更不会外发任何令牌**。

> ⚠️ **路径 B 的凭据即账号密码**：回退路径解密的 `accessToken` 等同你的 WorkBuddy 账号密码，具有高敏感性。请务必遵守以下红线：

- 令牌仅在内存中使用，通过管道立即被签到请求消费，**不写入任何日志文件、不落盘、不回显到终端、不提交到仓库**。
- `logs/` 仅记录签到结果（积分 / 连续天数 / 成功失败），**绝不含令牌原文**。切勿将日志或脚本输出粘贴分享。
- 路径 A 的请求发往本机回环地址（由桌面端转发）；路径 B 的网络访问仅发往腾讯官方接口 `copilot.tencent.com/billing/meter/*`。均不上传任何第三方。
- 解密成功时脚本会向 stderr 打印一行安全提示（不影响 stdout 的 token 管道），便于你确认凭据正在被使用。
- 请勿用于他人账户、批量注册刷分或任何违反 WorkBuddy 用户协议的用途；使用者自行承担使用风险。

### 为何需要这些能力（上下文说明）

本 skill 自述为"每日签到"，但完整链路需以下能力，均为本机运行、无后端，且对完成签到必不可少：

- **调用本机桌面端的服务代理（路径 A，首选，零凭据）**：`CODEBUDDY_SERVICE_PROXY_URL` 由桌面端注入，
  是官方为子进程提供的服务调用通道。脚本仅向 `127.0.0.1` 发起请求，凭据由桌面端附加，脚本侧不可见。
- **读取本地令牌（路径 B，回退）**：WorkBuddy 桌面端登录后把登录态存于本地——新版为 `workbuddy-desktop.info`
  （当前主流形态已改为 at-rest 信封加密，密钥只在 App 进程内存，纯 Node 无法解封）、v5.3.8 早期为明文 JSON（纯 Node 可读）、
  旧版为 `state.vscdb`（Electron `safeStorage` / 纯 Node + DPAPI 可解）。必须读到 `accessToken` 才能直连官方签到接口。
- **Node.js 运行时（仅路径 B）**：用于读取可直读的登录态并解析 JSON。推荐手动指定已校验的 Node（设 `WB_CHECKIN_NODE`）。
- **Electron 运行时（仅旧版账户）**：只有使用旧版 WorkBuddy/CodeBuddy（`state.vscdb`）时才需要，执行 `safeStorage.decryptString()` 解密令牌（macOS 命中钥匙串、Windows/Linux 走系统 DPAPI/keyring）。推荐手动指定已校验的 Electron（设 `WB_CHECKIN_ELECTRON`），不依赖自动下载。
- **python3 回退（默认关闭）**：仅当旧版分支的 `node:sqlite` 不可用时，设 `WB_CHECKIN_ALLOW_PY_FALLBACK=1` 才会调用外部 `python3` 读取会话库。默认关闭以缩小信任边界。
- **定时任务（crontab / launchd / 任务计划程序）**：用于多时间点幂等补签，脚本本身不写入系统定时，需你显式配置。

### 供应链提示

安装 Electron 默认**不自动下载**（避免静默引入第三方大二进制）。如需自动安装，须显式设置环境变量 `WB_CHECKIN_AUTO_INSTALL_ELECTRON=1` 确认从官方 npm registry 下载 `electron@37`。

## 所需权限

本 skill 运行需以下本地权限，均限定在最小范围：

| 权限 | 范围 | 说明 |
|------|------|------|
| 本地代码执行 | 仅本 skill 的 `checkin.sh/.ps1`、`jget.js`、`decrypt-token.js`、`setup.sh/.ps1` | 用户手动或定时触发，非后台常驻 |
| 本机回环网络 | 仅 `127.0.0.1` 上桌面端自己的服务代理端口（路径 A） | 只发「要调哪个后端接口」的声明，凭据由桌面端附加 |
| 本地文件读取 | 用户目录下的 WorkBuddy 登录态（v5.3.8+ 明文 `workbuddy-desktop.info` / 旧版 `state.vscdb`）；路径 A 命中时**不读取任何登录态文件** | 读取登录态以获取调用官方接口所需的 accessToken |
| 网络访问 | 仅 `copilot.tencent.com` 官方签到接口（路径 B）；路径 A 先经本机代理转发 | 不访问任何其他域名 |
| 环境变量读取 | `WB_CHECKIN_*`（Node/Electron 路径、应用名、错峰、回退开关、服务标识）、`CODEBUDDY_SERVICE_PROXY_URL` | 均为本机用户显式配置或桌面端注入 |
| 进程查询（可选） | 仅当 `CODEBUDDY_SERVICE_PROXY_URL` 缺失时，只读查询本机 WorkBuddy 进程 PID 与 `netstat` 监听端口 | 用于自愈式端口探测；环境变量存在时完全不触发 |
| 定时任务 | 由用户显式配置 crontab / launchd / 任务计划程序 | skill 不自动写入系统定时 |
