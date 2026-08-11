#!/bin/bash
# 功能说明：执行 Shell 语法、认证配置、网络策略备份和管理命令回归测试。

set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

echo "+ Shell syntax"
while IFS= read -r file; do
    if head -n 1 "$file" | grep -Eq '^#!.*(ba|z|k)?sh'; then
        bash -n "$file"
    fi
done < <(find "$PROJECT_ROOT/server" "$PROJECT_ROOT/deploy" -type f | sort)

echo "+ Command help"
help_output=$(bash "$PROJECT_ROOT/deploy/ovpn" help)
grep -Fq '用户与证书:' <<<"$help_output"
grep -Fq '固定密码认证:' <<<"$help_output"
grep -Fq '路由与设备:' <<<"$help_output"
grep -Fq 'adddomainroute' <<<"$help_output"
grep -Fq '| -adr' <<<"$help_output"
grep -Fq 'adddomainrouteall' <<<"$help_output"
grep -Fq '| -adra' <<<"$help_output"
grep -Fq '服务与规则:' <<<"$help_output"
grep -Fq 'backuphostnetwork' <<<"$help_output"
grep -Fq '非 LDAP 模式会自动追加 -<env>' <<<"$help_output"
grep -Fq '密码、OTP 密钥、私钥或 LDAP 凭据' <<<"$help_output"
if bash "$PROJECT_ROOT/deploy/install.sh" >/dev/null 2>&1; then
    echo "install.sh unexpectedly succeeded without arguments" >&2
    exit 1
fi

echo "+ CIDR and mask conversion"
(
    set -- help
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/deploy/ovpn" >/dev/null

    for prefix in {0..32}; do
        mask=$(cidr_to_mask "$prefix")
        converted_prefix=$(mask_to_cidr "$mask")
        if [[ $converted_prefix != "$prefix" ]]; then
            echo "CIDR round trip failed: $prefix -> $mask -> $converted_prefix" >&2
            exit 1
        fi
    done

    for prefix in -1 33 01 abc ""; do
        if cidr_to_mask "$prefix" >/dev/null; then
            echo "invalid CIDR prefix unexpectedly accepted: $prefix" >&2
            exit 1
        fi
    done

    for mask in \
        255.255.0 \
        255.255.255.255.0 \
        255.255.127.0 \
        255.0.255.0 \
        255.254.128.0 \
        255.255.255.1; do
        if mask_to_cidr "$mask" >/dev/null; then
            echo "invalid subnet mask unexpectedly accepted: $mask" >&2
            exit 1
        fi
    done
)

echo "+ Non-interactive PKI and OTP ownership safeguards"
grep -Fq 'easyrsa --batch build-ca' "$PROJECT_ROOT/server/bin/ovpn_initpki"
grep -Fq 'easyrsa --batch build-server-full' "$PROJECT_ROOT/server/bin/ovpn_initpki"
grep -Fq 'easyrsa --batch build-client-full' "$PROJECT_ROOT/deploy/ovpn"
grep -Fq 'easyrsa --batch renew' "$PROJECT_ROOT/deploy/ovpn"
# shellcheck disable=SC2016  # Matching literal source text.
grep -Fq 'chown 0:0 "$otp_file"' "$PROJECT_ROOT/deploy/ovpn"
# shellcheck disable=SC2016  # Matching literal source text.
grep -Fq 'chmod 400 "$otp_file"' "$PROJECT_ROOT/deploy/ovpn"
# shellcheck disable=SC2016  # Matching literal source text.
grep -Fq 'set_env_value "$runtime_env" OVPN_HOOKS_PATH "${OPENVPN}/hooks"' \
    "$PROJECT_ROOT/deploy/install.sh"
