#!/usr/bin/env bash
# 在 N150（新加坡）上下载 wstunnel 官方 release 并校验 sha256。
# ECS 在大陆访问 GitHub 很慢/经常失败，所以由 N150 下载后打包传过去。
#   用法: ./fetch-wstunnel.sh            （版本取 config.env 里的 WSTUNNEL_VERSION）
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"
VER=${1:-$( (source "$HERE/config.env" 2>/dev/null; echo "${WSTUNNEL_VERSION:-}") )}
[[ -n $VER ]] || die "不知道要下哪个版本：先 gen-config.sh，或 $0 11.1.0"
VER=${VER#v}
BASE="https://github.com/erebe/wstunnel/releases/download/v$VER"
DIST=$HERE/dist
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$DIST"

log "下载 checksums.txt (v$VER)"
curl -fsSL --retry 3 -o "$TMP/checksums.txt" "$BASE/checksums.txt"
for arch in amd64 arm64; do
  f="wstunnel_${VER}_linux_${arch}.tar.gz"
  log "下载 $f"
  curl -fsSL --retry 3 -o "$TMP/$f" "$BASE/$f"
  want=$(awk -v f="$f" '$2==f{print $1}' "$TMP/checksums.txt")
  [[ -n $want ]] || die "checksums.txt 里没有 $f"
  got=$(sha256sum "$TMP/$f" | awk '{print $1}')
  [[ $want == "$got" ]] || die "$f sha256 不匹配！期望 $want 实际 $got"
  mkdir -p "$TMP/x-$arch"
  tar -xzf "$TMP/$f" -C "$TMP/x-$arch"
  install -m 0755 "$TMP/x-$arch/wstunnel" "$DIST/wstunnel-linux-$arch"
  log "  sha256 OK → dist/wstunnel-linux-$arch"
done
"$DIST/wstunnel-linux-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" --version
