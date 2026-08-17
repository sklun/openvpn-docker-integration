# 客户端工具

`deploy/helpers/` 提供两个独立的 Linux 客户端工具。它们随离线部署包分发，但不由 `install.sh` 执行，不会复制到 `/opt/openvpn-<env>`，也不是 `ovpn` 管理命令的一部分。

## 临时启动客户端

`run-client.sh` 使用指定的 OpenVPN 配置启动后台客户端：

```shell
bash helpers/run-client.sh /etc/openvpn/client production.ovpn
bash helpers/run-client.sh /etc/openvpn/client production.ovpn alice 'password-or-otp'
```

参数依次为配置目录、配置文件名，以及可选的用户名和密码。用户名与密码必须同时提供；提供后脚本会在配置目录创建隐藏的 `.<config-name>.auth`，设置为 `0600`，并通过 `--auth-user-pass` 交给 OpenVPN。日志写入配置目录中的 `<user>_<YYYYMMDD>.log`；未提供用户时使用 `<config-name>_<YYYYMMDD>.log`。用户名中的文件名不安全字符会替换为 `_`，日志不会写出配置目录。

脚本通过 `.<config-name>.pid` 管理该配置启动的 OpenVPN 进程。再次执行时只处理 PID 文件指向且命令行同时匹配当前配置目录和配置文件名的进程，先发送 `SIGTERM`，等待 5 秒后仍未退出才发送 `SIGKILL`；陈旧 PID 文件会自动清理。

认证文件仍包含明文用户名和密码，脚本不会自动删除。连接完成后由管理员安全删除；密码作为命令行参数还可能进入 Shell 历史，因此不适合直接处理长期凭据。

运行要求：Bash、OpenVPN、Linux `/proc` 和 `tail`。

## 安装 systemd 服务

`install-client-service.sh` 根据一个现有客户端配置生成并启用 systemd 服务：

```shell
sudo bash helpers/install-client-service.sh /etc/openvpn/client/production.ovpn
```

脚本要求参数指向现有文件，并应使用绝对路径。以上示例生成：

```text
/etc/systemd/system/openvpn-client@production.service
```

服务通过 `/usr/sbin/openvpn` 启动配置，日志写入配置文件所在目录。脚本随后执行 `systemctl daemon-reload`、启动服务并启用开机启动。

运行要求：root 权限、systemd，以及路径固定为 `/usr/sbin/openvpn` 的 OpenVPN 客户端。脚本会直接覆盖同名 unit 文件；执行前应确认服务名没有被其他配置使用。

## 使用边界

- 这两个工具只管理客户端进程，不部署或管理 OpenVPN Server。
- 服务端生命周期、用户、认证和路由继续使用 `install.sh` 与 `ovpn`。
- 工具不会读取服务端 `ovpn.env`，也不会自动获取 `/opt/openvpn-<env>/clients/` 中生成的客户端配置。
- 当前工具面向受控 Linux 环境，不提供 macOS、Windows、移动端或 NetworkManager 集成。
