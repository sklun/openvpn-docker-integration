# 原生 nftables 实施任务

## 文档状态

本文档将 [原生 nftables 访问策略设计](nftables-design.md) 拆分为可实施、可验证的任务。所有任务当前均为待实施状态。

## 执行规则

- 按任务编号顺序实施；后续任务不得依赖尚未合并的临时代码路径。
- 不保留 iptables、ipset、旧变量、旧快照或旧命令参数兼容。
- 日常用户与路由操作不得调用完整同步或重写共享链。
- 每个任务完成后先运行静态和仓库测试，再决定是否进入容器集成测试。
- 代码变更必须同步更新当前行为文档；设计文档在决策变化时同步修订。

## T01：建立 nftables 测试契约

**范围**

- 为 `tests/test.sh` 增加可记录 nft 调用和批次内容的 mock。
- 建立用户对象名编码、CCD 路由解析、重复客户端 IP、空集合和非法输入测试。
- 固化“用户集合更新不得包含共享链 flush/delete/add”的断言。
- 固化所有规则都限定在 `table inet openvpn`，且不存在 `flush ruleset` 的断言。

**完成条件**

- 新测试能够区分完整同步、用户对象同步和单用户集合同步。
- 测试能证明用户 A 路由更新批次不包含用户 B 对象。
- 测试先与新实现同一提交启用，主分支不保留永久失败测试。

**验证**

```shell
bash -n tests/test.sh
bash tests/test.sh
```

## T02：实现原生 nftables 规则引擎

**范围**

- 将 `server/bin/ovpn_firewall` 改为只调用 `nft`。
- 删除后端解析、能力候选探测、iptables comment 查找和 ipset 管理函数。
- 实现统一输入校验、用户 ID 编码和 nft 批次生成。
- 实现项目表、源地址 verdict map、共享转发链、用户链、用户集合和 NAT 链。
- 使用 `state/nftables.lock` 保护所有提交与快照。

**命令职责**

| 命令 | 职责 |
| --- | --- |
| `sync-rules CLIENT_DB CCD_DIR` | 启动或管理员显式触发的完整项目表同步 |
| `sync-user USER CLIENT_IP CCD_FILE` | 只创建或重建指定用户对象和 map 元素 |
| `ensure-user USER CLIENT_IP CCD_FILE` | 只校验并在需要时重建指定用户对象 |
| `delete-user USER CLIENT_IP` | 只删除指定用户 map 元素、链和集合 |
| `sync-user-routes USER CCD_FILE ...` | 原子重建参数中指定用户的集合，不修改共享链 |

内部命令参数允许直接调整，不保留旧参数兼容，但所有调用点必须在同一任务链中完成更新。

**关键约束**

- 完整同步前先校验全部事实数据和 nft 语法。
- 运行期完整同步以单个 transaction 提交。
- 单用户路由同步只允许 `flush/add element` 目标用户集合。
- 用户新增、地址变化和删除只修改对应 map 元素与用户对象。
- 重复客户端 IP 在提交前失败。
- 任何路径都不得执行 `flush ruleset`。

**完成条件**

- mock 测试覆盖所有命令、成功路径和 transaction 失败路径。
- 用户 A 更新批次中没有共享链操作或用户 B 标识。
- 快照只包含项目表并使用 `0600`、UID/GID `65534`。

## T03：接入管理命令和用户生命周期

**范围**

- 更新 `deploy/ovpn` 中创建、删除、回滚、路由和列表操作的防火墙调用。
- 删除 `IPSET_NAME` 及 ipset 直接调用。
- 删除用户前先取得客户端 IP，并把它传给 `delete-user`，避免依赖已经删除的状态。
- `listroute` 通过 `ovpn_firewall` 查看目标用户集合，不直接执行 `nft`。
- 单用户路由失败时只恢复该用户 CCD 和集合。
- `addrouteall`、`delrouteall` 和域名批量路由只更新明确涉及的用户集合，并以一个 transaction 共同提交。

**完成条件**

- 创建、删除、失败回滚和路由操作均不调用 `sync-rules`。
- 任一单用户操作不生成其他用户对象变更。
- CCD 与运行集合失败回滚测试通过。

## T04：接入 LDAP 首次连接

**范围**

- 将 `IPTABLES_POLICY` 判断替换为新的访问策略变量。
- LDAP 首次分配地址后只调用目标用户的 `ensure-user`。
- 后续连接需要修复规则时仍只重建当前用户对象。
- 保持连接 Hook 在释放客户端状态锁后调用防火墙，维持既有锁顺序。

**完成条件**

- 防火墙同步失败会拒绝当前连接，但不会改变其他用户对象。
- 后续连接能够重试当前用户同步。
- LDAP 测试断言不存在完整规则同步。

## T05：替换镜像依赖和配置接口

**范围**

