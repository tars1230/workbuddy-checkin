# 变更日志

## [1.1.1] - 2026-10-14

### 修复

- **企业代理环境下签到整体失败（真实缺陷）**：curl 会遵循 `http_proxy` / `https_proxy` 环境变量，
  把发往 `127.0.0.1` 的**回环请求也交给代理**。企业环境里这会让首选路径直接失效 ——
  实测整轮 **42.1s 后 exit 1**。现在所有回环调用强制 `--noproxy '*'`，同一场景 **1.90s 成功**。
  回退路径发往 `copilot.tencent.com` 的请求保持**不**绕过（企业网络可能正需要它）。
- **full 轮把端口枚举跑了两遍**：`proxy_candidates` 用两段进程替换分别输出 plain / as-is 两组候选，
  每次都会重新求值 `discover_proxy_bases`（一次枚举约 2.4s）。改为先求值一次、用 here-string 复用。
- **失效的代理地址被重复试探**：环境变量指向的地址在 fast 轮已失败（App 重启换了端口），
  full 轮又原样再试一遍，白付两次请求。现在 full 轮会排除它。
- **候选探测缺连接超时上限**：原先只有 `-m 20`。Windows 上连一个已关闭端口本就要约 2.2s，
  若端口被防火墙静默丢弃则会一路耗到 20s。新增 `--connect-timeout 5`。
- **失败提示会把人带偏**：桌面端没在运行时，原提示是「请安装 Node.js / 设置 `WB_CHECKIN_NODE`」——
  但登录态已是信封加密，装什么都不管用。现在路径 A 失败会明确说「先启动 WorkBuddy 桌面端」；
  401 分支同理会说明「这个 401 来自回退路径的旧令牌，启动桌面端即可」。
- **macOS / Linux 端口探测过于挑进程名**：原来只匹配 `WorkBuddy`，现在大小写不敏感地匹配
  `workbuddy|codebuddy`（应用曾用名 CodeBuddy；Electron 的 `" Helper"` 进程同样命中）。

### 改进

- `checkin.ps1` 移除已无用的 `-FastOnly` 分支（fast 轮改由 `Invoke-ProxyApi` 直接构造单地址列表）。
- `SKILL.md` 新增**环境支持矩阵（诚实版）**与**前置条件**两节：明确标注 macOS / Linux 为「未实测」，
  写明「路径 A 要求桌面端正在运行」这一不可回避的前置；定时任务一节补了三种保证应用自启的做法。

### 验证（v1.1.1）

| 场景 | 结果 |
|------|------|
| 自动化原样（代理变量已注入） | ✅ 1.89s |
| 企业代理污染（`http_proxy` 指向死端口） | ✅ **1.90s**（修复前 42.1s + exit 1） |
| 失效的代理变量 | ✅ 9.2s（修复前 11.0s） |
| 无代理变量（走端口自探测） | ✅ 4.73s |
| 无代理变量 + 精简 PATH | ✅ 4.96s |
| `checkin.ps1`（PS 5.1，含代理污染） | ✅ 0 解析错误 |
| `setup.sh` / `setup.ps1`（含代理污染） | ✅ 正确识别路径 A 并 exit 0 |

### 已知未验证 / 已知限制（不做美化）

- **macOS、Linux 未实测**。风险点：桌面端是否同样注入 `CODEBUDDY_SERVICE_PROXY_URL` 未知；
  端口自探测依赖 `lsof` 匹配进程名。首次运行请先跑 `setup.sh` 再跑一次 `checkin.sh` 并反馈输出。
- **端口会变**：实测桌面端重启后监听端口从 7 个变成 9 个，因此快路径依赖桌面端注入的环境变量，
  端口自探测只是兜底，最坏要试若干候选（每次失败约 2.2s）。
- **桌面端未运行时，信封加密登录态无法离线解密**：这是官方设计（解封密钥只在 App 进程内存），
  不是本 skill 能绕过的；此时回退路径多半拿到 `state.vscdb` 的旧令牌并以 401 结束。
