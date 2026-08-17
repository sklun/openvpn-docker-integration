# 认证

## 认证组合

所有模式都围绕 OpenVPN 客户端身份建立，支持以下组合：

| OTP | 固定密码 | LDAP | 实际行为                                                                          |
| --- | -------- | ---- | --------------------------------------------------------------------------------- |
| 关  | 关       | 关   | 只校验客户端证书。                                                                |
| 开  | 关       | 关   | 证书加 TOTP；每个证书用户必须有 OTP 密钥。                                        |
| 开  | 开       | 关   | 固定密码名单中的用户使用固定密码，其他用户使用 TOTP。                             |
| 关  | 开       | 关   | 证书加固定密码；只有登记过固定密码的用户能通过 PAM。                              |
| 关  | 关       | 开   | LDAP 用户名密码加本地 JSON 授权；是否要求证书由 `LDAP_DISABLE_CERT_VERIFY` 决定。 |

安装器拒绝 LDAP 与 OTP/固定密码同时开启。OTP 与固定密码依赖镜像内固定 PAM 路径，因此 `OPENVPN` 必须为 `/etc/openvpn`。

认证模式会写入 `openvpn.conf` 和客户端配置，部署后只修改布尔值不会完整切换模式。认证模式变更应重新生成服务端配置、重建容器并重新导出客户端；生产环境优先新建环境验证。

## 证书与 PKI

安装时 `ovpn_initpki` 使用 Easy-RSA 创建：

- CA；`CA_NOPASS=true` 时无密码。
- DH 参数和 TLS Auth 密钥 `pki/ta.key`。
- 名称为 `OVPN_HOST` 的无密码服务端证书。
- 初始 CRL，并复制为运行目录 `crl.pem`。

创建用户：

```shell
ovpn createuser production alice
```

非 LDAP 模式下，证书 CN 默认规范为 `alice-production`；`OVPN_USER_SUFFIX` 可覆盖后缀。LDAP 模式不追加环境后缀。最终名称必须以字母开头，最多 31 个字符，以满足 ipset 命名限制。

`createuser` 生成无密码客户端私钥、内嵌式 `.ovpn`、可选 OTP、CCD、固定隧道 IP，并只增量创建该用户的访问规则。任一步失败会尝试吊销并删除本次证书、客户端文件、状态、密码记录和该用户规则。

续期与删除：

```shell
ovpn renewuser production alice
ovpn deluser production alice
ovpn listuser production
```

- `renewuser` 调用 Easy-RSA renew，并新增一个带日期的客户端配置；旧文件不会自动删除。
- `deluser` 吊销证书、更新 CRL、删除私钥/证书/请求、客户端目录、CCD、当前 IP 映射和固定密码，并在容器运行时只删除该用户的规则和 ipset。
- 历史 IP 文件不会因删除用户而清理，可用于审计。

客户端配置包含私钥、证书、CA 和 TLS Auth 密钥，必须按凭据保护。`clients/<user>/` 目录固定为 `0700`，其中 `.ovpn`、分离式证书材料和 OTP 交付文件固定为 `0600`。启用任一用户名密码认证时，生成器还会写入 `auth-user-pass`、`auth-nocache` 和 `reneg-sec 0`。

## OTP

启用 `OTP=true` 后，OpenVPN 使用 PAM 插件和 `pam_google_authenticator`。密钥保存在：

```text
otp/<normalized-user>.google_authenticator
```

创建用户时会生成 TOTP，并把终端二维码和信息写入 `clients/<user>/<user>-otpinfo`；该交付文件为 `0600`。密钥文件最终设置为 root 所有、`0400`。重置命令为：

```shell
ovpn resetotp production alice
```

重置会立即覆盖旧密钥，旧身份验证器随即失效；命令只在当前终端输出新二维码，不更新先前的 `-otpinfo` 文件。二维码、URI 和密钥等同于密码，不应写入普通工单或日志。

默认生成参数为基于时间、禁止重复使用、30 秒内最多 3 次、窗口大小 3。服务端和客户端系统时间应可靠同步。

## 固定密码

启用 `PASSWORD_AUTH=true` 后，先创建证书用户，再登记密码：

```shell
ovpn addpass production alice
ovpn chpass production alice
ovpn delpass production alice
ovpn listpass production
```

省略密码参数时使用隐藏输入。自动化可传入第四个参数，但会暴露在 shell 历史和进程参数中，不推荐。密码不能包含冒号或换行。

运行时文件为：

```text
auth/static-password-users
auth/static-passwords
```

