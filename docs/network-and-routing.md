# 路由与网络规则

## 数据模型

网络访问由三类数据共同决定：

| 数据         | 路径                   | 作用                                                                       |
| ------------ | ---------------------- | -------------------------------------------------------------------------- |
| 用户地址状态 | `state/client-ips.csv` | 用户名、固定隧道 IP、设备信息和最近登录时间；防火墙按用户名关联客户端 IP。 |
| 用户 CCD     | `ccd/<user>`           | `ifconfig-push` 固定地址，以及 `push "route IP MASK"` 用户目标路由。       |
| 环境配置     | `ovpn.env`             | NAT、访问策略、iptables 后端、客户端网段等全局网络选项。                   |

`state/client-ip-history.csv` 是历史映射，不参与规则构建。`state/iptables.rules`、`state/iptables.rules.backend` 和 `state/ipset.rules` 是操作后的审计快照，也不参与恢复。每次成功写入快照后都会统一为 UID/GID `65534` 和 `0600` 权限，避免容器内 root 原子替换文件造成属主漂移。

## 用户路由

创建证书用户时，`ovpn createuser` 会：

1. 从 `SUBNET_IP_FIRST + 1` 开始寻找未使用地址。
2. 向 `state/client-ips.csv` 和历史文件追加记录。
3. 在用户 CCD 开头写入 `ifconfig-push IP MASK`。
4. 只为新用户创建同名 ipset 和对应的 `FORWARD` 放行规则，不重建其他用户或全局规则。

使用管理命令维护目标路由：

```shell
ovpn addroute production alice 10.20.0.0/16
ovpn delroute production alice 10.20.0.0/16
ovpn addrouteall production 10.30.0.0/16
ovpn delrouteall production 10.30.0.0/16
ovpn listroute production alice
```

单个 IPv4 会规范为 `/32`。命令把 CIDR 转换为 CCD 中的点分掩码，例如：

```text
push "route 10.20.0.0 255.255.0.0"
```

这些命令要求容器正在运行。它们先备份 CCD，再修改文件，并通过 `ovpn_firewall update-routes` 增量修改对应用户的 ipset。一次批量操作只调用一次容器更新。失败时恢复 CCD，并只重建本次涉及用户的规则，不触发全量同步。

增量更新只改变 ipset，不重建 iptables；`IPTABLES_POLICY=false` 时不会建立或修改用户 ipset，但仍保存规则快照。CCD 的 push 指令仍会由 OpenVPN 下发给客户端。

## 域名路由

域名路由接受可读文件、单个域名或逗号分隔域名：

```shell
ovpn adddomainroute production alice ./domains.txt
ovpn adddomainroute production alice example.com,api.example.com --yes
ovpn adddomainrouteall production ./domains.txt --yes
```

文件支持每行一个域名、空行及 `#` 注释。管理命令在宿主机依次尝试 `getent ahostsv4`、`dig +short A`、`nslookup`，只保留 IPv4，并把每个结果写为 `/32` 路由。无 `--yes` 时先显示待添加、重复和失败明细，再请求一次确认。

域名只在执行命令时解析。CCD 保存的是当时的 IPv4 快照，不会跟随 DNS、CDN 或负载均衡结果自动更新。对地址经常变化的域名，应通过定期受控执行添加命令并清理过期地址维护；当前没有自动对账任务。

## `IPTABLES_POLICY` 实现

启用 `IPTABLES_POLICY=true` 时，`ovpn_firewall sync-rules` 的流程是：

1. 完整校验地址状态以及每个 CCD 的 IPv4 和连续子网掩码。校验完成前不删除现有规则。
2. 在 `FORWARD` 开头临时插入 `openvpn policy rebuild` DROP，阻止重建过程中的放行窗口。
3. 删除项目标记的旧转发规则，销毁容器网络命名空间中的全部 ipset。
4. 同步 NAT。
5. 添加 `tun0` 未授权流量的最终 DROP 和 TCP SYN 的 NFLOG 规则。
6. 为每个有地址记录和 CCD 的用户创建同名 `hash:net` ipset，并添加规则：只允许该用户的隧道 IP 访问其集合中的目标地址。
7. 删除临时 DROP，保存 iptables/ipset 快照。

因此启用策略后，用户 CCD 中没有路由即没有转发白名单。即使服务端有系统路由或设置了默认路由，未命中用户 ipset 的目标也会被拒绝。

