#!/bin/bash
# ============================================================
# WorkBuddy 每日积分签到（通用版，可分发）  v1.1.1
#
# 流程（两条路径，A 优先、B 兜底）：
#   路径 A（首选，零凭据）：调用桌面端注入的本地服务代理
#       CODEBUDDY_SERVICE_PROXY_URL → /internal/hooks/services/invoke，
#       由 App 自行附加登录态并转发云端。不接触任何令牌。
#   路径 B（回退）：读取本地令牌 → 查询签到状态 → 未签到则领取。
#
# 用法：
#   ./checkin.sh                      # 路径 A 优先；不可用时自动回退路径 B
#   WB_CHECKIN_NODE=<path> ./checkin.sh
#   WB_CHECKIN_ELECTRON=<path> ./checkin.sh
#   WB_CHECKIN_SERVICE_ID=<id> ./checkin.sh   # 覆盖 X-Service-Id（默认 auth）
#   WB_CHECKIN_JITTER=<sec> ./checkin.sh      # 随机错峰等待
# 定时（示例，每天 09:00）：
#   crontab -e
#   0 9 * * * /path/to/checkin.sh >> /path/to/logs/checkin.log 2>&1
#
# 运行时策略（仅路径 B 需要）：
#   - 优先用 Node 读取 v5.3.8+ 的新版明文登录态（无需 Electron）。
#   - 新版明文文件缺失时，回退到 Electron + safeStorage 解密旧版 state.vscdb。
#
# ⚠️ 凭据安全提示：
#   - 路径 A 全程不读取、不持有任何凭据。
#   - 路径 B 的本地令牌（accessToken）等同 WorkBuddy 账号密码，仅在本脚本内存中使用，
#     通过管道立即消费，不写入日志、不落地、不回显。
#   - 日志（logs/checkin.log）只记录签到结果（积分/连续天数），不含令牌。
#   - 切勿将日志、脚本输出粘贴分享或提交到任何仓库。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECRYPT_JS="$SCRIPT_DIR/decrypt-token.js"
LOG_DIR="$SCRIPT_DIR/../logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/checkin.log"