- `server/Dockerfile` 删除 `iptables`、`iptables-legacy` 和 `ipset`，安装 `nftables`。
- 固定并记录支持的 Alpine 与 nftables 基线。
- 删除 `OVPN_IPTABLES_BACKEND`。
- 将 `IPTABLES_POLICY` 替换为 `OVPN_ACCESS_POLICY`，不提供旧名称别名。
- 更新 `deploy/ovpn.env.example`、安装校验和安装确认输出。
- 容器启动在 OpenVPN 前完成 nftables 能力检查和规则同步，失败时不启动 OpenVPN。

**完成条件**

- 镜像中不存在 iptables 和 ipset 运行依赖。
- 配置、脚本和测试不再引用后端选择逻辑。
- 策略开关和 NAT 开关保持相互独立。

## T06：迁移拒绝日志和轮转

**范围**

- 保留 `ulogd`，使用 nftables `log ... group 16`。
- 精简并更新 `deploy/config/ulogd.conf`，输出改为 `logs/firewall.log`。
- 将日志规则放在用户分派之后、最终 DROP 之前，只记录将被拒绝的新建 TCP 请求。
- 更新容器入口、`server/bin/ovpn_logrotate` 和宿主机轮转脚本中的日志名称。
- 为最终 DROP、用户放行和 NAT 规则保留 counter。

**完成条件**

- 已授权 TCP SYN 不写入拒绝日志。
- 未授权 TCP SYN 写入 `firewall.log`，UDP 等拒绝流量增加 DROP counter。
- 日志轮转、压缩、保留天数和磁盘阈值逻辑继续生效。

## T07：迁移宿主机网络审计

**范围**

- 将 `backup-host-network.sh` 改为执行 `nft list ruleset`。
- 快照统一为 `state/host-nftables.rules`。
- 安装器要求宿主机存在并可执行 `nft`，删除 `iptables-save` 要求。
- 保持快照原子覆盖和 `0600` 权限。

**完成条件**

- 安装、启动、重启和 `backuphostnetwork` 都生成 nftables 宿主机快照。
- 宿主机不支持 nf_tables 时安装或备份明确失败，不尝试 iptables 降级。

## T08：清理旧实现和同步文档

**范围**

- 删除全部 iptables/ipset 后端探测、快照、锁、日志名称和测试 fixture。
- 更新 `README.md`、`docs/configuration.md`、`docs/network-and-routing.md`、`docs/operations.md`、`docs/authentication.md` 和 `docs/build-and-deployment.md`。
- 明确 `client-to-client` 可由管理员手工启用，但其用户态转发路径不受 nftables 用户 ACL 控制。
- 记录支持基线、项目表所有权、日常增量边界、完整同步边界和排障命令。
- 确认 README 不包含迁移说明或历史项目来源。

**完成条件**

- 除说明“不支持旧实现”的必要文字外，运行文件和当前行为文档不再描述 iptables/ipset。
- 文档中的命令、变量、文件名和实际实现一致。
- `rg` 检查结果经过人工确认，不存在遗漏调用。

## T09：容器集成与安全验证

**前置条件**

- T01 至 T08 完成。
- 按项目要求使用本机 OrbStack Fedora 环境，不使用远程 Docker。
- 完整测试请求允许清理并重新部署测试资源；测试结束后保留容器和卷。

**场景**

1. 构建只包含 nftables 实现的新镜像并启动测试环境。
2. 验证空 CCD 用户能够连接但不能转发。
3. 添加授权路由后验证目标可达，未授权目标继续被拒绝。
4. 客户端自行添加未授权静态路由和默认路由，验证无法越权。
5. 更新用户 A 集合前后记录用户 B 的对象、counter 和持续连接，确认不受影响。
6. 注入无效 CCD 和 nft transaction 失败，确认旧运行集合保留且 CCD 回滚。
7. 验证重叠 CIDR 添加、删除和 `auto-merge` 后的有效权限。
8. 验证重复客户端 IP 会在提交前失败。
9. 验证 NAT 开关和出口设备限定。
10. 验证未授权 TCP 请求写入 `firewall.log`，已授权请求不写入，DROP counter 正确增加。
11. 验证显式 `syncrules` 原子重建项目表且不改变项目外 nftables 对象。
12. 若管理员手工启用 `client-to-client`，单独记录该流量不属于 nftables ACL 验收范围。

**仓库验证**

```shell
bash -n deploy/ovpn deploy/install.sh deploy/package.sh server/build.sh tests/test.sh
bash tests/test.sh
```

**Docker 验证入口**

```shell
zsh -ic 'of docker ps'
zsh -ic 'of docker compose ps'
zsh -ic 'of docker compose up -d --build'
```

**最终完成条件**

- 所有仓库测试和容器安全场景通过。
- 测试服务、容器和卷按项目约定保留。
- 规则、日志、快照和文档中不存在未解释的旧实现残留。

