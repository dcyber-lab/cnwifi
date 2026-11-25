#!/usr/bin/env bash
# 只读预检：看清 N150 的网卡、路由、网络管理器、防火墙、端口占用，不做任何修改。
#   用法: sudo ./preflight.sh
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"
sec() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

sec "系统"
. /etc/os-release 2>/dev/null; echo "  $PRETTY_NAME / kernel $(uname -r) / $(uname -m)"
if modinfo wireguard >/dev/null 2>&1 || [[ -d /sys/module/wireguard ]]; then echo "  WireGuard 内核模块: 有"; else echo "  WireGuard 内核模块: 未找到"; fi
for c in wg nft dnsmasq curl dig tcpdump ss; do printf '  %-8s %s\n' "$c" "$(command -v $c || echo -)"; done

sec "网卡"
ip -br link | sed 's/^/  /'
echo; ip -br -4 addr | sed 's/^/  /'
wan=$(detect_wan_if); lan=$(detect_lan_if "$wan")
echo; echo "  物理有线网卡: $(list_physical_eth | tr '\n' ' ')"
echo "  推测 WAN（默认路由）: ${wan:-?}    推测 LAN（接 AP）: ${lan:-无法判断，需手动指定}"
for n in $(list_physical_eth); do
  printf '  %-12s 链路=%s 速率=%s master=%s\n' "$n" "$(cat /sys/class/net/$n/carrier 2>/dev/null | sed 's/1/up/;s/0/down/')" \
    "$(cat /sys/class/net/$n/speed 2>/dev/null || echo ?)" "$(basename "$(readlink /sys/class/net/$n/master 2>/dev/null)" 2>/dev/null || true)"
done
for n in $(list_wireless); do
  modes=$(wifi_modes "$n")
  if [[ -z $modes ]]; then ap="未知（装 iw 后再看）"; elif grep -qx AP <<<"$modes"; then ap="支持（没有 AP 时可作 LAN_IF，见 README）"; else ap="不支持"; fi
  printf '  %-12s 无线网卡  热点(AP)模式=%s\n' "$n" "$ap"
done

sec "路由 / 策略路由"
ip -4 route | sed 's/^/  /'
echo; ip rule | sed 's/^/  /'
ip route show table 100 2>/dev/null | grep -q . && { echo "  table 100:"; ip route show table 100 | sed 's/^/    /'; }
echo "  ip_forward=$(sysctl -n net.ipv4.ip_forward)  rp_filter(all)=$(sysctl -n net.ipv4.conf.all.rp_filter)"

sec "网络管理"
for s in NetworkManager systemd-networkd networking dhcpcd systemd-resolved; do
  printf '  %-18s %s\n' "$s" "$(systemctl is-active $s 2>/dev/null)"
done
ls /etc/netplan/*.yaml 2>/dev/null | sed 's/^/  netplan: /'
grep -rnsE '^\s*(auto|allow-hotplug|iface)\s' /etc/network/interfaces /etc/network/interfaces.d/ 2>/dev/null | sed 's/^/  ifupdown: /'
command -v nmcli >/dev/null && nmcli -t -f DEVICE,STATE,CONNECTION dev 2>/dev/null | sed 's/^/  nmcli: /'
command -v networkctl >/dev/null && networkctl list --no-legend 2>/dev/null | sed 's/^/  networkctl: /'

sec "防火墙"
for s in firewalld ufw docker nftables; do printf '  %-10s %s\n' "$s" "$(systemctl is-active $s 2>/dev/null)"; done
nft list tables 2>/dev/null | sed 's/^/  nft: /'
iptables -S FORWARD 2>/dev/null | head -5 | sed 's/^/  iptables: /'

sec "端口 53 / 67 占用"
ss -lunp 2>/dev/null | awk 'NR==1 || $4 ~ /:(53|67)$/' | sed 's/^/  /'

sec "已有 WireGuard"
ls /etc/wireguard/ 2>/dev/null | sed 's/^/  /'; ip -br link show type wireguard 2>/dev/null | sed 's/^/  /'

sec "外网"
curl -4 -fsS --max-time 8 https://myip.ipip.net 2>/dev/null | sed 's/^/  家里出口: /' || echo "  家里出口: 查询失败"
curl -fsSI --max-time 8 https://github.com >/dev/null 2>&1 && echo "  GitHub: 可访问" || echo "  GitHub: 不可访问"

sec "ECS 访问方式"
command -v aliyun >/dev/null && echo "  aliyun CLI: $(command -v aliyun)" || echo "  aliyun CLI: 无"
ls ~/.ssh/ 2>/dev/null | sed 's/^/  ~\/.ssh: /'
[[ -n ${SUDO_USER:-} ]] && ls "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/" 2>/dev/null | sed "s/^/  ~$SUDO_USER\/.ssh: /"
