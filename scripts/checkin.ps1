# ============================================================
# WorkBuddy 每日积分签到（Windows PowerShell 版，兼容 PS 5.1）  v1.1.1
#
# 流程（两条路径，A 优先、B 兜底）：
#   路径 A（首选，零凭据）：调用桌面端注入的本地服务代理
#       CODEBUDDY_SERVICE_PROXY_URL → /internal/hooks/services/invoke，
#       由 App 自行附加登录态并转发云端。不接触任何令牌。
#   路径 B（回退）：读取本地令牌 → 查询签到状态 → 未签到则领取。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File checkin.ps1
# 或（显式指定运行时）：
#   $env:WB_CHECKIN_NODE="C:\path\to\node.exe"
#   $env:WB_CHECKIN_ELECTRON="C:\path\to\electron.exe"
#   $env:WB_CHECKIN_SERVICE_ID="auth"        # 覆盖 X-Service-Id（默认 auth）
#   powershell -ExecutionPolicy Bypass -File checkin.ps1
# 定时（示例，每天 09:00，管理员或普通用户均可；内层引号按 schtasks 要求转义）：
#   schtasks /Create /TN WorkBuddyDailyCheckin /TR "powershell -ExecutionPolicy Bypass -File \"C:\path\checkin.ps1\"" /SC DAILY /ST 09:00 /F
#
# 运行时策略（仅路径 B 需要）：Node 优先（读取明文登录态），缺失时回退到 Electron + safeStorage。
#
# ⚠️ 凭据安全提示：
#   - 路径 A 全程不读取、不持有任何凭据。
#   - 路径 B 的本地令牌（accessToken）等同 WorkBuddy 账号密码，仅在本脚本内存中使用，
#     通过管道立即消费，不写入日志、不落地、不回显。
#   - 日志（logs/checkin.log）只记录签到结果（积分/连续天数），不含令牌。
#   - 切勿将日志、脚本输出粘贴分享或提交到任何仓库。
# ============================================================
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DecryptJs = Join-Path $ScriptDir "decrypt-token.js"
$SkillRoot = Split-Path -Parent $ScriptDir
$LogDir = Join-Path $SkillRoot "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "checkin.log"

# 统一按 UTF-8（无 BOM）追加：bash 版用 tee 写的是无 BOM UTF-8，
# 若这里用 Add-Content -Encoding UTF8，PS 5.1 建文件时会写入 BOM，两种写入口径不一致。
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Output $line
    [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", $Utf8NoBom)
}

# ---------- 可选：随机错峰（避免整点风暴） ----------
# 设置环境变量 WB_CHECKIN_JITTER=<秒> 时，开始前随机等待 0~N 秒
if ($env:WB_CHECKIN_JITTER) {
    try {
        $max = [int]$env:WB_CHECKIN_JITTER
        if ($max -gt 0) { Start-Sleep -Seconds (Get-Random -Maximum $max) }
    } catch {}
}

