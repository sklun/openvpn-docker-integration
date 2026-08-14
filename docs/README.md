# 项目文档

本文档集描述当前仓库支持的构建、部署、配置、网络、认证和维护方式。运行时目录、命令名称和行为以当前实现为准。

| 文档                                     | 内容                                               |
| ---------------------------------------- | -------------------------------------------------- |
| [构建与部署](build-and-deployment.md)    | 镜像构建、在线/离线部署、安装过程、升级和验证      |
| [`ovpn.env` 配置](configuration.md)      | 全部变量、约束、敏感项和配置变更生效方式           |
| [路由与网络规则](network-and-routing.md) | CCD、域名路由、ipset/iptables、NAT、回程路由和维护 |
| [认证](authentication.md)                | 证书、OTP、固定密码、LDAP、设备绑定及实现链路      |
| [运维与管理命令](operations.md)          | `ovpn` 命令变动流程、运行时数据、备份、日志和排障  |
| [客户端工具](client-tools.md)            | `deploy/helpers/` 中的客户端启动和服务安装工具     |

## 关键边界

- 每个环境安装在 `/opt/openvpn-<env>`，容器名为 `openvpn-<env>`。
- `ovpn.env` 是 Bash 脚本片段，会被 `source`；数组必须使用 Bash 数组语法。
- `ovpn restart` 备份运行目录并重建容器，但不会重新生成 `openvpn.conf`、PKI 或已有客户端配置。
- 再次执行 `install.sh` 会把原运行目录移走，并初始化新的运行目录和 PKI；它不是原地升级命令。
- `state/*.rules` 是审计快照，不是自动恢复源。运行规则由 `ovpn.env`、`state/client-ips.csv` 和 `ccd/` 重建。
- 项目不依赖历史仓库，也不提供旧目录、旧脚本名或兼容别名。
- `deploy/helpers/` 是随部署包分发的独立客户端工具，不属于服务端安装器、运行时目录或 `ovpn` 管理命令。