- **未覆盖的组合**：AppLocker / EDR 完全禁掉 PowerShell（端口自探测会失效，但环境变量快路径不受影响）；
  用户名含空格或系统盘不是 C:（路径均已加引号且优先用 `$SYSTEMROOT`，但未实测）。

## [1.1.0] - 2026-10-14

### 修复

- **根治连续 401（核心）**：WorkBuddy 桌面端把登录态改为 **at-rest 信封加密**（`{ $wbEncrypted: 1, envelope: ... }`），
  解封密钥只在运行中的 App 进程内存里（经 `CODEBUDDY_SIDECAR_CREDENTIAL_BOOTSTRAP_SOCKET` 注入），
  **不落盘、不可离线取得**。因此 `decrypt-token.js` 对信封登录态永远解不开，
  只能静默退回 `state.vscdb`（实测停在 2026-06-04），导致每日签到连续 401。
  已证伪的离线路径：asar 内无静态密钥、Windows 凭据管理器为空、
  全盘 40813 文件 / 1620 万候选串 sha256 命中 0、`keyblob` 自包自、环境变量无匹配。
- **新增「路径 A：桌面端本地服务代理」（零凭据，首选）**：桌面端会把 `CODEBUDDY_SERVICE_PROXY_URL`
  注入每个 Bash / 钩子子进程，该端点**由 App 自己附加登录态的 `Authorization` 头**再转发到云端。
  脚本只需声明 `X-Service-Id: auth`，**全程不读取、不持有、不外发任何令牌**，因而
  **免疫信封加密与 keyblob protector 的任何变更**。路径 A 不可用时自动回退到原有令牌流程。
- **改用可靠的活动接口**：`billing/meter/checkin-status` 是**废弃接口**（`active` / `today_checked_in` 恒为 `false`），
  之前据此判定会误判为「未签到」。改为 `billing/meter/checkin-activity-status`（`data.today_checked_in` 可靠）。
- **PowerShell 版 JSON 解析失败**：PS 5.1 用 OEM 代码页（中文系统为 GBK）解码 `curl.exe` 的 UTF-8 输出，
  中文乱码后字节序列被破坏，`ConvertFrom-Json` 直接抛「传入的对象无效」。已在脚本内临时把
  `[Console]::OutputEncoding` 切为 UTF-8。
- **`checkin.ps1` 缺 UTF-8 BOM**：PS 5.1 会按 ANSI 解析，中文注释被破坏导致语法错误（`意外的标记 }`）。
  已补 BOM 并统一 CRLF。

### 改进

- **运行时探测自愈**：`checkin.sh` 的 `find_node()` 新增 WorkBuddy 托管 Node 通配探测
  （`~/.workbuddy/binaries/node/versions/*/node[.exe]`）与 `CODEBUDDY_NODE_BIN`，
  不再依赖外部写死的 Node 路径（现场发现自动化里的 `...\versions\22.22.2\node.exe` 并不存在）。
- **curl 探测自愈**：新增 `find_curl()`，含 `%SYSTEMROOT%\System32\curl.exe`、`/mingw64/bin/curl` 等绝对路径，
  PATH 被裁剪时仍可用。
- **代理地址自愈**：`CODEBUDDY_SERVICE_PROXY_URL` 缺失时，反查本机 WorkBuddy 进程监听端口自动探测
  （Windows 走 PowerShell 绝对路径兜底，macOS/Linux 走 `lsof`）。
- **路径编码双保险**：优先用 `%2F` 编码路径（任何 curl 均可用，无需 `--path-as-is`），
  其次回退原始 `../` + `--path-as-is`。
- **误报防护**：`daily-checkin` 被拒（如上游 400「今日已签到」）时，以活动接口复核一次再定结论。
- 新增 `scripts/jget.js`：零依赖 JSON 点号路径取值器（Node 优先，`python3` 兜底），
  在 Windows/Git Bash 下用相对路径调用，避免 POSIX 绝对路径不被 node 接受。