前者决定哪些用户走固定密码分支，后者保存 `user:password`。当前实现保存的是受文件权限保护的明文密码，不是哈希；两个文件设为 `0600`。管理命令对两个文件共用一把锁，新增时先写密码再加入用户名单，修改和删除使用临时文件原子替换。备份、故障采集和管理员权限必须按此风险控制。

PAM 顺序如下：

1. `pam_listfile` 检查用户名是否在固定密码名单。
2. 命中时由 `ovpn_static_auth` 对比输入密码并结束认证。
3. 未命中时进入 Google Authenticator。

因此同时开启 OTP 和固定密码时，一个用户只能按名单选择其中一个分支，不是要求输入两个因子。只开启固定密码时，未登记用户会落入没有密钥的 OTP 分支并失败。

## LDAP 认证与本地授权

LDAP 模式生成 OpenVPN LDAP 插件配置，使用：

- LDAP 插件校验用户名密码。
- `username-as-common-name` 把 LDAP 用户名作为 OpenVPN common name。
- `ldap-authorize.sh` 再检查本地 JSON 白名单。
- `client-connect-ldap.sh` 首次连接时固定地址、维护状态并增量创建该用户规则。

安装器初始化的授权文件为：

```json
{
  "retain_user": [],
  "LDAP_user": []
}
```

允许用户的最小示例：

```json
{
  "retain_user": [],
  "LDAP_user": [{ "user": "alice" }, { "user": "bob" }]
}
```

当前代码只读取 `.LDAP_user[].user`；`retain_user` 和对象中的其他字段不参与授权或路由。用户名必须以字母开头，且最多 31 个字符。授权成功时，如果 CCD 不存在，会从默认模板创建空 CCD。

首次 LDAP 连接由 OpenVPN 地址池提供地址，连接 Hook 在客户端状态锁内把它写为 CCD `ifconfig-push`，并追加当前/历史 IP 状态；后续成功连接在同一把锁内更新最后登录时间。释放状态锁后，Hook 检查该用户的规则、ipset 和 CCD 路由是否一致；缺失或不一致时只重建该用户。防火墙同步失败会拒绝本次连接，但状态记录保留，后续连接会再次检查并重试。空 CCD 没有目标白名单，用户认证可成功但转发会被拒绝，直到管理员添加路由。

`AUTO_REVOKE` 只管理本地证书用户，安装器拒绝将它与 LDAP 同时启用。LDAP 用户的停用应在 LDAP 目录和本地 JSON 授权名单中完成。

当前 LDAP 配置生成器会去掉 URL 中的 scheme，再固定输出 `ldap://` 和 `TLSEnable no`。因此不能把填写 `ldaps://` 视为启用了 TLS；在可信网络之外使用前必须扩展并验证 TLS 配置。

`LDAP_DISABLE_CERT_VERIFY=true` 会写入 `verify-client-cert optional`，允许 LDAP 用户不带客户端证书；设为 `false` 时 LDAP 密码之外仍需有效证书。

## 设备绑定

`DEVICE_AUTH=true` 时，安装器选择设备绑定 `client-connect` Hook。LDAP 模式优先选择 LDAP Hook，因此当前不支持 LDAP 与该设备绑定流程组合。

客户端配置包含 `push-peer-info`，但标准 OpenVPN 客户端不会自动提供项目使用的全部扩展字段。兼容客户端需上报 `IV_PLAT`、`IV_PLAT_VER`、`IV_USER`、`IV_INFO`、`IV_DISK` 等字段；移动端使用 `UV_UUID` 和 `IV_HWADDR` 组合设备标识。

首次连接采用信任首次使用（TOFU）：在客户端状态锁内记录当次上报的设备信息并允许连接，不与预置设备数据比较。后续连接逐项匹配，只有验证成功才更新最后登录时间；设备变化、未签名 GUI 标记、未知平台或后续匹配所需字段缺失会拒绝连接。首次绑定、成功登录时间、解绑以及用户状态删除共用同一把锁，避免并发覆盖。查看和解绑：

```shell
ovpn listhwaddr production alice
ovpn delhwaddr production alice
```

解绑会清空设备字段但保留用户、隧道 IP 和最近登录时间；下次连接重新绑定。

## 认证和连接日志

连接 Hook 在 `logs/loginlog/` 记录每日登录和退出日志，并把 `trusted_ip` 记录为接入 VPN 前的来源地址。设备认证会记录更详细的匹配结果。OpenVPN 主认证错误见 `logs/openvpn.log` 或：

```shell
ovpn status production
```

排障时按顺序检查证书状态、认证模式、用户规范化后的名称、OTP/固定密码文件、LDAP 插件和 JSON 授权，再检查 CCD 与防火墙。认证成功不代表目标路由已授权。