grep -Fq 'file=/etc/openvpn/auth/static-password-users' "$PROJECT_ROOT/server/otp/openvpn"
grep -Fq 'file="@OPENVPN@/logs/iptables.log"' "$PROJECT_ROOT/deploy/config/ulogd.conf"
grep -Fq 'maintenance/backup-host-network.sh' "$PROJECT_ROOT/deploy/install.sh"
grep -Fq 'require_command iptables-save' "$PROJECT_ROOT/deploy/install.sh"
# shellcheck disable=SC2016  # Matching literal source text.
if grep -R -E 'OVPN_SCRIPTS_PATH|(/etc/openvpn|\$OPENVPN|\$\{OPENVPN\})/(scripts|tools)([^[:alnum:]_.-]|$)' \
    "$PROJECT_ROOT/server" "$PROJECT_ROOT/deploy" >/dev/null; then
    echo "legacy runtime path remains in current implementation" >&2
    exit 1
fi
for legacy_directory in scripts tools deploy/scripts deploy/tools server/scripts server/tools; do
    [[ ! -e $PROJECT_ROOT/$legacy_directory ]]
done
template_last_byte=$(tail -c 1 "$PROJECT_ROOT/deploy/templates/ccd/default" | od -An -t x1 | tr -d '[:space:]')
[[ $template_last_byte == 0a ]]

echo "+ OTP QR output"
otp_runtime="$TEST_ROOT/otp-runtime"
otp_bin="$TEST_ROOT/otp-bin"
otp_args_log="$TEST_ROOT/otp-args.log"
otp_uri_log="$TEST_ROOT/otp-uri.log"
mkdir -p "$otp_runtime" "$otp_bin"
cat >"$otp_runtime/ovpn.env" <<'EOF'
OTP=true
OVPN_HOST="vpn.test.example"
EOF
cat >"$otp_bin/google-authenticator" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$OTP_ARGS_LOG"
secret_file=""
while [ "$#" -gt 0 ]; do
    case $1 in
        -s)
            secret_file=$2
            shift 2
            ;;
        *) shift ;;
    esac
done
printf 'JBSWY3DPEHPK3PXP\n' >"$secret_file"
printf 'AUTHENTICATOR-OUTPUT\n'
EOF
cat >"$otp_bin/qrencode" <<'EOF'
#!/bin/sh
cat >"$OTP_URI_LOG"
printf 'QR-CODE-OUTPUT\n'
EOF
chmod +x "$otp_bin/google-authenticator" "$otp_bin/qrencode"
otp_output=$(OPENVPN="$otp_runtime" OTP_ARGS_LOG="$otp_args_log" OTP_URI_LOG="$otp_uri_log" \
    PATH="$otp_bin:$PATH" bash "$PROJECT_ROOT/server/bin/ovpn_otp_user" alice)
grep -Fq 'AUTHENTICATOR-OUTPUT' <<<"$otp_output"
grep -Fq 'QR-CODE-OUTPUT' <<<"$otp_output"
grep -Fq -- '--qr-mode=NONE' "$otp_args_log"
grep -Fq -- '-l alice@vpn.test.example' "$otp_args_log"
grep -Fq -- '-i vpn.test.example' "$otp_args_log"
grep -Fxq 'otpauth://totp/alice@vpn.test.example?secret=JBSWY3DPEHPK3PXP&issuer=vpn.test.example' "$otp_uri_log"

make_env() {
    local target=$1 ldap=$2 otp=$3 password_auth=$4
    sed \
        -e "s|^OPENVPN=.*|OPENVPN=\"$TEST_ROOT/runtime\"|" \
        -e 's|^OVPN_HOST=.*|OVPN_HOST="vpn.test.example"|' \
        -e "s|^LDAP=.*|LDAP=$ldap|" \
        -e "s|^OTP=.*|OTP=$otp|" \
        -e "s|^PASSWORD_AUTH=.*|PASSWORD_AUTH=$password_auth|" \
        -e 's|^LDAP_URL=.*|LDAP_URL="ldap.test.example:389"|' \
        -e 's|^LDAP_BIND_DN=.*|LDAP_BIND_DN="cn=test,dc=example,dc=com"|' \
        -e 's|^LDAP_PASSWORD=.*|LDAP_PASSWORD="test-only"|' \
        -e 's|^LDAP_BASE_DN=.*|LDAP_BASE_DN="dc=example,dc=com"|' \
        -e 's|^OVPN_ROUTES=.*|OVPN_ROUTES=("10.20.0.0/16")|' \
        "$PROJECT_ROOT/deploy/ovpn.env.example" >"$target"
}