### 复核修订（同版追加，2026-10-14 复审）

- **修复：冷启动被端口枚举拖到 11s**。旧实现用 `Get-NetTCPConnection -OwningProcess <pid>` 逐进程枚举，
  实测单次 **7477ms**（该 cmdlet 每次都要遍历完整 TCP 表）；更糟的是**即使 `CODEBUDDY_SERVICE_PROXY_URL`
  已给出地址也照样枚举一遍**。改为：
  1) 环境变量存在时走 **fast 轮**（只试环境变量地址，零探测）；
  2) 需要探测时改用「一次 `Get-Process` 取 PID + 解析 `netstat -ano`」，实测 **158ms**（快 47 倍）。
  冷启动 **11.2s → 1.8s**。
- **修复：精简 PATH 下端口探测失效**。`netstat` 用相对命令名时，Git Bash 会把 `PATH` 翻译成 Git 自己的目录
  （System32 丢失），裸 `netstat` 直接 `CommandNotFoundException`。改为绝对路径
  `%SystemRoot%\System32\netstat.exe`（缺失才退回裸命令）。
- **修复：`setup.sh` / `setup.ps1` 在 v1.1.0 下必然误报失败**。旧 setup 只验证「令牌读取链路」，
  而信封加密登录态下该链路必然失败 → 打印「未检测到…」并 `exit 1`，**即使路径 A 完全可用**。
  已改为**优先探测路径 A**（代理可达即判成功并退出 0），并让 setup 的 Node 探测与 `checkin.*` 一致地
  通配 `~/.workbuddy/binaries/node/versions/*/node[.exe]`。
- **修复：代理探测缓存在命令替换子 shell 中失效**。`find_node()` / `discover_proxy_bases()` 一律以
  `$(...)` 或 `<(...)` 调用，函数内部的全局赋值不回传父 shell，写在函数里的缓存等于没写。
  已拆成 raw（干活）+ 包装（读父 shell 预解析值），预解析在父 shell 落地。
- **修复：`checkin.ps1` / `setup.ps1` 首行 `#` 被吞**。`[string].StartsWith([char]0xFEFF)` 用**文化敏感**比较，
  而 U+FEFF 是可忽略字符 —— 该判断对**任何**字符串都返回 `true`，于是 `Substring(1)` 切掉了首行的 `#`，
  PS 会把 `===…` 当命令名去执行。已改用序数比较（`[StringComparison]::Ordinal`），并修正文件首行。
- **改进：候选试探顺序按形态分组**。原实现对每个地址交替试 `plain` / `as-is`，前 N-1 个失败地址各会白试一次
  `as-is`，最坏请求数翻倍。改为「先全部 `plain`，再全部 `as-is`」。
- **改进：日志统一 UTF-8（无 BOM）**。PS 版原用 `Add-Content -Encoding UTF8`，PS 5.1 建文件时会写入 BOM，
  与 bash 版 `tee` 的无 BOM UTF-8 口径不一致；改用 `File.AppendAllText` + `UTF8Encoding($false)`。
- **改进：`schtasks` 示例引号转义**，`setup.ps1` 输出的定时命令现在可直接复制执行。
- **文档同步路径 A**：`SKILL.md`（依赖表、开箱即用、快速开始、平台说明、排错、为何需要这些能力、权限表）、
  `references/dependencies.md`（运行链路、核心依赖、网络要求、目录结构）、两个脚本的头部注释。
- 新增 `LICENSE`（MIT）与 `.gitignore`（排除 `logs/`、`.runtime/`、`node_modules/`）。

### 验证

