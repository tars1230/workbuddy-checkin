#!/bin/bash
# ============================================================
# WorkBuddy 每日签到 - 环境安装脚本（通用版）  v1.1.1
#
# 检查顺序（与 checkin.sh 一致）：
#   路径 A（首选）：本地服务代理可用？→ 零凭据，无需 Node / Electron，直接完成
#   路径 B（回退）：Node 读取登录态 → 旧版 state.vscdb 需 Electron
#
# v5.3.8+ 新版登录态已改为 at-rest 信封加密，解封密钥只在 App 进程内存，
# 纯 Node / Electron 均无法离线解密（这是 v1.0.x 长期 401 的根因）。
# 因此路径 A 是推荐路径；路径 B 仅在没有运行中的桌面端时才需要。
#
# 用法：./setup.sh [--electron <路径或自动下载>]
#   （默认）自动探测：代理 → Node → Electron
#   --electron auto   检测已有运行时，缺失则通过 npm 下载
#   --electron <path> 指定已安装的 Electron 二进制（旧版账户用）
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(dirname "$SCRIPT_DIR")"
RUNTIME_DIR="$SKILL_ROOT/.runtime"
ELECTRON_BIN="$RUNTIME_DIR/electron/Electron.app/Contents/MacOS/Electron"

echo "== WorkBuddy 每日签到 · 环境检查 =="

# ---------- 探测 Node（路径 B 需要：读登录态 + 跑 jget.js 解析 JSON）----------
find_node() {
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
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  # WorkBuddy 托管 Node（版本目录名随升级变化，故用通配而非写死）
  local managed
  for managed in "$HOME/.workbuddy/binaries/node/versions"/*/node \
                 "$HOME/.workbuddy/binaries/node/versions"/*/node.exe; do
    if [ -x "$managed" ]; then echo "$managed"; return 0; fi
  done
  return 1
}

# ---------- 探测 curl（PATH 可能被裁剪，含绝对路径兜底）----------
find_curl() {
  local c
  for c in "$(command -v curl 2>/dev/null)" \
           "/mingw64/bin/curl" \
           "/usr/bin/curl" \
           "${SYSTEMROOT:-}/System32/curl.exe" \
           "/c/Windows/System32/curl.exe" \
           "/usr/local/bin/curl" \
           "/opt/homebrew/bin/curl"; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}

# ---------- 探测已存在的 Electron（仅旧版 state.vscdb 回退需要）----------
detect_electron() {
  local cands=(
    "$HOME/.workbuddy/tools/electron/Electron.app/Contents/MacOS/Electron"
    "$HOME/.workbuddy/tools/electron/electron.exe"
    "$ELECTRON_BIN"
    "$RUNTIME_DIR/electron/electron.exe"
    "$(command -v electron 2>/dev/null)"
  )
  local c
  for c in "${cands[@]}"; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}

