#!/usr/bin/env node
/**
 * WorkBuddy 每日签到 - 令牌读取脚本（通用版，可分发）
 *
 * 优先读取 WorkBuddy v5.3.8+ 的新版明文登录态；缺失时回退到旧版
 * state.vscdb + Electron safeStorage 解密。最终输出 accessToken。
 *
 * ⚠️ 安全警示（务必阅读）：
 *   - 本脚本输出的 accessToken 等同 WorkBuddy 账号密码，属于高敏感凭据。
 *   - token 仅通过 stdout 的 `DECRYPT_RESULT:<token>` 单行输出，由调用方（checkin.sh/ps1）
 *     经管道立即消费；切勿 `tee`/重定向到文件、切勿粘贴分享、切勿提交到任何仓库。
 *   - 日志只记录签到结果（积分/连续天数），绝不记录 token 原文。
 *   - 读取/解密成功时会向 stderr 打印一行安全提示（不进入 stdout，不会污染 token 管道）。
 *
 * 依赖：
 *   - 新版明文分支：仅需 Node.js（无版本特殊要求），纯 Node 读取 JSON。
 *   - 旧版 state.vscdb 分支：需要 Electron 运行时（≥ 30，使用 node:sqlite + safeStorage）。
 *
 * 运行方式（两种都支持，调用方按运行时可用性选择）：
 *   node decrypt-token.js                                          # 新版明文优先，纯 Node 即可
 *   env -u ELECTRON_RUN_AS_NODE <electron二进制> decrypt-token.js  # 旧版回退需要 Electron
 *
 * 输出：stdout 单行 `DECRYPT_RESULT:<accessToken>`；失败输出 DECRYPT_RESULT:ERR ...
 *
 * 跨平台登录态位置：
 *   新版明文（v5.3.8+，主路径）：
 *     - macOS:   ~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info
 *     - Windows: %APPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info
 *     - Linux:   ~/.config/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info
 *   旧版 state.vscdb（回退路径，兼容 WorkBuddy / CodeBuddy 早期版本）：
 *     - macOS:   ~/Library/Application Support/{WorkBuddy,CodeBuddy}/User/globalStorage/state.vscdb
 *     - Windows: %APPDATA%\{WorkBuddy,CodeBuddy}\User\globalStorage\state.vscdb
 *     - Linux:   ~/.config/{WorkBuddy,CodeBuddy}/User/globalStorage/state.vscdb
 */
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

// Electron 仅旧版 state.vscdb 分支需要；try/catch 使脚本可在纯 node 下执行。
// 新版明文分支不依赖 Electron，require 失败时自动跳过旧版分支。
let app = null;
let safeStorage = null;
try {
  const electron = require("electron");
  app = electron.app || null;
  safeStorage = electron.safeStorage || null;
} catch (e) {
  // 纯 Node 运行（无 Electron）：仅新版明文分支可用，旧版 state.vscdb 分支自动禁用。
}

// ---------- 统一输出：同步 flush 后立即退出 ----------
// 旧实现 setTimeout(200ms) 在 bash 命令替换 $(...) 上下文里会因 pipe 提前关闭
// 导致 token 截断/丢失。改为 write 后立即退出，由 Node 内置 stdout 缓冲自行处理。
function emitAndExit(code, line) {
  process.stdout.write(line + "\n");
  // 同步退出，避免延迟导致调用方管道截断 token
  if (app && typeof app.exit === "function") {
    app.exit(code);
  } else {
    process.exit(code);
  }
}

