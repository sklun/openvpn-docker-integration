# OpenVPN Docker Integration

基于 Shell 脚本和 Docker Compose 的 OpenVPN 服务集成方案，提供镜像构建、环境部署、用户与证书管理、多种认证方式、客户端路由及日常维护能力。

`server/` 相关脚本基于 [kylemanna/docker-openvpn](https://github.com/kylemanna/docker-openvpn) 开发。

## 功能

- 按环境部署相互隔离的 OpenVPN 实例
- 证书、OTP、固定密码及 LDAP 认证
- 用户证书签发、续期、吊销和客户端配置导出
- CCD 静态地址、用户路由、全局路由和域名路由
- 客户端硬件地址绑定
- 容器规则重载与宿主机 iptables 网络策略备份
- 日志轮转和不活跃客户端清理
- 离线部署包生成

## 目录结构

```text
openvpn-docker-integration/
├── server/
│   ├── Dockerfile
│   ├── build.sh
│   ├── bin/
│   └── otp/openvpn
├── deploy/
│   ├── config/
│   ├── helpers/
│   ├── hooks/
│   ├── maintenance/
│   ├── templates/
│   ├── install.sh
│   ├── ovpn
│   ├── ovpn.env.example
│   └── package.sh
└── tests/
    └── test.sh
```

- `server/`：OpenVPN 镜像及容器内命令。
- `deploy/`：安装器、管理命令、运行时脚本、模板和配置示例。
- `tests/`：Shell 语法、配置生成和管理命令测试。

## 运行时结构

`install.sh` 默认将环境安装到 `/opt/openvpn-<env>`：

```text
/opt/openvpn-<env>/
├── auth/
├── ccd/
├── clients/
├── config/
├── hooks/
├── logs/
├── maintenance/
├── otp/
├── pki/
├── state/
├── templates/ccd/
├── compose.yaml
├── openvpn.conf
└── ovpn.env
```

- `auth/`：认证配置、固定密码用户和授权文件。
- `ccd/`：实际生效的客户端专属配置。
- `clients/`：客户端配置及用户相关文件。
- `hooks/`：OpenVPN 认证、连接和断开钩子。
- `pki/`：Easy-RSA PKI 数据。
- `state/`：运行状态、容器规则，以及 `host-iptables.rules` 和可选的
  `host-ip6tables.rules` 宿主机网络策略快照。
- `templates/ccd/`：CCD 默认模板。

## 环境要求

镜像构建端需要：

- Docker Buildx
- Bash

目标 Linux 主机需要：

- root 权限
- Docker Engine
- Docker Compose 插件
- Bash、`crontab` 和 `iptables-save`

生成离线部署包的机器还需要 `tar`；如需将镜像包含在部署包内，还需要 Docker。

## 构建镜像

```shell
bash server/build.sh openvpn-integration:local --load
```

默认构建 `linux/amd64` 镜像。通过 `OVPN_BUILD_PLATFORM` 指定其他平台：

```shell
OVPN_BUILD_PLATFORM=linux/arm64 bash server/build.sh openvpn-integration:local --load
```

第二个参数只能是 `--load` 或 `--push`，默认使用 `--load`。

## 配置

从示例创建部署配置：

```shell
cd deploy
cp ovpn.env.example ovpn.env
${EDITOR:-vi} ovpn.env
```

常用配置项包括镜像名称、服务端地址、VPN 网段、DNS、认证模式、LDAP 连接、路由和日志策略。具体变量及默认值以 [deploy/ovpn.env.example](deploy/ovpn.env.example) 为准。

认证模式必须使用以下有效组合之一：

| OTP | 固定密码 | LDAP | 行为 |
| --- | --- | --- | --- |
| 关闭 | 关闭 | 关闭 | 仅验证客户端证书 |
| 开启 | 关闭 | 关闭 | 所有用户使用 OTP |
| 开启 | 开启 | 关闭 | 固定密码名单内用户使用密码，其他用户使用 OTP |
| 关闭 | 开启 | 关闭 | 所有已登记用户使用固定密码 |
| 关闭 | 关闭 | 开启 | 使用 LDAP |

LDAP 模式不能同时启用 OTP 或固定密码认证。

## 安装

在目标 Linux 主机以 root 用户执行：

```shell
cd deploy
bash install.sh production ./ovpn.env
```

安装器会：

1. 创建 `/opt/openvpn-production` 运行目录。
2. 安装运行时钩子、维护脚本和 Compose 配置。
3. 生成 OpenVPN 服务端配置和初始 PKI。
4. 安装 `/usr/local/bin/ovpn` 管理命令。
5. 配置维护任务并启动服务。

环境名仅允许字母、数字、下划线和连字符。

## 管理命令

运行 `ovpn help` 查看完整帮助。

### 用户与证书

| 命令 | 用途 |
| --- | --- |
| `ovpn createuser ENV USER` | 创建用户并生成客户端配置 |
| `ovpn renewuser ENV USER` | 续期用户证书 |
| `ovpn deluser ENV USER` | 吊销并删除用户 |
| `ovpn listuser ENV` | 列出用户 |
| `ovpn clientip ENV USER [IP]` | 查看或设置用户静态 IP |
| `ovpn resetotp ENV USER` | 重置用户 OTP |

用户名必须以字母开头，只能包含字母、数字、点、下划线和连字符。非 LDAP 模式会在内部追加环境后缀，最终名称长度不能超过 31 个字符。

启用 OTP 时，`createuser` 和 `resetotp` 会在终端输出可供身份验证器扫描的 UTF-8 二维码。`createuser` 还会将包含二维码和 OTP 信息的输出保存到用户客户端目录；二维码包含 OTP 密钥，应按敏感凭据保护。

### 固定密码

| 命令 | 用途 |
| --- | --- |
| `ovpn addpass ENV USER [PASSWORD]` | 添加固定密码用户 |
| `ovpn delpass ENV USER` | 删除固定密码用户 |
| `ovpn chpass ENV USER [PASSWORD]` | 修改固定密码 |
| `ovpn listpass ENV` | 列出固定密码用户 |

省略密码参数时，命令会通过隐藏输入读取密码，避免密码出现在 shell 历史和进程参数中。

### 路由与设备

| 命令 | 用途 |
| --- | --- |
| `ovpn listroute ENV USER` | 查看用户路由 |
| `ovpn addroute ENV USER ROUTE` | 添加用户 IPv4 路由 |
| `ovpn delroute ENV USER ROUTE` | 删除用户路由 |
| `ovpn adddomainroute ENV USER SOURCE [--yes]` | 解析域名文件或参数并添加用户路由 |
| `ovpn adddomainrouteall ENV SOURCE [--yes]` | 为所有 CCD 用户添加域名路由 |
| `ovpn addrouteall ENV ROUTE` | 为所有用户添加路由 |
| `ovpn delrouteall ENV ROUTE` | 为所有用户删除路由 |
| `ovpn listhwaddr ENV USER` | 查看用户硬件地址绑定 |
| `ovpn delhwaddr ENV USER` | 删除用户硬件地址绑定 |

`ROUTE` 接受 IPv4 地址或 CIDR。`SOURCE` 可以是域名文件，也可以是直接传入的单个域名或以英文逗号分隔的多个域名。域名文件每行一个域名，空行和以 `#` 开头的注释会被忽略：

```text
example.com
api.example.com
```

`adddomainroute` 默认显示解析结果并要求确认，自动化场景可传入 `--yes`。已存在于用户 CCD 的域名路由会计入重复数，并以 `域名 -> IPv4/32` 格式列出；如果解析结果全部已存在，命令直接成功返回且不再要求确认。

`adddomainrouteall` 使用相同的 `SOURCE` 格式，将域名解析结果应用到全部 CCD 用户。域名只解析一次，命令只确认一次；待添加和重复明细会同时显示对应用户名。

```shell
ovpn adddomainroute production alice example.com,api.example.com
ovpn adddomainroute production alice example.com,api.example.com --yes
ovpn adddomainrouteall production example.com,api.example.com --yes
```

### 服务

| 命令 | 用途 |
| --- | --- |
| `ovpn start ENV` | 启动环境 |
| `ovpn stop ENV` | 停止环境 |
| `ovpn status ENV` | 查看状态 |
| `ovpn restart ENV` | 备份配置后重建服务 |
| `ovpn reloadipset ENV` | 重新加载 ipset |
| `ovpn reloadiptables ENV` | 重新加载 iptables |
| `ovpn backuphostnetwork ENV` | 刷新宿主机 iptables 网络策略备份 |

安装、`start` 和 `restart` 会在 Docker 网络就绪后自动刷新宿主机网络策略快照。
备份文件用于审计和人工恢复；管理命令不会自动将整套规则恢复到宿主机。

常用示例：

```shell
ovpn createuser production alice
ovpn clientip production alice 192.168.255.10
ovpn addroute production alice 10.20.0.0/16
ovpn adddomainroute production alice ./domains.txt
ovpn adddomainroute production alice example.com,api.example.com
ovpn adddomainrouteall production ./domains.txt --yes
ovpn addpass production alice
ovpn status production
```

## 部署包

生成包含部署文件及可选镜像的压缩包：

```shell
bash deploy/package.sh
bash deploy/package.sh openvpn-deploy.tar.gz openvpn-integration:local
```

第一个参数是输出文件名，第二个可选参数是需要一并打包的镜像。默认输出为 `deploy/openvpn-deploy.tar.gz`。

## 验证

运行仓库测试：

```shell
bash tests/test.sh
```

测试覆盖 Bash 语法、命令帮助、运行时目录、服务端文件导出、部署包结构、密码保密、OTP/固定密码配置、LDAP 配置、固定密码用户管理及宿主机网络策略备份。

单独检查关键脚本语法：

```shell
bash -n deploy/ovpn deploy/install.sh deploy/package.sh \
  deploy/maintenance/backup-host-network.sh server/build.sh tests/test.sh
```
