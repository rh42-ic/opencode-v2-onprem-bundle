#!/usr/bin/env bash
# opencode v2 onprem bundle 安装脚本 —— 只做拷贝（二进制/资产/配置/env.sh → PREFIX），不生成任何文件
#
# 管理员安装（不写 /usr/local/bin）:
#   sudo ./install.sh                    # 默认 /opt/opencode
#   sudo ./install.sh --prefix /opt/opencode
# 无 root 备选:
#   ./install.sh --user                  # bin → ~/.local/bin，assets → ~/.local/share/opencode-onprem
#
# 用户侧（source $PREFIX/env.sh 之后）:
#   install.sh --seed                    # per-user 缓存：rg + TUI 高亮 + 全部 vendored 插件（幂等）
#   install.sh --config                  # 需要时帮忙 copy：配置模板 → ~/.config/opencode/（已有则跳过）
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
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
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
  mkdir -p "$PREFIX/bin" "$PREFIX/config" "$ASSETS_TARGET"
  install -m 755 "$SCRIPT_DIR/bin/opencode" "$PREFIX/bin/opencode"
  install -m 755 "$SCRIPT_DIR/bin/rg" "$PREFIX/bin/rg"
  cp -a "$SCRIPT_DIR/assets/." "$ASSETS_TARGET/"
  cp -a "$SCRIPT_DIR/config/opencode.airgap.json" "$PREFIX/config/"
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

# --seed：rg + tree-sitter 高亮 + vendored 插件，全部原样拷贝进 per-user 缓存
if [ "$DO_SEED" = 1 ]; then
  [ -x "$PREFIX/bin/rg" ] || [ -x "$SCRIPT_DIR/bin/rg" ] || { echo "[seed] ERROR: rg not found（先执行主安装）" >&2; exit 1; }
  BINDIR="$([ -x "$PREFIX/bin/rg" ] && echo "$PREFIX/bin" || echo "$SCRIPT_DIR/bin")"
  mkdir -p "$XDG_CACHE/opencode/bin"
  install -m 755 "$BINDIR/rg" "$XDG_CACHE/opencode/bin/rg"
  echo "[seed] rg -> $XDG_CACHE/opencode/bin/rg"

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

# --config：配置模板（plugins 清单已在 build 时注入模板）
if [ "$DO_CONFIG" = 1 ]; then
  TPL="$PREFIX/config/opencode.airgap.json"
  [ -f "$TPL" ] || TPL="$SCRIPT_DIR/config/opencode.airgap.json"
  [ -f "$TPL" ] || { echo "[config] ERROR: 模板未找到" >&2; exit 1; }
  mkdir -p "$XDG_CONF/opencode"
  if [ -f "$XDG_CONF/opencode/opencode.json" ] || [ -f "$XDG_CONF/opencode/opencode.jsonc" ]; then
    echo "[config] 已有配置，未覆盖。模板: $TPL"
  else
    cp "$TPL" "$XDG_CONF/opencode/opencode.jsonc"
    echo "[config] 模板 -> $XDG_CONF/opencode/opencode.jsonc"
  fi
fi
