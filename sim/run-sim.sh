#!/usr/bin/env bash
# 仿真测试：用 network namespace 搭出完整拓扑，跑真实的 ECS / N150 安装脚本、wstunnel、WireGuard、
# dnsmasq、nftables、策略路由，然后逐条验证验收标准和 fail-closed。仅用于开发验证。
#
#   [client]──eth1──[n150]──eth0──┐                       ┌──[ecs] 203.0.113.10
#    回国Wi-Fi                     [home] 198.51.100.2 ──[net]── 192.0.2.1 (查IP网站)
#   [lan] 192.168.1.20 ───────────┘ 新加坡宽带             ├── 223.5.5.5/223.6.6.6 (模拟阿里DNS)
#                                                          └── 8.8.8.8 (模拟被墙的谷歌DNS)
#
# 用法: sudo sim/run-sim.sh /path/to/wstunnel
set -uo pipefail
# 容器里的代理变量会干扰 netns 里的 curl
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy ALL_PROXY all_proxy
SIM=$(cd "$(dirname "$0")" && pwd); KIT=$(dirname "$SIM")
WSTUNNEL_BIN=${1:-/usr/local/bin/wstunnel}
W=/tmp/cnwifi-sim; WEBLOG=$W/web.log; ALIDNS_LOG=$W/alidns.log
NSS=(net ecs home n150 client lan)
PASS=0; FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
phase() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
X() { local ns=$1; shift; ip netns exec "$ns" "$@"; }
expect() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