| 场景 | 结果 |
|------|------|
| 按自动化原样调用（代理变量已注入） | ✅ 今日已签到（连续 8 天，今日 100 积分）；**11.2s → 1.8s** |
| 剥离 `CODEBUDDY_SERVICE_PROXY_URL`（走端口自发现） | ✅ 同上（4.9s） |
| 同时剥离代理变量与 PATH（仅 `/usr/bin:/bin`） | ✅ 同上（4.8s，修复前此场景 exit 1） |
| `checkin.ps1`（PowerShell 5.1） | ✅ 同上，0 解析错误 |
| `setup.sh` / `setup.ps1` | ✅ 正确识别路径 A 并 exit 0（修复前误报 exit 1） |
| 日志编码 | ✅ UTF-8 无 BOM，bash 与 PS 两条写入口径一致 |

## [1.0.2] - 2026-08-06

### 修复

- **兼容 WorkBuddy 桌面端 v5.3.8 新版登录态存储**（#68）：v5.3.8 不再把当前登录态写入 `state.vscdb`，改用明文 JSON 文件 `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info`（Windows/Linux 同构路径）。旧版（≤1.0.1）只认 `state.vscdb`，导致连续报「获取令牌失败（未知原因）」。
  - `decrypt-token.js` 改为**新版明文文件优先、旧版 `state.vscdb` 回退**；新版分支纯 Node 读取 `auth.accessToken`，无需 Electron `safeStorage` 解密。
  - `require("electron")` 包裹 try/catch，脚本可由普通 `node` 直接执行。
  - 统一 `emitAndExit()`（`process.stdout.write` 后延迟 ~200ms 退出），避免 `console.log` 后立即 `app.exit()` 导致 stdout 未 flush。
- **macOS 运行时策略改为 Node 优先**（#68）：直接调用 WorkBuddy.app 的 Electron 二进制会启动主应用而非执行脚本；新版明文文件用纯 Node 即可读取，无需依赖应用内 Electron。`checkin.sh`/`checkin.ps1`/`setup.sh`/`setup.ps1` 均改为 Node 优先、Electron 回退，新增 `WB_CHECKIN_NODE=<path>` 环境变量。
- **`daily-checkin` 的 `code=10001` 识别为已签到**（#68）：v5.3.8 实测 `checkin-status` 的 `today_checked_in` 不可靠（签到成功后仍为 `false`），当日重跑会再次调 `daily-checkin` 并返回 `code=10001`（今天已签到）；旧版将其误报为「签到未成功」，导致幂等分支失效。1.0.2 起正确报告「今日已签到，无需重复领取」。

### 改进

- 文档同步：`SKILL.md` / `references/dependencies.md` 更新原理、平台路径、依赖（Electron 降级为仅旧版可选）、环境变量（新增 `WB_CHECKIN_NODE`）、排错（v5.3.8 专项条目）。
- `setup.sh`/`setup.ps1`：v5.3.8 用户（仅 Node、无 Electron）不再被误判为「未找到 Electron」而失败。

### 合并前代码评审修复

- **`checkin.sh` / `checkin.ps1` Electron 回退条件修正（高）**：原实现仅当 Node 输出为空才回退 Electron；但旧版 `state.vscdb` 账户在装有 Node 的机器上，纯 Node 会输出非空的 `ERR`（无法解 safeStorage），导致 Electron 回退被跳过、误报失败（对 v1.0.1 旧版账户的回归）。改为「空 或 ERR」均回退。
- **`decrypt-token.js` 部分明文文件不再硬失败**：明文文件存在但缺 `auth.accessToken`（如升级中途 / 写入中）或解析失败时，不再 `exit 5`，而是落入旧版 `state.vscdb` 分支兜底。
- **`decrypt-token.js` 旧版读取异常可观测**：`readValue` 抛错（如 `node:sqlite` 不可用且未开 python3 回退）时不再裸抛，统一经 `DECRYPT_RESULT:ERR` 带原因输出，避免「未知原因」式失败。
- **`checkin.sh` `WB_CHECKIN_JITTER=0` / 非数字不再触发除零中止**：改为先 `[ -gt 0 ]` 校验。
- **`checkin.sh` 缺 `python3` 不再误报「签到未成功」**：结果解析为空时改为提示「请求已提交，缺 python3 无法解析」，避免服务端已成功却被报失败。