// ---------- 新版明文认证文件候选路径（按平台） ----------
function desktopAuthFileCandidates() {
  const home = os.homedir();
  const ap = process.env.APPDATA || "";
  const xdg = process.env.XDG_CONFIG_HOME || path.join(home, ".config");
  const rel = path.join(
    "CodeBuddyExtension",
    "Data",
    "Public",
    "auth",
    "workbuddy-desktop.info",
  );
  if (process.platform === "darwin") {
    return [path.join(home, "Library", "Application Support", rel)];
  }
  if (process.platform === "win32") {
    // WorkBuddy v5.3.8+ 桌面端实际写入 LOCALAPPDATA（AppData\\Local），而不是
    // APPDATA（AppData\\Roaming）。SKILL 旧版本只认 APPDATA，导致 Windows
    // 主路径探测失败、退回到旧版 state.vscdb 分支。两路都返回，按探测先后命中。
    const lap = process.env.LOCALAPPDATA || "";
    return [
      path.join(lap, rel),       // WorkBuddy v5.3.8+ 实际位置（AppData\\Local）
      path.join(ap, rel),        // 历史 SKILL 路径（AppData\\Roaming，向后兼容）
    ];
  }
  return [path.join(xdg, rel)];
}

// ---------- 旧版 state.vscdb 会话库候选路径（按优先级） ----------
function legacyVscdbCandidates() {
  const home = os.homedir();
  const ap = process.env.APPDATA || "";
  const xdg = process.env.XDG_CONFIG_HOME || path.join(home, ".config");
  const apps = ["WorkBuddy", "CodeBuddy"];
  const roots =
    process.platform === "darwin"
      ? apps.map((a) => path.join(home, "Library", "Application Support", a))
      : process.platform === "win32"
        ? apps.map((a) => path.join(ap, a))
        : apps.map((a) => path.join(xdg, a));
  return roots.map((r) => path.join(r, "User", "globalStorage", "state.vscdb"));
}

// ---------- 旧版会话 key 候选 ----------
const SESSION_KEYS = [
  'secret://{"extensionId":"tencent-cloud.coding-copilot","key":"planning-genie.new.accessTokencn"}',
];

// ---------- 读取 vscdb（node:sqlite 优先，失败回退 python3，需显式开启） ----------
// 安全说明：python3 回退会扩展本地执行信任边界（调用外部解释器读取凭据库）。
// 默认关闭；仅在确需回退时设置 WB_CHECKIN_ALLOW_PY_FALLBACK=1 启用。
function readValue(dbPath, key) {
  try {
    const { DatabaseSync } = require("node:sqlite");
    const db = new DatabaseSync(dbPath, { readOnly: true });
    const row = db.prepare("SELECT value FROM ItemTable WHERE key = ?").get(key);
    db.close();
    return row ? row.value : null;
  } catch (e) {
    if (process.env.WB_CHECKIN_ALLOW_PY_FALLBACK !== "1") {
      throw new Error(
        "无法用 node:sqlite 读取会话数据库，且未开启 python3 回退。" +
        "如需回退请设置 WB_CHECKIN_ALLOW_PY_FALLBACK=1（会调用外部 python3 解释器）"
      );
    }
    // node:sqlite 不可用时，用 python3 读（macOS/Linux 一般自带）
    try {
      const script =
        "import sqlite3,sys,json;c=sqlite3.connect(sys.argv[1]);r=c.execute('SELECT value FROM ItemTable WHERE key=?',(sys.argv[2],)).fetchone();print(json.dumps(r[0]) if r else '')";
      const out = execFileSync("python3", [ "-c", script, dbPath, key ], {
        encoding: "utf8",
        timeout: 15000,
      }).trim();
      return out ? JSON.parse(out) : null;
    } catch (e2) {
      throw new Error("无法读取会话数据库(需要 node:sqlite 或 python3): " + e2.message);
    }
  }
}

function toBuffer(parsed) {
  if (parsed && parsed.type === "Buffer" && Array.isArray(parsed.data)) return Buffer.from(parsed.data);
  if (typeof parsed === "string") return Buffer.from(parsed, "base64");
  if (Buffer.isBuffer(parsed)) return parsed;
  return null;
}

