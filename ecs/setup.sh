#!/usr/bin/env bash
# cnwifi — ECS（大陆出口）端安装脚本。以 root 在阿里云 ECS 上运行：
#   tar xzf cnwifi-ecs.tar.gz && cd cnwifi-ecs && bash setup.sh
# 可重复运行（幂等）。支持 Ubuntu / Debian / Alibaba Cloud Linux 3 / CentOS Stream 等。
set -euo pipefail
cd "$(dirname "$0")"
c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
log()  { printf '%s[ecs]%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s[ecs 警告]%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%s[ecs 错误]%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
have_systemd() { [[ -d /run/systemd/system ]]; }

[[ $EUID -eq 0 ]] || die "请用 root 运行"
[[ -r ./ecs.env ]] || die "缺少 ecs.env"
# shellcheck disable=SC1091
source ./ecs.env
for v in ECS_IP WSTUNNEL_PORT PATH_SECRET WG_IF WG_PORT WG_ECS_ADDR WG_N150_ADDR WG_PREFIX WG_MTU \
         ECS_WG_PRIVKEY N150_WG_PUBKEY WG_PSK; do
  [[ -n ${!v:-} ]] || die "ecs.env 缺少 $v"
done
MARK="# managed-by: cnwifi"

# ---------- 1. 软件包 ----------
pkg_install() {
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$@"
  elif command -v dnf >/dev/null; then
    dnf install -y "$@" || { dnf install -y epel-release epel-aliyuncs-release 2>/dev/null || true; dnf install -y "$@"; }
  elif command -v yum >/dev/null; then
    yum install -y "$@"
  else
    die "不认识的发行版，请手动安装: $*"
  fi
}
need=()
command -v wg      >/dev/null || need+=(wireguard-tools)
command -v nft     >/dev/null || need+=(nftables)
command -v openssl >/dev/null || need+=(openssl)
command -v curl    >/dev/null || need+=(curl)
if ! command -v ip >/dev/null; then
  if command -v apt-get >/dev/null; then need+=(iproute2); else need+=(iproute); fi
fi
if (( ${#need[@]} )); then log "安装: ${need[*]}"; pkg_install "${need[@]}"; fi
NFT=$(command -v nft)

# 内核 WireGuard 支持
modprobe wireguard 2>/dev/null || true
if ip link add cnwifi-wgtest type wireguard 2>/dev/null; then
  ip link del cnwifi-wgtest
elif command -v wireguard-go >/dev/null; then
  warn "内核没有 WireGuard 模块，将使用 wireguard-go（用户态，性能较低）"
else
  die "内核不支持 WireGuard。Ubuntu/Debian 请 apt install wireguard；或换 Ubuntu 22.04/24.04 镜像"
fi

# ---------- 2. 出口网卡 ----------
EXT_IF=${EXT_IF:-$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}
[[ -n $EXT_IF ]] || die "找不到默认路由网卡"
log "出口网卡: $EXT_IF"

# ---------- 3. wstunnel ----------
case $(uname -m) in
  x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die "不支持的架构 $(uname -m)" ;;
esac
[[ -x ./wstunnel-linux-$arch ]] || die "包里没有 wstunnel-linux-$arch"
install -m 0755 "./wstunnel-linux-$arch" /usr/local/bin/wstunnel
log "wstunnel: $(/usr/local/bin/wstunnel --version)"

if ! id wstunnel >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent \
          --shell "$(command -v nologin || echo /bin/false)" wstunnel
fi

install -d -m 0755 /etc/cnwifi
install -d -m 0750 -g wstunnel /etc/cnwifi/tls
if [[ ! -s /etc/cnwifi/tls/cert.pem || ! -s /etc/cnwifi/tls/key.pem ]]; then
  log "生成自签 TLS 证书（不用 wstunnel 内置证书，避免被指纹识别）"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=$ECS_IP" -keyout /etc/cnwifi/tls/key.pem -out /etc/cnwifi/tls/cert.pem 2>/dev/null
fi
chown root:wstunnel /etc/cnwifi/tls/cert.pem /etc/cnwifi/tls/key.pem
chmod 0640 /etc/cnwifi/tls/cert.pem /etc/cnwifi/tls/key.pem

umask 077
cat >/etc/cnwifi/wstunnel-server.env <<EOF
$MARK
WSTUNNEL_RESTRICT_HTTP_UPGRADE_PATH_PREFIX=$PATH_SECRET
WSTUNNEL_PORT=$WSTUNNEL_PORT
WG_PORT=$WG_PORT
NO_COLOR=true
TOKIO_WORKER_THREADS=2
EOF
umask 022

# ---------- 4. WireGuard ----------
install -d -m 0700 /etc/wireguard
WGCONF=/etc/wireguard/$WG_IF.conf
if [[ -e $WGCONF ]] && ! grep -qF "$MARK" "$WGCONF"; then
  die "$WGCONF 已存在且不是 cnwifi 生成的，为避免覆盖已退出（可在 ecs.env 里改 WG_IF）"
fi
umask 077
cat >"$WGCONF" <<EOF
$MARK
# ECS 端：只接受经本机 wstunnel 转进来的流量（UDP $WG_PORT 已被防火墙限制为仅 lo）
[Interface]
Address = $WG_ECS_ADDR/$WG_PREFIX
ListenPort = $WG_PORT
PrivateKey = $ECS_WG_PRIVKEY
MTU = $WG_MTU
PostUp = sysctl -qw net.ipv4.ip_forward=1

[Peer]
# N150（新加坡）
PublicKey = $N150_WG_PUBKEY
PresharedKey = $WG_PSK
AllowedIPs = $WG_N150_ADDR/32
EOF
umask 022

# ---------- 5. sysctl ----------
cat >/etc/sysctl.d/99-zzz-cnwifi.conf <<EOF
$MARK
net.ipv4.ip_forward = 1
EOF
sysctl -q -p /etc/sysctl.d/99-zzz-cnwifi.conf
if grep -Eq '^\s*net\.ipv4\.ip_forward\s*=\s*0' /etc/sysctl.conf 2>/dev/null; then
  warn "/etc/sysctl.conf 里有 net.ipv4.ip_forward=0，如果有人跑 sysctl --system 会被覆盖；建议删掉那一行"
fi
# 外层 wstunnel 是一条跨境长 TCP（新加坡→广州实测 RTT 300ms+、晚高峰丢包 10–30%），cubic 会塌到几乎不动，
# WG 握手和 N150 看门狗的 ping 都跟着卡住。ECS 是专用机，全局开 BBR（N150 端只对到 ECS 的路由开）。
install -d /etc/modules-load.d
cat >/etc/modules-load.d/cnwifi-bbr.conf <<EOF
$MARK
tcp_bbr
EOF
cat >/etc/sysctl.d/99-zzz-cnwifi-bbr.conf <<EOF
$MARK
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
modprobe tcp_bbr 2>/dev/null || true
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  sysctl -q -p /etc/sysctl.d/99-zzz-cnwifi-bbr.conf || warn "BBR sysctl 没有全部生效"
  log "TCP 拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
else
  warn "内核没有 BBR（tcp_bbr），外层 TCP 仍用 $(sysctl -n net.ipv4.tcp_congestion_control)，晚高峰可能很慢"
fi

# ---------- 6. nftables（独立的 table，不碰系统其它规则） ----------
WG_NET="$(echo "$WG_ECS_ADDR" | cut -d. -f1-3).0/$WG_PREFIX"
cat >/etc/cnwifi/ecs.nft <<EOF
$MARK
table inet cnwifi
delete table inet cnwifi
table inet cnwifi {
	# 隧道里的设备不许访问 ECS 内网 / 阿里云元数据 (100.100.100.200) 等私有地址
	set no_go {
		type ipv4_addr; flags interval
		elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
		             172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 }
	}

	chain input {
		type filter hook input priority filter; policy accept;
		# WireGuard 只接受本机 wstunnel 转进来的（等效于"WG 只监听 127.0.0.1"）
		iifname != "lo" udp dport $WG_PORT counter drop
		iifname "$WG_IF" ct state established,related accept
		iifname "$WG_IF" icmp type echo-request accept
		iifname "$WG_IF" counter drop
	}

	chain forward {
		type filter hook forward priority filter; policy accept;
		iifname "$WG_IF" ip daddr @no_go counter drop
		iifname "$WG_IF" oifname "$EXT_IF" accept
		iifname "$EXT_IF" oifname "$WG_IF" ct state established,related accept
		iifname "$WG_IF" counter drop
		oifname "$WG_IF" counter drop
	}

	chain mangle_forward {
		type filter hook forward priority mangle; policy accept;
		oifname "$WG_IF" tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
	}

	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr $WG_NET oifname "$EXT_IF" counter masquerade
	}
}
EOF
"$NFT" -c -f /etc/cnwifi/ecs.nft || die "nft 规则语法检查失败"

# ---------- 7. systemd ----------
cat >/etc/systemd/system/cnwifi-fw.service <<EOF
$MARK
[Unit]
Description=cnwifi firewall (nft table inet cnwifi)
DefaultDependencies=no
After=local-fs.target nftables.service firewalld.service
Before=network-pre.target wg-quick@$WG_IF.service cnwifi-wstunnel-server.service
Wants=network-pre.target
# 有人重启 nftables.service（会 flush ruleset）时，跟着重新加载
PartOf=nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NFT -f /etc/cnwifi/ecs.nft

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/cnwifi-wstunnel-server.service <<EOF
$MARK
[Unit]
Description=cnwifi wstunnel server (WSS :$WSTUNNEL_PORT -> 127.0.0.1:$WG_PORT/udp)
After=network-online.target cnwifi-fw.service
Wants=network-online.target cnwifi-fw.service
StartLimitIntervalSec=0

[Service]
User=wstunnel
Group=wstunnel
EnvironmentFile=/etc/cnwifi/wstunnel-server.env
ExecStart=/usr/local/bin/wstunnel server \\
  --restrict-to 127.0.0.1:\${WG_PORT} \\
  --tls-certificate /etc/cnwifi/tls/cert.pem \\
  --tls-private-key /etc/cnwifi/tls/key.pem \\
  wss://0.0.0.0:\${WSTUNNEL_PORT}
Restart=always
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

install -d /etc/systemd/system/wg-quick@"$WG_IF".service.d
cat >/etc/systemd/system/wg-quick@"$WG_IF".service.d/cnwifi.conf <<EOF
$MARK
[Unit]
After=cnwifi-fw.service
Wants=cnwifi-fw.service

[Service]
Restart=on-failure
RestartSec=5
EOF

if have_systemd; then
  systemctl daemon-reload
  systemctl enable cnwifi-fw.service "wg-quick@$WG_IF.service" cnwifi-wstunnel-server.service >/dev/null 2>&1
  systemctl restart cnwifi-fw.service
  systemctl restart "wg-quick@$WG_IF.service"
  systemctl restart cnwifi-wstunnel-server.service
  sleep 2
  for u in cnwifi-fw "wg-quick@$WG_IF" cnwifi-wstunnel-server; do
    if systemctl is-active -q "$u"; then log "服务 $u: active"
    else systemctl --no-pager -l status "$u" | tail -20; die "服务 $u 没起来"; fi
  done
else
  warn "没有 systemd（测试环境？），只写了文件，没有启动服务"
fi

# ---------- 8. 自检 ----------
if have_systemd; then
  ss -ltn "sport = :$WSTUNNEL_PORT" | grep -q LISTEN && log "wstunnel 正在监听 TCP $WSTUNNEL_PORT" || die "wstunnel 没在监听 $WSTUNNEL_PORT"
  egress=$(curl -4 -fsS --max-time 8 https://myip.ipip.net 2>/dev/null || true)
  log "ECS 自身出口: ${egress:-（查询失败，不影响）}"
fi
cat <<EOF

${c_ok}ECS 端完成。${c_off}
  - 阿里云安全组入方向只需要：TCP 22（SSH）和 TCP $WSTUNNEL_PORT（wstunnel）。
    UDP $WG_PORT 不要放行。
  - WireGuard 公钥: $(wg pubkey <<<"$ECS_WG_PRIVKEY")
EOF
