#!/usr/bin/env bash
# verify.sh —— bundle 离线验收（模拟内网级别1：死外网 + 全新 HOME + 本地 mock）
# 用法: verify.sh <bundle-dir|bundle.tar.gz> [--skip-tui]
set -euo pipefail
BUNDLE="${1:?usage: verify.sh <bundle-dir|bundle.tar.gz> [--skip-tui]}"
SKIP_TUI=0
[ "${2:-}" = "--skip-tui" ] && SKIP_TUI=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=()

pass() { echo "[verify] PASS: $1"; }
fail() { echo "[verify] FAIL: $1"; FAILURES+=("$1"); }

# ── 准备：解压 + 干净 HOME（放 work/ 下，避免挤爆小 tmpfs）────────────────────
mkdir -p "$SCRIPT_DIR/../work"
TMP="$(mktemp -d "$SCRIPT_DIR/../work/verify.XXXXXX")"
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR"
VERIFY_OK=0
trap 'kill ${MOCK_PID:-} ${OLLAMA_PID:-} 2>/dev/null || true; sleep 1; [ "$VERIFY_OK" = 1 ] && rm -rf "$TMP" 2>/dev/null || true' EXIT

if [ -f "$BUNDLE" ]; then
  case "$BUNDLE" in
    *.zip)
      # win32-x64 zip：本机不可运行 → 完整性检查后 SKIP（发布标注 unverified）
      if command -v unzip >/dev/null 2>&1 && ! unzip -tq "$BUNDLE" >/dev/null 2>&1; then
        echo "[verify] FAIL: zip 完整性检查失败"
        exit 1
      fi
      echo "[verify] SKIP: win32-x64 zip（完整性检查通过；本机不可运行，发布标注 unverified）"
      VERIFY_OK=1
      exit 0
      ;;
  esac
  tar -xzf "$BUNDLE" -C "$TMP"
  BUNDLE_DIR="$(echo "$TMP"/opencode-*-onprem*)"
else
  BUNDLE_DIR="$(cd "$BUNDLE" && pwd)"
fi
echo "[verify] bundle: $BUNDLE_DIR"