// ---------- 纯 Node 解密旧版 state.vscdb（Chromium v10 + DPAPI 主密钥） ----------
// 旧版 WorkBuddy 把 accessToken 以 Chromium OS-Crypt 格式存入 state.vscdb：
//   v10 || 12B nonce || ciphertext || 16B tag   （AES-256-GCM）
// 主密钥（32B）存在 %APPDATA%\WorkBuddy\Local State 的 os_crypt.encrypted_key，
// 前缀 "DPAPI" + DPAPI 密文；DPAPI 解封须由 Windows 宿主完成，故调用 PowerShell。
function localStateCandidates() {
  const ap = process.env.APPDATA || "";
  const apps = ["WorkBuddy", "CodeBuddy", "WorkBuddy Beta"];
  return apps.map((a) => path.join(ap, a, "Local State"));
}

function dpapiUnseal(base64Blob) {
  const ps = [
    "$ErrorActionPreference='Stop'",
    "Add-Type -AssemblyName System.Security | Out-Null",
    "$b = [Convert]::FromBase64String($env:WB_DPAPI_BLOB)",
    "$k = [System.Security.Cryptography.ProtectedData]::Unprotect($b, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)",
    "[Convert]::ToBase64String($k)",
  ].join("; ");
  try {
    const out = execFileSync(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", ps],
      {
        encoding: "utf8",
        timeout: 20000,
        env: Object.assign({}, process.env, { WB_DPAPI_BLOB: base64Blob }),
      },
    ).trim();
    return out ? Buffer.from(out, "base64") : null;
  } catch (e) {
    return null;
  }
}

function getOsCryptMasterKey() {
  for (const f of localStateCandidates()) {
    if (!fs.existsSync(f)) continue;
    try {
      const j = JSON.parse(fs.readFileSync(f, "utf8"));
      const enc = j && j.os_crypt && j.os_crypt.encrypted_key;
      if (!enc) continue;
      const raw = Buffer.from(enc, "base64");
      // 去掉 "DPAPI" 前缀（5 字节）后即为 DPAPI 密文，需宿主解密
      let blob = raw;
      if (raw.slice(0, 5).toString("latin1") === "DPAPI") blob = raw.slice(5);
      const key = dpapiUnseal(blob.toString("base64"));
      if (key && key.length === 32) return key;
    } catch (e) {
      // 换下一个候选
    }
  }
  return null;
}

function tryDecryptLegacyVscdbNative() {
  // 1) 取密文：state.vscdb ItemTable 中的会话条目
  let buf = null;
  for (const p of legacyVscdbCandidates()) {
    if (!fs.existsSync(p)) continue;
    for (const k of SESSION_KEYS) {
      let v = null;
      try { v = readValue(p, k); } catch (e) { continue; }
      if (!v) continue;
      try {
        const parsed = JSON.parse(v);
        const b = toBuffer(parsed);
        if (b && b.length > 28) { buf = b; break; }
      } catch (e) { /* 继续 */ }
    }
    if (buf) break;
  }
  if (!buf) return null;

  // 2) 取主密钥（DPAPI 解封）
  const key = getOsCryptMasterKey();
  if (!key) {
    process.stderr.write("[诊断] 无法取得本机 OS-Crypt 主密钥（DPAPI 解封失败）\n");
    return null;
  }

  // 3) 解密 v10 负载
  try {
    const crypto = require("crypto");
    const payload = buf.slice(3); // 去 "v10"
    const nonce = payload.slice(0, 12);
    const tag = payload.slice(payload.length - 16);
    const ct = payload.slice(12, payload.length - 16);
    const d = crypto.createDecipheriv("aes-256-gcm", key, nonce);
    d.setAuthTag(tag);
    const plain = Buffer.concat([d.update(ct), d.final()]).toString("utf8");
    // 4) 从明文（JSON 或裸串）中取 accessToken
    try {
      const obj = JSON.parse(plain);
      const tok =
        typeof obj === "string"
          ? obj
          : (obj && (obj.accessToken || (obj.auth && obj.auth.accessToken)));
      if (tok && typeof tok === "string") return tok;
    } catch (e) {
      if (plain && plain.length > 20) return plain.trim();
    }
  } catch (e) {
    process.stderr.write("[诊断] v10 负载解密失败: " + e.message + "\n");
  }
  return null;
}

