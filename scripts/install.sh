#!/usr/bin/env bash
# opencode v2 onprem bundle 安装脚本 —— 主安装只做拷贝（二进制/资产/schema/配置/env.sh → PREFIX），不生成任何文件
#
# 管理员安装（不写 /usr/local/bin）:
#   sudo ./install.sh                    # 默认 /opt/opencode
#   sudo ./install.sh --prefix /opt/opencode
# 无 root 备选:
#   ./install.sh --user                  # bin → ~/.local/bin，assets → ~/.local/share/opencode-onprem
#
# 用户侧（source $PREFIX/env.sh 之后）:
#   install.sh --seed                    # per-user 缓存：TUI 高亮 + 全部 vendored 插件（幂等；rg 在 PREFIX/bin，无需拷贝）
#   install.sh --config                  # 新装：复制模板 + 本地 schema；已有配置：jq 迁移（不覆盖用户设置）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="/opt/opencode"
DO_SEED=0
DO_CONFIG=0
USER_MODE=0
GOT_ACTION=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --user) USER_MODE=1; GOT_ACTION=1; shift ;;
    --seed) DO_SEED=1; GOT_ACTION=1; shift ;;
    --config) DO_CONFIG=1; GOT_ACTION=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
XDG_CONF="${XDG_CONFIG_HOME:-$HOME/.config}"

# 主安装（默认调用或 --user）：纯拷贝
if [ "$GOT_ACTION" = 0 ] || [ "$USER_MODE" = 1 ]; then
  if [ "$USER_MODE" = 1 ]; then
    PREFIX="$HOME/.local"
    ASSETS_TARGET="$XDG_DATA/opencode-onprem"
  else
    ASSETS_TARGET="$PREFIX/assets"
  fi
  echo "[install] installing to $PREFIX"
  mkdir -p "$PREFIX/bin" "$PREFIX/config" "$PREFIX/schema" "$ASSETS_TARGET"
  install -m 755 "$SCRIPT_DIR/bin/opencode" "$PREFIX/bin/opencode"
  install -m 755 "$SCRIPT_DIR/bin/rg" "$PREFIX/bin/rg"
  cp -a "$SCRIPT_DIR/assets/." "$ASSETS_TARGET/"
  cp -a "$SCRIPT_DIR/config/opencode.airgap.json" "$PREFIX/config/"
  cp -a "$SCRIPT_DIR/schema/." "$PREFIX/schema/"
  cp -f "$SCRIPT_DIR/README.md" "$SCRIPT_DIR/MANIFEST.json" "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/env.sh" "$PREFIX/"
  echo "[install] done. 用户执行: source $PREFIX/env.sh"
fi

# 资产定位（bundle 原目录或已安装位置）
if [ "$USER_MODE" = 1 ]; then
  ASSETS="$XDG_DATA/opencode-onprem"
else
  ASSETS="$PREFIX/assets"
fi
[ -d "$ASSETS" ] || ASSETS="$SCRIPT_DIR/assets"

# --seed：tree-sitter 高亮 + vendored 插件，原样拷贝进 per-user 缓存（rg 已随 PREFIX/bin 进 PATH，无需拷贝）
if [ "$DO_SEED" = 1 ]; then
  TS_DIR="$XDG_DATA/opentui/tree-sitter"
  mkdir -p "$TS_DIR/languages" "$TS_DIR/queries"
  cp -f "$ASSETS/tree-sitter/languages/"*.wasm "$TS_DIR/languages/" 2>/dev/null || true
  cp -f "$ASSETS/tree-sitter/queries/"*.scm "$TS_DIR/queries/" 2>/dev/null || true
  echo "[seed] tree-sitter -> $TS_DIR"

  for NODE_MODULES in "$ASSETS/npm/"*/node_modules; do
    [ -d "$NODE_MODULES" ] || continue
    KEY="$(basename "$(dirname "$NODE_MODULES")")"
    GEN="$XDG_CACHE/opencode/npm/$KEY/$(date +%s%3N)"
    mkdir -p "$GEN"
    cp -a "$NODE_MODULES" "$GEN/node_modules"
    echo "[seed] $KEY -> $GEN"
  done
fi

# JSONC（注释 + 尾随逗号）→ 严格 JSON，供 jq 迁移使用
jsonc_to_json() {
  awk '
  {
    line = $0
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (instr) {
        out = out c
        if (c == "\\") { i++; out = out substr(line, i, 1); continue }
        if (c == "\"") instr = 0
        continue
      }
      if (c == "\"") { instr = 1; out = out c; continue }
      if (inblock) { if (c == "*" && substr(line, i+1, 1) == "/") { inblock = 0; i++ }; continue }
      if (c == "/" && substr(line, i+1, 1) == "/") break
      if (c == "/" && substr(line, i+1, 1) == "*") { inblock = 1; i++; continue }
      out = out c
    }
    out = out "\n"
  }
  END {
    while (match(out, /,[[:space:]]*[]}]/))
      out = substr(out, 1, RSTART-1) substr(out, RSTART+1, RLENGTH-1) substr(out, RSTART+RLENGTH)
    printf "%s", out
  }'
}

