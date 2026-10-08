# 原生 nftables 访问策略设计

## 文档状态

本文档描述计划中的原生 nftables 实现，不代表当前版本已经支持。当前运行实现仍以 [路由与网络规则](network-and-routing.md) 为准。

## 目标

- 使用原生 nftables 取代 `iptables`、`iptables-legacy`、`iptables-nft` 和 ipset。
- 阻止客户端通过自行添加路由访问未授权目标。
- 日常用户和路由操作只修改目标用户的运行对象，不重写共享链或其他用户集合。
- 全量规则变更通过单个 nft transaction 原子提交，不产生临时放行窗口。
- 只管理项目自有 nftables 表，不清理其他程序创建的表、链或集合。
- 保留 NAT、拒绝日志、运行快照和按用户检查能力。

## 非目标

- 不兼容旧内核、iptables 后端或现有 ipset 运行状态。
- 不提供旧配置项、旧快照名称或旧命令参数的兼容别名。
- 不自动添加、删除或拒绝 OpenVPN `client-to-client` 配置。
- 不从旧防火墙快照恢复规则；运行规则仍由 `ovpn.env`、客户端地址状态和 CCD 重建。
- 首期只支持当前的 TUN、IPv4 客户端地址和 IPv4 目标路由模型，不扩展 TAP 或 IPv6 路由授权。

## 安全边界

客户端路由只决定流量是否进入 VPN，不构成服务端授权。转发流量必须同时满足：

1. 从受管 TUN 接口进入。
2. 源地址对应一个服务端分配的唯一客户端 IPv4 地址。
3. 目标 IPv4 地址属于该用户服务端 CCD 生成的集合。

客户端自行添加默认路由、静态路由或更具体路由，不会改变 nftables 中的用户集合；未命中集合的流量最终被丢弃。

`client-ips.csv` 中的客户端 IPv4 地址必须唯一。全量同步、创建用户和地址更新在修改 nftables 前检查冲突；冲突时保持原运行规则并返回失败。

OpenVPN 的多客户端模式负责把认证身份绑定到虚拟地址，并拒绝不属于该客户端内部路由的源地址。nftables 在共享 TUN 接口上只能看到数据包地址，不能重新识别 OpenVPN 用户身份。

### `client-to-client`

项目不自动配置或禁止 `client-to-client`。管理员可以直接修改 OpenVPN 配置启用它，但需要理解：未使用 DCO 时，OpenVPN 会在用户态内部转发客户端间流量，这部分流量不会进入 TUN 接口，因此不受本文档的 nftables 用户 ACL 控制。

本文档设计的策略保护客户端经 TUN 接口访问容器外目标的转发路径。若管理员需要控制客户端间访问，应另行使用 OpenVPN 自身的客户端策略能力，不能把本文档的 nftables 策略视为该路径的授权机制。

## 事实数据

| 数据 | 路径 | 用途 |
| --- | --- | --- |
| 客户端地址 | `state/client-ips.csv` | 建立用户与唯一隧道 IPv4 地址的关联 |
| 用户路由 | `ccd/<user>` | 生成该用户允许访问的 IPv4/CIDR 集合 |
| 全局配置 | `ovpn.env` | 控制访问策略、NAT、客户端网段和出口设备 |

`state/nftables.rules` 只是提交后的审计快照，不参与恢复或规则生成。

## nftables 对象模型

每个 OpenVPN 容器有独立网络命名空间，因此使用固定项目表：

```text
table inet openvpn
├── map client_dispatch
├── chain forward
├── chain vpn_forward
├── chain postrouting
└── 每个用户
    ├── set routes_<user-id>
    └── chain user_<user-id>
```

`<user-id>` 由用户名原始字节编码为小写十六进制，前缀固定，不直接执行或插值用户名。这样可以获得确定、无碰撞且只包含 nftables 安全字符的对象名。

### 共享对象

示意规则如下，最终语法以目标镜像内 nftables 验证结果为准：

```nft
table inet openvpn {
    map client_dispatch {
        type ipv4_addr : verdict
    }

    chain vpn_forward {
        ip saddr vmap @client_dispatch
        ct state new tcp flags & (fin | syn | rst | ack) == syn \
            log prefix "openvpn-denied " group 16
        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "tun0" jump vpn_forward
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.8.0.0/24 oifname "eth0" counter masquerade
    }
}
```

