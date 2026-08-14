# `ovpn.env` 配置

## 文件规则

部署源文件通常为 `deploy/ovpn.env`，安装后生效文件为 `/opt/openvpn-<env>/ovpn.env`。它不是通用 dotenv 文件，而是会被多个 Bash 脚本直接 `source` 的 Bash 配置：

- 字符串建议使用双引号；布尔值只使用不带引号或带引号的 `true`、`false`。
- 多值配置使用 Bash 数组，例如 `OVPN_DNS_SERVERS=("1.1.1.1" "8.8.8.8")`。
- 不要在不可信来源的基础上生成此文件；其中的命令替换也会以调用脚本的身份执行。
- 文件包含 LDAP 密码等敏感值。安装器将其权限设为 `0600`，备份和日志中也不应输出其内容。
- `install.sh` 只修改复制到运行目录的副本，不修改部署源文件。

## 路径与镜像

| 变量         | 示例/默认值                 | 说明                                                                                          |
| ------------ | --------------------------- | --------------------------------------------------------------------------------------------- |
| `OPENVPN`    | `/etc/openvpn`              | 容器内数据挂载点。启用 OTP 或固定密码时必须保持 `/etc/openvpn`，因为 PAM 配置使用该固定路径。 |
| `OVPN_IMAGE` | `openvpn-integration:local` | Compose 和一次性管理容器使用的镜像。                                                          |

## 网络与客户端下发

| 变量                 | 示例/默认值       | 说明                                                                              |
| -------------------- | ----------------- | --------------------------------------------------------------------------------- |
| `OVPN_HOST`          | `vpn.example.com` | 客户端连接地址，也是服务端证书的名称；不能为空。                                  |
| `OVPN_PORT`          | `1194`            | 宿主机发布端口，范围 `1-65535`；容器内固定监听 `1194`。                           |
| `OVPN_PROTO`         | `udp`             | `udp`、`udp6`、`tcp` 或 `tcp6`。Compose 根据它选择 UDP/TCP 端口映射。             |
| `OVPN_CLIENT_SUBNET` | `10.8.0.0/24`     | 客户端地址池 CIDR。安装器接受前缀 `1-29` 并据此写入池边界。已部署后不要原地修改。 |
| `OVPN_DEFROUTE`      | `false`           | 新生成的客户端配置是否包含 `redirect-gateway def1`；不隐式启用 NAT。              |
| `OVPN_NAT`           | `true`            | 是否为整个客户端网段创建一条全局 `POSTROUTING MASQUERADE`；不按用户拆分。         |
| `OVPN_NATDEVICE`     | `eth0`            | MASQUERADE 的容器出口设备，名称最长 15 个受支持字符。                             |
| `OVPN_MTU`           | 空                | 非空时写入服务端 `tun-mtu`、push 指令和新生成的客户端配置。                       |
| `OVPN_TLS_CIPHER`    | 空                | 非空时写入服务端和新生成客户端的 `tls-cipher`。                                   |
| `OVPN_CIPHER`        | `AES-256-CBC`     | 写入服务端和新生成客户端的 `data-ciphers-fallback`。                              |
| `OVPN_AUTH`          | 空                | 非空时写入服务端和新生成客户端的 `auth`。                                         |
| `OVPN_DNS_SERVERS`   | `()`              | 每项生成一条服务端 `push "dhcp-option DNS ..."`。                                 |
| `OVPN_ROUTES`        | `()`              | 服务端全局路由。CIDR 会转换为 `route IP MASK`；这是全局下发，不是每用户白名单。   |
| `OVPN_PUSH`          | `()`              | 每项作为一条服务端 `push "..."` 写入。不要在元素外重复写 `push`。                 |

`OVPN_ROUTES` 只影响 OpenVPN 路由配置。启用 `IPTABLES_POLICY` 时，用户仍需在 CCD 中具有相应目标路由，否则容器转发规则会拒绝访问。

## 认证

