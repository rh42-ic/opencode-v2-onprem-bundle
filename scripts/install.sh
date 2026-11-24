#!/usr/bin/env bash
# opencode v2 onprem bundle 安装脚本 —— 只做拷贝：bin/ assets/ schema/ config/ env.sh seed.sh → PREFIX
#
#   sudo ./install.sh                  # 默认 /opt/opencode
#   sudo ./install.sh --prefix <dir>
# 用户侧（source $PREFIX/env.sh 后）: $PREFIX/seed.sh      # per-user 缓存种子（幂等）
# 配置：参考 $PREFIX/config/opencode.airgap.jsonc 自行创建 ~/.config/opencode/opencode.jsonc
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="/opt/opencode"
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

echo "[install] installing to $PREFIX"
mkdir -p "$PREFIX/bin" "$PREFIX/config" "$PREFIX/schema" "$PREFIX/assets"
install -m 755 "$SCRIPT_DIR/bin/opencode" "$PREFIX/bin/opencode"
install -m 755 "$SCRIPT_DIR/bin/rg" "$PREFIX/bin/rg"
cp -a "$SCRIPT_DIR/assets/." "$PREFIX/assets/"
cp -a "$SCRIPT_DIR/config/." "$PREFIX/config/"
cp -a "$SCRIPT_DIR/schema/." "$PREFIX/schema/"
cp -f "$SCRIPT_DIR/README.md" "$SCRIPT_DIR/MANIFEST.json" "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/seed.sh" "$SCRIPT_DIR/env.sh" "$PREFIX/"
chmod 755 "$PREFIX/install.sh" "$PREFIX/seed.sh"
echo "[install] done. 用户执行: source $PREFIX/env.sh && $PREFIX/seed.sh"
