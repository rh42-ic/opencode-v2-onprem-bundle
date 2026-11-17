#!/usr/bin/env bash
# per-user 离线缓存种子（幂等，可重复执行）：
#   tree-sitter 高亮 → ${XDG_DATA_HOME:-~/.local/share}/opentui/tree-sitter/
#   全部 vendored 插件 → ${XDG_CACHE_HOME:-~/.cache}/opencode/npm/<key>/<now_ms>/node_modules
# rg 不需要种子：随 PREFIX/bin 进 PATH
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$SCRIPT_DIR/assets"
XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"

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