# ---------- 探测 Node 运行时（路径 B：读登录态 + 解析 JSON） ----------
$script:__NodeBinProbed = $false
$script:__NodeBinCache = ""
function Find-Node {
    if ($script:__NodeBinProbed) { return $script:__NodeBinCache }
    $script:__NodeBinProbed = $true
    if ($env:WB_CHECKIN_NODE -and (Test-Path $env:WB_CHECKIN_NODE)) {
        $script:__NodeBinCache = $env:WB_CHECKIN_NODE; return $script:__NodeBinCache
    }
    $cands = @(
        (Get-Command node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        $env:CODEBUDDY_NODE_BIN,
        (Join-Path $env:ProgramFiles "nodejs\node.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "nodejs\node.exe")
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { $script:__NodeBinCache = $c; return $c } }
    # WorkBuddy 托管 Node（版本目录名随升级变化，故用通配而非写死）
    foreach ($m in @(Get-ChildItem -Path (Join-Path $HOME ".workbuddy\binaries\node\versions") -Filter "node.exe" -Recurse -ErrorAction SilentlyContinue)) {
        if ($m -and (Test-Path $m.FullName)) { $script:__NodeBinCache = $m.FullName; return $m.FullName }
    }
    $script:__NodeBinCache = ""
    return ""
}

# ---------- 探测 Electron 运行时（仅旧版 state.vscdb 回退分支需要） ----------
function Find-Electron {
    if ($env:WB_CHECKIN_ELECTRON -and (Test-Path $env:WB_CHECKIN_ELECTRON)) {
        return $env:WB_CHECKIN_ELECTRON
    }
    $cands = @(
        (Join-Path $HOME ".workbuddy\tools\electron\electron.exe"),
        (Join-Path $HOME ".workbuddy\skills\workbuddy-checkin\.runtime\electron\electron.exe"),
        (Join-Path $SkillRoot ".runtime\electron\electron.exe"),
        (Join-Path $ScriptDir "..\node_modules\electron\dist\electron.exe")
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return ""
}

# ============================================================
# 首选路径（v1.1.0）：WorkBuddy 本地服务代理 —— 零凭据签到
#
# 原理同 checkin.sh：桌面端会把 CODEBUDDY_SERVICE_PROXY_URL 注入子进程，
# 该端点由 App 自己附加登录态 Authorization 头再转发到云端。
# 调用方只需声明 X-Service-Id，全程不需要、也拿不到任何令牌，
# 因此免疫 at-rest 信封加密 / keyblob protector 变更导致的 401。
#
# 本路径不可用时，自动回退到下方原有的「读取本地令牌 → 直连云端」流程。
# ============================================================
$ProxySvcId = if ($env:WB_CHECKIN_SERVICE_ID) { $env:WB_CHECKIN_SERVICE_ID } else { "auth" }

# ⚠️ PowerShell 5.1 会用 OEM 代码页（中文系统为 GBK）解码 curl.exe 的 stdout，
# 而 curl 输出是 UTF-8。中文一旦被错误解码，字节序列即被破坏，
# ConvertFrom-Json 会直接抛「传入的对象无效」。故临时把解码切到 UTF-8。
$__prevConsoleEncoding = $null
try {
    $__prevConsoleEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch {}

# 函数内若用 Write-Log（走输出流）会污染返回值，故用只写主机+日志文件的版本
function Write-LogHost([string]$msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", $Utf8NoBom)
}

# 结果缓存：枚举端口有代价，而 Invoke-ProxyApi 的候选循环会对每个候选重复求值
# ⚠️ 性能教训：早期用 `Get-NetTCPConnection -OwningProcess <pid>` 逐进程枚举，
#    实测 7.5s（该 cmdlet 每次都要遍历完整 TCP 表）。改为「一次 Get-Process 取 PID
#    + 解析 netstat -ano（绝对路径）」后约 0.16s。
$script:__ProxyBasesProbed = $false
$script:__ProxyBasesCache = @()

function Get-ProxyBases {
    if ($script:__ProxyBasesProbed) { return $script:__ProxyBasesCache }
    $script:__ProxyBasesProbed = $true
    $bases = @()
    $ports = @()
    try {
        $pids = @(Get-Process -Name WorkBuddy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        if ($pids.Count -gt 0) {
            # netstat 用绝对路径：精简 PATH（计划任务/cron）下裸 netstat 可能解析不到
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
    $script:__ProxyBasesCache = @($bases | Select-Object -Unique)
    return $script:__ProxyBasesCache
}

# 在一批候选地址上尝试请求；按形态分组（先全部百分号编码形态，再全部 as-is 兼容形态），
# 避免每个失败地址都白试一次兼容变体。返回首个 code=0 的响应，全失败返回 ""
# ⚠️ 回环请求必须加 --noproxy '*'：企业环境常设 http_proxy/https_proxy，
#    不绕过就会把 127.0.0.1 的请求也丢给代理 —— 实测会导致整轮签到 42s 后失败。
# ⚠️ --connect-timeout 5 兜住「端口静默丢包」的最坏情况。
function Invoke-ProxyOnBases([string]$Target, $Bases) {
    $enc = $Target -replace '/', '%2F'
    $list = @($Bases)
    foreach ($pass in @("plain", "asis")) {
        foreach ($x in $list) {
            if (-not $x) { continue }
            if ($pass -eq "plain") { $u = "$x/..%2F..%2F$enc" } else { $u = "$x/../../$Target" }
            $resp = ""
            try {
                $resp = & curl.exe -s -m 20 --connect-timeout 5 --noproxy "*" -X POST $u `
                    -H "X-Service-Id: $ProxySvcId" `
                    -H "Content-Type: application/json" `
                    -H "Accept: application/json" -d '{}' 2>$null
            } catch { $resp = "" }
            if ($resp -and ($resp -match '"code"\s*:\s*0')) { return $resp }
        }
    }
    return ""
}

# 快慢两轮：先只用环境变量地址（廉价），失败才做端口枚举（昂贵）
# full 轮排除刚试过的环境变量地址：它已失效（App 重启换了端口），再试只是白付两次请求
function Invoke-ProxyApi([string]$Target) {
    if ($env:CODEBUDDY_SERVICE_PROXY_URL) {
        $envBase = $env:CODEBUDDY_SERVICE_PROXY_URL.TrimEnd('/')
        $r = Invoke-ProxyOnBases $Target @($envBase)
        if ($r) { return $r }
        $rest = @(Get-ProxyBases | Where-Object { $_ -ne $envBase })
        return (Invoke-ProxyOnBases $Target $rest)
    }
    return (Invoke-ProxyOnBases $Target (Get-ProxyBases))
}

function Get-JsonField($json, [string]$Path) {
    if (-not $json) { return $null }
    try {
        $o = $json | ConvertFrom-Json
        foreach ($k in $Path.Split('.')) { $o = $o.$k }
        return $o
    } catch { return $null }
}

function Invoke-ProxyCheckin {
    $st = Invoke-ProxyApi "billing/meter/checkin-activity-status"
    if (-not $st) { return $false }
    if ((Get-JsonField $st "data.today_checked_in") -eq $true) {
        Write-LogHost "✅ 今日已签到（连续 $(Get-JsonField $st 'data.streak_days') 天，今日 $(Get-JsonField $st 'data.today_credit') 积分）— 本地代理路径"
        return $true
    }
    $res = Invoke-ProxyApi "billing/meter/daily-checkin"
    if ((Get-JsonField $res "code") -eq 0) {
        Write-LogHost "🎉 签到成功！领取 $(Get-JsonField $res 'data.credit') 积分（连续 $(Get-JsonField $res 'data.streak_days') 天）— 本地代理路径"
        return $true
    }
    # daily-checkin 被拒时以活动接口复核一次，避免误报失败
    $re = Invoke-ProxyApi "billing/meter/checkin-activity-status"
    if ((Get-JsonField $re "data.today_checked_in") -eq $true) {
        Write-LogHost "✅ 今日已签到（连续 $(Get-JsonField $re 'data.streak_days') 天）— 本地代理路径"
        return $true
    }
    Write-LogHost "⚠️ 本地代理路径未完成签到，回退令牌路径重试"
    return $false
}

if (Invoke-ProxyCheckin) { exit 0 }
# 首选路径失败：下面的提示要据此区分「桌面端没开」和「缺运行时」——
# 登录态已信封加密，脱机时装 Node/Electron 都救不了，提示错了会让人白折腾。
$ProxyFailed = $true
try { if ($__prevConsoleEncoding) { [Console]::OutputEncoding = $__prevConsoleEncoding } } catch {}

# ---------- 1. 读取令牌：Node 优先，Electron 回退 ----------
$Token = ""
# Node 优先
$NodeBin = Find-Node
if ($NodeBin) {
    try {
        $out = & $NodeBin $DecryptJs 2>$null | Select-String "^DECRYPT_RESULT:"
        if ($out) { $Token = (($out | Select-Object -First 1).Line -replace "^DECRYPT_RESULT:", "").Trim() }
    } catch {}
}
# Electron 回退（Node 未取到有效 token，或 Node 报 ERR —— 如旧版账户无明文文件、纯 Node 无法解密 state.vscdb）
if (-not $Token -or $Token.StartsWith("ERR")) {
    $Electron = Find-Electron
    if ($Electron) {
        # 关键：若环境存在 ELECTRON_RUN_AS_NODE，必须移除，否则 require('electron') 拿不到 safeStorage
        Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
        try {
            $out = & $Electron $DecryptJs 2>$null | Select-String "^DECRYPT_RESULT:"
            if ($out) { $Token = (($out | Select-Object -First 1).Line -replace "^DECRYPT_RESULT:", "").Trim() }
        } catch {
            Write-Log "❌ 调用 Electron 解密脚本出错：$($_.Exception.Message)"
        }
    }
}

if (-not $Token -or $Token.StartsWith("ERR")) {
    if ($ProxyFailed) {
        Write-Log "❌ 两条路径都失败了。首选路径（本地服务代理）不可用，最常见的原因是 WorkBuddy 桌面端没在运行 —— 先启动桌面端再重试；当前登录态是 at-rest 信封加密（解封密钥只在 App 进程内存），脱机状态下没有任何离线办法拿到令牌，装 Node.js / Electron 都不解决问题。"
        if ($Token) { Write-Log "   （回退路径的报错：$Token）" }
    } elseif (-not $Token) {
        Write-Log "❌ 未找到 Node 或 Electron 运行时，或运行时未能产出令牌。请安装 Node.js，或设置 WB_CHECKIN_NODE / WB_CHECKIN_ELECTRON。"
    } else {
        Write-Log "❌ 获取令牌失败（$Token）。请确认已安装并登录 WorkBuddy 桌面端。"
    }
    exit 1
}

$Api = "https://copilot.tencent.com"

# ---------- 2. 查询签到状态 ----------
$Status = ""
try {
    $Status = & curl.exe -s -m 15 -X POST "$Api/billing/meter/checkin-status" `
        -H "Content-Type: application/json" -H "Accept: application/json" `
        -H "Authorization: Bearer $Token" -d '{}' 2>$null
} catch { $Status = "" }
if (-not $Status) { Write-Log "❌ 查询签到状态失败（网络异常）"; exit 1 }
if ($Status -match "401|unauthorized") {
    if ($ProxyFailed) {
        Write-Log "❌ 收到 401。首选路径（本地服务代理）没生效，最常见的原因是 WorkBuddy 桌面端没在运行；这里的 401 来自回退路径读到的旧令牌。先启动桌面端再重试即可。"
    } else {
        Write-Log "❌ 令牌已过期（401），请打开 WorkBuddy 桌面端刷新登录态后重试"
    }
    exit 1
}

# 注意：today_checked_in 字段在 v5.3.8 实测不可靠（签到成功后仍可能为 false）。
# 此处仅用于快速短路与 401 探测；真正的幂等兜底在下方 daily-checkin 的 code=10001 处理。
$Checked = $false
try { $Checked = [bool]($Status | ConvertFrom-Json).data.today_checked_in } catch {}
if ($Checked) { Write-Log "✅ 今日已签到，无需重复领取"; exit 0 }

# ---------- 3. 执行签到 ----------
$Result = ""
try {
    $Result = & curl.exe -s -m 15 -X POST "$Api/billing/meter/daily-checkin" `
        -H "Content-Type: application/json" -H "Accept: application/json" `
        -H "Authorization: Bearer $Token" -d '{}' 2>$null
} catch { $Result = "" }
if (-not $Result) { Write-Log "❌ 签到请求失败（网络异常）"; exit 1 }

$Credit = ""
try {
    $d = $Result | ConvertFrom-Json
    if ($d.code -eq 0) { $Credit = "OK credit=$($d.data.credit) streak_days=$($d.data.streak_days)" }
    elseif ($d.code -eq 10001) { $Credit = "ALREADY today" }   # 当日已签到：接口幂等拒绝，视为成功
    else { $Credit = "FAIL code=$($d.code) msg=$($d.msg)" }
} catch { $Credit = "PARSE_ERR" }

if ($Credit -like "OK*") { Write-Log "🎉 签到成功！领取 $Credit" }
elseif ($Credit -like "ALREADY*") { Write-Log "✅ 今日已签到，无需重复领取（接口返回已签到）" }
else { Write-Log "⚠️ 签到未成功：$Credit" }
