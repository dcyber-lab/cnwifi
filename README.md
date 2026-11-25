# cnwifi — 回国 Wi-Fi（N150 + 阿里云 ECS）

连「回国 Wi-Fi」的设备，全部流量经 wstunnel(WSS) 包裹的 WireGuard 从阿里云大陆 ECS 出去；
隧道断了就**断网**，绝不回落到新加坡 IP。家里其它设备不受影响。

```
主路由 192.168.1.0/24 (新加坡)
   │
 [WAN_IF] N150 [LAN_IF 192.168.50.1] ── AP(桥接, 关DHCP) ── 回国 Wi-Fi: 扫地机/电视/手机
   │
   └─ wstunnel client ──WSS(TCP 3xxxx, 直连 IP)──▶ ECS wstunnel server ─▶ 127.0.0.1:51820 WireGuard ─▶ 大陆出口
```

没有 AP 时，LAN_IF 也可以直接用 N150 自带的无线网卡，由 N150 自己发射回国 Wi-Fi（见[下文](#没有-ap-时用-n150-自带无线)）。

## 文件

| 文件 | 在哪跑 | 作用 |
|---|---|---|
| `preflight.sh` | N150 | 只读预检：网卡（含无线网卡是否支持 AP）、路由、网络管理器、防火墙、53/67 端口 |
| `gen-config.sh <ECS_IP>` | N150 | 生成 `config.env`：随机端口、路径密钥、两端 WG 密钥、热点密码（含私钥，600 权限） |
| `fetch-wstunnel.sh` | N150 | 从 GitHub 下载 wstunnel v11.1.0（amd64+arm64）并校验 sha256 |
| `make-ecs-bundle.sh` | N150 | 打包 `dist/cnwifi-ecs.tar.gz`（只含 ECS 需要的密钥） |
| `deploy-ecs.sh [root@IP] [ssh参数]` | N150 | scp + ssh 到 ECS 执行安装 |
| `ecs/setup.sh` | ECS | ECS 端安装（WG、wstunnel、nftables、systemd） |
| `n150/setup.sh` | N150 | N150 端安装（WG、wstunnel、dnsmasq、策略路由、nftables、看门狗；LAN_IF 是无线网卡时再加 hostapd 热点）。可重复运行，换 LAN 口也直接重跑 |
| `n150/cnwifi` | N150 | 装到 `/usr/local/sbin/cnwifi`：status / test / failtest / watchdog / uninstall |
| `sim/` | 开发机 | 网络命名空间仿真测试（含换 LAN 口重装），不用部署 |

N150 上安装后生成的文件（都在 `/etc/cnwifi/` 和 `/etc/systemd/system/`）：

| 文件 | 作用 |
|---|---|
| `cnwifi.env` | `cnwifi` 工具读的配置（不含密钥） |
| `wstunnel-client.env`、`/etc/wireguard/wg0.conf` | 路径密钥、WG 私钥（600） |
| `cnwifi.nft`、`dnsmasq.conf` | 防火墙规则；只服务 LAN_IF 的 DHCP/DNS |
| `hostapd.conf` | 仅热点模式：SSID、Wi-Fi 密码（600） |
| `cnwifi-policy.service` | 开机最先跑 `cnwifi apply`：防火墙 → 黑洞路由 → 策略规则 → 网关地址 |
| `cnwifi-dnsmasq.service`、`cnwifi-wstunnel.service`、`wg-quick@wg0`、`cnwifi-watchdog.timer` | DHCP/DNS、隧道、看门狗 |
| `cnwifi-hostapd.service` | 仅热点模式：`Requires/After=cnwifi-policy`，防护就位后才发射信号 |
| `cnwifi-wstunnel.service.d/bbr.conf` | wstunnel 每次启动前跑 `cnwifi bbr-route`：只给到 ECS 的主机路由开 BBR |

## 部署步骤

```bash
# 在 N150 上（把整个 cnwifi 目录拷过去）
sudo ./preflight.sh                 # 先看清网卡名，确认 LAN 口
sudo apt install -y wireguard-tools # gen-config 需要 wg 生成密钥
./gen-config.sh <ECS公网IP>          # 核对输出的 WAN_IF / LAN_IF，不对就改 config.env
./fetch-wstunnel.sh
./make-ecs-bundle.sh
./deploy-ecs.sh root@<ECS公网IP>     # 或：用 Workbench 上传 dist/cnwifi-ecs.tar.gz 后
                                    #     tar xzf cnwifi-ecs.tar.gz && bash cnwifi-ecs/setup.sh
```

**阿里云安全组**入方向只放行：TCP 22、TCP `WSTUNNEL_PORT`（gen-config 输出的 3xxxx）。UDP 51820 不要开。

```bash
sudo ./n150/setup.sh                # 装完自动跑 cnwifi test
sudo cnwifi failtest 60             # 断网演练；每步停 60 秒，期间用手机试 cip.cc 应打不开
```

## 没有 AP 时用 N150 自带无线

`gen-config.sh` 只自动识别有线 LAN 口。手头没有 AP（或 AP 没电）时，把 `config.env` 里的 `LAN_IF` 改成
N150 的无线网卡名（`sudo ./preflight.sh` 会列出无线网卡和是否支持 AP 模式，常见名字 `wlo1` / `wlp1s0`），
再跑 `sudo ./n150/setup.sh`。setup 发现 LAN_IF 是无线网卡就会：

- 安装 `hostapd` 和 `iw`。系统自带的 `hostapd.service`（Ubuntu 装完是 masked 的）保持不动，不用管；
- 按 `config.env` 写 `/etc/cnwifi/hostapd.conf`（权限 600），WPA2-PSK / CCMP，最多 16 台设备；
- 装 `cnwifi-hostapd.service`：`Requires=` + `After=cnwifi-policy.service`，**防火墙、策略路由、网关地址都就位之后才发射信号**，
  fail-closed 和有线模式完全一样。

热点参数在 `config.env` 里（gen-config 生成的新配置自带；旧配置没有就手动加上）：

```bash
LAN_IF=wlo1                  # 无线网卡名
WIFI_SSID=CN-WiFi            # 含空格或中文要加单引号，最长 32 字节
WIFI_PASS=xxxxxxxxxxxx       # WPA2 密码 8–63 位；gen-config 随机生成 12 位
WIFI_CHANNEL=11              # 只支持 2.4 GHz 信道 1–13
WIFI_COUNTRY=SG              # 国家代码，决定可用信道和发射功率
```

注意：

- **只开 2.4 GHz**。石头等扫地机、很多智能家居只认 2.4 GHz；Intel 网卡在 5 GHz 一般也不允许开 AP。
- 无线网卡要支持 AP 模式（`iw list` 的 `Supported interface modes` 里有 `* AP`，Intel AX101 实测可用），
  且不能同时拿来连家里 Wi-Fi：WAN 走有线。netplan 的 `wifis:` 里配了这块网卡的话先删掉，setup 预检会拦下。
- 网卡被 rfkill 软关闭时（`rfkill list` 显示 `Soft blocked: yes`）先 `sudo rfkill unblock wifi`。
- N150 内置天线一般较弱，尽量把 N150 放在扫地机附近。
- `cnwifi status` 的「Wi-Fi 热点」一栏显示 SSID、信道和已连接设备（MAC / IP / 主机名 / 信号）。
- 有线 ↔ 无线互换、或换别的网口：改 `LAN_IF` 后直接重跑 setup。上次安装留在旧网口上的网关地址和
  `iif 旧网口` 的策略路由会被识别为自己的、自动撤掉（期间 nft 防护一直加载着）；从无线换回有线时会停掉并删除 cnwifi-hostapd。

## fail-closed 是怎么保证的（四层，任何一层单独失效都不会漏）

1. **策略路由**：`ip rule pref 1000 iif LAN_IF lookup 100`；table 100 = `default dev wg0 metric 100` + `blackhole default metric 200`。
   wg0 一消失，它的路由随之消失，只剩黑洞。
2. **规则级黑洞**：`ip rule pref 1001 iif LAN_IF blackhole`。即使 table 100 被清空，也不会落到 main 表。
3. **nftables**（独立的 `table inet cnwifi`）：转发只放行 LAN↔wg0；`LAN → WAN` 显式丢弃并计数（leak-guard）。
4. **开机顺序**：`cnwifi apply` 先装防火墙、黑洞、规则，**最后**才给 LAN 口配 192.168.50.1。网关地址出现前设备根本无路可走。
   热点模式下 hostapd 排在这之后才启动，信号出现时防护早已就位。

另外：wstunnel 停了时，流量仍进 wg0，被 WireGuard 加密后发往已停止的本地端口然后丢弃，不可能明文出去。
上游 DNS（223.5.5.5/223.6.6.6）同样走 table 100 + 黑洞（pref 1002/1003），隧道断了 N150 也不会从新加坡去查。
看门狗每分钟检查一次，防护缺了会自动补回，隧道连续两次不通就重启 wstunnel 和 wg0，记录在 `/var/log/cnwifi.log` 和 journal（`journalctl -t cnwifi`）。

## 和原需求的几处差异（有意为之）

- **"WG 监听 127.0.0.1"**：内核 WireGuard 不能绑定到指定地址。改用 nftables 丢弃所有非 `lo` 进来的 UDP 51820，再加上安全组不开放，效果相同。
- **`ip rule from 192.168.50.0/24` 改为 `iif LAN_IF`**：用 `from` 会把 N150 自己回给客户端的 DNS/DHCP 应答也导进 wg0（因为源地址 192.168.50.1 也在网段里）；
  而且 `iif` 更严：手动设了别的静态 IP 的设备也会被兜进隧道/黑洞。
- **额外加的**：
  - 劫持回国网段所有 53 端口到本机 dnsmasq：设备写死 8.8.8.8 这类 DNS 在大陆是被墙的。
  - ECS 禁止隧道访问内网和阿里云元数据 100.100.100.200。
  - wstunnel 用自签证书，不用它内置的证书，避免证书指纹被识别。
  - 用路径密钥做认证：错误密钥或非 WG 目标的连接都会被拒。
  - 回国网段禁用 IPv6；dnsmasq ≥ 2.87 时（Debian 12、Ubuntu 24.04）不下发 AAAA 记录。
  - 外层 wstunnel TCP 用 BBR。新加坡→广州晚高峰实测 RTT ~340ms、丢包 10–30%，cubic 下这条 TCP 会塌掉
    （ssthresh 掉到 2），WG 握手和看门狗 ping 跟着卡住，看门狗又反复重启 wstunnel；两端开 BBR 后隧道 ping 不丢包。
    ECS 是专用机，全局开（`/etc/sysctl.d/99-zzz-cnwifi-bbr.conf` + `/etc/modules-load.d/cnwifi-bbr.conf`）；
    N150 可能还跑着别的服务，只给到 ECS 的那条主机路由加 `congctl bbr`（`cnwifi bbr-route`，wstunnel 每次启动前刷新，
    失败不影响隧道）。`cnwifi status` 的「隧道」一栏显示当前用的是哪个算法。

## 日常

```bash
cnwifi status            # 服务 / 隧道 / 防护 / 租约 / 日志
sudo cnwifi test         # 验收自检
sudo cnwifi failtest 60  # 断网演练
journalctl -u cnwifi-wstunnel -u wg-quick@wg0 -f
journalctl -u cnwifi-hostapd -f   # 热点模式：设备连接/断开、认证失败
```

- 视频卡：ECS 带宽改按流量计费、调高峰值，不用换机器；MTU 可在 `config.env` 的 `WG_MTU` 调（1280–1380），改完两端重新跑 setup。
- 换密钥：`./gen-config.sh <IP> --force`，然后 ECS 和 N150 都重新安装。
- 卸载：`sudo cnwifi uninstall`（N150）。

## 扫地机配网

手机连回国 Wi-Fi，先打开 cip.cc 确认显示的是大陆 IP，再打开石头 App，地区选「中国大陆」，给扫地机配网，让扫地机连回国 Wi-Fi。配完手机切回家里 Wi-Fi 即可。
扫地机只支持 2.4 GHz：用外部 AP 时要开 2.4 GHz（或双频同名）；热点模式默认就是 2.4 GHz。