cleanup() {
  [[ -n ${PROBE_PID:-} ]] && kill "$PROBE_PID" 2>/dev/null
  for ns in "${NSS[@]}"; do
    for p in $(ip netns pids "$ns" 2>/dev/null); do kill "$p" 2>/dev/null; done
  done
  sleep 0.5
  for ns in "${NSS[@]}"; do ip netns del "$ns" 2>/dev/null; done
  [[ -e /var/log/cnwifi.log ]] && cp /var/log/cnwifi.log "$W/cnwifi.log" 2>/dev/null
  [[ ${1:-} == start ]] && rm -rf /run/sim /tmp/cnwifi-sim-logs
  for ns in ecs n150; do [[ -d /etc/netns/$ns/systemd/system ]] && { rm -rf "$W/units-$ns"; cp -r "/etc/netns/$ns/systemd/system" "$W/units-$ns"; }; done 2>/dev/null
  rm -rf /etc/netns/ecs /etc/netns/n150 /run/cnwifi /var/log/cnwifi.log /var/lib/cnwifi /var/run/wireguard/*.sock
  rm -f /usr/local/sbin/systemctl /usr/local/sbin/cnwifi
  rmdir /run/systemd/system 2>/dev/null; rmdir /run/systemd 2>/dev/null
}
trap cleanup EXIT
cleanup start 2>/dev/null

# ---------------------------------------------------------------------------
phase "P0 搭拓扑"
rm -rf "$W"; mkdir -p "$W"
for ns in "${NSS[@]}"; do ip netns add "$ns"; X "$ns" ip link set lo up; done
veth() { ip link add "$2" netns "$1" type veth peer name "$4" netns "$3"; X "$1" ip link set "$2" up; X "$3" ip link set "$4" up; }
veth net n-ecs ecs eth0
veth net n-home home wan0
veth home h-n150 n150 eth0
veth home h-lan lan eth0
veth n150 eth1 client eth0

X net sysctl -qw net.ipv4.ip_forward=1
X net ip addr add 203.0.113.1/24 dev n-ecs
X net ip addr add 198.51.100.1/24 dev n-home
for a in 192.0.2.1 223.5.5.5 223.6.6.6 8.8.8.8; do X net ip addr add $a/32 dev lo; done

X ecs ip addr add 203.0.113.10/24 dev eth0; X ecs ip route add default via 203.0.113.1

X home sysctl -qw net.ipv4.ip_forward=1
X home ip addr add 198.51.100.2/24 dev wan0; X home ip route add default via 198.51.100.1
X home ip link add br0 type bridge; X home ip link set br0 up
X home ip link set h-n150 master br0; X home ip link set h-lan master br0
X home ip addr add 192.168.1.1/24 dev br0
# 最坏情况：主路由对任何源地址都做 NAT，且有回国网段的回程路由 → 一旦 N150 漏包，就能完整连出去
X home ip route add 192.168.50.0/24 via 192.168.1.10
X home nft -f - <<'EOF'
table ip nat {
  chain post { type nat hook postrouting priority 100; oifname "wan0" masquerade; }
}
EOF

X n150 ip addr add 192.168.1.10/24 dev eth0; X n150 ip route add default via 192.168.1.1
X n150 sysctl -qw net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.default.rp_filter=1   # 模拟严格 rp_filter
X lan ip addr add 192.168.1.20/24 dev eth0; X lan ip route add default via 192.168.1.1

# 模拟互联网服务
cat >"$W/web.py" <<'EOF'
import http.server, sys
LOG = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        ip = self.client_address[0]
        with open(LOG, "a") as f: f.write(f"{ip} {self.path}\n")
        body = (b"x" * 4_000_000) if self.path == "/big" else f"当前 IP：{ip}\n".encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("192.0.2.1", 80), H).serve_forever()
EOF
touch "$WEBLOG" "$ALIDNS_LOG"; chmod 666 "$WEBLOG" "$ALIDNS_LOG"
X net python3 "$W/web.py" "$WEBLOG" >/dev/null 2>&1 &
X net dnsmasq --conf-file=/dev/null -x "$W/alidns.pid" --listen-address=223.5.5.5,223.6.6.6 --bind-interfaces \
  --no-resolv --no-hosts --address=/www.taobao.com/192.0.2.80 --address=/#/192.0.2.99 \
  --log-queries --log-facility="$ALIDNS_LOG" -u root
X net dnsmasq --conf-file=/dev/null -x "$W/gdns.pid" --listen-address=8.8.8.8 --bind-interfaces \
  --no-resolv --no-hosts --address=/#/6.6.6.6 -u root
sleep 1
expect "lan → 网站可达（新加坡出口 198.51.100.2）" bash -c "X() { ip netns exec \"\$@\"; }; X lan curl -fsS --max-time 3 http://192.0.2.1/ | grep -q 198.51.100.2"

# fake systemd
mkdir -p /run/systemd/system /etc/cnwifi /etc/wireguard /var/run/wireguard
install -m 0755 "$SIM/fake-systemctl" /usr/local/sbin/systemctl
for ns in ecs n150; do
  for d in cnwifi wireguard systemd sysctl.d logrotate.d; do mkdir -p "/etc/netns/$ns/$d"; done
  mkdir -p "/etc/netns/$ns/systemd/system"
done

# ---------------------------------------------------------------------------
phase "P1 生成配置 + ECS 安装"
cp -r "$KIT" "$W/kit"; rm -rf "$W/kit/sim" "$W/kit/config.env" "$W/kit/dist"
mkdir -p "$W/kit/dist"
install -m 0755 "$WSTUNNEL_BIN" "$W/kit/dist/wstunnel-linux-amd64"
install -m 0755 "$WSTUNNEL_BIN" "$W/kit/dist/wstunnel-linux-arm64"
X n150 "$W/kit/gen-config.sh" 203.0.113.10 || { fail "gen-config"; exit 1; }
sed -i 's|^IPCHECK_URLS=.*|IPCHECK_URLS="http://192.0.2.1/"|' "$W/kit/config.env"
grep -E '^(WAN_IF|LAN_IF|WSTUNNEL_PORT)=' "$W/kit/config.env" | sed 's/^/  /'
X n150 "$W/kit/make-ecs-bundle.sh" >/dev/null || { fail "make-ecs-bundle"; exit 1; }
# wireguard-go 的控制 socket 在 /var/run/wireguard/<if>.sock，两个 netns 共用文件系统，ECS 端换个接口名避免冲突
mkdir -p "$W/ecs"; tar -C "$W/ecs" -xzf "$W/kit/dist/cnwifi-ecs.tar.gz"
sed -i 's/^WG_IF=.*/WG_IF=wgecs/' "$W/ecs/cnwifi-ecs/ecs.env"
if X ecs bash "$W/ecs/cnwifi-ecs/setup.sh" >"$W/ecs-setup.log" 2>&1; then pass "ECS setup.sh 成功"; else fail "ECS setup.sh 失败"; tail -30 "$W/ecs-setup.log"; exit 1; fi
grep -E '服务|监听' "$W/ecs-setup.log" | sed 's/^/    /'
PORT=$(sed -n 's/^WSTUNNEL_PORT=\([0-9]*\).*/\1/p' "$W/kit/config.env")
expect "ECS: wstunnel 监听 TCP $PORT" bash -c "ip netns exec ecs ss -ltn 'sport = :$PORT' | grep -q LISTEN"
expect "ECS: WG UDP 51820 对外丢弃（nft input 规则存在）" bash -c "ip netns exec ecs nft list chain inet cnwifi input | grep -q 'udp dport 51820'"

# ---------------------------------------------------------------------------
phase "P2 N150 安装"
if X n150 "$W/kit/n150/setup.sh" >"$W/n150-setup.log" 2>&1; then pass "N150 setup.sh 成功（含 cnwifi test）"; else fail "N150 setup.sh 失败"; fi
sed -n '/\[1\] 服务/,$p' "$W/n150-setup.log" | sed 's/^/    /'

# ---------------------------------------------------------------------------
phase "P3 验收：回国 Wi-Fi 客户端"
cat >"$W/udhcpc.sh" <<'EOF'
#!/bin/sh
case "$1" in
  bound|renew)
    ip addr flush dev "$interface"; ip addr add "$ip/${mask:-24}" dev "$interface"
    ip route replace default via "$router"
    : > /tmp/cnwifi-sim/client-resolv; for d in $dns; do echo "nameserver $d" >> /tmp/cnwifi-sim/client-resolv; done ;;
