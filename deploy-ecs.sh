#!/usr/bin/env bash
# 通过 SSH 把 ECS 安装包传上去并执行。
#   用法: ./deploy-ecs.sh [ssh目标，默认 root@<ECS_IP>] [其它 ssh 参数，如 -i ~/.ssh/aliyun.pem -p 22]
# 也可以不用这个脚本：把 dist/cnwifi-ecs.tar.gz 通过阿里云 Workbench 上传后手动执行
#   tar xzf cnwifi-ecs.tar.gz && bash cnwifi-ecs/setup.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"
load_config "$HERE/config.env"
TARGET=${1:-root@$ECS_IP}; shift || true
[[ -s $HERE/dist/cnwifi-ecs.tar.gz ]] || "$HERE/make-ecs-bundle.sh"
SSH_OPTS=(-o ConnectTimeout=15 -o ServerAliveInterval=15 "$@")
log "上传到 $TARGET ..."
scp "${SSH_OPTS[@]}" "$HERE/dist/cnwifi-ecs.tar.gz" "$TARGET:/root/cnwifi-ecs.tar.gz"
log "在 ECS 上执行 setup.sh ..."
# shellcheck disable=SC2029
ssh "${SSH_OPTS[@]}" "$TARGET" 'cd /root && rm -rf cnwifi-ecs && tar xzf cnwifi-ecs.tar.gz && bash cnwifi-ecs/setup.sh; rc=$?; rm -rf /root/cnwifi-ecs /root/cnwifi-ecs.tar.gz; exit $rc'