echo "+ OTP/password configuration generation"
mkdir -p "$TEST_ROOT/runtime"
make_env "$TEST_ROOT/runtime/ovpn.env" false true true
OPENVPN="$TEST_ROOT/runtime" bash "$PROJECT_ROOT/server/bin/ovpn_gen_server_conf" >/dev/null
for directory in auth ccd clients config hooks logs otp state templates/ccd; do
    [[ -d $TEST_ROOT/runtime/$directory ]]
done
[[ ! -e $TEST_ROOT/runtime/scripts && ! -e $TEST_ROOT/runtime/tools \
    && ! -e $TEST_ROOT/runtime/exports ]]
grep -Fq "client-connect $TEST_ROOT/runtime/hooks/client-connect.sh" "$TEST_ROOT/runtime/openvpn.conf"
grep -Fq "client-disconnect $TEST_ROOT/runtime/hooks/client-disconnect.sh" "$TEST_ROOT/runtime/openvpn.conf"
grep -Fq 'openvpn-plugin-auth-pam.so' "$TEST_ROOT/runtime/openvpn.conf"
grep -Fq 'route 10.20.0.0 255.255.0.0' "$TEST_ROOT/runtime/openvpn.conf"
grep -Fq 'user nobody' "$TEST_ROOT/runtime/openvpn.conf"
if grep -Fq 'openvpn-auth-ldap.so' "$TEST_ROOT/runtime/openvpn.conf"; then
    echo "LDAP plugin unexpectedly present in PAM mode" >&2
    exit 1
fi

echo "+ LDAP configuration generation"
rm -rf "$TEST_ROOT/runtime"
mkdir -p "$TEST_ROOT/runtime"
make_env "$TEST_ROOT/runtime/ovpn.env" true false false
OPENVPN="$TEST_ROOT/runtime" bash "$PROJECT_ROOT/server/bin/ovpn_gen_server_conf" >/dev/null
grep -Fq 'openvpn-auth-ldap.so' "$TEST_ROOT/runtime/openvpn.conf"
grep -Fq 'auth-user-pass-verify' "$TEST_ROOT/runtime/openvpn.conf"
grep -Fq 'URL ldap://ldap.test.example:389' "$TEST_ROOT/runtime/auth/ldap.conf"
if grep -Fq 'user nobody' "$TEST_ROOT/runtime/openvpn.conf"; then
    echo "LDAP policy mode unexpectedly drops privileges before provisioning hooks" >&2
    exit 1
fi
if grep -Fq 'openvpn-plugin-auth-pam.so' "$TEST_ROOT/runtime/openvpn.conf"; then
    echo "PAM plugin unexpectedly present in LDAP mode" >&2
    exit 1
fi

echo "+ Shell-native fixed password management"
password_runtime="$TEST_ROOT/openvpn-test"
mkdir -p "$TEST_ROOT/bin"
printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/bin/flock"
chmod +x "$TEST_ROOT/bin/flock"
cat >"$TEST_ROOT/bin/docker" <<'EOF'
#!/bin/sh
if [ "${MOCK_DOCKER_FAIL:-0}" = 1 ]; then
    exit 23
fi
if [ "${1:-}" = inspect ]; then
    printf 'true\n'
fi
exit 0
EOF
chmod +x "$TEST_ROOT/bin/docker"
cat >"$TEST_ROOT/bin/getent" <<'EOF'
#!/bin/sh
if [ "${1:-}" != ahostsv4 ]; then
    exit 2
