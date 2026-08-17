# 运维与管理命令

## 运行时目录

安装器为环境 `production` 创建 `/opt/openvpn-production`：

```text
/opt/openvpn-production/
├── auth/                 # LDAP、固定密码和本地授权
├── ccd/                  # 用户固定 IP 和目标路由
├── clients/              # 客户端配置及 OTP 交付文件
├── config/               # ulogd 配置
├── hooks/                # 连接和断开 Hook
├── logs/                 # OpenVPN、iptables、登录和维护日志
├── maintenance/          # 日志、吊销、宿主机规则备份
├── otp/                  # TOTP 密钥
├── pki/                  # Easy-RSA PKI
├── state/                # 地址、设备、锁、规则与审计快照
├── templates/ccd/default
├── compose.yaml
├── openvpn.conf
└── ovpn.env
```

其中 `ovpn.env`、`auth/`、`otp/`、`pki/` 和 `clients/` 含敏感数据。完整备份应加密、限制读取并验证恢复权限。

## 服务命令

```shell
ovpn start production
ovpn stop production
ovpn restart production
ovpn status production
ovpn syncrules production
ovpn backuphostnetwork production
```

| 命令                | 变动流程                                                                                                                                                   |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `start`             | `docker compose up -d`；首次部署启动时探测并写回 iptables 后端，后续启动复用结果；同步规则、启动 ulogd 和 OpenVPN；随后宿主机备份当前 iptables/ip6tables。 |
| `stop`              | `docker compose stop`；保留容器、运行目录和卷挂载数据。                                                                                                    |
| `restart`           | `cp -a` 完整备份运行目录，执行 Compose `down` 和 `up -d`，再备份宿主机网络策略。不会生成新配置或 PKI。                                                     |
| `status`            | 输出 Compose 状态和容器最近 100 行日志。                                                                                                                   |
| `syncrules`         | 从运行时 `ovpn.env`、当前用户地址和 CCD 校验并重建容器规则，刷新规则快照；快照保持 UID/GID `65534` 和 `0600` 权限。                                        |
| `backuphostnetwork` | 原子覆盖当前环境中的宿主机 iptables/ip6tables 审计快照。                                                                                                   |

`restart` 的备份路径为 `/opt/openvpn-<env>-YYYY_MMDD_HHMMSS`。命令没有自动清理策略，也不会在失败时自动恢复；执行前确认同一文件系统有足够空间。

## 用户操作变动流程

| 命令         | 持久化变动                                                         | 运行时变动                                     | 失败处理                                                     |
| ------------ | ------------------------------------------------------------------ | ---------------------------------------------- | ------------------------------------------------------------ |
| `createuser` | 签发证书和私钥，生成 `.ovpn`/可选 OTP，创建 CCD，分配当前及历史 IP | 只创建该用户的规则和 ipset                     | 自动尝试吊销和删除本次资源及该用户规则                       |
| `renewuser`  | Easy-RSA 续期，新增带日期 `.ovpn`                                  | 无；OpenVPN 继续依据证书和 CRL 验证            | 没有跨步骤回滚；失败后检查 PKI 和输出目录                    |
| `deluser`    | 吊销并删除证书材料、客户端目录、CCD、当前 IP 和固定密码            | 容器运行时只删除该用户规则和 ipset；停止时跳过 | 多步操作无整体事务，出错后对照 PKI、CRL、状态和 CCD 人工核查 |
| `resetotp`   | 覆盖用户 TOTP 密钥                                                 | 下一次认证立即使用新密钥                       | 旧密钥已失效，必须可靠交付新二维码                           |
| `clientip`   | 无                                                                 | 无                                             | 查询当前和历史映射；当前命令不支持设置 IP                    |
| `listhwaddr` | 无                                                                 | 无                                             | 只读取当前状态记录                                           |
| `delhwaddr`  | 原子清空当前记录的设备字段                                         | 下次连接重新绑定                               | 保留用户 IP 和登录时间                                       |

用户名输入会在非 LDAP 环境追加环境后缀。例如命令参数 `alice` 在 `production` 中通常对应 `alice-production`。命令也接受已经带正确后缀的名称。

## 固定密码操作

| 命令       | 变动                                                                 |
| ---------- | -------------------------------------------------------------------- |
| `addpass`  | 在文件锁内先追加密码，再把用户加入固定密码名单。要求证书用户已存在。 |
| `chpass`   | 在文件锁内原子替换指定用户密码。                                     |
| `delpass`  | 在文件锁内从两个文件原子删除用户。                                   |
| `listpass` | 只输出用户名，不输出密码。                                           |

密码文件是明文敏感数据。交互运行时省略命令行密码参数，避免进入历史记录；自动化应通过受控终端或重新设计秘密注入方式，不要把密码写入普通脚本。

固定密码管理、用户删除和创建失败回滚共用 `auth/.static-password.lock`。客户端地址、登录时间、设备绑定、CCD 初始化、用户删除及管理命令的 CCD 路由事务共用 `state/.client-ip.lock`，避免并发命令丢失路由或状态。连接 Hook 在释放状态锁后执行防火墙操作；管理路由命令则持锁完成 CCD、运行 ipset 和失败回滚的整体变更。

## 路由操作