# 平台门控：verify 需要在本机运行 bundle 二进制，仅 linux-x64 支持完整套件
BPLATFORM="$(sed -n 's/.*"platform": *"\([^"]*\)".*/\1/p' "$BUNDLE_DIR/MANIFEST.json" 2>/dev/null | head -1 || echo unknown)"
if [ "$BPLATFORM" != "linux-x64" ]; then
  echo "[verify] SKIP: 平台为 $BPLATFORM，本机验证不可行（发布需标注 unverified）"
  VERIFY_OK=1
  exit 0
fi

# ── mock 端点 ──────────────────────────────────────────────────────────────────
TESTS_DIR="$(cd "$SCRIPT_DIR/../tests" && pwd)"
for p in 8902 11434; do
  if curl -s -m 1 -o /dev/null "127.0.0.1:$p" 2>/dev/null; then
    fail "前置检查: 端口 $p 已被占用（残留进程会污染断言，请先清理）"
  fi
done
python3 "$TESTS_DIR/mock-llm.py" & MOCK_PID=$!
python3 "$TESTS_DIR/mock-ollama.py" & OLLAMA_PID=$!
for i in $(seq 1 20); do
  curl -s -m 1 localhost:8902/v1/models >/dev/null 2>&1 && curl -s -m 1 localhost:11434/api/tags >/dev/null 2>&1 && break
  sleep 0.3
done
curl -s -m 2 localhost:8902/v1/models >/dev/null || { fail "mock-llm 未就绪"; }
curl -s -m 2 localhost:11434/api/tags >/dev/null || { fail "mock-ollama 未就绪"; }

# ── 安装（临时 prefix，无需 root）+ 用户侧种子（独立 seed.sh）───────────────
# -u 清掉 runner 预设的 XDG_*，确保全部落在干净 HOME
env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u XDG_STATE_HOME HOME="$HOME_DIR" \
  bash "$BUNDLE_DIR/install.sh" --prefix "$TMP/opt" >/dev/null
env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u XDG_STATE_HOME HOME="$HOME_DIR" \
  bash "$TMP/opt/seed.sh"

# ── A9: 配置 schema 独立目录 + 外部引用递归本地化 + omo-slim schema ─────────────
[ -f "$TMP/opt/schema/config.json" ] && pass "A9 bundle 含配置 schema 目录（schema/config.json）" || fail "A9 bundle 缺 schema/config.json"
grep -q '"./schema/config.json"' "$TMP/opt/config/opencode.airgap.jsonc" 2>/dev/null \
  && pass "A9 模板 \$schema 指向本地" || fail "A9 模板仍指向远程 schema"
jq -e '[.. | objects | .["$ref"]? | strings | select(test("^https?://"))] | length == 0' "$TMP/opt/schema/config.json" >/dev/null 2>&1 \
  && pass "A9 schema 无残留远程 \$ref（已递归本地化）" || fail "A9 schema 仍含远程 \$ref"
jq -e '[.. | objects | .["$ref"]? | strings | select(startswith("models.dev-model-schema.json#"))] | length > 0' "$TMP/opt/schema/config.json" >/dev/null 2>&1 \
  && pass "A9 外部引用改写为本地文件" || fail "A9 外部引用未本地化"
[ -f "$TMP/opt/schema/models.dev-model-schema.json" ] && pass "A9 models.dev schema 已随包" || fail "A9 缺 models.dev-model-schema.json"
[ -f "$TMP/opt/schema/oh-my-opencode-slim.json" ] && pass "A9 omo-slim schema 已随包" || fail "A9 缺 oh-my-opencode-slim.json"

# ── 测试环境：fresh HOME + env.sh + 死外网 + LiteLLM 式 provider 配置 ─────────
export HOME="$HOME_DIR"
# runner 可能预设 XDG_*，会让 opencode 读写真实用户目录 —— 全程隔离
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME 2>/dev/null || true
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9
export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
export NO_PROXY="127.0.0.1,localhost,::1"
export no_proxy="$NO_PROXY"
# shellcheck disable=SC1091
source "$TMP/opt/env.sh"   # 离线开关由随包 env.sh 提供（同时验证其存在与生效）

# 测试配置（provider 覆盖模板；plugins 从 MANIFEST 生成 —— 与 build 注入模板同源）
mkdir -p "$HOME/.config/opencode"
python3 - "$TMP/opt/MANIFEST.json" "$HOME/.config/opencode/opencode.jsonc" <<'PYEOF'
import json, sys
specs = [p["spec"] for p in json.load(open(sys.argv[1]))["plugins"] if p.get("default") == "on"]
cfg = {
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "localtest": {
      "name": "Local Test",
      "npm": "@opencode/ai/providers/openai-compatible",
      "options": { "baseURL": "http://127.0.0.1:8902/v1", "apiKey": "dummy" },
      "models": { "mock-7b": { "name": "Mock 7B", "tools": True } }
    }
  },
  "model": "localtest/mock-7b",
  "plugins": specs,
}
json.dump(cfg, open(sys.argv[2], "w"), indent=2, ensure_ascii=False)
PYEOF

# 前置：vendored 插件必须全部由 seed.sh 落地（config 引用未落地插件会阻塞 model.list）
while IFS= read -r KEY; do
  [ -n "$KEY" ] || continue
  ls "$HOME/.cache/opencode/npm/$KEY"/*/node_modules/*/package.json >/dev/null 2>&1 \
    || fail "前置: 插件缓存未落地 $KEY（后续断言结果无效）"
done < <(ls "$TMP/opt/assets/npm")

oc() { timeout 120 opencode "$@"; }
LOG_DIR="$HOME/.local/share/opencode/log"

# A1: 等待 provider 就绪（冷机插件激活可能数十秒）→ 只列本地 provider
READY_OUT=""
READY=0
for i in $(seq 1 40); do
  READY_OUT="$(oc --standalone models 2>&1 || true)"
  echo "$READY_OUT" | grep -q "localtest/mock-7b" && { READY=1; break; }
  sleep 3
done
OUT="$READY_OUT"
[ "$READY" = 1 ] && pass "A1 provider 就绪" || fail "A1 provider 120s 未就绪: $(echo "$OUT" | tail -3)"
echo "$OUT" | grep -q "localtest/mock-7b" && pass "A1 本地 provider 列出" || fail "A1 本地 provider 未列出: $OUT"
if echo "$OUT" | grep -qE "opencode-go/|deepseek/"; then fail "A1 云端 provider 未被隐藏"; else pass "A1 云端 provider 已隐藏"; fi

# A2: 推理
OUT="$(oc --standalone run -m localtest/mock-7b "say hi" 2>&1 || true)"
echo "$OUT" | grep -q "PONG from mock local model" && pass "A2 推理" || fail "A2 推理: $(echo "$OUT" | tail -3)"

# A3: shell 工具闭环
OUT="$(oc --standalone run --auto -m localtest/mock-7b "run the echo tool" 2>&1 || true)"
echo "$OUT" | grep -q "Tool ran and printed: hello-from-local-tool" && pass "A3 shell 工具闭环" || fail "A3 工具闭环: $(echo "$OUT" | tail -3)"

# A4: rg 本地命中 + 无 GitHub 下载尝试
command -v rg >/dev/null || fail "A4 rg 不在 PATH"
rg --version >/dev/null 2>&1 && pass "A4 rg 可用" || fail "A4 rg 不可执行"
[ ! -e "$HOME/.cache/opencode/bin/rg" ] && pass "A4 rg 未复制到用户缓存（仅 PREFIX/bin）" || fail "A4 rg 被多余复制到用户缓存"
if [ -d "$LOG_DIR" ] && grep -rq "github.com/BurntSushi" "$LOG_DIR" 2>/dev/null; then
  fail "A4 日志出现 ripgrep GitHub 下载尝试"
else
  pass "A4 无 ripgrep 下载尝试"
fi

# A5: TUI 高亮（tree-sitter 种子生效，无报错刷屏）
if [ "$SKIP_TUI" = 0 ]; then
  env HOME="$HOME_DIR" timeout 45 script -qec "opencode --standalone --prompt 'show me a python code sample' --log-level debug" /dev/null </dev/null >/dev/null 2>&1 || true
  sleep 2
  if [ -d "$LOG_DIR" ]; then
    if grep -rq "No parser available" "$LOG_DIR" 2>/dev/null; then
      fail "A5 日志出现 No parser available（高亮种子未生效）"
    else
      pass "A5 无 parser 报错刷屏"
    fi
    if grep -rq "Downloading from URL" "$LOG_DIR" 2>/dev/null; then
      fail "A5 日志出现 tree-sitter 远程下载"
    else
      pass "A5 无 tree-sitter 远程下载"
    fi
  else
    fail "A5 无日志目录（TUI 未启动？）"
  fi
fi

# A6: 无致命错误
if [ -d "$LOG_DIR" ] && grep -rqiE "Server process exited|FATAL" "$LOG_DIR" 2>/dev/null; then
  fail "A6 日志出现致命错误: $(grep -rhiE 'Server process exited|FATAL' "$LOG_DIR" | head -2)"
else
  pass "A6 无致命错误"
fi

# A7: 零配置 Ollama 自动发现 + 推理
OLLAMA_OK=0
for i in $(seq 1 20); do
  OUT="$(oc --standalone models 2>&1 || true)"
  echo "$OUT" | grep -q "ollama/qwen3:8b" && { OLLAMA_OK=1; break; }
  sleep 3
done
[ "$OLLAMA_OK" = 1 ] && pass "A7 Ollama 自动发现" || fail "A7 Ollama 未发现"
if [ "$OLLAMA_OK" = 1 ]; then
  OUT="$(oc --standalone run -m ollama/qwen3:8b "say hi" 2>&1 || true)"
  echo "$OUT" | grep -q "PONG from fake ollama" && pass "A7 Ollama 推理" || fail "A7 Ollama 推理: $(echo "$OUT" | tail -3)"
fi

# A8: vendored 插件离线加载（前置已验缓存落地；此处核对数量与 config 注入）
N_VENDORED="$(ls "$TMP/opt/assets/npm" | wc -l)"
[ "$N_VENDORED" -ge 5 ] && pass "A8 目录覆盖 $N_VENDORED 个 vendored 插件" || fail "A8 目录数量异常: $N_VENDORED"
grep -q "oh-my-opencode-slim" "$HOME/.config/opencode/opencode.jsonc" 2>/dev/null \
  && grep -q "billion-context" "$HOME/.config/opencode/opencode.jsonc" \
  && grep -q "opencode-auto-permissions" "$HOME/.config/opencode/opencode.jsonc" \
  && pass "A8 config 含默认启用插件（模板注入）" || fail "A8 config 缺默认启用插件"
grep -q "opencode-litellm@git\|superpowers@git" "$HOME/.config/opencode/opencode.jsonc" \
  && fail "A8 非 default 插件不应注入 config" || pass "A8 仅默认启用插件注入 config"

# ── 结果 ──────────────────────────────────────────────────────────────────────
echo "[verify] =================================================="
if [ ${#FAILURES[@]} -eq 0 ]; then
  echo "[verify] ALL PASS"
  VERIFY_OK=1
  exit 0
else
  echo "[verify] ${#FAILURES[@]} FAILURE(S):"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  echo "[verify] 调试现场保留: $TMP"
  exit 1
fi
