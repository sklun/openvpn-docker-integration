# OpenVPN Docker Integration

基于 Shell、Docker Compose 和 OpenVPN 的多环境服务端集成，提供证书生命周期、OTP/固定密码/LDAP 认证、CCD 固定地址、每用户网络策略、设备绑定及日常维护。

## 功能

- 独立的 `/opt/openvpn-<env>` 运行环境
- OpenVPN Server 镜像构建和在线/离线部署
- 证书、TOTP、固定密码及 LDAP 认证
- 用户固定 IP、IPv4/CIDR 路由和域名 IPv4 路由
- iptables nft/legacy 自适应、每用户 ipset 白名单和 NAT
- 设备绑定、登录审计、日志轮转和不活跃证书吊销

## 快速开始

构建镜像：

```shell
bash server/build.sh openvpn-integration:local --load
```

准备并部署环境：

```shell
cp deploy/ovpn.env.example deploy/ovpn.env
${EDITOR:-vi} deploy/ovpn.env
cd deploy
bash install.sh production ./ovpn.env
```

创建用户并查看服务：

```shell
ovpn createuser production alice
ovpn status production
```

安装器需要在目标 Linux 主机以 root 执行。目标主机需要 Docker Engine、Docker Compose 插件、Bash、`crontab` 和 `iptables-save`。

## 文档

| 文档                                          | 内容                                  |
| --------------------------------------------- | ------------------------------------- |
| [项目文档索引](docs/README.md)                | 文档入口和实现边界                    |
| [构建与部署](docs/build-and-deployment.md)    | 镜像、部署包、安装、更新和验证        |
| [`ovpn.env` 配置](docs/configuration.md)      | 全部变量、约束和变更生效矩阵          |
| [路由与网络规则](docs/network-and-routing.md) | CCD、域名、ipset/iptables、NAT 和维护 |
| [认证](docs/authentication.md)                | 证书、OTP、固定密码、LDAP 和设备绑定  |
| [运维与管理命令](docs/operations.md)          | `ovpn` 操作变动流程、备份、日志和排障 |
| [客户端工具](docs/client-tools.md)            | 客户端临时启动和 systemd 服务安装脚本 |

运行 `ovpn help` 查看当前管理命令及参数。

## 目录

```text
openvpn-docker-integration/
├── server/       # 镜像定义、容器入口及 OpenVPN 辅助命令
├── deploy/       # 安装器、管理 CLI、客户端工具、Hook、维护脚本和模板
├── docs/         # 项目文档
└── tests/        # 仓库级 Shell 测试
```

## 验证

```shell
bash -n deploy/ovpn deploy/install.sh deploy/package.sh server/build.sh tests/test.sh
bash tests/test.sh
```