# --config：新装复制模板 + 本地 schema 目录；已有配置用 jq 迁移（v1→v2 变动项、失效项清理），绝不覆盖用户设置
if [ "$DO_CONFIG" = 1 ]; then
  TPL="$PREFIX/config/opencode.airgap.json"
  [ -f "$TPL" ] || TPL="$SCRIPT_DIR/config/opencode.airgap.json"
  SCHEMA_DIR="$PREFIX/schema"
  [ -d "$SCHEMA_DIR" ] || SCHEMA_DIR="$SCRIPT_DIR/schema"
  [ -f "$TPL" ] || { echo "[config] ERROR: 模板未找到" >&2; exit 1; }
  CONF_DIR="$XDG_CONF/opencode"
  mkdir -p "$CONF_DIR/schema"
  # schema 独立目录放在配置同层：模板/迁移后的 "$schema" 为相对路径 ./schema/config.json
  [ -d "$SCHEMA_DIR" ] && cp -a "$SCHEMA_DIR/." "$CONF_DIR/schema/"

  CFG="$(ls "$CONF_DIR"/opencode.jsonc "$CONF_DIR"/opencode.json 2>/dev/null | head -1 || true)"
  if [ -z "$CFG" ]; then
    cp "$TPL" "$CONF_DIR/opencode.jsonc"
    echo "[config] 新装：模板 -> $CONF_DIR/opencode.jsonc（填写 provider 后使用；schema -> $CONF_DIR/schema/）"
  else
    if ! command -v jq >/dev/null 2>&1; then
      echo "[config] 已有配置 $CFG，未覆盖。迁移需要 jq（未安装，跳过）。模板参考: $TPL"
    else
      TMPJ="$(mktemp)"
      if ! jsonc_to_json < "$CFG" > "$TMPJ" || ! jq empty "$TMPJ" 2>/dev/null; then
        rm -f "$TMPJ"
        echo "[config] 解析失败（非 JSON/JSONC？），未改动: $CFG"
      else
        # v2 schema 的合法顶层键（用于删除失效/未知项）；schema 缺失时退化为不裁剪
        VALID="$(jq -c '.properties | keys' "$SCHEMA_DIR/config.json" 2>/dev/null || jq -c 'keys' "$TMPJ")"
        DISABLED="$(jsonc_to_json < "$TPL" | jq -c '.disabled_providers // []' 2>/dev/null || echo '[]')"
        BAK="$CFG.bak.$(date +%Y%m%d%H%M%S)"
        if jq --argjson valid "$VALID" --argjson disabled "$DISABLED" '
          . as $c
          | $c
          | with_entries(select(.key as $k | $valid | index($k)))
          | .plugins = (((if (.plugins | type) == "array" then .plugins else [] end)
              + (if (.plugin | type) == "array" then .plugin else [] end))
            | map(if (type == "string" and test("^opencode-acp(@|$)")) then "billion-context" else . end)
            | unique)
          | del(.plugin)
          | .disabled_providers = (((if (.disabled_providers | type) == "array" then .disabled_providers else [] end) + $disabled) | unique)
          | .["$schema"] = "./schema/config.json"
        ' "$TMPJ" > "$TMPJ.out"; then
          cp "$CFG" "$BAK"
          mv "$TMPJ.out" "$CFG"
          echo "[config] 迁移完成: $CFG"
          echo "[config] 变更: plugin→plugins、opencode-acp→billion-context、失效键清理、\$schema 指向本地（注释已丢弃）"
          echo "[config] 备份: $BAK"
        else
          echo "[config] jq 迁移失败，未改动: $CFG" >&2
        fi
        rm -f "$TMPJ" "$TMPJ.out"
      fi
    fi
  fi

  # omo-slim 插件自己的配置（若有）：$schema 改指本地副本（编辑器离线补全用）
  OMO="$(ls "$CONF_DIR"/oh-my-opencode-slim.jsonc "$CONF_DIR"/oh-my-opencode-slim.json 2>/dev/null | head -1 || true)"
  if [ -n "$OMO" ] && command -v jq >/dev/null 2>&1; then
    TMPO="$(mktemp)"
    if jsonc_to_json < "$OMO" > "$TMPO" && jq empty "$TMPO" 2>/dev/null; then
      if ! jq -e '.["$schema"] == "./schema/oh-my-opencode-slim.json"' "$TMPO" >/dev/null 2>&1; then
        cp "$OMO" "$OMO.bak.$(date +%Y%m%d%H%M%S)"
        jq '.["$schema"] = "./schema/oh-my-opencode-slim.json"' "$TMPO" > "$TMPO.out" && mv "$TMPO.out" "$OMO"
        echo "[config] oh-my-opencode-slim: \$schema -> ./schema/oh-my-opencode-slim.json（注释已丢弃，已备份）"
      fi
    fi
    rm -f "$TMPO" "$TMPO.out"
  fi
fi