fi
case ${2:-} in
    app.test)
        printf '10.30.0.10 STREAM app.test\n10.30.0.10 DGRAM app.test\n'
        ;;
    api.test)
        printf '10.30.0.10 STREAM api.test\n10.30.0.11 STREAM api.test\n'
        ;;
    direct.test)
        printf '10.30.0.13 STREAM direct.test\n'
        ;;
    direct-api.test)
        printf '10.30.0.14 STREAM direct-api.test\n'
        ;;
    all.test)
        printf '10.30.0.15 STREAM all.test\n'
        ;;
    cancel.test)
        printf '10.30.0.12 STREAM cancel.test\n'
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/getent"
cat >"$TEST_ROOT/bin/iptables-save" <<'EOF'
#!/bin/sh
if [ "${MOCK_IPTABLES_SAVE_FAIL:-0}" = 1 ]; then
    printf 'partial backup\n'
    exit 29
fi
printf '*filter\n:FORWARD ACCEPT [0:0]\nCOMMIT\n'
EOF
chmod +x "$TEST_ROOT/bin/iptables-save"
cat >"$TEST_ROOT/bin/ip6tables-save" <<'EOF'
#!/bin/sh
printf '*filter\n:FORWARD ACCEPT [0:0]\nCOMMIT\n'
EOF
chmod +x "$TEST_ROOT/bin/ip6tables-save"
export PATH="$TEST_ROOT/bin:$PATH"
mkdir -p "$password_runtime/auth" "$password_runtime/pki/issued" "$password_runtime/state" \
	"$password_runtime/maintenance" "$password_runtime/templates/ccd"
cp "$PROJECT_ROOT/deploy/maintenance/backup-host-network.sh" "$password_runtime/maintenance/"
chmod +x "$password_runtime/maintenance/backup-host-network.sh"
sed \
    -e 's|^OTP=.*|OTP=true|' \
    -e 's|^PASSWORD_AUTH=.*|PASSWORD_AUTH=true|' \
    -e 's|^LDAP=.*|LDAP=false|' \
    "$PROJECT_ROOT/deploy/ovpn.env.example" >"$password_runtime/ovpn.env"
touch "$password_runtime/pki/issued/alice-test.crt"
touch "$password_runtime/auth/static-password-users" "$password_runtime/auth/static-passwords"
password_log="$TEST_ROOT/password-command.log"

OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
	addpass test alice first-secret >/dev/null 2>"$password_log"
grep -Fq '+ 添加固定密码用户: alice-test' "$password_log"
grep -Fq '* 固定密码用户添加完成: alice-test' "$password_log"
if grep -Fq 'first-secret' "$password_log"; then
	echo "password leaked into command log" >&2
	exit 1
fi
grep -Fxq 'alice-test' "$password_runtime/auth/static-password-users"
grep -Fxq 'alice-test:first-secret' "$password_runtime/auth/static-passwords"

OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
	chpass test alice second-secret >/dev/null 2>"$password_log"
grep -Fq '+ 修改固定密码用户密码: alice-test' "$password_log"
grep -Fq '* 固定密码修改完成: alice-test' "$password_log"
if grep -Fq 'second-secret' "$password_log"; then
	echo "password leaked into command log" >&2
	exit 1
fi
grep -Fxq 'alice-test:second-secret' "$password_runtime/auth/static-passwords"
if grep -Fq 'first-secret' "$password_runtime/auth/static-passwords"; then
    echo "old password was not removed" >&2
    exit 1
fi