| 变量                       | 示例/默认值                     | 说明                                                                                                                       |
| -------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `CA_NOPASS`                | `true`                          | 初始化时创建无密码 CA。设为 `false` 会在 PKI 初始化时要求 CA 密码。                                                        |
| `OTP`                      | `true`                          | 使用 PAM Google Authenticator TOTP。                                                                                       |
| `PASSWORD_AUTH`            | `false`                         | 启用固定密码认证。可与 OTP 同时开启。                                                                                      |
| `OVPN_USER_SUFFIX`         | 空                              | 非 LDAP 用户证书名后缀；空值使用环境名。只用于运行目录名与已有证书后缀不一致的受控场景。                                   |
| `LDAP`                     | `false`                         | 启用 LDAP 用户名密码认证。不能与 OTP 或固定密码同时开启。                                                                  |
| `LDAP_CONF`                | `${OPENVPN}/auth/ldap.conf`     | 生成的 LDAP 插件配置路径。                                                                                                 |
| `LDAP_DISABLE_CERT_VERIFY` | `true`                          | `true` 时写入 `verify-client-cert optional`；LDAP 用户可不提供客户端证书。                                                 |
| `LDAP_URL`                 | 空                              | LDAP 服务地址，可带 `ldap://`/`ldaps://` 前缀，但当前生成器统一写成 `ldap://` 且 `TLSEnable no`。不要把它当作 LDAPS 支持。 |
| `LDAP_BIND_DN`             | 空                              | LDAP 查询账号 DN，LDAP 模式必填。                                                                                          |
| `LDAP_PASSWORD`            | 空                              | LDAP 查询账号密码，敏感值。                                                                                                |
| `LDAP_BASE_DN`             | 空                              | 用户搜索 Base DN，LDAP 模式必填。                                                                                          |
| `LDAP_SEARCHFILTER`        | `(cn=%u)`                       | 用户过滤器，`%u` 由插件替换为登录名。                                                                                      |
| `LDAP_AUTHZ_FILE`          | `${OPENVPN}/auth/vpn_user.json` | 本地 LDAP 授权名单。当前实现只检查 `.LDAP_user[].user`。                                                                   |

认证组合见 [认证](authentication.md)。

## 访问策略、设备与生命周期

| 变量                    | 示例/默认值 | 说明                                                                                                       |
| ----------------------- | ----------- | ---------------------------------------------------------------------------------------------------------- |
| `IPTABLES_POLICY`       | `true`      | 为每个用户建立目标 ipset 白名单，并拒绝未授权的 `tun0` 转发。                                              |
| `OVPN_IPTABLES_BACKEND` | 空          | 唯一后端状态。为空时自动探测并写回 `nft` 或 `legacy`；已有值且命令可用时直接复用，不可用时重新探测并覆盖。 |
| `DEVICE_AUTH`           | `false`     | 选择设备绑定连接 Hook。要求客户端通过 peer-info 上报项目约定的扩展字段。LDAP 模式优先使用 LDAP Hook。      |
| `AUTO_REVOKE`           | `false`     | 安装时是否写入每日自动吊销 crontab。安装后只改此变量不会增删 crontab。                                     |
| `AUTO_REVOKE_MONTHS`    | `3`         | 最近登录时间超过 `月数 x 30 天` 的证书用户将被 `ovpn deluser` 删除。                                       |

## OpenVPN、PKI 与日志