| 命令                                   | 变动流程                                                                                                                                   |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `addroute` / `delroute`                | 备份单个 CCD，修改 route push，增量更新该用户 ipset，保存快照；失败则恢复 CCD 并只重建该用户规则。                                         |
| `addrouteall` / `delrouteall`          | 备份全部 CCD，批量修改，一次增量更新全部用户集合；失败时恢复全部 CCD。                                                                     |
| `adddomainroute` / `adddomainrouteall` | 宿主机解析 IPv4，显示明细并确认，备份目标 CCD，批量追加 `/32` 并一次更新 ipset。存在解析失败时，已解析地址仍会被写入，但命令最终返回失败。 |
| `listroute`                            | 显示 CCD route push；容器运行时同时显示对应 ipset。                                                                                        |

域名批量命令可能出现“部分已生效但退出码非零”：只要至少有待添加地址，解析成功项会先写入和同步，之后因其他域名解析失败而返回失败。自动化必须读取输出并重新核对 `listroute`，不能把非零退出码等同于完全没有变动。

更完整的实现和网络维护方式见 [路由与网络规则](network-and-routing.md)。

## 定时维护

安装器在 root crontab 中管理当前环境的以下任务：

```text
0 0 * * * /opt/openvpn-<env>/maintenance/rotate-logs.sh
15 0 * * * /opt/openvpn-<env>/maintenance/revoke-inactive-clients.sh
```

每次安装都会先移除当前环境旧的两条受管任务，再写入日志轮转任务；第二项只在 `AUTO_REVOKE=true` 时写入，因此使用 `false` 重新初始化会移除旧吊销任务。其他 crontab 行保持不变。

### 日志轮转

`rotate-logs.sh` 每日进入容器调用 `ovpn_logrotate`，对 `iptables.log` 和 `openvpn.log` 执行 `copytruncate`、压缩和按 `LOG_RETAIN_DAYS` 轮转。当日志文件系统使用率达到 `LOG_DISK_LIMIT`，脚本从两类压缩日志中各删除最旧文件，直到低于阈值或无文件可删。

容器停止时 `docker exec` 会失败，任务不会继续磁盘清理。维护窗口后应检查 crontab 结果和磁盘空间。

### 不活跃用户吊销

`revoke-inactive-clients.sh` 只管理本地证书用户，读取当前地址状态的最后登录 Unix 时间。超过 `AUTO_REVOKE_MONTHS x 30 天` 后调用 `ovpn deluser`，并写入 `logs/revoke.log`。安装器拒绝 LDAP 与 `AUTO_REVOKE` 同时启用，维护脚本在 LDAP 环境中也会直接跳过。

没有有效最后登录时间的记录会跳过。该操作不仅吊销证书，还删除客户端目录、CCD、当前状态和固定密码，属于不可由脚本自动撤销的生命周期操作。启用前验证系统时间、备份、用户例外需求及登录时间更新链路。当前 `retain_user` 不会排除自动吊销。

## 备份与恢复

建议备份范围为完整 `/opt/openvpn-<env>`，以保持 PKI、CRL、客户端状态、认证数据和 CCD 一致。只恢复单个文件容易造成证书、状态和规则不一致。

当前工具只创建备份，不执行自动恢复。人工恢复建议：

1. 停止环境并保留现场。
2. 额外备份当前失败目录和容器日志。
3. 校验目标备份包含完整 PKI、`ovpn.env`、`openvpn.conf`、CCD、状态和认证文件。
4. 恢复为原运行路径，检查所有权；一般运行目录由 UID/GID `65534` 使用，OTP 文件为 root `0400`。
5. 启动环境，执行 `ovpn syncrules ENV`，再验证证书、认证和路由。

不要直接恢复 `state/iptables.rules` 或 `state/ipset.rules`。项目预期从事实数据重新构建规则。

## 日常检查

```shell
ovpn status production
ovpn listuser production
ovpn listpass production
ovpn listroute production alice
ovpn clientip production alice
```

同时检查：

- `logs/openvpn.log`：服务端启动、TLS 和认证问题。
- `logs/openvpn-status.log`：当前会话状态。
- `logs/loginlog/`：来源地址、登录、设备绑定和退出。
- `logs/iptables.log`：访问策略 NFLOG。
- 运行时 `ovpn.env` 中的 `OVPN_IPTABLES_BACKEND`：实际使用的后端；首次探测成功后应为 `nft` 或 `legacy`。
- `state/*.rules`：最近一次同步后的审计快照。
- root crontab 与日志目录磁盘占用。

## 排障顺序

1. `ovpn status ENV` 确认容器和 OpenVPN 启动结果。
2. 检查运行时 `ovpn.env` 与 `openvpn.conf` 是否一致；配置文件修改不代表生成配置已改变。
3. 用 `ovpn listuser` 检查证书状态，再检查 OTP、固定密码或 LDAP 授权链。
4. 用 `ovpn clientip` 确认用户名规范化和隧道地址。
5. 用 `ovpn listroute` 比较 CCD 与 ipset；必要时运行 `ovpn syncrules`。
6. 检查 NAT、宿主机转发和目的网络回程路由。
7. 对照登录、OpenVPN 和 iptables 日志定位是认证失败、路由缺失还是策略拒绝。

## 仓库验证

所有测试应在项目规定的容器环境中执行：

```shell
bash -n deploy/ovpn deploy/install.sh deploy/package.sh server/build.sh tests/test.sh
bash tests/test.sh
```

测试覆盖 shell 语法、配置生成、客户端凭据权限、设备 TOFU 与登录时间、LDAP、固定密码、CCD 并发、客户端 PID 管理、定时任务收敛、域名路由、规则后端选择、全量/增量规则同步、回滚和部署包结构。