# ---------- 探测 Node 运行时（路径 B 读登录态 / JSON 取值） ----------
# ⚠️ 缓存必须落在**父 shell**：本函数一律以 $(find_node) 形式调用，命令替换是子 shell，
#    函数内部的全局赋值不会回传，写在函数里的"缓存"等于没写。故拆成 raw（干活）+ 包装（读父 shell 的值）。
_NODE_BIN=""
_NODE_BIN_WARMED=""
find_node_raw() {
  # 1) 显式指定
  if [ -n "${WB_CHECKIN_NODE:-}" ] && [ -x "$WB_CHECKIN_NODE" ]; then
    printf '%s' "$WB_CHECKIN_NODE"; return
  fi
  # 2) PATH 上的 node + 常见绝对路径（cron/launchd 的 PATH 可能很精简）
  local cands=(
    "$(command -v node 2>/dev/null)"
    "${CODEBUDDY_NODE_BIN:-}"
    "$HOME/.local/bin/node"
    "/opt/homebrew/bin/node"
    "/usr/local/bin/node"
    "$HOME/.nvm/versions/node"/*/bin/node
  )
  local c
  for c in "${cands[@]}"; do
    if [ -n "$c" ] && [ -x "$c" ]; then printf '%s' "$c"; return; fi
  done
  # 3) WorkBuddy 托管 Node（版本目录名随升级变化，故用通配而不是写死）
  local managed
  for managed in "$HOME/.workbuddy/binaries/node/versions"/*/node \
                 "$HOME/.workbuddy/binaries/node/versions"/*/node.exe; do
    if [ -x "$managed" ]; then printf '%s' "$managed"; return; fi
  done
  printf '%s' ""
}
find_node() {
  if [ "$_NODE_BIN_WARMED" = "1" ]; then printf '%s' "$_NODE_BIN"; return; fi
  printf '%s' "$(find_node_raw)"
}
# 父 shell 预解析一次，后续 find_node 调用零开销
_NODE_BIN="$(find_node_raw)"
_NODE_BIN_WARMED=1

# ---------- 探测 Electron 运行时（仅旧版 state.vscdb 回退分支需要） ----------
find_electron() {
  # 1) 显式指定
  if [ -n "${WB_CHECKIN_ELECTRON:-}" ] && [ -x "$WB_CHECKIN_ELECTRON" ]; then
    echo "$WB_CHECKIN_ELECTRON"; return
  fi
  # 2) 本 skill 常见安装位置（含 Windows/Git Bash 路径，electron.exe）
  local cands=(
    "$HOME/.workbuddy/tools/electron/Electron.app/Contents/MacOS/Electron"
    "$HOME/.workbuddy/tools/electron/electron.exe"
    "$HOME/.workbuddy/skills/workbuddy-checkin/.runtime/electron/Electron.app/Contents/MacOS/Electron"
    "$HOME/.workbuddy/skills/workbuddy-checkin/.runtime/electron/electron.exe"
    "$SCRIPT_DIR/../.runtime/electron/Electron.app/Contents/MacOS/Electron"
    "$SCRIPT_DIR/../.runtime/electron/electron.exe"
    "$(command -v electron 2>/dev/null)"
  )
  for c in "${cands[@]}"; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return; fi
  done
  echo ""
}

# ---------- 读取令牌：Node 优先，Electron 回退 ----------
# Windows 兼容：Node 在 Git Bash 下不接受 POSIX 风格绝对路径（/c/Users/...），
# 需转 Windows 风格（C:\Users\...）或用相对路径。这里优先用相对路径，最稳。
read_token() {
  local out="" node_bin electron_bin
  # 进入脚本所在目录，Node 接受相对路径 decrypt-token.js
  cd "$SCRIPT_DIR" 2>/dev/null || true
  local DECRYPT_REL="decrypt-token.js"
  node_bin="$(find_node)"
  if [ -n "$node_bin" ]; then
    out=$("$node_bin" "$DECRYPT_REL" 2>/dev/null | grep "^DECRYPT_RESULT:" | sed 's/^DECRYPT_RESULT://')
  fi
  if [ -z "$out" ] || [[ "$out" == ERR* ]]; then
    # Node 未产出 token（未装 Node / 崩溃），或 Node 报 ERR（如旧版账户无明文文件、
    # 纯 Node 无法解密 state.vscdb）→ 回退到 Electron 解旧版库
    electron_bin="$(find_electron)"
    if [ -n "$electron_bin" ]; then
      out=$(env -u ELECTRON_RUN_AS_NODE "$electron_bin" "$DECRYPT_REL" 2>/dev/null \
        | grep "^DECRYPT_RESULT:" | sed 's/^DECRYPT_RESULT://')
    fi
  fi
  echo "$out"
}

# ---------- 探测 curl（PATH 可能被裁剪，故含常见绝对路径兜底） ----------
find_curl() {
  local c
  for c in "$(command -v curl 2>/dev/null)" \
           "/mingw64/bin/curl" \
           "/usr/bin/curl" \
           "${SYSTEMROOT:-}/System32/curl.exe" \
           "/c/Windows/System32/curl.exe" \
           "/usr/local/bin/curl" \
           "/opt/homebrew/bin/curl"; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return; fi
  done
  echo ""
}

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# ---------- 可选：随机错峰（避免整点风暴） ----------
# 设置 WB_CHECKIN_JITTER=<正整数秒> 时，脚本在开始前随机等待 0~N 秒
# 须 > 0：RANDOM % 0 会触发除零异常；非数字也会被 `[ -gt 0 ]` 拒绝（静默跳过）
if [ "${WB_CHECKIN_JITTER:-0}" -gt 0 ] 2>/dev/null; then
  jitter=$((RANDOM % WB_CHECKIN_JITTER))
  [ "$jitter" -gt 0 ] && sleep "$jitter"
fi

# ============================================================
# 首选路径（v1.1.0）：WorkBuddy 本地服务代理 —— 零凭据签到
#
# 原理：桌面端会把 CODEBUDDY_SERVICE_PROXY_URL 注入到每个 Bash / 钩子子进程
#       （形如 http://127.0.0.1:<port>/internal/hooks/services/invoke）。
#       该端点是官方设计的「服务调用代理」：由 App 自己把登录态的
#       Authorization 头附加到请求上再转发到云端。调用方只需声明
#       X-Service-Id，全程不需要、也拿不到任何令牌。
#
#       于是签到不再依赖"解密本地登录态"，从而彻底免疫
#       at-rest 信封加密 / keyblob protector 变更导致的 401。
#
#       （本路径为本地回环调用；路径前缀 ./../ 用于把请求落到
#         /billing/meter/*。代理端会对该路径做归一化，属已知可用行为。）
#
# 若本路径不可用（未注入环境变量、桌面端未运行、代理拒绝），
# 自动回退到下方原有的"读取本地令牌 → 直连云端"流程。
# ============================================================
JGET_JS="$SCRIPT_DIR/jget.js"
PROXY_SVC_ID="${WB_CHECKIN_SERVICE_ID:-auth}"
CURL_BIN="$(find_curl)"

# 列出候选代理地址。
#   $1=fast  → 只回环境变量给的地址（零探测，毫秒级）
#   $1=full  → 环境变量 + 反查本机 WorkBuddy 监听端口
#
# ⚠️ 性能教训：早期版本用 `Get-NetTCPConnection -OwningProcess <pid>` 逐进程枚举，
#    实测单次 7.5s（该 cmdlet 每次都要遍历完整 TCP 表）。改成
#    「一次 Get-Process 取 PID + 解析 netstat -ano」后降到约 0.16s。
#    并且环境变量存在时**不应**枚举端口——白跑一次就把冷启动从 0.3s 拉到 11s。
_PROXY_BASES_CACHE=""
_PROXY_BASES_WARMED=""
discover_proxy_bases() {
  local mode="${1:-full}"

  local env_base=""
  if [ -n "${CODEBUDDY_SERVICE_PROXY_URL:-}" ]; then
    env_base="${CODEBUDDY_SERVICE_PROXY_URL%/}"
  fi

  if [ "$mode" = "fast" ]; then
    [ -n "$env_base" ] && printf '%s\n' "$env_base"
    return 0
  fi

  # 缓存同样必须在父 shell（调用点一律是命令/进程替换）→ 由 WARMED 标志读取预解析结果
  if [ "$_PROXY_BASES_WARMED" = "1" ]; then
    printf '%s\n' "$_PROXY_BASES_CACHE"
    return
  fi
  discover_proxy_bases_raw "$env_base"
}

discover_proxy_bases_raw() {
  local bases="${1:-}"

  local ports="" ps_bin=""
  # PATH 可能被裁剪，故 powershell 也试其绝对路径
  if command -v powershell.exe >/dev/null 2>&1; then
    ps_bin="powershell.exe"
  elif [ -x "${SYSTEMROOT:-}/System32/WindowsPowerShell/v1.0/powershell.exe" ]; then
    ps_bin="${SYSTEMROOT:-}/System32/WindowsPowerShell/v1.0/powershell.exe"
  elif [ -x "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]; then
    ps_bin="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  fi
  if [ -n "$ps_bin" ]; then
    # 单引号包裹整段脚本：内部用 PS 双引号，避免 bash 展开 $p / $f
    # ⚠️ netstat 必须用绝对路径：cron / 计划任务等精简 PATH 场景下，Git Bash 会把
    #    PATH 翻译成 Git 自己的目录（System32 丢失），裸 netstat 直接解析不到。
    local ps_cmd='$p=@(Get-Process -Name WorkBuddy -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Id);if($p.Count){$ns=Join-Path $env:SystemRoot "System32\netstat.exe";if(-not (Test-Path $ns)){$ns="netstat"};& $ns -ano|Select-String "LISTENING"|ForEach-Object{$f=-split $_.Line;if($f.Count -ge 5 -and $p -contains [int]$f[4]){($f[1] -split ":")[-1]}}|Select-Object -Unique}'
    ports=$("$ps_bin" -NoProfile -NonInteractive -Command "$ps_cmd" \
      2>/dev/null | tr -d '\r' | tr -d ' ')
  fi
  if [ -z "$ports" ] && [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    # macOS: 进程名通常为 Electron，且全局 lsof 在部分系统因内核 Mach 端口锁会严重卡死。
    # 用 macOS 原生 netstat -anv -p tcp 搭配 pgrep 毫秒级提取 WorkBuddy 监听端口
    local wb_pids
    wb_pids=$(pgrep -f -i 'workbuddy|codebuddy' 2>/dev/null | tr '\n' '|' | sed 's/|$//')
    if [ -n "$wb_pids" ]; then
      ports=$(netstat -anv -p tcp 2>/dev/null \
        | awk -v pids="^($wb_pids)$" '/LISTEN/ {
            for (i=1; i<=NF; i++) {
              if ($i ~ /:[0-9]+$/) {
                split($i, a, ":")
                if (a[2] ~ pids) {
                  split($4, b, ".")
                  print b[length(b)]
                }
              }
            }
          }' | sort -u)
    fi
  fi
  if [ -z "$ports" ] && command -v ss >/dev/null 2>&1; then
    ports=$(ss -tulpn 2>/dev/null | grep -iE 'workbuddy|codebuddy' | awk '{print $5}' | sed 's/.*://' | tr -d ' ')
  fi
  if [ -z "$ports" ] && command -v lsof >/dev/null 2>&1; then
    # macOS / Linux 回退。进程名按大小写不敏感匹配 WorkBuddy / CodeBuddy
    # （应用曾用名 CodeBuddy；Electron 的渲染/工具进程名会带 " Helper" 后缀，同样命中）
    ports=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
      | grep -iE 'workbuddy|codebuddy' | awk '{print $9}' | sed 's/.*://' | tr -d ' ')
  fi

  local p
  for p in $ports; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    bases="$bases
http://127.0.0.1:$p/internal/hooks/services/invoke"
  done

  printf '%s\n' "$bases" | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++'
}

# 环境变量缺失时才需要端口枚举；此时在父 shell 预解析一次，让 full 轮的缓存真正生效
if [ -z "${CODEBUDDY_SERVICE_PROXY_URL:-}" ]; then
  _PROXY_BASES_CACHE="$(discover_proxy_bases_raw "")"
  _PROXY_BASES_WARMED=1
fi

# 生成候选请求：优先「百分号编码路径」（所有 curl 均可，无需额外 flag），
# 其次「原始 ../ + --path-as-is」作为兼容兜底。
# ⚠️ 按形态分组（先全部 plain，再全部 as-is），而不是每个地址交替两种形态：
#    否则前 N-1 个失败地址各会白试一次 as-is，最坏情况请求数翻倍。
# ⚠️ 地址列表只求值一次（用 here-string，不要写两遍进程替换）：否则 full 轮会把
#    「端口枚举」整段跑两遍，实测每次约 1s，纯属白烧。
# $3=1 表示排除环境变量地址（它已在 fast 轮试过，full 轮不该为它再付两次请求）
# 每行格式：<mode>|<url>
proxy_candidates() {
  local tgt="$1" dmode="${2:-full}" skip_env="${3:-0}" enc bases base
  enc=$(printf '%s' "$tgt" | sed 's#/#%2F#g')
  bases="$(discover_proxy_bases "$dmode")"
  if [ "$skip_env" = "1" ] && [ -n "${CODEBUDDY_SERVICE_PROXY_URL:-}" ]; then
    bases="$(printf '%s\n' "$bases" | grep -vxF "${CODEBUDDY_SERVICE_PROXY_URL%/}" || true)"
  fi
  while IFS= read -r base; do
    [ -z "$base" ] && continue
    printf '%s\n' "plain|${base}/..%2F..%2F${enc}"
  done <<< "$bases"
  while IFS= read -r base; do
    [ -z "$base" ] && continue
    printf '%s\n' "as-is|${base}/../../${tgt}"
  done <<< "$bases"
}

# 在给定的一批候选地址上尝试请求；返回首个 code=0 的响应
# ⚠️ 回环请求必须加 --noproxy '*'：企业环境常设 http_proxy/https_proxy 环境变量，
#    不绕过就会把 127.0.0.1 的请求也丢给代理 —— 实测会导致整轮签到 42s 后直接失败。
# ⚠️ --connect-timeout 2 兜住「端口静默丢包」的最坏情况（Windows 上连一个关闭的端口
#    本就要约 2.2s；若被防火墙静默丢弃，没有这个上限会一路耗到 -m 10）。
proxy_try_bases() {
  local tgt="$1" dmode="$2" skip_env="${3:-0}" line mode u resp
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    mode="${line%%|*}"
    u="${line#*|}"
    if [ "$mode" = "as-is" ]; then
      resp=$("$CURL_BIN" -s -m 10 --connect-timeout 2 --noproxy '*' --path-as-is -X POST "$u" \
        -H "X-Service-Id: $PROXY_SVC_ID" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' -d '{}' 2>/dev/null)
    else
      resp=$("$CURL_BIN" -s -m 10 --connect-timeout 2 --noproxy '*' -X POST "$u" \
        -H "X-Service-Id: $PROXY_SVC_ID" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json' -d '{}' 2>/dev/null)
    fi
    case "$resp" in
      *'"code":0'*) printf '%s' "$resp"; return 0 ;;
    esac
  done < <(proxy_candidates "$tgt" "$dmode" "$skip_env")
  return 1
}

# 调用云端接口，返回首个 code=0 的响应；全部失败返回非 0
# 快慢两轮：先只用环境变量地址（廉价），失败才做端口枚举（昂贵）
# 注意 fast 轮传 skip_env=0 —— fast 模式本身就只输出环境变量地址，不能再排除，否则候选为空
proxy_call() {
  local tgt="$1"
  [ -z "$CURL_BIN" ] && return 1
  if [ -n "${CODEBUDDY_SERVICE_PROXY_URL:-}" ]; then
    proxy_try_bases "$tgt" fast 0 && return 0
    # fast 轮失败（地址已失效 / App 重启换了端口）→ full 轮，并跳过刚试过的环境变量地址
    proxy_try_bases "$tgt" full 1 && return 0
    return 1
  fi
  proxy_try_bases "$tgt" full 0
}

# JSON 取值：Node（jget.js）优先，python3 兜底
# Node 在 Windows/Git Bash 下不接受 POSIX 绝对路径，故 cd 到脚本目录后用相对路径调用
jget() {
  local json="$1" path="$2" node_bin out rc
  node_bin="$(find_node)"
  if [ -n "$node_bin" ] && [ -f "$JGET_JS" ]; then
    out=$( cd "$SCRIPT_DIR" && printf '%s' "$json" | "$node_bin" 'jget.js' "$path" 2>/dev/null ); rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then printf '%s' "$out"; return; fi
  fi
  printf '%s' "$json" | python3 -c "
import sys, json
try:
    o = json.load(sys.stdin)
    for k in '$path'.split('.'):
        o = o[k]
    print(o if not isinstance(o, (dict, list)) else json.dumps(o, ensure_ascii=False))
except Exception:
    print('')
" 2>/dev/null
}

# checkin_activity_status 是当前有效的活动接口；checkin-status 为废弃接口
# （该接口 today_checked_in 恒为 false，不可用于判定，仅保留给旧版云端兜底）
proxy_checkin() {
  local st today
  st="$(proxy_call 'billing/meter/checkin-activity-status')" || return 1
  today="$(jget "$st" 'data.today_checked_in')"

  if [ "$today" = "true" ] || [ "$today" = "True" ]; then
    local streak credit
    streak="$(jget "$st" 'data.streak_days')"
    credit="$(jget "$st" 'data.today_credit')"
    log "✅ 今日已签到（连续 ${streak:-?} 天，今日 ${credit:-?} 积分）— 本地代理路径"
    return 0
  fi

  local res code
  res="$(proxy_call 'billing/meter/daily-checkin')"
  code="$(jget "$res" 'code')"

  if [ "$code" = "0" ]; then
    local credit streak
    credit="$(jget "$res" 'data.credit')"
    [ -z "$credit" ] && credit="$(jget "$res" 'data.today_credit')"
    streak="$(jget "$res" 'data.streak_days')"
    log "🎉 签到成功！领取 ${credit:-?} 积分（连续 ${streak:-?} 天）— 本地代理路径"
    return 0
  fi

  # daily-checkin 被拒（如上游 400）时，以活动接口为准复核一次，避免误报失败
  local re
  re="$(proxy_call 'billing/meter/checkin-activity-status')"
  if [ "$(jget "$re" 'data.today_checked_in')" = "true" ]; then
    log "✅ 今日已签到（连续 $(jget "$re" 'data.streak_days') 天）— 本地代理路径"
    return 0
  fi

  log "⚠️ 本地代理路径未完成签到（daily-checkin code=${code:-空}），回退令牌路径重试"
  return 1
}

if proxy_checkin; then
  exit 0
fi
# 记录首选路径失败：下面的失败提示要据此区分「桌面端没开」和「缺运行时」——
# 登录态已信封加密，脱机时装 Node/Electron 都救不了，提示错了会让人白折腾。
PROXY_FAILED=1

# ---------- 1. 读取令牌 ----------
TOKEN="$(read_token)"

if [ -z "$TOKEN" ] || [[ "$TOKEN" == ERR* ]]; then
  if [ "$PROXY_FAILED" = "1" ]; then
    log "❌ 两条路径都失败了。首选路径（本地服务代理）不可用，最常见的原因是 WorkBuddy 桌面端没在运行 —— 先启动桌面端再重试；当前登录态是 at-rest 信封加密（解封密钥只在 App 进程内存），脱机状态下没有任何离线办法拿到令牌，装 Node.js / Electron 都不解决问题。"
    [ -n "$TOKEN" ] && log "   （回退路径的报错：${TOKEN}）"
  elif [ -z "$TOKEN" ]; then
    log "❌ 未找到 Node 或 Electron 运行时，或运行时未能产出令牌。请安装 Node.js，或设置 WB_CHECKIN_NODE / WB_CHECKIN_ELECTRON 指向可用运行时。"
  else
    log "❌ 获取令牌失败（${TOKEN}）。请确认已安装并登录 WorkBuddy 桌面端。"
  fi
  exit 1
fi

API="https://copilot.tencent.com"

# ---------- 2. 查询签到状态 ----------
STATUS=$("${CURL_BIN:-curl}" -s -m 15 -X POST "$API/billing/meter/checkin-status" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "Authorization: Bearer $TOKEN" -d '{}' 2>/dev/null || echo "")

if [ -z "$STATUS" ]; then
  log "❌ 查询签到状态失败（网络异常）"
  exit 1
fi
if echo "$STATUS" | grep -qi "401\|unauthorized"; then
  if [ "$PROXY_FAILED" = "1" ]; then
    log "❌ 收到 401。首选路径（本地服务代理）没生效，最常见的原因是 WorkBuddy 桌面端没在运行；这里的 401 来自回退路径读到的旧令牌。先启动桌面端再重试即可——桌面端在运行时由 App 代持令牌，根本不需要解密。"
  else
    log "❌ 令牌已过期（401），请打开 WorkBuddy 桌面端刷新登录态后重试"
  fi
  exit 1
fi

# 注意：today_checked_in 字段在 v5.3.8 实测不可靠（签到成功后仍可能为 false）。
# 此处仅用于「能省一次签到请求就省」的快速短路与 401 探测；真正的幂等兜底
# 放在下方 daily-checkin 的 code=10001 处理。
CHECKED=$(echo "$STATUS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('data', {}).get('today_checked_in', False))
except Exception:
    print('unknown')
" 2>/dev/null)

if [ "$CHECKED" = "True" ]; then
  log "✅ 今日已签到，无需重复领取"
  exit 0
fi

# ---------- 3. 执行签到 ----------
RESULT=$("${CURL_BIN:-curl}" -s -m 15 -X POST "$API/billing/meter/daily-checkin" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "Authorization: Bearer $TOKEN" -d '{}' 2>/dev/null || echo "")

if [ -z "$RESULT" ]; then
  log "❌ 签到请求失败（网络异常）"
  exit 1
fi

CREDIT=$(echo "$RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get('code') == 0:
        data = d.get('data', {})
        print(f\"OK credit={data.get('credit')} streak_days={data.get('streak_days')}\")
    elif d.get('code') == 10001:
        # 当日已签到：接口幂等拒绝，视为成功
        print('ALREADY today')
    else:
        print(f\"FAIL code={d.get('code')} msg={d.get('msg')}\")
except Exception:
    print('PARSE_ERR')
" 2>/dev/null)

if [[ "$CREDIT" == OK* ]]; then
  log "🎉 签到成功！领取 $CREDIT"
elif [[ "$CREDIT" == ALREADY* ]]; then
  log "✅ 今日已签到，无需重复领取（接口返回已签到）"
elif [ -z "$CREDIT" ]; then
  # 多为缺 python3 导致结果无法解析：服务端可能已成功，不能误报失败
  log "⚠️ 签到请求已提交，但缺少 python3 无法解析结果（请打开 WorkBuddy 确认；安装 python3 可恢复明细）"
else
  log "⚠️ 签到未成功：$CREDIT"
fi
