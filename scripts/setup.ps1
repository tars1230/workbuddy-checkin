# ============================================================
# WorkBuddy 每日签到 - 环境安装脚本（Windows PowerShell 版）  v1.1.1
#
# 检查顺序（与 checkin.ps1 一致）：
#   路径 A（首选）：本地服务代理可用？→ 零凭据，无需 Node / Electron，直接完成
#   路径 B（回退）：Node 读取登录态 → 旧版 state.vscdb 需 Electron
#
# v5.3.8+ 新版登录态已改为 at-rest 信封加密，解封密钥只在 App 进程内存，
# 纯 Node / Electron 均无法离线解密（这是 v1.0.x 长期 401 的根因）。
# 因此路径 A 是推荐路径；路径 B 仅在没有运行中的桌面端时才需要。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -ElectronPath C:\path\to\electron.exe
# ============================================================
param(
    [string]$ElectronPath = ""
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$RuntimeDir = Join-Path $SkillRoot ".runtime"
$DefaultElectron = Join-Path $RuntimeDir "electron\electron.exe"
$DecryptJs = Join-Path $ScriptDir "decrypt-token.js"
$ProxySvcId = if ($env:WB_CHECKIN_SERVICE_ID) { $env:WB_CHECKIN_SERVICE_ID } else { "auth" }

# ⚠️ PS 5.1 用 OEM 代码页（中文系统为 GBK）解码 curl.exe 的 UTF-8 输出会破坏中文字节，
# 故临时把解码切到 UTF-8，保证响应内容可被安全匹配。
$__prevConsoleEncoding = $null
try {
    $__prevConsoleEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch {}

Write-Output "== WorkBuddy 每日签到 · 环境检查 =="

# ---------- 探测 Node（路径 B 需要：读登录态 + 解析 JSON） ----------
function Find-Node {
    if ($env:WB_CHECKIN_NODE -and (Test-Path $env:WB_CHECKIN_NODE)) { return $env:WB_CHECKIN_NODE }
    $cands = @(
        (Get-Command node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        $env:CODEBUDDY_NODE_BIN,
        (Join-Path $env:ProgramFiles "nodejs\node.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "nodejs\node.exe")
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    # WorkBuddy 托管 Node（版本目录名随升级变化，故用通配而非写死）
    foreach ($m in @(Get-ChildItem -Path (Join-Path $HOME ".workbuddy\binaries\node\versions") -Filter "node.exe" -Recurse -ErrorAction SilentlyContinue)) {
        if ($m -and (Test-Path $m.FullName)) { return $m.FullName }
    }
    return ""
}

# ---------- 探测已存在的 Electron（仅旧版 state.vscdb 回退需要） ----------
function Find-Electron {
    if ($ElectronPath -and (Test-Path $ElectronPath)) { return $ElectronPath }
    if ($env:WB_CHECKIN_ELECTRON -and (Test-Path $env:WB_CHECKIN_ELECTRON)) { return $env:WB_CHECKIN_ELECTRON }
    $cands = @(
        (Join-Path $HOME ".workbuddy\tools\electron\electron.exe"),
        $DefaultElectron,
        (Join-Path $HOME ".workbuddy\skills\workbuddy-checkin\.runtime\electron\electron.exe")
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return ""
}

# ---------- 列出候选代理地址：环境变量优先，缺失时反查 WorkBuddy 监听端口 ----------
# 性能：用「一次 Get-Process 取 PID + 解析 netstat -ano（绝对路径）」，
# 而非 `Get-NetTCPConnection -OwningProcess`（后者实测 7.5s，前者约 0.16s）。
function Get-ProxyBases {
    $bases = @()
    $ports = @()
    try {
        $pids = @(Get-Process -Name WorkBuddy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        if ($pids.Count -gt 0) {
            $ns = Join-Path $env:SystemRoot "System32\netstat.exe"
            if (-not (Test-Path $ns)) { $ns = "netstat" }
            $ports = & $ns -ano 2>$null | Select-String "LISTENING" | ForEach-Object {
                $f = -split $_.Line
                if ($f.Count -ge 5 -and $pids -contains [int]$f[4]) { ($f[1] -split ":")[-1] }
            } | Select-Object -Unique
        }
    } catch {}
    if ($env:CODEBUDDY_SERVICE_PROXY_URL) {
        $bases += $env:CODEBUDDY_SERVICE_PROXY_URL.TrimEnd('/')
    }
    foreach ($p in @($ports)) {
        if ("$p" -match '^\d+$') { $bases += "http://127.0.0.1:$p/internal/hooks/services/invoke" }
    }
    return @($bases | Select-Object -Unique)
}

# ---------- 路径 A 探测：本地服务代理是否可用（零凭据，不接触任何令牌） ----------
# 回环请求加 --noproxy "*"：企业环境设了 http_proxy/https_proxy 时会误把 127.0.0.1 的请求丢给代理
function Test-ProxyAvailable {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { return $false }
    $enc = "billing/meter/checkin-activity-status" -replace '/', '%2F'
    # 先只用环境变量地址（廉价），失败再端口枚举
    $groups = @()
    if ($env:CODEBUDDY_SERVICE_PROXY_URL) { $groups += ,@($env:CODEBUDDY_SERVICE_PROXY_URL.TrimEnd('/')) }
    $groups += ,@(Get-ProxyBases)
    foreach ($g in $groups) {
        foreach ($pass in @("plain", "asis")) {
            foreach ($base in @($g)) {
                if (-not $base) { continue }
                if ($pass -eq "plain") { $u = "$base/..%2F..%2F$enc" } else { $u = "$base/../../billing/meter/checkin-activity-status" }
                $resp = ""
                try {
                    $resp = & curl.exe -s -m 20 --connect-timeout 5 --noproxy "*" -X POST $u `
                        -H "X-Service-Id: $ProxySvcId" `
                        -H "Content-Type: application/json" `
                        -H "Accept: application/json" -d '{}' 2>$null
                } catch { $resp = "" }
                if ($resp -and ($resp -match '"code"\s*:\s*0')) { return $true }
            }
        }
    }
    return $false
}

function Show-Done {
    Write-Output ""
    Write-Output "== 完成 =="
    $CheckinPs1 = Join-Path $ScriptDir "checkin.ps1"
    Write-Output "运行签到：  powershell -ExecutionPolicy Bypass -File `"$CheckinPs1`""
    Write-Output "设置定时（每天 09:00，示例；内层引号已按 schtasks 要求转义，可直接复制）："
    Write-Output "  schtasks /Create /TN WorkBuddyDailyCheckin /TR `"powershell -ExecutionPolicy Bypass -File \`"$CheckinPs1\`"`" /SC DAILY /ST 09:00 /F"
}

# ============================================================
# 路径 A（首选，v1.1.0+）：桌面端本地服务代理 —— 零凭据
# ============================================================
if (Test-ProxyAvailable) {
    Write-Output "✅ 检测到 WorkBuddy 本地服务代理，签到链路可用（路径 A）。"
    Write-Output "   该路径由桌面端代为出网，全程不读取、不持有任何令牌，"
    Write-Output "   也不需要 Node.js / Electron，且免疫登录态加密格式变更。"
    Write-Output "   ⚠️ 前提：运行时 WorkBuddy 桌面端需处于运行状态。"
    Show-Done
    try { if ($__prevConsoleEncoding) { [Console]::OutputEncoding = $__prevConsoleEncoding } } catch {}
    exit 0
}

Write-Output "（未检测到可用的本地服务代理：桌面端可能未在运行。继续尝试回退路径 B。）"
Write-Output ""

# ============================================================
# 路径 B：读取本地登录态 → 直连云端
# ============================================================
$NodeBin = Find-Node
$Token = ""
if ($NodeBin) {
    try {
        $out = & $NodeBin $DecryptJs 2>$null | Select-String "^DECRYPT_RESULT:"
        if ($out) { $Token = (($out | Select-Object -First 1).Line -replace "^DECRYPT_RESULT:", "").Trim() }
    } catch { $Token = "" }
}

if ($NodeBin -and $Token -and -not $Token.StartsWith("ERR")) {
    Write-Output "✅ 检测到 Node 可直读的登录态（v5.3.8 早期明文形态），令牌读取链路可用。"
    Write-Output "   运行时：$NodeBin（无需安装 Electron）"
    Write-Output "   提示：若该形态变为信封加密，脚本会自动切回路径 A（推荐先确保桌面端在运行）。"
    Show-Done
    try { if ($__prevConsoleEncoding) { [Console]::OutputEncoding = $__prevConsoleEncoding } } catch {}
    exit 0
}

Write-Output "（Node 未能直读登录态——新版信封加密属预期行为，按旧版 state.vscdb 流程处理。）"
Write-Output ""

$Electron = Find-Electron
if (-not $Electron) {
    # 供应链安全：自动从 npm 下载第三方运行时（约 100MB）默认关闭，需显式开启。
    if (-not $env:WB_CHECKIN_AUTO_INSTALL_ELECTRON) {
        Write-Output "⚠️ 路径 A 不可用、Node 无法直读登录态、也未找到 Electron 运行时。"
        Write-Output "   按优先级自查："
        Write-Output "   1) 【最常见】确认 WorkBuddy 桌面端正在运行并已登录 —— 路径 A 只要桌面端在跑就可用，"
        Write-Output "      无需任何运行时。先打开桌面端，再重新运行本脚本即可。"
        Write-Output "   2) 确认已安装 Node.js（路径 B 读取明文登录态需要）。"
        Write-Output "   3) 仅旧版 WorkBuddy/CodeBuddy（state.vscdb）账户才需要 Electron，二选一："
        Write-Output "      a) 手动指定已校验的 Electron：  setup.ps1 -ElectronPath C:\path\to\electron.exe"
        Write-Output "      b) 确认要从官方 npm 下载（约 100MB），先执行："
        Write-Output "           `$env:WB_CHECKIN_AUTO_INSTALL_ELECTRON=1"
        Write-Output "         再运行本脚本。"
        try { if ($__prevConsoleEncoding) { [Console]::OutputEncoding = $__prevConsoleEncoding } } catch {}
        exit 1
    }
    Write-Output "⚠️ 未检测到 Electron，尝试通过 npm 下载（约 100MB，需要 Node.js）..."
    Write-Output "   ⚠️ 供应链提示：将从官方 npm registry 下载 electron@37 并执行，请确认网络可信。"
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npm) {
        Write-Output "❌ 未找到 npm。请先安装 Node.js（https://nodejs.org 下载 LTS 版），"
        Write-Output "   或手动下载 Electron 并执行 setup.ps1 -ElectronPath <electron.exe>。"
        try { if ($__prevConsoleEncoding) { [Console]::OutputEncoding = $__prevConsoleEncoding } } catch {}
        exit 1
    }
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    Push-Location $RuntimeDir
    npm init -y | Out-Null
    npm install electron@37 2>$null | Out-Null
    if (-not (Test-Path (Join-Path $RuntimeDir "node_modules\electron\dist\electron.exe"))) {
        Write-Output "❌ Electron 下载失败（网络/代理问题）。可配置 npm 镜像后重试："
        Write-Output "   npm config set registry https://registry.npmmirror.com"
        Pop-Location
        try { if ($__prevConsoleEncoding) { [Console]::OutputEncoding = $__prevConsoleEncoding } } catch {}
        exit 1
    }
    Move-Item -Force (Join-Path $RuntimeDir "node_modules\electron\dist") (Join-Path $RuntimeDir "electron")
    Remove-Item -Recurse -Force (Join-Path $RuntimeDir "node_modules") -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $RuntimeDir "package.json"), (Join-Path $RuntimeDir "package-lock.json") -ErrorAction SilentlyContinue
    Pop-Location
    $Electron = $DefaultElectron
    Write-Output "✅ Electron 安装完成：$Electron"
} else {
    Write-Output "✅ 已检测到 Electron：$Electron"
}

# ---------- 验证旧版解密链路 ----------
Write-Output "== 验证令牌解密 =="
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
$Token = ""
try {
    $out = & $Electron $DecryptJs 2>$null | Select-String "^DECRYPT_RESULT:"
    if ($out) { $Token = (($out | Select-Object -First 1).Line -replace "^DECRYPT_RESULT:", "").Trim() }
} catch { $Token = "" }

if (-not $Token -or $Token.StartsWith("ERR")) {
    Write-Output "❌ 解密失败（$Token）。请确认：1) 已安装并登录 WorkBuddy 桌面端且**正在运行**（路径 A 通常已足够）；"
    Write-Output "   2) 旧版账户应用名若为 CodeBuddy，设置环境变量 WB_CHECKIN_APP_NAME=CodeBuddy 后重试；"
    Write-Output "   3) 新版信封加密登录态无法离线解密，请改用路径 A。"
    try { if ($__prevConsoleEncoding) { [Console]::OutputEncoding = $__prevConsoleEncoding } } catch {}
    exit 1
}

Write-Output "✅ 令牌解密成功（长度 $($Token.Length)）"
Show-Done
try { if ($__prevConsoleEncoding) { [Console]::OutputEncoding = $__prevConsoleEncoding } } catch {}