esac
EOF
chmod +x "$W/udhcpc.sh"
X client busybox udhcpc -i eth0 -n -q -t 5 -s "$W/udhcpc.sh" >"$W/udhcpc.log" 2>&1
CIP=$(X client ip -4 -o addr show dev eth0 | awk '{print $4}')
expect "客户端 DHCP 拿到地址 $CIP（池 100–150）" bash -c "[[ '$CIP' =~ ^192\.168\.50\.(1[0-4][0-9]|150)/24$ ]]"
expect "DHCP 下发网关 192.168.50.1" bash -c "ip netns exec client ip route | grep -q 'default via 192.168.50.1'"
expect "DHCP 下发 DNS 192.168.50.1" grep -q 'nameserver 192.168.50.1' "$W/client-resolv"
R=$(X client curl -fsS --max-time 5 http://192.0.2.1/ 2>&1)
echo "    客户端访问查IP网站: $R"
expect "验收1：回国 Wi-Fi 出口是 ECS (203.0.113.10)" bash -c "[[ '$R' == *203.0.113.10* ]]"
: >"$ALIDNS_LOG"
R=$(X client dig +short +time=3 +tries=1 @192.168.50.1 www.taobao.com)
expect "验收2：经 192.168.50.1 解析 www.taobao.com → $R（来自模拟阿里DNS）" bash -c "[[ '$R' == 192.0.2.80 ]]"
R=$(X client dig +short +time=3 +tries=1 @8.8.8.8 www.taobao.com)
expect "验收2：设备写死 8.8.8.8 也被劫持到 223.5.5.5（得到 $R，而非 6.6.6.6）" bash -c "[[ '$R' == 192.0.2.80 ]]"
sleep 0.5
expect "验收2：阿里DNS 看到的查询来源是 ECS 203.0.113.10（经隧道）" grep -q 'from 203.0.113.10' "$ALIDNS_LOG"
expect "验收2：阿里DNS 没有收到来自新加坡 IP 的查询" bash -c "! grep -q 'from 198.51.100.2' '$ALIDNS_LOG'"
R=$(X lan curl -fsS --max-time 5 http://192.0.2.1/)
expect "验收5：主 Wi-Fi 设备出口仍是新加坡 198.51.100.2" bash -c "[[ '$R' == *198.51.100.2* ]]"
R=$(X n150 curl -fsS --max-time 5 http://192.0.2.1/)
expect "验收5：N150 自身出口仍是新加坡（Table=off 没动默认路由）" bash -c "[[ '$R' == *198.51.100.2* ]]"
SZ=$(X client curl -fsS --max-time 30 -o /dev/null -w '%{size_download}' http://192.0.2.1/big)
expect "大文件经隧道下载完整（MTU/MSS clamp 正常）: $SZ 字节" bash -c "[[ '$SZ' == 4000000 ]]"
expect "客户端访问 N150 主网段 192.168.1.1 被拒（隔离）" bash -c "! ip netns exec client curl -fsS --max-time 3 http://192.168.1.1/ >/dev/null 2>&1"

# ---------------------------------------------------------------------------
phase "P4 验收3：fail-closed 断网演练（客户端持续探测，网站记录来源 IP）"
echo normal >"$W/probe-phase"
( while :; do ip netns exec client curl -s --max-time 2 "http://192.0.2.1/probe-$(cat "$W/probe-phase")" >/dev/null 2>&1; sleep 0.3; done ) &
PROBE_PID=$!
sleep 2
echo outage >"$W/probe-phase"
X n150 cnwifi failtest 0 >"$W/failtest.log" 2>&1; rc=$?
sed 's/^/    /' "$W/failtest.log"
expect "cnwifi failtest 通过" test $rc -eq 0
echo after >"$W/probe-phase"; sleep 4
expect "断网期间：网站从未收到来自新加坡 IP 的客户端探测" bash -c "! grep -E '^198\.51\.100\.2 /probe-outage' '$WEBLOG'"
expect "恢复后：探测重新经 ECS 到达" grep -qE '^203\.0\.113\.10 /probe-after' "$WEBLOG"
grep -c probe-outage "$WEBLOG" | sed 's/^/    断网期间到达网站的探测数（应很少，只有停服务前的在途请求）: /'

phase "P4b 更狠：N150 上本来就有 eth0 MASQUERADE + 隧道全停"
X n150 nft -f - <<'EOF'
table ip legacy_nat {
  chain post { type nat hook postrouting priority 100; oifname "eth0" masquerade; }
}
EOF
echo outage2 >"$W/probe-phase"
X n150 systemctl stop cnwifi-watchdog.timer cnwifi-wstunnel "wg-quick@wg0"
sleep 5
expect "隧道全停 + 有 eth0 NAT：没有探测以新加坡 IP 到达" bash -c "! grep -qE '^198\.51\.100\.2 /probe-outage2' '$WEBLOG'"
expect "客户端 DNS 也不通（上游 DNS 黑洞，不会走新加坡查询）" bash -c "! ip netns exec client dig +short +time=2 +tries=1 @192.168.50.1 www.taobao.com | grep -q ."

phase "P5 纵深防御：逐层拆掉防护，确认下一层兜住"
X n150 ip route flush table 100
echo outage3 >"$W/probe-phase"; sleep 3
expect "拆掉 table 100（含黑洞路由）→ ip rule 1001 blackhole 兜住" bash -c "! grep -qE '^198\.51\.100\.2 /probe-outage3' '$WEBLOG'"
C0=$(X n150 nft -a list chain inet cnwifi forward | awk '/leak-guard/{for(i=1;i<=NF;i++) if($i=="packets"){print $(i+1)}}')
X n150 ip rule del pref 1000; X n150 ip rule del pref 1001
echo outage4 >"$W/probe-phase"; sleep 3
C1=$(X n150 nft -a list chain inet cnwifi forward | awk '/leak-guard/{for(i=1;i<=NF;i++) if($i=="packets"){print $(i+1)}}')
expect "再拆掉 ip rule → nft leak-guard 兜住（没有新加坡探测）" bash -c "! grep -qE '^198\.51\.100\.2 /probe-outage4' '$WEBLOG'"
expect "leak-guard 计数增加 $C0 → $C1（证明是它拦下的）" test "${C1:-0}" -gt "${C0:-0}"
X n150 cnwifi watchdog
expect "看门狗自愈：规则/黑洞路由已恢复" bash -c "ip netns exec n150 cnwifi check >/dev/null"
grep -E '防护缺失' /var/log/cnwifi.log | tail -1 | sed 's/^/    日志: /'
X n150 nft delete table ip legacy_nat

phase "P6 看门狗：隧道恢复 / wstunnel 崩溃自动重启"
X n150 systemctl start cnwifi-wstunnel "wg-quick@wg0" cnwifi-watchdog.timer
for _ in $(seq 15); do X n150 ping -c1 -W1 -I wg0 10.66.66.1 >/dev/null 2>&1 && break; sleep 1; done
expect "手动恢复后隧道通" X n150 ping -c1 -W2 -I wg0 10.66.66.1
kill -9 "$(cat /run/sim/n150/cnwifi-wstunnel.service.pid)"   # 模拟 wstunnel 崩溃（真实 systemd 会 3 秒后自动拉起，这里只靠看门狗）
sleep 1
X n150 cnwifi watchdog; X n150 cnwifi watchdog
sleep 1
for _ in $(seq 20); do X n150 ping -c1 -W1 -I wg0 10.66.66.1 >/dev/null 2>&1 && break; sleep 1; done
expect "看门狗连续两次检测失败后重启 wstunnel/wg0，隧道恢复" X n150 ping -c1 -W2 -I wg0 10.66.66.1
X n150 cnwifi watchdog
grep -E '隧道|重启' /var/log/cnwifi.log | tail -4 | sed 's/^/    日志: /'
expect "日志记录了'隧道不通''重启''隧道恢复'" bash -c "grep -q 隧道不通 /var/log/cnwifi.log && grep -q 重启 /var/log/cnwifi.log && grep -q 隧道恢复 /var/log/cnwifi.log"

phase "P7 验收4：模拟 N150 重启（清空所有运行时状态，按 systemd 顺序拉起）"
for u in cnwifi-watchdog.timer "wg-quick@wg0" cnwifi-wstunnel cnwifi-dnsmasq cnwifi-policy; do X n150 systemctl stop "$u"; done
X n150 nft flush ruleset; X n150 ip rule flush; X n150 ip rule add pref 0 lookup local; X n150 ip rule add pref 32766 lookup main; X n150 ip rule add pref 32767 lookup default
X n150 ip route flush table 100; X n150 ip addr flush dev eth1; X n150 ip link set eth1 down
X n150 sysctl -qw net.ipv4.ip_forward=0
echo boot >"$W/probe-phase"
expect "开机前（cnwifi-policy 未运行）：客户端连网关都没有，无法出网" bash -c "! ip netns exec client curl -s --max-time 2 http://192.0.2.1/ >/dev/null"
X n150 sysctl -q -p /etc/sysctl.d/99-zzz-cnwifi.conf 2>/dev/null   # systemd-sysctl
for u in cnwifi-policy cnwifi-dnsmasq cnwifi-wstunnel "wg-quick@wg0" cnwifi-watchdog.timer; do
  X n150 systemctl start "$u" || fail "启动 $u"
done
for _ in $(seq 20); do X client curl -fsS --max-time 2 http://192.0.2.1/ 2>/dev/null | grep -q 203.0.113.10 && break; sleep 1; done
R=$(X client curl -fsS --max-time 3 http://192.0.2.1/)
expect "N150 重启后自动恢复，客户端出口 = ECS（$R）" bash -c "[[ '$R' == *203.0.113.10* ]]"
expect "开机过程中没有任何新加坡出口的客户端探测" bash -c "! grep -qE '^198\.51\.100\.2 /probe-boot' '$WEBLOG'"

phase "P8 验收4：模拟 ECS 重启（N150 不动，靠 wstunnel 重连 + WG keepalive 自动恢复）"
for u in cnwifi-wstunnel-server "wg-quick@wgecs" cnwifi-fw; do X ecs systemctl stop "$u"; done
X ecs nft flush ruleset; X ecs sysctl -qw net.ipv4.ip_forward=0
echo ecsdown >"$W/probe-phase"; sleep 3
expect "ECS 宕机期间客户端断网，且没有新加坡出口" bash -c "! grep -qE '^198\.51\.100\.2 /probe-ecsdown' '$WEBLOG'"
X ecs sysctl -q -p /etc/sysctl.d/99-zzz-cnwifi.conf 2>/dev/null
for u in cnwifi-fw "wg-quick@wgecs" cnwifi-wstunnel-server; do X ecs systemctl start "$u" || fail "ECS 启动 $u"; done
ok=0
for i in $(seq 60); do
  X client curl -fsS --max-time 2 http://192.0.2.1/ 2>/dev/null | grep -q 203.0.113.10 && { ok=1; break; }
  (( i % 20 == 0 )) && X n150 cnwifi watchdog
  sleep 1
done
expect "ECS 重启后隧道自动恢复（${i}s）" test $ok -eq 1

phase "P9 其它"
if [[ -d /proc/sys/net/ipv6 ]]; then
  expect "eth1 已禁用 IPv6" bash -c "[[ \$(ip netns exec n150 sysctl -n net.ipv6.conf.eth1.disable_ipv6) == 1 ]]"
else
  echo "    （本容器内核未编译 IPv6，跳过 IPv6 检查；nft inet 表的 forward 链对 IPv6 同样只放行 eth1↔wg0）"
fi
expect "ECS 防火墙禁止隧道访问阿里云元数据 100.100.100.200" bash -c "ip netns exec ecs nft list set inet cnwifi no_go | grep -q 100.64.0.0/10"
expect "WG 密钥/路径密钥文件权限 600" bash -c "[[ \$(stat -c %a /etc/netns/n150/wireguard/wg0.conf) == 600 && \$(stat -c %a /etc/netns/n150/cnwifi/wstunnel-client.env) == 600 ]]"
expect "路径密钥不出现在进程命令行里" bash -c "! ps -eo args | grep -v grep | grep -q \$(sed -n 's/^PATH_SECRET=\([0-9a-f]*\).*/\1/p' $W/kit/config.env)"
SECRET=$(sed -n 's/^PATH_SECRET=\([0-9a-f]*\).*/\1/p' "$W/kit/config.env")
SRVLOG=/run/sim/ecs/cnwifi-wstunnel-server.service.log
probe_ws() {  # $1=前缀 $2=-L 规格；发几个 UDP 包，返回服务端新增日志
  local before; before=$(wc -l <"$SRVLOG")
  ip netns exec n150 setpriv --reuid=wstunnel --regid=wstunnel --init-groups env NO_COLOR=true wstunnel client -P "$1" -L "$2" "wss://203.0.113.10:$PORT" >/dev/null 2>&1 &
  local pid=$!; sleep 1
  X n150 bash -c 'for i in 1 2 3; do echo x >/dev/udp/127.0.0.1/55555; sleep 0.3; done'
  sleep 1; kill $pid 2>/dev/null; wait $pid 2>/dev/null
  tail -n +$((before + 1)) "$SRVLOG"
}
OUT=$(probe_ws wrongsecret 'udp://127.0.0.1:55555:127.0.0.1:51820?timeout_sec=0')
echo "$OUT" | grep -iE 'reject|path|prefix|denied|not allowed|restrict' | head -2 | sed 's/^/    服务端日志: /'
if grep -q "Rejecting connection.*port: 51820" <<<"$OUT"; then pass "ECS: 错误路径密钥的 wstunnel 客户端被拒"; else fail "ECS: 错误路径密钥的 wstunnel 客户端被拒"; fi
OUT=$(probe_ws "$SECRET" 'udp://127.0.0.1:55555:127.0.0.1:53?timeout_sec=0')
echo "$OUT" | grep -iE 'reject|path|prefix|denied|not allowed|restrict' | head -2 | sed 's/^/    服务端日志: /'
if grep -q "Rejecting connection.*port: 53" <<<"$OUT"; then pass "ECS: 密钥正确但目标不是 127.0.0.1:51820 也被拒（--restrict-to）"; else fail "ECS: 密钥正确但目标不是 127.0.0.1:51820 也被拒（--restrict-to）"; fi
X n150 cnwifi status >"$W/status.log" 2>&1; sed 's/^/    /' "$W/status.log"

phase "结果"
printf '  PASS %d   FAIL %d\n' "$PASS" "$FAIL"
((FAIL == 0))
