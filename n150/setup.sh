#!/usr/bin/env bash
# cnwifi — N150 端安装脚本。在 cnwifi 目录下以 root 运行：sudo ./n150/setup.sh
# 可重复运行（幂等）。需要先有 config.env（gen-config.sh）和 dist/wstunnel-linux-*（fetch-wstunnel.sh）。
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
source "$HERE/lib.sh"
require_root
load_config "$HERE/config.env"
MARK="# managed-by: cnwifi"

mask_of() { local p=$1 m=0; ((p > 0)) && m=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF )); echo "$((m>>24&255)).$((m>>16&255)).$((m>>8&255)).$((m&255))"; }
LAN_MASK=$(mask_of "$LAN_PREFIX")
IFS=. read -r a b c d <<<"$LAN_ADDR"; IFS=. read -r m1 m2 m3 m4 <<<"$LAN_MASK"
LAN_CIDR="$((a&m1)).$((b&m2)).$((c&m3)).$((d&m4))/$LAN_PREFIX"

# =====================================================================
# 0. 预检（任何一项不满足就停下，不改动系统）
# =====================================================================
log "预检 ..."
[[ -e /sys/class/net/$LAN_IF ]] || die "LAN 口 $LAN_IF 不存在。实际网卡: $(ls /sys/class/net | tr '\n' ' ')，请改 config.env"
[[ -e /sys/class/net/$WAN_IF ]] || die "WAN 口 $WAN_IF 不存在，请改 config.env"
[[ $LAN_IF != "$WAN_IF" ]] || die "LAN_IF 和 WAN_IF 不能相同"
cur_wan=$(detect_wan_if)
[[ $cur_wan == "$WAN_IF" ]] || warn "config 里 WAN_IF=$WAN_IF，但当前默认路由走 ${cur_wan:-无}"
[[ ! -e /sys/class/net/$LAN_IF/master ]] || die "$LAN_IF 是 $(basename "$(readlink -f /sys/class/net/$LAN_IF/master)") 的成员（网桥/bond），不能直接用作回国口"

other=$(ip -4 -o addr show dev "$LAN_IF" | awk '{print $4}' | grep -vxF "$LAN_ADDR/$LAN_PREFIX" || true)
[[ -z $other ]] || die "$LAN_IF 上已有其它地址: $other（插错口？或被别的网络配置管理？）"
while read -r cidr dev; do
  [[ $dev == "$LAN_IF" ]] && continue
  cidr_overlap "$cidr" "$LAN_CIDR" && die "回国网段 $LAN_CIDR 与 $dev 上的 $cidr 冲突，请改 LAN_ADDR"
done < <(ip -4 -o addr show | awk '{print $4, $2}')
cidr_overlap "$WG_ECS_ADDR/$WG_PREFIX" "$LAN_CIDR" && die "WG 网段与回国网段冲突"

if [[ -e /etc/wireguard/$WG_IF.conf ]] && ! grep -qF "$MARK" "/etc/wireguard/$WG_IF.conf"; then
  die "/etc/wireguard/$WG_IF.conf 已存在且不是 cnwifi 的。请在 config.env 里换个 WG_IF（比如 wgcn）"
fi
if ip link show "$WG_IF" >/dev/null 2>&1 && [[ ! -e /etc/wireguard/$WG_IF.conf ]]; then
  die "接口 $WG_IF 已存在（被别的程序占用），请换个 WG_IF"
fi
foreign_rt=$(ip route show table "$RT_TABLE" 2>/dev/null | grep -vE "^(blackhole default|default dev $WG_IF)" || true)
[[ -z $foreign_rt ]] || die "路由表 $RT_TABLE 已被占用（请在 config.env 换个 RT_TABLE）: $foreign_rt"
foreign_rules=$(ip rule show | grep -E '^100[0-3]:' | grep -vE "iif $LAN_IF|to (${UPSTREAM_DNS// /|}) " || true)
[[ -z $foreign_rules ]] || die "ip rule 优先级 1000-1003 已被占用: $foreign_rules"
if systemctl is-active -q firewalld 2>/dev/null; then
  die "firewalld 正在运行。它会拦截转发，需要先手动放行（或停用 firewalld）后再装"