# ---------- 列出候选代理地址：环境变量优先，缺失时反查 WorkBuddy 监听端口 ----------
_PROXY_BASES_CACHE=""
discover_proxy_bases() {
  if [ -n "$_PROXY_BASES_CACHE" ]; then printf '%s\n' "$_PROXY_BASES_CACHE"; return; fi
  local bases=""
  if [ -n "${CODEBUDDY_SERVICE_PROXY_URL:-}" ]; then
    bases="${CODEBUDDY_SERVICE_PROXY_URL%/}"
  fi

  local ports="" ps_bin=""
  if command -v powershell.exe >/dev/null 2>&1; then
    ps_bin="powershell.exe"
  elif [ -x "${SYSTEMROOT:-}/System32/WindowsPowerShell/v1.0/powershell.exe" ]; then
    ps_bin="${SYSTEMROOT:-}/System32/WindowsPowerShell/v1.0/powershell.exe"
  elif [ -x "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]; then
    ps_bin="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  fi
  if [ -n "$ps_bin" ]; then
    # netstat 用绝对路径：精简 PATH 下 Git Bash 会把 PATH 翻成 Git 自己的目录，裸 netstat 解析不到
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
    ports=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
      | grep -iE 'workbuddy|codebuddy' | awk '{print $9}' | sed 's/.*://' | tr -d ' ')
  fi

  local p
  for p in $ports; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    bases="$bases
http://127.0.0.1:$p/internal/hooks/services/invoke"
  done

  _PROXY_BASES_CACHE=$(printf '%s\n' "$bases" | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++')
  printf '%s\n' "$_PROXY_BASES_CACHE"
}

# ---------- 路径 A 探测：本地服务代理是否可用（零凭据，不接触任何令牌）----------
# 回环请求加 --noproxy '*'：企业环境设了 http_proxy/https_proxy 时会误把 127.0.0.1 的请求丢给代理
probe_proxy() {
  local curl_bin base resp
  curl_bin="$(find_curl)" || return 1
  while IFS= read -r base; do
    [ -z "$base" ] && continue
    resp=$("$curl_bin" -s -m 10 --connect-timeout 2 --noproxy '*' -X POST \
      "${base}/..%2F..%2Fbilling%2Fmeter%2Fcheckin-activity-status" \
      -H "X-Service-Id: ${WB_CHECKIN_SERVICE_ID:-auth}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json' -d '{}' 2>/dev/null)
    case "$resp" in *'"code":0'*) return 0 ;; esac
  done < <(discover_proxy_bases)
  return 1
}

# ---------- 用 Node 探测登录态是否可读（不输出 token 内容）----------
probe_token_with_node() {
  local node_bin line
  node_bin="$(find_node)" || return 1
  line=$(cd "$SCRIPT_DIR" && "$node_bin" "decrypt-token.js" 2>/dev/null | grep "^DECRYPT_RESULT:" | head -1)
  [ -n "$line" ] || return 1
  case "$line" in
    DECRYPT_RESULT:ERR*) return 1;;   # 信封加密/文件缺失 → 纯 Node 解不开（预期行为）
    *) return 0;;
  esac
}

print_done() {
  echo ""
  echo "== 完成 =="
  echo "运行签到：  $SCRIPT_DIR/checkin.sh"
  echo "设置定时：  每天 09:00 示例 → crontab -e 添加："
  echo "  0 9 * * * $SCRIPT_DIR/checkin.sh >> $SKILL_ROOT/logs/checkin.log 2>&1"
}

chmod +x "$SCRIPT_DIR/checkin.sh" 2>/dev/null

# ============================================================
# 路径 A（首选，v1.1.0+）：桌面端本地服务代理 —— 零凭据
# ============================================================
if probe_proxy; then
  echo "✅ 检测到 WorkBuddy 本地服务代理，签到链路可用（路径 A）。"
  echo "   该路径由桌面端代为出网，全程不读取、不持有任何令牌，"
  echo "   也不需要 Node.js / Electron，且免疫登录态加密格式变更。"
  echo "   ⚠️ 前提：运行时 WorkBuddy 桌面端需处于运行状态。"
  print_done
  exit 0
fi

echo "（未检测到可用的本地服务代理：桌面端可能未在运行。继续尝试回退路径 B。）"
echo ""

# ============================================================
# 路径 B：读取本地登录态 → 直连云端
# ============================================================
if probe_token_with_node; then
  NODE_BIN="$(find_node)"
  echo "✅ 检测到 Node 可直读的登录态（v5.3.8 早期明文形态），令牌读取链路可用。"
  echo "   运行时：${NODE_BIN}（无需安装 Electron）"
  echo "   提示：若该形态变为信封加密，脚本会自动切回路径 A（推荐先确保桌面端在运行）。"
  print_done
  exit 0
fi

echo "（Node 未能直读登录态——新版信封加密属预期行为，按旧版 state.vscdb 流程处理。）"
echo ""

MODE="${1:-auto}"
ELECTRON=""