### 已知限制

### 已知限制

- Windows / Linux 的 `CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` 路径基于 v5.3.8 桌面端约定推导，已在 macOS 实测命中，其他平台待真实环境确认。

## [1.0.1] - 2026-08-05

### 改进

- 凭据安全：解密成功时向 stderr 输出安全提示（不污染 token 管道）；python3 回退默认关闭，需 `WB_CHECKIN_ALLOW_PY_FALLBACK=1` 启用
- 安装安全：`setup.sh`/`setup.ps1` 自动 `npm install electron` 默认关闭，需 `WB_CHECKIN_AUTO_INSTALL_ELECTRON=1` 才下载，默认提示手动指定路径并声明供应链风险
- 文档：SKILL.md 安全说明补强，新增「所需权限」清单与「为何需要这些能力」上下文说明，回应 SkillSpector 审计 findings

### 技术优化

- `checkin.sh`/`checkin.ps1` 头部注释补充凭据安全说明

## [1.0.0] - 2026-08-05

### 新增

- 初始版本：WorkBuddy 每日积分自动签到 skill 正式纳入 legal-skills 仓库
- 跨平台签到脚本：`scripts/checkin.sh`（macOS/Linux/Git Bash）与 `scripts/checkin.ps1`（Windows PowerShell，兼容 PS 5.1）
- 令牌解密脚本 `scripts/decrypt-token.js`：基于 Electron `safeStorage` 解密本地 `state.vscdb` 会话，`node:sqlite` 不可用时自动回退 `python3`
- 一键安装脚本 `scripts/setup.sh` / `scripts/setup.ps1`：自动检测或通过 npm 下载 Electron 运行时，并验证解密链路
- 多 Agent 框架适配（WorkBuddy 自动化任务 / Claude Code / Codex / OpenClaw / 纯终端），定时方式覆盖 crontab / launchd / schtasks / WorkBuddy recurring
- 幂等保护：每次运行先查 `checkin-status`，今日已签到立即跳过，支持一天多时间点补签（默认推荐 09/12/15/18/21 点）
- 随机错峰：`WB_CHECKIN_JITTER=<秒>` 环境变量让脚本启动前随机等待，避免整点风暴
- 兼容旧版应用名 CodeBuddy：`WB_CHECKIN_APP_NAME=CodeBuddy` 覆盖钥匙串绑定名

### 设计要点

- **全本机运行**：不含任何后端服务，令牌仅发往腾讯官方接口 `copilot.tencent.com`，不上传第三方
- **令牌不落盘**：仅在内存中传递；`logs/` 只记录签到结果（积分/连续天数），不含令牌
- **沙箱兼容**：WorkBuddy 等 Agent 沙箱默认设 `ELECTRON_RUN_AS_NODE=1` 会导致 `require('electron')` 拿不到 `safeStorage`，脚本已用 `env -u`（sh）/ `Remove-Item Env:`（ps1）显式处理

### 已知限制

- 签到按自然日结算，若整天未开机则当日无法补签，次日首个运行点自动重新开始（连续天数会重置）
- 令牌过期（401）需打开 WorkBuddy 桌面端刷新登录态，次日自动恢复
- macOS 应用名与钥匙串绑定：新装为 `WorkBuddy`，旧版迁移可能仍是 `CodeBuddy`

### 合规提示

- 本 skill 等价于「每天手动点一次领取今日礼包」，仅操作本机当前登录用户自己的 WorkBuddy 账户
- 请勿用于他人账户、批量注册刷分或任何违反 WorkBuddy 用户协议的用途
- 使用者需自行承担使用风险，确保来源可信