`client_dispatch` 把客户端源 IPv4 地址映射为 `jump user_<user-id>` verdict。未知源地址、IPv6 流量、用户集合未命中的目标以及空集合用户都会返回 `vpn_forward` 并命中最终 DROP。

访问策略关闭时不创建用户 ACL 对象，`forward` 不挂接 `vpn_forward`；NAT 是否存在仍只由 `OVPN_NAT` 决定。

### 用户对象

每个用户拥有独立目标集合和普通链：

```nft
set routes_616c696365 {
    type ipv4_addr
    flags interval
    auto-merge
    elements = { 10.20.0.0/16, 192.0.2.10 }
}

chain user_616c696365 {
    ip daddr @routes_616c696365 counter accept
    return
}
```

空 CCD 对应空集合。用户仍可完成认证和建立隧道，但所有经 TUN 发起的转发流量都会被拒绝。

## 变更模型

### 路由更新

单用户 `addroute` 或 `delroute` 的顺序是：

1. 在客户端状态锁内备份并修改目标 CCD。
2. 校验该用户 CCD 中的全部路由。
3. 生成只包含该用户集合的 nft 批次。
4. 在一个 transaction 中 `flush set` 并加入修改后 CCD 的全部路由。
5. 提交成功后写入统一运行快照；失败时 nftables 保留旧集合，管理命令恢复 CCD。

集合使用 `auto-merge` 处理重叠或包含的 CIDR。因为每次从目标用户完整 CCD 生成集合，删除下级网段时不会错误删除仍由上级网段提供的权限。

该操作不得修改共享链、`client_dispatch` 或其他用户对象。批量命令只更新命令明确指定的用户集合，并在一个 transaction 中共同成功或共同失败。

### 创建、重建和删除用户

创建或重建用户只提交以下对象：

- 该用户的集合及元素。
- 该用户的普通链。
- `client_dispatch` 中该用户源地址对应的一个元素。

删除用户按相反顺序删除同一批对象。地址变化时，只替换该用户的 map 元素和必要的用户对象。所有命令在提交前检查新地址没有被其他用户占用。

`ensure-user` 可以无条件原子重建目标用户对象；即使 LDAP 每次连接调用，也只影响该用户，不允许退化为全量同步。

### 完整同步

只有以下入口允许重建完整项目表：

- 容器启动且 OpenVPN 尚未开始接收连接。
- 管理员显式执行 `ovpn syncrules ENV`。

实现先完成全部数据校验和 nft 语法检查，再通过单个 transaction 刷新 `table inet openvpn` 内的对象。禁止使用 `flush ruleset`，禁止修改项目表以外的任何对象，也不再需要临时 DROP 规则。

首次启动可以先确保空项目表存在；若后续构建 transaction 失败，OpenVPN 启动必须失败。运行期间的完整同步失败时，内核继续保留旧规则。

## 并发和锁

- 使用 `state/nftables.lock` 串行化完整同步、用户操作、集合更新和快照写入。
- 管理命令仍先持有 `state/.client-ip.lock` 完成 CCD/地址事务，再调用容器防火墙命令。
- 防火墙命令不得反向获取客户端状态锁，避免锁顺序反转。
- 全局锁只影响管理操作排队，不代表需要重写全部用户规则。

## NAT

NAT 使用同一项目表中的 `postrouting` base chain。`OVPN_NAT=true` 时仅创建一条覆盖 `OVPN_CLIENT_SUBNET` 且限定 `OVPN_NATDEVICE` 的 masquerade 规则。

用户集合更新不得修改 NAT。只有容器启动、显式完整同步或 NAT 配置变更触发 NAT 规则更新。

## 日志和计数器

nftables 使用原生 `log ... group 16` 把未授权的新建 TCP 请求发送到 NFLOG。`ulogd` 继续作为用户态消费者，将日志写入：

```text
logs/firewall.log
```

