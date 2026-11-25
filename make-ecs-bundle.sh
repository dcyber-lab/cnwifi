#!/usr/bin/env bash
# 打包 ECS 端安装包 dist/cnwifi-ecs.tar.gz（只含 ECS 需要的密钥，不含 N150 私钥）
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"
load_config "$HERE/config.env"
for a in amd64 arm64; do
  [[ -x $HERE/dist/wstunnel-linux-$a ]] || die "缺少 dist/wstunnel-linux-$a，先运行 ./fetch-wstunnel.sh"
done
B=$HERE/dist/cnwifi-ecs
rm -rf "$B"; mkdir -p "$B"
cp "$HERE/ecs/setup.sh" "$B/"
cp "$HERE/dist/wstunnel-linux-amd64" "$HERE/dist/wstunnel-linux-arm64" "$B/"
umask 077
cat >"$B/ecs.env" <<EOF
ECS_IP=$ECS_IP
WSTUNNEL_PORT=$WSTUNNEL_PORT
PATH_SECRET=$PATH_SECRET
WG_IF=$WG_IF
WG_PORT=$WG_PORT
WG_ECS_ADDR=$WG_ECS_ADDR
WG_N150_ADDR=$WG_N150_ADDR
WG_PREFIX=$WG_PREFIX
WG_MTU=$WG_MTU
ECS_WG_PRIVKEY=$ECS_WG_PRIVKEY
N150_WG_PUBKEY=$N150_WG_PUBKEY
WG_PSK=$WG_PSK
EOF
tar -C "$HERE/dist" -czf "$HERE/dist/cnwifi-ecs.tar.gz" cnwifi-ecs
chmod 600 "$HERE/dist/cnwifi-ecs.tar.gz"
log "已生成 dist/cnwifi-ecs.tar.gz（含 ECS 私钥，传完即删）"