// ============================================================
// 0. 新版信封加密登录态（WorkBuddy 桌面端新版，纯 Node 即可解密）
// ============================================================
// 新版 ~/AppData/Local/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info
// 的 auth.accessToken 不再是明文字符串，而是信封对象：
//   { $wbEncrypted: 1, envelope: base64(JSON { suite, keyId, nonce, authTag, ciphertext }) }
// 加密套件 suite=1：AES-256-GCM，密钥来自 ~/.workbuddy/keyblob（同一 envelope 格式），
// keyblob 的 slot 内 wrapped 字段由 Windows DPAPI（CryptProtectData，CurrentUser 作用域）
// 保护。DPAPI 只能由宿主 Node 进程经 PowerShell ProtectedData 解封，故此处以
// 子进程方式调用 PowerShell 完成解封，密钥仅在内存中流转，不落盘、不打印。

// 同一 envelope 结构解包（不打印任何密文内容）
function parseEnvelope(envStr) {
  const obj = JSON.parse(Buffer.from(envStr, "base64").toString("utf8"));
  if (obj && obj.$wbEncrypted) return parseEnvelope(obj.envelope);
  return obj;
}

// ---------- AtRest 信封解密（suite=1 / AES-256-GCM / scheme=sym-v1 / framing=file） ----------
// 与桌面端实现严格对齐（逆向自 codebuddy-headless.js）：
//   AAD = "WB-AAD\0" | 0x01 | LP("WBEF1") | LP("sym-v1") | uint32BE(suite)
//         | LP(keyId) | 0x01(file) | 0x00 | 0x00/0x01/0x02(final 未设)
//   LP(x) = uint32BE(byteLen) | bytes(utf8)
function encodeUint32(v) {
  const b = Buffer.allocUnsafe(4);
  b.writeUInt32BE(v);
  return b;
}
function encodeLengthPrefixed(s) {
  const b = Buffer.from(s, "utf8");
  return Buffer.concat([encodeUint32(b.length), b]);
}
function buildAad(keyId, suite) {
  return Buffer.concat([
    Buffer.from("WB-AAD\0", "ascii"),
    Buffer.from([1]),
    encodeLengthPrefixed("WBEF1"),   // framing: file
    encodeLengthPrefixed("sym-v1"),  // scheme
    encodeUint32(suite),
    encodeLengthPrefixed(keyId),
    Buffer.from([1]),                // framing code: file = 1
    Buffer.from([0]),                // sequence: 无
    Buffer.from([0]),                // final: 未设置 = 0
  ]);
}
function deriveKeyId(key) {
  return require("crypto").createHash("sha256").update(key).digest("hex").slice(0, 16);
}

function decryptEnvelope(env, keyBuf) {
  const crypto = require("crypto");
  if (env.suite !== 1) throw new Error("unsupported suite " + env.suite);
  if (env.keyId !== deriveKeyId(keyBuf)) throw new Error("keyId mismatch");
  const nonce = Buffer.from(env.nonce, "base64");
  const tag = Buffer.from(env.authTag, "base64");
  const ct = Buffer.from(env.ciphertext, "base64");
  const decipher = crypto.createDecipheriv("aes-256-gcm", keyBuf, nonce, { authTagLength: 16 });
  decipher.setAAD(buildAad(env.keyId, env.suite));
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ct), decipher.final()]).toString("utf8");
}