# 供应链安全：自动从 npm 下载第三方运行时（约 100MB）默认关闭，需显式开启。
# 推荐手动指定已校验的 Electron：setup.sh --electron /path/to/electron
if [ -z "${WB_CHECKIN_AUTO_INSTALL_ELECTRON:-}" ] && [ "$MODE" = "auto" ]; then
  if ELECTRON="$(detect_electron)"; then
    echo "✅ 已检测到 Electron：$ELECTRON"
  else
    echo "⚠️ 路径 A 不可用、Node 无法直读登录态、也未找到 Electron 运行时。"
    echo "   按优先级自查："
    echo "   1) 【最常见】确认 WorkBuddy 桌面端正在运行并已登录 —— 路径 A 只要桌面端在跑就可用，"
    echo "      无需任何运行时。先打开桌面端，再重新运行本脚本即可。"
    echo "   2) 确认已安装 Node.js（路径 B 读取明文登录态需要）。"
    echo "   3) 仅旧版 WorkBuddy/CodeBuddy（state.vscdb）账户才需要 Electron，二选一："
    echo "      a) 手动指定已校验的 Electron：  setup.sh --electron /path/to/electron"
    echo "      b) 确认要从官方 npm 下载（约 100MB），先执行："
    echo "           export WB_CHECKIN_AUTO_INSTALL_ELECTRON=1"
    echo "         再运行本脚本。"
    echo "   （手动放置后也可用环境变量 WB_CHECKIN_ELECTRON=<path> 直接运行 checkin.sh）"
    exit 1
  fi
else
  case "$MODE" in
    auto)
      if ELECTRON="$(detect_electron)"; then
        echo "✅ 已检测到 Electron：$ELECTRON"
      else
        echo "⚠️ 未检测到 Electron 运行时，尝试通过 npm 下载（约 100MB，需要 node/npm）..."
        echo "   ⚠️ 供应链提示：将从官方 npm registry 下载 electron@37 并执行，请确认网络可信。"
        command -v npm >/dev/null 2>&1 || { echo "❌ 未找到 npm，请先安装 Node.js，或手动放置 Electron 后重试"; exit 1; }
        mkdir -p "$RUNTIME_DIR"
        cd "$RUNTIME_DIR"
        npm init -y >/dev/null 2>&1
        npm install electron@37 >/dev/null 2>&1 || { echo "❌ Electron 下载失败（网络/代理问题），请手动安装"; exit 1; }
        mv node_modules/electron/dist "$RUNTIME_DIR/electron"
        rm -rf node_modules package.json package-lock.json
        ELECTRON="$ELECTRON_BIN"
        echo "✅ Electron 安装完成：$ELECTRON"
      fi
      ;;
    --electron)
      ELECTRON="${2:-}"
      [ -n "$ELECTRON" ] && [ -x "$ELECTRON" ] || { echo "❌ 指定的 Electron 不存在：$ELECTRON"; exit 1; }
      echo "✅ 使用指定 Electron：$ELECTRON"
      ;;
    *)
      echo "用法：$0 [--electron <path>]"; exit 1;;
  esac
fi

# ---------- 验证旧版解密链路 ----------
echo "== 验证令牌解密 =="
TOKEN=$(env -u ELECTRON_RUN_AS_NODE "$ELECTRON" "$SCRIPT_DIR/decrypt-token.js" 2>/dev/null \
  | grep "^DECRYPT_RESULT:" | sed 's/^DECRYPT_RESULT://')

if [ -z "$TOKEN" ] || [[ "$TOKEN" == ERR* ]]; then
  echo "❌ 解密失败（${TOKEN:-未知原因}）。请确认：1) 已安装并登录 WorkBuddy 桌面端且**正在运行**（路径 A 通常已足够）；2) 旧版账户应用名为 WorkBuddy（老版本 CodeBuddy 设 WB_CHECKIN_APP_NAME=CodeBuddy）；3) 新版信封加密登录态无法离线解密，请改用路径 A。"
  exit 1
fi

echo "✅ 令牌解密成功（长度 ${#TOKEN}）"
print_done