不需要单独安装 NFLOG 命令或服务包，但保留 `ulogd` 及精简配置，原因是 nftables 自身不能直接把独立环境日志写入该文件。不指定 group 的 `log` 会进入宿主机内核日志，不满足当前按环境落盘和轮转的要求。

最终 DROP、用户放行和 NAT 规则保留 nftables counter。日志只记录用户分派后仍将被拒绝的新建 TCP 请求，避免记录已授权连接；其他被拒绝协议通过 DROP counter 观测。

## 配置和文件命名

计划删除：

- `OVPN_IPTABLES_BACKEND`
- `IPTABLES_POLICY`
- `IPSET_NAME`
- `state/iptables.rules`
- `state/iptables.rules.backend`
- `state/ipset.rules`
- `logs/iptables.log`

计划新增或替换为：

| 名称 | 用途 |
| --- | --- |
| `OVPN_ACCESS_POLICY` | 是否启用每用户服务端访问策略 |
| `state/nftables.lock` | nftables 管理操作锁 |
| `state/nftables.rules` | 项目表审计快照 |
| `logs/firewall.log` | ulogd 写入的拒绝日志 |
| `state/host-nftables.rules` | 宿主机 nftables 审计快照 |

不提供旧变量或文件名兼容。用户名允许字符保持不变；原先仅由 ipset 名称引入的 31 字符说明应删除，是否调整产品级用户名长度另行决定。

## 支持基线

- 目标主机必须提供 nf_tables 内核能力。
- 容器镜像安装 `nftables`，删除 iptables 和 ipset 软件包。
- 安装器和容器启动只验证 nftables 所需能力，不执行后端选择或降级。
- 建议明确并测试 Linux 5.10 或更新版本，镜像版本应固定到可重复构建的 Alpine 版本。

## 管理和性能评估

| 维度 | 当前 iptables + ipset | 原生 nftables 设计 |
| --- | --- | --- |
| 数据路径 | 按顺序扫描每用户 `FORWARD` 规则，再查询目标 ipset | 源 IP verdict map 分派后，只查询目标用户集合 |
| 单路由更新 | 单个 `ipset add/del`，操作量最小 | 原子重建目标用户集合，操作量与该用户路由数相关 |
| 用户隔离 | 用户有独立 ipset，但规则共处共享链 | map 元素、用户链和集合均可独立更新 |
| 完整同步 | 多命令修改并使用临时 DROP | 单 transaction 原子替换项目表 |
| 所有权 | 依赖 comment 识别规则，当前实现还会销毁命名空间中全部 ipset | 固定项目表和确定对象名，不触碰其他表 |
| 状态检查 | `iptables-save` 与 `ipset save` 两套输出 | `nft list table` 一套规则和快照 |
| 依赖 | 多套 iptables 前端、ipset、探测和降级逻辑 | 单一 nftables 前端和明确内核基线 |
| 日志 | iptables NFLOG + ulogd | nftables log group + ulogd，落盘链路相同 |

小规模用户下，两种实现的数据路径差异通常不是主要瓶颈。用户数量增加后，verdict map 避免逐条扫描用户规则；每包仍只进入一个用户链并执行一次目标集合查询。

新方案的管理面代价是路由变更重建目标用户完整集合，而不是修改单个元素。这换取了重叠 CIDR 的正确语义、原子提交和明确的用户故障域。它不会造成全链路规则重写，也不会使其他用户短暂失去规则。

每用户增加一个 nft chain 对象，内存对象数量略有增加；相对地，镜像和运行逻辑不再维护 xtables 兼容层与独立 ipset 子系统。实际容量边界应通过集成测试覆盖目标用户数和目标路由数，而不是只依据命令耗时推断。

## 验收原则

- 客户端自行添加未授权路由后，数据包命中最终 DROP。
- 已授权目标正常访问，删除授权后现有后续数据包立即被拒绝。
- 更新用户 A 的集合时，用户 B 的 map 元素、链、集合、counter 和连通性保持不变。
- nft 批次失败时，目标用户旧集合和 CCD 能恢复到一致状态。
- 空集合、重复地址、非法 CCD、NAT 开关和策略关闭均有独立测试。
- 项目运行文件中不再调用 iptables 或 ipset，也不存在后端探测与兼容别名。