fi
if grep -rqsE "^\s*(auto|allow-hotplug|iface)\s+$LAN_IF\b" /etc/network/interfaces /etc/network/interfaces.d/ 2>/dev/null; then
  grep -rnsE "^\s*(auto|allow-hotplug|iface)\s+$LAN_IF\b" /etc/network/interfaces /etc/network/interfaces.d/ >&2 || true
  die "/etc/network/interfaces 里配置了 $LAN_IF，请先删除这几行（cnwifi 会自己管理它）"
fi
# 53/67 端口冲突（systemd-resolved 的 127.0.0.53/54 不冲突）
conflict=$(ss -H -lunp 2>/dev/null | awk '$4 ~ /(^|[^0-9])(0\.0\.0\.0|\*|\[::\]):(53|67)$/' | grep -v cnwifi || true)
if [[ -n $conflict ]]; then
  warn "有程序监听所有地址的 53/67 端口，可能与回国 Wi-Fi 的 DHCP/DNS 冲突："
  echo "$conflict" >&2
fi

# =====================================================================
# 1. 软件包
# =====================================================================
pkg_install() {
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$@"
  elif command -v dnf >/dev/null; then dnf install -y "$@"
  else die "请手动安装: $*"; fi
}
apt=0; command -v apt-get >/dev/null && apt=1
need=()
command -v wg       >/dev/null || need+=(wireguard-tools)
command -v nft      >/dev/null || need+=(nftables)
command -v curl     >/dev/null || need+=(curl)
command -v tcpdump  >/dev/null || need+=(tcpdump)
command -v ping     >/dev/null || { ((apt)) && need+=(iputils-ping) || need+=(iputils); }
command -v dig      >/dev/null || { ((apt)) && need+=(dnsutils) || need+=(bind-utils); }
# Debian/Ubuntu 用 dnsmasq-base：只有程序，没有会监听所有网卡的 dnsmasq.service
command -v dnsmasq  >/dev/null || { ((apt)) && need+=(dnsmasq-base) || need+=(dnsmasq); }
if ((${#need[@]})); then log "安装: ${need[*]}"; pkg_install "${need[@]}"; fi
NFT=$(command -v nft); DNSMASQ=$(command -v dnsmasq)

modprobe wireguard 2>/dev/null || true
if ip link add cnwifi-wgtest type wireguard 2>/dev/null; then
  ip link del cnwifi-wgtest
elif command -v wireguard-go >/dev/null; then
  warn "内核没有 WireGuard 模块，使用 wireguard-go（用户态）"
else
  die "内核不支持 WireGuard（apt install wireguard / 升级内核）"
fi

# =====================================================================
# 2. wstunnel
# =====================================================================
case $(uname -m) in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die "不支持的架构" ;; esac
[[ -x $HERE/dist/wstunnel-linux-$arch ]] || die "缺少 dist/wstunnel-linux-$arch，先运行 ./fetch-wstunnel.sh"
install -m 0755 "$HERE/dist/wstunnel-linux-$arch" /usr/local/bin/wstunnel
log "wstunnel: $(/usr/local/bin/wstunnel --version)"
id wstunnel >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent \
  --shell "$(command -v nologin || echo /bin/false)" wstunnel

# =====================================================================
# 3. 配置文件
# =====================================================================
# 如果之前装过且 LAN 口换了，先撤掉旧网关地址
if [[ -r /etc/cnwifi/cnwifi.env ]]; then
  old_if=$(. /etc/cnwifi/cnwifi.env; echo "$LAN_IF"); old_addr=$(. /etc/cnwifi/cnwifi.env; echo "$LAN_ADDR/$LAN_PREFIX")
  [[ $old_if != "$LAN_IF" ]] && ip addr del "$old_addr" dev "$old_if" 2>/dev/null || true
fi
install -d -m 0755 /etc/cnwifi /var/lib/cnwifi
cat >/etc/cnwifi/cnwifi.env <<EOF
$MARK
ECS_IP=$ECS_IP
WSTUNNEL_PORT=$WSTUNNEL_PORT
WG_IF=$WG_IF
WG_PORT=$WG_PORT
WG_LOCAL_UDP=$WG_LOCAL_UDP
WG_ECS_ADDR=$WG_ECS_ADDR
WG_N150_ADDR=$WG_N150_ADDR
WG_PREFIX=$WG_PREFIX
WG_MTU=$WG_MTU
WAN_IF=$WAN_IF
LAN_IF=$LAN_IF
LAN_ADDR=$LAN_ADDR
LAN_PREFIX=$LAN_PREFIX
DHCP_START=$DHCP_START
DHCP_END=$DHCP_END
UPSTREAM_DNS="$UPSTREAM_DNS"
RT_TABLE=$RT_TABLE
IPCHECK_URLS="${IPCHECK_URLS:-https://myip.ipip.net https://cip.cc}"
EOF

umask 077
cat >/etc/cnwifi/wstunnel-client.env <<EOF
$MARK
WSTUNNEL_HTTP_UPGRADE_PATH_PREFIX=$PATH_SECRET
ECS_IP=$ECS_IP
WSTUNNEL_PORT=$WSTUNNEL_PORT
WG_LOCAL_UDP=$WG_LOCAL_UDP
WG_PORT=$WG_PORT
NO_COLOR=true
TOKIO_WORKER_THREADS=2
EOF

install -d -m 0700 /etc/wireguard
cat >"/etc/wireguard/$WG_IF.conf" <<EOF
$MARK
# N150 端：Table = off，不碰 N150 自己的默认路由；只往 table $RT_TABLE 加一条 default
[Interface]
Address = $WG_N150_ADDR/$WG_PREFIX
PrivateKey = $N150_WG_PRIVKEY
MTU = $WG_MTU
Table = off
PostUp = sysctl -qw net.ipv4.conf.%i.rp_filter=2
PostUp = ip route replace default dev %i table $RT_TABLE metric 100

[Peer]
# ECS（大陆），经本机 wstunnel 转发
PublicKey = $ECS_WG_PUBKEY
PresharedKey = $WG_PSK
Endpoint = 127.0.0.1:$WG_LOCAL_UDP
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
umask 022

# ---- nftables ----
dns_set=$(echo "$UPSTREAM_DNS" | sed 's/ \+/, /g')
cat >/etc/cnwifi/cnwifi.nft <<EOF
$MARK
table inet cnwifi
delete table inet cnwifi
table inet cnwifi {
	chain prerouting_nat {
		type nat hook prerouting priority dstnat; policy accept;
		# 设备写死的 DNS（如 8.8.8.8，在大陆被墙）也劫持到本机 dnsmasq → $dns_set
		iifname "$LAN_IF" ip daddr != $LAN_ADDR udp dport 53 counter dnat ip to $LAN_ADDR
		iifname "$LAN_IF" ip daddr != $LAN_ADDR tcp dport 53 counter dnat ip to $LAN_ADDR
	}

	chain input {
		type filter hook input priority filter; policy accept;
		iifname "$LAN_IF" jump lan_input
		iifname "$WG_IF" ct state established,related accept
		iifname "$WG_IF" counter drop
	}

	chain lan_input {
		ct state established,related accept
		meta l4proto icmp accept
		udp dport { 53, 67 } accept
		tcp dport 53 accept
		counter reject with icmpx type admin-prohibited
	}

	chain forward {
		type filter hook forward priority filter; policy accept;
		iifname "$LAN_IF" oifname "$WG_IF" accept
		iifname "$WG_IF" oifname "$LAN_IF" ct state established,related accept
		iifname "$LAN_IF" oifname "$WAN_IF" counter drop comment "leak-guard"
		iifname "$LAN_IF" counter drop
		oifname "$LAN_IF" counter drop
		iifname "$WG_IF" counter drop
		oifname "$WG_IF" counter drop
	}

	chain mangle_forward {
		type filter hook forward priority mangle; policy accept;
		oifname "$WG_IF" tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
	}

	chain postrouting_nat {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "$WG_IF" counter masquerade
	}
}
EOF
"$NFT" -c -f /etc/cnwifi/cnwifi.nft || die "nft 规则语法检查失败"

# ---- dnsmasq ----
dnsver=$("$DNSMASQ" --version | awk 'NR==1{print $3}')
filter_aaaa=""
[[ $(printf '%s\n2.87\n' "$dnsver" | sort -V | head -1) == 2.87 ]] && filter_aaaa="filter-AAAA   # 回国 Wi-Fi 没有 IPv6，不下发 AAAA"
{
  echo "$MARK"
  echo "# 只服务回国 Wi-Fi（$LAN_IF），不影响 N150 上其它 DNS"
  cat <<EOF
interface=$LAN_IF
except-interface=lo
bind-dynamic
no-resolv
no-hosts
no-poll
EOF
  for d in $UPSTREAM_DNS; do echo "server=$d"; done
  cat <<EOF
domain-needed
bogus-priv
cache-size=2000
$filter_aaaa
dhcp-range=$DHCP_START,$DHCP_END,$LAN_MASK,12h
dhcp-option=option:router,$LAN_ADDR
dhcp-option=option:dns-server,$LAN_ADDR
dhcp-authoritative
dhcp-leasefile=/var/lib/cnwifi/dnsmasq.leases
pid-file=/run/cnwifi-dnsmasq.pid
log-facility=-
EOF
} >/etc/cnwifi/dnsmasq.conf
"$DNSMASQ" --test --conf-file=/etc/cnwifi/dnsmasq.conf >/dev/null 2>&1 || { "$DNSMASQ" --test --conf-file=/etc/cnwifi/dnsmasq.conf; die "dnsmasq 配置检查失败"; }

# ---- cnwifi 工具 ----
install -m 0755 "$HERE/n150/cnwifi" /usr/local/sbin/cnwifi

# ---- sysctl ----
cat >/etc/sysctl.d/99-zzz-cnwifi.conf <<EOF
$MARK
net.ipv4.ip_forward = 1
net.ipv6.conf.$LAN_IF.disable_ipv6 = 1
EOF

# ---- logrotate ----
cat >/etc/logrotate.d/cnwifi <<EOF
/var/log/cnwifi.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
EOF

# ---- 不让系统的网络管理器碰 LAN 口（地址由 cnwifi-policy.service 配置） ----
if systemctl is-active -q NetworkManager 2>/dev/null; then
  cat >/etc/NetworkManager/conf.d/90-cnwifi.conf <<EOF
$MARK
[keyfile]
unmanaged-devices+=interface-name:$LAN_IF
EOF
  nmcli general reload conf 2>/dev/null || systemctl reload NetworkManager || true
  log "NetworkManager: 已设置 $LAN_IF 为 unmanaged"
fi
if systemctl is-active -q systemd-networkd 2>/dev/null; then
  install -d /etc/systemd/network
  cat >/etc/systemd/network/05-cnwifi-lan.network <<EOF
$MARK
[Match]
Name=$LAN_IF

[Link]
Unmanaged=yes
EOF
  networkctl reload 2>/dev/null || true
  log "systemd-networkd/netplan: 已设置 $LAN_IF 为 unmanaged"
fi

# =====================================================================
# 4. systemd 单元
# =====================================================================
LAN_DEV="sys-subsystem-net-devices-$(systemd-escape "$LAN_IF" 2>/dev/null || echo "$LAN_IF").device"
cat >/etc/systemd/system/cnwifi-policy.service <<EOF
$MARK
[Unit]
Description=cnwifi fail-closed guard (nft + policy routing + $LAN_IF address)
DefaultDependencies=no
After=local-fs.target systemd-sysctl.service systemd-modules-load.service nftables.service $LAN_DEV
Wants=$LAN_DEV network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target
# 有人重启 nftables.service（flush ruleset）时，跟着重新加载
PartOf=nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cnwifi apply

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/cnwifi-dnsmasq.service <<EOF
$MARK
[Unit]
Description=cnwifi dnsmasq (DHCP + DNS, $LAN_IF only)
Requires=cnwifi-policy.service
After=cnwifi-policy.service network.target

[Service]
ExecStartPre=$DNSMASQ --test --conf-file=/etc/cnwifi/dnsmasq.conf
ExecStart=$DNSMASQ -k --conf-file=/etc/cnwifi/dnsmasq.conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/cnwifi-wstunnel.service <<EOF
$MARK
[Unit]
Description=cnwifi wstunnel client (udp 127.0.0.1:$WG_LOCAL_UDP -> wss://$ECS_IP:$WSTUNNEL_PORT)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=wstunnel
Group=wstunnel
EnvironmentFile=/etc/cnwifi/wstunnel-client.env
ExecStart=/usr/local/bin/wstunnel client \\
  --connection-retry-max-backoff 30s \\
  -L udp://127.0.0.1:\${WG_LOCAL_UDP}:127.0.0.1:\${WG_PORT}?timeout_sec=0 \\
  wss://\${ECS_IP}:\${WSTUNNEL_PORT}
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

install -d "/etc/systemd/system/wg-quick@$WG_IF.service.d"
cat >"/etc/systemd/system/wg-quick@$WG_IF.service.d/cnwifi.conf" <<EOF
$MARK
[Unit]
Wants=cnwifi-policy.service
After=cnwifi-policy.service cnwifi-wstunnel.service
EOF

cat >/etc/systemd/system/cnwifi-watchdog.service <<EOF
$MARK
[Unit]
Description=cnwifi watchdog (tunnel health + guard self-heal)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cnwifi watchdog
EOF

cat >/etc/systemd/system/cnwifi-watchdog.timer <<EOF
$MARK
[Unit]
Description=cnwifi watchdog every minute

[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

# =====================================================================
# 5. 启动（顺序：防护 → DHCP/DNS → 隧道 → 看门狗）
# =====================================================================
sysctl -q -p /etc/sysctl.d/99-zzz-cnwifi.conf 2>/dev/null || true
if have_systemd; then
  systemctl daemon-reload
  systemctl enable cnwifi-policy.service cnwifi-dnsmasq.service cnwifi-wstunnel.service \
                   "wg-quick@$WG_IF.service" cnwifi-watchdog.timer >/dev/null 2>&1
  # 已有防护时可以安全地重置规则（nft 里的 leak-guard 先就位）
  if nft list table inet cnwifi >/dev/null 2>&1; then /usr/local/sbin/cnwifi apply --reset; fi
  systemctl restart cnwifi-policy.service
  systemctl restart cnwifi-dnsmasq.service
  systemctl restart cnwifi-wstunnel.service
  systemctl restart "wg-quick@$WG_IF.service"
  systemctl restart cnwifi-watchdog.timer
  for u in cnwifi-policy cnwifi-dnsmasq cnwifi-wstunnel "wg-quick@$WG_IF" cnwifi-watchdog.timer; do
    systemctl is-active -q "$u" || { systemctl --no-pager -l status "$u" | tail -20; die "$u 没起来"; }
  done
  log "所有服务已启动，等待隧道握手 ..."
  for _ in $(seq 15); do ping -n -q -c1 -W2 -I "$WG_IF" "$WG_ECS_ADDR" >/dev/null 2>&1 && break; sleep 2; done
  /usr/local/sbin/cnwifi test || warn "自检有失败项，见上面输出"
else
  warn "没有 systemd（测试环境？），只写了文件，没有启动服务"
fi
