#!/usr/bin/env bash
# build.sh —— 维护者本地调试入口（正式发布一律走 GitHub Actions，用户无需构建）
# 用法: ./build.sh [ref|tag] [--platform linux-x64|win32-x64] [--from-source] [--skip-verify]
#   ref 缺省 = upstream 最新 tag；二进制默认下载官方 release（tag ref 时），
#   --from-source 强制源码编译（非 tag ref 自动走源码）；--skip-verify 跳过 16 项离线验收
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REF=""
PLATFORM="linux-x64"
FROM_SOURCE=0
SKIP_VERIFY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM="$2"; shift 2 ;;
    --from-source) FROM_SOURCE=1; shift ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) if [ -z "$REF" ]; then REF="$1"; else echo "unexpected arg: $1" >&2; exit 1; fi; shift ;;
  esac
done

WORK="${WORK:-$SCRIPT_DIR/work}"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "[build] === 1/6 resolve ref ==="
if [ -z "$REF" ]; then
  REPO="${OPENCODE_REPO:-https://github.com/anomalyco/opencode}"
  REF="$(git ls-remote --tags --refs --sort='-v:refname' "$REPO" 'v*' | head -1 | sed 's|.*refs/tags/||')"
  [ -n "$REF" ] || { echo "ERROR: cannot resolve latest tag from $REPO" >&2; exit 1; }
  echo "[build] latest tag: $REF"
fi

echo "[build] === 2/6 prepare source (worktree + patches) ==="
"$SCRIPT_DIR/scripts/prepare-source.sh" "$REF" "$WORK"
# shellcheck disable=SC1091
. "$WORK/build.env"

echo "[build] === 3/6 binary (official release default) ==="
if [ "$FROM_SOURCE" = 1 ] || ! printf '%s' "$REF" | grep -qE '^v[0-9]'; then
  "$SCRIPT_DIR/scripts/build-binary.sh" "$WORK" "$PLATFORM"
else
  "$SCRIPT_DIR/scripts/fetch-official.sh" "$WORK" "$PLATFORM"
fi

echo "[build] === 4/6 fetch runtime assets ==="
"$SCRIPT_DIR/scripts/fetch-assets.sh" "$WORK"

echo "[build] === 5/6 pack ==="
"$SCRIPT_DIR/scripts/pack.sh" "$WORK"

echo "[build] === 6/6 verify ==="
TARBALL="$SCRIPT_DIR/out/opencode-v${VERSION}-onprem-bundle-${PLATFORM}.tar.gz"
if [ "$SKIP_VERIFY" = 1 ]; then
  echo "[build] verify skipped (--skip-verify)"
else
  "$SCRIPT_DIR/scripts/verify.sh" "$TARBALL"
fi

echo "[build] DONE: $TARBALL"