实现固定匹配接口 `tun0`。虽然配置允许把 `OVPN_DEVICE` 改为 `tap`，当前防火墙实现并未随之适配；生产部署应使用默认 `tun`。

全量同步会销毁容器内全部 ipset；NAT 则只删除 comment 为 `openvpn client masquerade` 的项目自有规则，并在 `OVPN_NAT=true` 时重新追加一条。因此每个 OpenVPN 容器只有一条覆盖整个 `OVPN_CLIENT_SUBNET` 的全局 MASQUERADE，用户新增、删除和路由操作都不会修改它，其他用途的 MASQUERADE 也不会被本项目清理。

## iptables 后端

`OVPN_IPTABLES_BACKEND` 支持：

| 值       | 行为                                                                                                  |
| -------- | ----------------------------------------------------------------------------------------------------- |
| 空       | 依次探测 nft、legacy，成功后把结果写回同一变量。                                                      |
| `nft`    | 命令对存在时直接复用；不存在时重新探测 nft、legacy 并覆盖原值。                                       |
| `legacy` | 命令对存在时直接复用；优先显式 legacy 命令，也兼容经典非 nft `iptables`。不存在时重新探测并覆盖原值。 |

### 后端探测流程

`ensure_backend` 只在后端值为空或对应命令对不可用时进入能力探测。探测通过临时资源验证当前容器、宿主机内核和所选前端能够共同完成项目实际需要的规则操作。完整流程如下：

1. 对 `state/iptables.lock` 加独占文件锁，所有后端选择、全量同步、用户增量操作和快照保存共用该锁，避免并发修改规则。
2. 根据逻辑后端解析成对命令：nft 使用 `iptables-nft`/`iptables-nft-save`；legacy 优先使用显式 legacy 命令，也兼容没有 nft 标记的经典 `iptables`。
3. 使用项目专用的固定临时 filter/nat 链 `OVPNFWPROBE` 和 ipset `ovpn-fw-probe`。全局锁保证不会并发探测；每次探测前清理所有可用前端上的同名资源，使新进程也能回收上次异常退出或后端切换留下的内容。
4. 无条件验证 `hash:net` ipset、iptables set match 和 comment 扩展。这些是每用户目标集合与放行规则的基础能力。
5. 仅在 `IPTABLES_POLICY=true` 时验证 NFLOG，因为访问日志规则依赖该 target；关闭策略时不因 NFLOG 不可用而拒绝后端。
6. 仅在 `OVPN_NAT=true` 时创建临时 nat 链，并用 TEST-NET-1 地址 `192.0.2.1/32` 验证 MASQUERADE。临时链没有挂接到 `POSTROUTING`，不会承载实际 VPN 流量。
7. 任一步失败都清理临时 filter/nat 链和 ipset，并尝试下一个候选；成功时同样立即清理，再把逻辑后端写回运行时 `ovpn.env` 中的 `OVPN_IPTABLES_BACKEND`。

探测候选固定为 nft、legacy。探测成功后，所有正式规则命令和 `iptables-save` 都复用写回的选择，避免 nft/legacy 混用。

`OVPN_IPTABLES_BACKEND` 同时是配置项和实际状态，也是唯一的后端环境变量。空值表示默认 `auto` 行为，但 `auto` 不作为持久化值；成功后只写入 `nft` 或 `legacy`。

若人工维护的运行时 `ovpn.env` 缺少该配置项，探测成功后会在标准错误中输出提示，并自动追加探测结果。

首次部署时该值为空，容器入口执行 `ovpn_firewall sync-rules` 时确保后端可用，必要时完成一次能力探测并写回。后续容器重启、手动 `ovpn syncrules`、用户、路由和快照操作都通过各自的顶层防火墙命令复用该值，不重复创建临时链和 ipset；单次命令内部也不会重复解析后端。

只有两种情况会探测：值为空，或值为 `nft`/`legacy` 但对应命令对已不可用。需要手动重新检测时，清空 `OVPN_IPTABLES_BACKEND`，再重启容器或执行 `ovpn syncrules ENV`。

探测资源与正式规则有明确边界：固定名称的临时链和集合仅用于验证能力，执行后立即删除；正式全局 NAT 使用 `POSTROUTING` 中 comment 为 `openvpn client masquerade` 的单例规则，用户访问则使用用户名命名的 ipset 和对应 `FORWARD` 规则。

