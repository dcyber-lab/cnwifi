# shellcheck shell=bash
# cnwifi 公共函数（被 gen-config.sh / preflight.sh / n150/setup.sh 引用）

c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
log()  { printf '%s[cnwifi]%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%s[错误]%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "请用 root 运行（sudo $0 ...）"; }
have_systemd() { [[ -d /run/systemd/system ]]; }

load_config() {
  local f=$1
  [[ -r $f ]] || die "找不到配置文件 $f（先运行 ./gen-config.sh <ECS公网IP>）"
  # shellcheck disable=SC1090
  source "$f"
  local v
  for v in ECS_IP WSTUNNEL_PORT WSTUNNEL_VERSION PATH_SECRET WG_PORT WG_LOCAL_UDP \
           WG_IF WG_ECS_ADDR WG_N150_ADDR WG_PREFIX WG_MTU \
           LAN_IF WAN_IF LAN_ADDR LAN_PREFIX DHCP_START DHCP_END UPSTREAM_DNS RT_TABLE; do
    [[ -n ${!v:-} ]] || die "配置项 $v 为空（$f）"
  done
}

# 默认路由所在网卡（WAN）
detect_wan_if() {
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# 物理有线网卡（有 device 目录、不是无线网卡）
list_physical_eth() {
  local p n
  for p in /sys/class/net/*; do
    n=${p##*/}
    [[ -e $p/device ]] || continue
    [[ -d $p/wireless || -e $p/phy80211 ]] && continue
    echo "$n"
  done
}

# 猜测 LAN 口：除 WAN 以外唯一的物理有线网卡；猜不出来就返回空
detect_lan_if() {
  local wan=${1:-$(detect_wan_if)} cands=() n
  while read -r n; do [[ -n $n && $n != "$wan" ]] && cands+=("$n"); done < <(list_physical_eth)
  [[ ${#cands[@]} -eq 1 ]] && echo "${cands[0]}"
  return 0
}

# 192.168.50.0/24 -> 两个 CIDR 是否重叠（只处理 IPv4）
ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }
cidr_overlap() {
  local n1=${1%/*} p1=${1#*/} n2=${2%/*} p2=${2#*/} p m
  p=$(( p1 < p2 ? p1 : p2 ))
  m=$(( p == 0 ? 0 : (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  (( ($(ip2int "$n1") & m) == ($(ip2int "$n2") & m) ))
}