| 变量                   | 示例/默认值                        | 说明                                                                                                   |
| ---------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `OVPN_DEVICE`          | `tun`                              | 写入服务端和新客户端的设备类型。当前网络规则固定匹配 `tun0`，因此 `tap` 或不同设备名没有完整配套实现。 |
| `OVPN_KEEPALIVE`       | `10 60`                            | 服务端 `keepalive` 参数。                                                                              |
| `OVPN_MANAGEMENT`      | 空                                 | 非空时写入管理接口地址和端口，例如 `127.0.0.1 2080`。                                                  |
| `OVPN_MANAGEMENT_PASS` | `${OPENVPN}/auth/.management-pass` | 管理接口密码文件；启用前必须自行创建并收紧权限。                                                       |
| `EASYRSA_PKI`          | `${OPENVPN}/pki`                   | PKI 数据目录。                                                                                         |
| `EASYRSA`              | `/usr/share/easy-rsa`              | Easy-RSA 程序目录；当前辅助命令主要依赖镜像内 `easyrsa` 命令。                                         |
| `EASYRSA_CRL_DAYS`     | `3650`                             | Easy-RSA CRL 有效期。                                                                                  |
| `EASYRSA_CERT_EXPIRE`  | `3650`                             | 新证书默认有效期。                                                                                     |
| `LOG_VERB`             | `3`                                | OpenVPN `verb` 级别。                                                                                  |
| `LOG_PATH`             | `${OPENVPN}/logs`                  | 主日志、登录日志和轮转脚本使用的目录。                                                                 |
| `OVPN_LOG_PATH`        | `${LOG_PATH}/openvpn.log`          | OpenVPN 主日志。                                                                                       |
| `OVPN_STATUS_LOG_PATH` | `${LOG_PATH}/openvpn-status.log`   | OpenVPN 状态日志。                                                                                     |
| `LOG_RETAIN_DAYS`      | `90`                               | `ovpn_logrotate` 的压缩日志轮转数量。                                                                  |
| `LOG_DISK_LIMIT`       | `90`                               | 日志目录所在文件系统使用率达到该百分比时，清理最旧压缩日志。                                           |
| `OVPN_HOOKS_PATH`      | `${OPENVPN}/hooks`                 | 运行时 Hook 目录；安装器会在运行时副本中覆盖为 `${OPENVPN}/hooks`。                                    |
| `EXTRA_CONF`           | `()`                               | 原样追加到 `openvpn.conf` 的指令数组，使用前自行验证安全性和兼容性。                                   |
| `SUBNET_IP_FIRST`      | 空                                 | 安装器从客户端网段计算，写入运行时副本。不要手工维护。                                                 |
| `SUBNET_IP_LAST`       | 空                                 | 同上。                                                                                                 |

## 配置变更生效矩阵

运行脚本会在不同时间读取配置，不能对所有变量统一执行 `restart`：

| 变更类型              | 典型变量                                                                                        | 正确操作                                                                                                                          |
| --------------------- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| 只影响运行规则        | `OVPN_NAT`、`OVPN_NATDEVICE`、`IPTABLES_POLICY`、`OVPN_IPTABLES_BACKEND`                        | 修改运行时 `ovpn.env` 后执行 `ovpn syncrules ENV`。将后端值清空可在下一次规则操作时重新探测并写回。                               |
| Compose 解析参数      | `OVPN_IMAGE`、`OVPN_PORT`、`OVPN_PROTO`、`OPENVPN`                                              | 需要重建容器；其中协议和挂载点还与已生成配置耦合，生产环境应按新环境部署处理。                                                    |
| 固化到 `openvpn.conf` | `OVPN_CLIENT_SUBNET`、DNS、全局路由、push、认证模式、LDAP、MTU、密码套件、日志路径、Hook 路径等 | 必须重新运行 `ovpn_gen_server_conf` 并审查结果后重建容器；管理 CLI 没有封装该流程。地址池、认证模式、挂载点等高风险项应新建环境。 |
| 固化到客户端配置      | `OVPN_HOST`、`OVPN_PORT`、`OVPN_PROTO`、`OVPN_DEFROUTE`、MTU、密码套件、认证开关                | 已有 `.ovpn` 不会改变。需为每个用户执行 `ovpn renewuser ENV USER` 生成新文件，或用容器内批量工具重新导出；旧文件不会自动删除。    |
| 安装时行为            | `CA_NOPASS`、`AUTO_REVOKE`、`OVPN_CLIENT_SUBNET` 的池边界                                       | 只改运行时文件不会重做初始化或 crontab。人工维护相应状态，或规划重新部署。                                                        |
| 维护脚本每次读取      | `AUTO_REVOKE_MONTHS`、`LOG_RETAIN_DAYS`、`LOG_DISK_LIMIT`                                       | 修改后下一次维护任务使用新值；`AUTO_REVOKE` 本身仍由安装时 crontab 决定。                                                         |

`ovpn restart` 只执行运行目录备份、`docker compose down` 和 `up -d`。它会让容器启动脚本重新读取规则相关配置，但不会重新生成 `openvpn.conf`、LDAP 配置、PKI、运行时 Hook 或客户端文件。