全量同步只由容器入口启动和管理员显式执行 `ovpn syncrules` 触发。创建、删除用户、LDAP 首次接入和路由操作均采用按用户增量更新。修改后端或运行规则配置后执行：

```shell
ovpn syncrules production
```

## NAT、默认路由和回程路由

`OVPN_NAT` 与 `OVPN_DEFROUTE` 独立：

- `OVPN_NAT=true` 为 `OVPN_CLIENT_SUBNET` 创建从 `OVPN_NATDEVICE` 出口的 MASQUERADE。
- `OVPN_DEFROUTE=true` 只让新生成的客户端配置包含 `redirect-gateway def1`。

MASQUERADE 是环境级规则，不是用户规则。它只在容器启动或手动执行 `ovpn syncrules ENV` 时按配置同步；无论环境中有多少用户，都只需要这一条。

| 场景                      | NAT  | 目的端看到的源地址                           | 要求                                                      |
| ------------------------- | ---- | -------------------------------------------- | --------------------------------------------------------- |
| 常规远程接入              | 开   | 容器出口地址，后续可能再被 Docker/宿主机转换 | 目的网络通常无需 VPN 客户端网段回程路由                   |
| 目的端识别隧道客户端      | 关   | 客户端隧道地址，如 `10.8.0.2`                | 目的网络和 Docker 主机必须把客户端网段路由回 OpenVPN 容器 |
| 识别接入 VPN 前的公网地址 | 任意 | 三层转发无法保留该地址                       | 使用连接日志中的 `trusted_ip` 做身份关联                  |

关闭 NAT 前，在目的网络网关添加到 Docker 主机的路由，并在 Docker 主机添加到 OpenVPN 容器的路由，同时启用并允许 IPv4 转发。默认 Compose 没有固定容器 IP，重建后地址可能变化；生产使用时应固定地址或自动更新宿主机回程路由。

查询容器地址示例：

```shell
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  openvpn-production
```

假设客户端网段为 `10.8.0.0/24`、Docker 主机内网地址为 `192.168.1.10`、容器地址为 `172.20.0.2`：

```shell
# 目的网络网关
ip route replace 10.8.0.0/24 via 192.168.1.10

# Docker 主机
ip route replace 10.8.0.0/24 via 172.20.0.2
```

设置 `OVPN_NAT=false` 后执行 `ovpn syncrules production` 即可重建 NAT 规则。修改 `OVPN_DEFROUTE` 后必须重新生成并分发用户 `.ovpn`；服务重启不会修改现有客户端文件。

## 全局路由与每用户路由

`OVPN_ROUTES` 由配置生成器写为服务端 `route` 指令，用于 OpenVPN Server 自身的路由表，不会生成客户端 `push`。需要向所有客户端下发目标路由时，可在 `OVPN_PUSH` 中添加 `route ...`，但启用访问策略时仍要同步维护每用户 CCD 白名单。

优先使用 `ovpn addroute*` 维护用户访问，因为这些命令会同时更新 CCD 和运行 ipset。手工编辑 CCD 后必须执行 `ovpn syncrules ENV`；全量同步会先校验全部 CCD，任一非法掩码都会使同步失败并保留原运行规则。

## 宿主机网络策略备份

安装、`ovpn start` 和 `ovpn restart` 会在服务启动后调用 `maintenance/backup-host-network.sh`，将宿主机规则原子写入：

```text
state/host-iptables.rules
state/host-ip6tables.rules
```

也可手工执行：

```shell
ovpn backuphostnetwork production
```

该快照用于审计和人工恢复，不会自动 `iptables-restore`。因为备份发生在 Compose 启动之后，它包含当时 Docker 已建立的宿主机网络规则。

## 网络维护流程

推荐变更步骤：

1. 备份 `/opt/openvpn-<env>`，执行 `ovpn backuphostnetwork ENV`。
2. 用管理命令修改用户路由；若修改全局规则配置，则编辑运行时 `ovpn.env`。
3. 对手工 CCD 或规则配置变更执行 `ovpn syncrules ENV`。
4. 用 `ovpn listroute ENV USER` 对比 CCD 和运行 ipset。
5. 从该用户客户端验证允许目标和应拒绝目标，同时检查 `logs/iptables.log`。
6. 变更 NAT 时从目的网络验证双向回程，不要只在容器内检查规则存在性。
