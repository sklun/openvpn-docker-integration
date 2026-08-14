# 构建与部署

## 组件与环境要求

项目分成镜像和部署包两部分：`server/` 生成 OpenVPN Server 镜像，`deploy/` 在目标 Linux 主机上初始化独立环境并提供管理命令。

构建端需要 Docker Buildx 和 Bash。目标主机需要 root、Docker Engine、Docker Compose 插件、Bash、`crontab` 和 `iptables-save`。生成部署包还需要 `tar`。

默认目标平台为 `linux/amd64`。容器使用 `NET_ADMIN`，并在启动时创建 `/dev/net/tun`、iptables/ipset 规则和日志服务；目标主机必须允许这些操作。

## 构建镜像

在仓库根目录执行：

```shell
bash server/build.sh openvpn-integration:local --load
```

参数如下：

| 参数                  | 默认值                      | 说明                                     |
| --------------------- | --------------------------- | ---------------------------------------- |
| 第一个参数            | `openvpn-integration:local` | 镜像名称和标签                           |
| 第二个参数            | `--load`                    | `--load` 加载到本机，`--push` 推送到仓库 |
| `OVPN_BUILD_PLATFORM` | `linux/amd64`               | Buildx 目标平台                          |

例如构建 ARM64 镜像：

```shell
OVPN_BUILD_PLATFORM=linux/arm64 \
  bash server/build.sh registry.example.com/openvpn/integration:v1 --push
```

镜像基于 Alpine，包含 OpenVPN、Easy-RSA、LDAP/PAM/Google Authenticator 插件、iptables 的 nft/legacy 前端、ipset、ulogd、logrotate 和容器内 `ovpn_*` 辅助命令。默认入口是 `ovpn_run`。

## 准备配置

配置文件由 Bash 直接加载，必须保持 Bash 语法：

```shell
cp deploy/ovpn.env.example deploy/ovpn.env
${EDITOR:-vi} deploy/ovpn.env
```

至少确认以下值：

```bash
OVPN_IMAGE="openvpn-integration:local"
OVPN_HOST="vpn.example.com"
OVPN_PORT="1194"
OVPN_CLIENT_SUBNET="10.8.0.0/24"
```

认证模式、网络策略和全部变量见 [`ovpn.env` 配置](configuration.md)。

## 直接部署

在目标 Linux 主机以 root 执行：

```shell
cd deploy
bash install.sh production ./ovpn.env
```

环境名只允许字母、数字、下划线和连字符。安装器固定使用 `/opt/openvpn-<env>`，当前没有修改该安装根路径的参数。

安装流程如下：

1. 加载并校验配置，计算客户端地址池的首尾地址。
2. 如果部署目录中存在 `vpnserverimage.tar`，加载它；否则本地镜像不存在时拉取 `OVPN_IMAGE`。
3. 如果运行目录已存在，将其移动到同级时间戳目录，例如 `/opt/openvpn-production-2026_0813_120000`。
4. 创建 `auth/`、`ccd/`、`clients/`、`hooks/`、`logs/`、`maintenance/`、`otp/`、`state/` 等运行目录，复制配置、Hook、维护脚本和 Compose 模板。
5. 把源配置复制为运行时 `ovpn.env`，写入计算得到的 `SUBNET_IP_FIRST`、`SUBNET_IP_LAST` 和 `OVPN_HOOKS_PATH`。源文件不会被修改。
6. 使用一次性容器生成 `openvpn.conf`，初始化 CA、服务端证书、DH、`ta.key` 和 CRL。
7. 安装 `/usr/local/bin/ovpn`，写入日志轮转及可选的自动吊销 crontab。
8. 将运行目录交给容器内 `nobody` 用户，启动 Compose 服务，随后备份宿主机当前 iptables/ip6tables 策略。

运行时结构见 [运维与管理命令](operations.md)。

## 离线部署包

只打包部署文件：

```shell
bash deploy/package.sh
```

把指定镜像一起导出：

```shell
bash deploy/package.sh openvpn-deploy.tar.gz openvpn-integration:local
```

默认输出为 `deploy/openvpn-deploy.tar.gz`。部署包包含 `docs/` 文档集和 `helpers/` 客户端工具；带镜像时还包含 `vpnserverimage.tar`，安装器会优先 `docker load`。解压后复制并编辑 `ovpn.env.example`，再执行：

```shell
cp ovpn.env.example ovpn.env
bash install.sh production ./ovpn.env
```

部署包不包含任何现有 PKI、凭据、客户端配置或运行状态。

`helpers/` 不由 `install.sh` 安装到服务端运行目录。需要在客户端使用时，应单独复制目标脚本并按[客户端工具](client-tools.md)中的依赖和安全边界执行。

## 更新与重新部署

当前项目没有自动的原地升级命令。按变更类型选择操作：

| 变更                                                            | 操作                                                                             |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| 仅更新镜像实现，运行时数据格式不变                              | 先备份运行目录，更新 `OVPN_IMAGE`，执行 `ovpn restart ENV`                       |
| 更新运行时 Hook、维护脚本、Compose 模板或 `/usr/local/bin/ovpn` | 从新部署包人工替换对应文件，核对权限后重启；不要直接重跑安装器                   |
| 修改仅由 `openvpn.conf` 固化的变量                              | 使用新配置生成结果并受控替换，或规划全新环境；仅 `restart` 不会重新生成配置      |
| 修改 PKI 根参数、服务端证书名称或客户端地址池                   | 规划新环境和客户端迁移，不要原地改写已有运行状态                                 |
| 完全重新初始化                                                  | 再次执行 `install.sh`；旧目录会被移动备份，新 PKI 会导致旧客户端不再适用于新实例 |

任何人工替换前至少备份 `/opt/openvpn-<env>`。包含 `ovpn.env`、PKI 和认证文件的备份应按敏感数据保护。

## 验证

先在仓库测试容器中运行静态和仓库测试：

```shell
bash -n deploy/ovpn deploy/install.sh deploy/package.sh server/build.sh tests/test.sh
bash tests/test.sh
```

部署后检查：

```shell
ovpn status production
ovpn listuser production
ovpn syncrules production
```

再从受支持的客户端验证证书/用户名密码认证、地址分配、目标路由和断开日志。不要只以容器处于 running 状态作为功能验证。
