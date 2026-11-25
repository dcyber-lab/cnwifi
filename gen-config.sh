#!/usr/bin/env bash
# 生成 config.env：随机端口、wstunnel 路径密钥、两端 WireGuard 密钥。
# 在 N150 上运行一次即可；之后 ECS 和 N150 都从这份配置安装。
#   用法: ./gen-config.sh <ECS公网IP> [--force]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"

ECS_IP=${1:-}; FORCE=${2:-}
[[ $ECS_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "用法: $0 <ECS公网IP> [--force]"
OUT=$HERE/config.env
if [[ -e $OUT && $FORCE != --force ]]; then
  die "$OUT 已存在。重新生成会换掉所有密钥（两端都要重装）。确认要换请加 --force"
fi
command -v wg >/dev/null || die "需要 wg 命令生成密钥：apt install wireguard-tools（或 dnf install wireguard-tools）"

wan=$(detect_wan_if)
lan=$(detect_lan_if "$wan")
[[ -n $wan ]] || die "找不到默认路由所在网卡"
if [[ -z $lan ]]; then
  warn "无法自动判断 LAN 口（物理网卡: $(list_physical_eth | tr '\n' ' ')），先填 eth1，请手动改 config.env 里的 LAN_IF"
  lan=eth1
fi

ecs_priv=$(wg genkey); ecs_pub=$(wg pubkey <<<"$ecs_priv")
n150_priv=$(wg genkey); n150_pub=$(wg pubkey <<<"$n150_priv")
psk=$(wg genpsk)
secret=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
port=$(( 30000 + $(od -An -tu2 -N2 /dev/urandom | tr -d ' ') % 10000 ))

umask 077
cat >"$OUT" <<EOF
# cnwifi 配置（含私钥，权限 600，不要外传）
# 生成时间: $(date '+%F %T')

# ---------- ECS ----------
ECS_IP=$ECS_IP
WSTUNNEL_PORT=$port          # 阿里云安全组只放行这个 TCP 端口 + SSH
WSTUNNEL_VERSION=11.1.0
PATH_SECRET=$secret          # wstunnel 升级路径密钥，路径不对的连接直接拒绝

# ---------- WireGuard ----------
WG_IF=wg0
WG_PORT=51820                # ECS 上 WG 监听端口（只接受本机 wstunnel 转进来的）
WG_LOCAL_UDP=51821           # N150 上 wstunnel 客户端监听的本地 UDP 端口（WG Endpoint）
WG_ECS_ADDR=10.66.66.1
WG_N150_ADDR=10.66.66.2
WG_PREFIX=24
WG_MTU=1380                  # 1280–1380 之间按实测调
ECS_WG_PRIVKEY=$ecs_priv
ECS_WG_PUBKEY=$ecs_pub
N150_WG_PRIVKEY=$n150_priv
N150_WG_PUBKEY=$n150_pub
WG_PSK=$psk

# ---------- N150 / 回国 Wi-Fi ----------
WAN_IF=$wan                  # 接主路由的网卡（自动检测，请核对）
LAN_IF=$lan                  # 接 AP 的网卡（自动检测，请核对）
LAN_ADDR=192.168.50.1
LAN_PREFIX=24
DHCP_START=192.168.50.100
DHCP_END=192.168.50.150
UPSTREAM_DNS="223.5.5.5 223.6.6.6"
RT_TABLE=100

# 验收时用来查出口 IP 的网址（第一个能访问的为准）
IPCHECK_URLS="https://myip.ipip.net https://cip.cc https://ip.sb"
EOF
log "已生成 $OUT"
log "  ECS: $ECS_IP  wstunnel 端口: TCP $port"
log "  WAN_IF=$wan  LAN_IF=$lan   ← 请核对网卡名"
