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

## 文件

| 文件 | 在哪跑 | 作用 |
|---|---|---|
| `preflight.sh` | N150 | 只读预检：网卡、路由、网络管理器、防火墙、53/67 端口 |
| `gen-config.sh <ECS_IP>` | N150 | 生成 `config.env`：随机端口、路径密钥、两端 WG 密钥（含私钥，600 权限） |
| `fetch-wstunnel.sh` | N150 | 从 GitHub 下载 wstunnel v11.1.0（amd64+arm64）并校验 sha256 |
| `make-ecs-bundle.sh` | N150 | 打包 `dist/cnwifi-ecs.tar.gz`（只含 ECS 需要的密钥） |
| `deploy-ecs.sh [root@IP] [ssh参数]` | N150 | scp + ssh 到 ECS 执行安装 |
| `ecs/setup.sh` | ECS | ECS 端安装（WG、wstunnel、nftables、systemd） |
| `n150/setup.sh` | N150 | N150 端安装（WG、wstunnel、dnsmasq、策略路由、nftables、看门狗） |
| `n150/cnwifi` | N150 | 装到 `/usr/local/sbin/cnwifi`：status / test / failtest / watchdog / uninstall |
| `sim/` | 开发机 | 网络命名空间仿真测试（39 项），不用部署 |

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

## fail-closed 是怎么保证的（四层，任何一层单独失效都不会漏）

1. **策略路由**：`ip rule pref 1000 iif LAN_IF lookup 100`；table 100 = `default dev wg0 metric 100` + `blackhole default metric 200`。
   wg0 一消失，它的路由随之消失，只剩黑洞。
2. **规则级黑洞**：`ip rule pref 1001 iif LAN_IF blackhole`。即使 table 100 被清空，也不会落到 main 表。
3. **nftables**（独立的 `table inet cnwifi`）：转发只放行 LAN↔wg0；`LAN → WAN` 显式丢弃并计数（leak-guard）。
4. **开机顺序**：`cnwifi apply` 先装防火墙、黑洞、规则，**最后**才给 LAN 口配 192.168.50.1。网关地址出现前设备根本无路可走。

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

## 日常

```bash
cnwifi status            # 服务 / 隧道 / 防护 / 租约 / 日志
sudo cnwifi test         # 验收自检
sudo cnwifi failtest 60  # 断网演练
journalctl -u cnwifi-wstunnel -u wg-quick@wg0 -f
```

- 视频卡：ECS 带宽改按流量计费、调高峰值，不用换机器；MTU 可在 `config.env` 的 `WG_MTU` 调（1280–1380），改完两端重新跑 setup。
- 换密钥：`./gen-config.sh <IP> --force`，然后 ECS 和 N150 都重新安装。
- 卸载：`sudo cnwifi uninstall`（N150）。

## 扫地机配网

手机连回国 Wi-Fi，先打开 cip.cc 确认显示的是大陆 IP，再打开石头 App，地区选「中国大陆」，给扫地机配网，让扫地机连回国 Wi-Fi。配完手机切回家里 Wi-Fi 即可。