listed=$(OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" listpass test)
[[ $listed == 'alice-test' ]]

OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
    delpass test alice >/dev/null
[[ ! -s $password_runtime/auth/static-password-users ]]
[[ ! -s $password_runtime/auth/static-passwords ]]

echo "+ Service lifecycle logs"
service_log="$TEST_ROOT/service-command.log"
OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
    start test >/dev/null 2>"$service_log"
grep -Fq '+ 启动 VPN Server: openvpn-test' "$service_log"
grep -Fq '* VPN Server 启动完成: openvpn-test' "$service_log"
grep -Fq '*filter' "$password_runtime/state/host-iptables.rules"
grep -Fq '*filter' "$password_runtime/state/host-ip6tables.rules"

OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
	backuphostnetwork test >/dev/null 2>"$service_log"
grep -Fq '+ 备份宿主机网络策略: openvpn-test' "$service_log"
grep -Fq '* 宿主机网络策略备份完成:' "$service_log"

host_backup_before=$(cat "$password_runtime/state/host-iptables.rules")
if MOCK_IPTABLES_SAVE_FAIL=1 OVPN_RUNTIME_ROOT="$TEST_ROOT" \
	bash "$PROJECT_ROOT/deploy/ovpn" backuphostnetwork test >/dev/null 2>"$service_log"; then
	echo "failed host network policy backup unexpectedly succeeded" >&2
	exit 1
fi
[[ $(cat "$password_runtime/state/host-iptables.rules") == "$host_backup_before" ]]
if find "$password_runtime/state" -maxdepth 1 -type f -name 'host-iptables.rules.*' | grep -q .; then
	echo "failed host network policy backup left a temporary file" >&2
	exit 1
fi

if MOCK_DOCKER_FAIL=1 OVPN_RUNTIME_ROOT="$TEST_ROOT" \
    bash "$PROJECT_ROOT/deploy/ovpn" start test >/dev/null 2>"$service_log"; then
    echo "failed Docker command unexpectedly succeeded" >&2
    exit 1
fi
grep -Fq -- '- 操作失败（命令: start，环境: test' "$service_log"

echo "+ First CCD route append"
mkdir -p "$password_runtime/ccd"
cp "$PROJECT_ROOT/deploy/templates/ccd/default" \
    "$password_runtime/ccd/alice-test"
OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
    addroute test alice 10.30.0.0/16 >/dev/null 2>"$service_log"
grep -Fq '| 为用户 alice-test 添加路由: 10.30.0.0/16' "$service_log"
grep -Fq '* 路由添加完成: alice-test -> 10.30.0.0/16' "$service_log"
grep -Fxq 'push "route 10.30.0.0 255.255.0.0"' "$password_runtime/ccd/alice-test"

echo "+ Domain route integration"
domain_file="$TEST_ROOT/domains.txt"
cat >"$domain_file" <<'EOF'
# Duplicate 10.30.0.10 across two domains must be added once.
app.test
api.test # inline comments are supported
EOF
domain_log="$TEST_ROOT/domain-command.log"
OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
    adddomainroute test alice "$domain_file" --yes >/dev/null 2>"$domain_log"
grep -Fq '|   api.test -> 10.30.0.10/32' "$domain_log"
grep -Fq '| 汇总: 解析域名 2 个，待添加 IPv4 2 个，重复 1 个，失败 0 个' "$domain_log"
grep -Fq '* 域名路由添加完成: alice-test，成功 2 个，重复 1 个' "$domain_log"
grep -Fxq 'push "route 10.30.0.10 255.255.255.255"' "$password_runtime/ccd/alice-test"
grep -Fxq 'push "route 10.30.0.11 255.255.255.255"' "$password_runtime/ccd/alice-test"

OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
    adddomainroute test alice 'direct.test, direct-api.test' --yes >/dev/null 2>"$domain_log"
grep -Fq '| 汇总: 解析域名 2 个，待添加 IPv4 2 个，重复 0 个，失败 0 个' "$domain_log"
grep -Fq '* 域名路由添加完成: alice-test，成功 2 个，重复 0 个' "$domain_log"
grep -Fxq 'push "route 10.30.0.13 255.255.255.255"' "$password_runtime/ccd/alice-test"
grep -Fxq 'push "route 10.30.0.14 255.255.255.255"' "$password_runtime/ccd/alice-test"

OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
    adddomainroute test alice 'direct.test,direct-api.test' </dev/null >/dev/null 2>"$domain_log"
grep -Fq '| 重复路由:' "$domain_log"
grep -Fq '|   direct.test -> 10.30.0.13/32' "$domain_log"
grep -Fq '|   direct-api.test -> 10.30.0.14/32' "$domain_log"
grep -Fq '| 汇总: 解析域名 2 个，待添加 IPv4 0 个，重复 2 个，失败 0 个' "$domain_log"
grep -Fq '* 域名路由添加完成: alice-test，成功 0 个，重复 2 个' "$domain_log"
if grep -Eq '待添加路由:|是否继续添加以上路由' "$domain_log"; then
    echo "existing domain routes unexpectedly requested confirmation" >&2
    exit 1
fi
[[ $(grep -Fxc 'push "route 10.30.0.13 255.255.255.255"' "$password_runtime/ccd/alice-test") -eq 1 ]]
[[ $(grep -Fxc 'push "route 10.30.0.14 255.255.255.255"' "$password_runtime/ccd/alice-test") -eq 1 ]]

cp "$PROJECT_ROOT/deploy/templates/ccd/default" "$password_runtime/ccd/bob-test"
printf 'push "route 10.30.0.15 255.255.255.255"\n' >>"$password_runtime/ccd/alice-test"
OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
    adddomainrouteall test all.test --yes >/dev/null 2>"$domain_log"
grep -Fq '|   bob-test: all.test -> 10.30.0.15/32' "$domain_log"
grep -Fq '|   alice-test: all.test -> 10.30.0.15/32' "$domain_log"
grep -Fq '| 汇总: 解析域名 1 个，待添加用户路由 1 个，重复 1 个，失败 0 个' "$domain_log"
grep -Fq '* 全部用户域名路由添加完成: test，成功 1 个，重复 1 个' "$domain_log"
grep -Fxq 'push "route 10.30.0.15 255.255.255.255"' "$password_runtime/ccd/alice-test"
grep -Fxq 'push "route 10.30.0.15 255.255.255.255"' "$password_runtime/ccd/bob-test"

OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
    adddomainrouteall test all.test </dev/null >/dev/null 2>"$domain_log"
grep -Fq '| 汇总: 解析域名 1 个，待添加用户路由 0 个，重复 2 个，失败 0 个' "$domain_log"
grep -Fq '* 全部用户域名路由添加完成: test，成功 0 个，重复 2 个' "$domain_log"
if grep -Eq '待添加路由:|是否继续添加以上路由' "$domain_log"; then
    echo "existing all-user domain routes unexpectedly requested confirmation" >&2
    exit 1
fi

printf 'cancel.test\n' >"$domain_file"
printf 'n\n' | OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
    adddomainroute test alice "$domain_file" >/dev/null 2>"$domain_log"
grep -Fq '| 已取消域名路由添加' "$domain_log"
if grep -Fq 'push "route 10.30.0.12 255.255.255.255"' "$password_runtime/ccd/alice-test"; then
    echo "cancelled domain route was unexpectedly added" >&2
    exit 1
fi

printf 'bad-.test\n' >"$domain_file"
if OVPN_RUNTIME_ROOT="$TEST_ROOT" bash "$PROJECT_ROOT/deploy/ovpn" \
    adddomainroute test alice "$domain_file" --yes >/dev/null 2>"$domain_log"; then
    echo "invalid domain unexpectedly succeeded" >&2
    exit 1
fi
if ! grep -Fq -- '- 域名文件中没有可添加的 IPv4 路由（解析失败: 1）' "$domain_log"; then
    cat "$domain_log" >&2
    exit 1
fi

echo "+ Deploy package layout"
cp -R "$PROJECT_ROOT/deploy" "$TEST_ROOT/deploy-package"
bash "$TEST_ROOT/deploy-package/package.sh" audit.tar.gz '' >/dev/null
package_entries=$(tar -tzf "$TEST_ROOT/deploy-package/audit.tar.gz")
grep -Fq './hooks/client-connect-basic.sh' <<<"$package_entries"
grep -Fq './maintenance/rotate-logs.sh' <<<"$package_entries"
grep -Fq './maintenance/backup-host-network.sh' <<<"$package_entries"
grep -Fq './templates/ccd/default' <<<"$package_entries"
if grep -Eq '^\./(scripts|tools)/' <<<"$package_entries"; then
    echo "legacy directory found in deploy package" >&2
    exit 1
fi

echo "* All static tests passed"