// 用 DPAPI 解封 keyblob 中的静态密钥（PowerShell CurrentUser 作用域）
function unwrapStaticKey() {
  const keyblobPath = path.join(os.homedir(), ".workbuddy", "keyblob");
  if (!fs.existsSync(keyblobPath)) return null;
  const blob = JSON.parse(fs.readFileSync(keyblobPath, "utf8"));
  const slot = Array.isArray(blob.slots) && blob.slots[0];
  if (!slot || !slot.wrapped) return null;
  try {
    // keyblob 的 slot.wrapped 由与凭据同一族的 AtRest 信封保护；protector key 由桌面端托管。
    // 若本机无该 protector，则此路不可用（静默回退到 state.vscdb 路径）。
    const env = parseEnvelope(slot.wrapped);
    const protector = process.env.WB_CHECKIN_PROTECTOR_KEY;
    if (!protector) return null;
    const key = Buffer.from(protector, "base64");
    if (key.length !== 32) return null;
    const plain = JSON.parse(decryptEnvelope(env, key));
    const wrappedKey = Buffer.from(plain.atRestSecretKey || "", "base64");
    if (wrappedKey.length !== 32) return null;
    return { key: wrappedKey };
  } catch (e) {
    return null;
  }
}

// 读取新版加密登录态；成功返回 token 字符串，失败返回 null（由后续分支兜底）
// 注：信封密钥（keyblob）当前无法用 DPAPI 解封（protector 非本机 DPAPI blob），
// 静默跳过即可；旧版 state.vscdb 分支已有可用的纯 Node 解密路径。
function readEncryptedDesktopToken() {
  for (const f of desktopAuthFileCandidates()) {
    if (!fs.existsSync(f)) continue;
    let j;
    try { j = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { continue; }
    const at = j && j.auth && j.auth.accessToken;
    if (!at) continue;
    if (typeof at === "string") return at; // 老版明文，直接可用
    if (!at.$wbEncrypted || !at.envelope) continue;
    let env;
    try { env = parseEnvelope(at.envelope); } catch (e) { continue; }
    const unwrapped = unwrapStaticKey();
    if (!unwrapped || unwrapped.err) continue; // 无法解封密钥：静默兜底
    try {
      const plain = decryptEnvelope(env, unwrapped.key);
      const parsed = JSON.parse(plain);
      const tok =
        typeof parsed === "string"
          ? parsed
          : (parsed && (parsed.accessToken || (parsed.auth && parsed.auth.accessToken)));
      if (tok && typeof tok === "string") return tok;
    } catch (e) {
      // 解密失败：静默兜底
    }
  }
  return null;
}

// ---------- 1. 新版明文认证文件（WorkBuddy v5.3.8+，纯 Node 读取，优先）----------
// 命中且含 accessToken 即输出；文件缺失 / 无 token / 解析失败均不硬失败，
// 统一落入下方旧版 state.vscdb 分支兜底（覆盖升级中途、文件写入中等场景）。
const encryptedToken = readEncryptedDesktopToken();
if (encryptedToken) {
  process.stderr.write(
    "[安全提示] 已从本地登录态读取 accessToken（新版信封加密存储），仅用于 WorkBuddy 官方签到接口；" +
    "请勿将其写入日志、分享或提交。\n"
  );
  emitAndExit(0, "DECRYPT_RESULT:" + encryptedToken);
  return;
}

for (const f of desktopAuthFileCandidates()) {
  if (!fs.existsSync(f)) continue;
  try {
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    const token = j && j.auth && j.auth.accessToken;
    if (token && typeof token === "string") {
      process.stderr.write(
        "[安全提示] 已从本地登录态读取 accessToken（新版明文存储），仅用于 WorkBuddy 官方签到接口；" +
        "请勿将其写入日志、分享或提交。\n"
      );
      emitAndExit(0, "DECRYPT_RESULT:" + token);
      return;
    }
    // 文件存在但无 accessToken：落入旧版分支兜底
  } catch (e) {
    // 解析失败（文件损坏 / 写入中）：忽略，落入旧版分支兜底
  }
}

// ---------- 2. 回退：旧版 state.vscdb ----------
// 两条解密路径：
//   (a) Electron safeStorage（需 Electron 运行时，最稳，优先）
//   (b) 纯 Node：凭据实为 Chromium 风格 v10 AES-256-GCM，主密钥在
//       %APPDATA%\WorkBuddy\Local State 的 os_crypt.encrypted_key（DPAPI 保护），
//       经 PowerShell ProtectedData 解封后本地解密。全程本机内存，不落盘、不打印。
if (!app || !safeStorage) {
  const nativeToken = tryDecryptLegacyVscdbNative();
  if (nativeToken) {
    process.stderr.write(
      "[安全提示] 已从本地会话解密 accessToken（旧版 state.vscdb，纯 Node + 本机 DPAPI），" +
      "仅用于 WorkBuddy 官方签到接口；请勿将其写入日志、分享或提交。\n"
    );
    emitAndExit(0, "DECRYPT_RESULT:" + nativeToken);
    return;
  }
  // 纯 Node 运行且无新版明文文件：给出明确指引。
  emitAndExit(
    6,
    "DECRYPT_RESULT:ERR 未找到可解密的本机登录态（新版明文/加密登录态与旧版 state.vscdb 均未命中）。" +
    "请确认已安装并登录 WorkBuddy 桌面端 v5.3.8+，或打开桌面端刷新登录态后重试。"
  );
  return;
}

// 注意：app.setName 必须在 ready 之前调用，否则 safeStorage 会以默认应用名
// 绑定钥匙串服务，导致解不到 WorkBuddy 的密钥。旧版应用名可通过环境变量覆盖。
const APP_NAME = process.env.WB_CHECKIN_APP_NAME || "WorkBuddy";
app.setName(APP_NAME);

let dbPath = null;
let raw = null;
let legacyReadErr = null;
for (const p of legacyVscdbCandidates()) {
  if (!fs.existsSync(p)) continue;
  for (const k of SESSION_KEYS) {
    try {
      const v = readValue(p, k);
      if (v) { dbPath = p; raw = v; break; }
    } catch (e) {
      legacyReadErr = e; // 记录但不中断，继续尝试其他候选 key/库
    }
  }
  if (raw) break;
}
if (!raw) {
  // 读取旧版库本身报错时附带原因，避免「未知原因」式失败（issue #68 投诉点）
  const hint = legacyReadErr ? "（读取旧版 state.vscdb 失败：" + legacyReadErr.message + "）" : "";
  emitAndExit(2, "DECRYPT_RESULT:ERR 未找到 WorkBuddy 本地登录态（新版明文文件与旧版 state.vscdb 均未命中" + hint + "，请先安装并登录 WorkBuddy 桌面端）");
  return;
}

app.whenReady().then(() => {
  if (!safeStorage.isEncryptionAvailable()) {
    emitAndExit(3, "DECRYPT_RESULT:ERR 系统加密不可用");
    return;
  }
  try {
    const buf = toBuffer(JSON.parse(raw));
    if (!buf) throw new Error("未知的存储格式");
    const decrypted = safeStorage.decryptString(buf);
    const session = JSON.parse(decrypted);
    const token = session && session.auth && session.auth.accessToken;
    if (token) {
      process.stderr.write(
        "[安全提示] 已从本地会话解密 accessToken（旧版 state.vscdb），仅用于 WorkBuddy 官方签到接口；" +
        "请勿将其写入日志、分享或提交。\n"
      );
      emitAndExit(0, "DECRYPT_RESULT:" + token);
      return;
    }
    emitAndExit(4, "DECRYPT_RESULT:ERR 会话中无 accessToken");
  } catch (e) {
    emitAndExit(
      4,
      "DECRYPT_RESULT:ERR 解密失败(" + e.message +
      ")。若为旧版应用（CodeBuddy），请设置环境变量 WB_CHECKIN_APP_NAME=CodeBuddy 后重试；" +
      "或打开 WorkBuddy 桌面端刷新登录态"
    );
  }
});
