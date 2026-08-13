#!/bin/bash
# 功能说明：创建独立的 OpenVPN 环境目录，初始化配置与数据，并通过 Compose 启动服务。

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
	cat <<EOF
Usage: $0 <env> [ovpn.env]

Initialize /opt/openvpn-<env> from an ovpn.env file and start it
with Docker Compose. The source env file is never modified.
EOF
}

fail() {
	echo "Error: $*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

is_true() {
	[[ ${1:-false} == "true" ]]
}

ipv4_to_int() {
	local a b c d
	IFS=. read -r a b c d <<<"$1"
	# printf '%u\n' "$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))"
	printf '%u\n' "$((10#$a * 16777216 + 10#$b * 65536 + 10#$c * 256 + 10#$d))"

}

int_to_ipv4() {
	local value=$1
	printf '%d.%d.%d.%d\n' \
		"$(((value >> 24) & 255))" \
		"$(((value >> 16) & 255))" \
		"$(((value >> 8) & 255))" \
		"$((value & 255))"
}

validate_cidr() {
	local cidr=$1 max_prefix=${2:-32} ip prefix octet
	[[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
	ip=${cidr%/*}
	prefix=${cidr#*/}
	IFS=. read -ra octets <<<"$ip"
	for octet in "${octets[@]}"; do
		((10#$octet <= 255)) || return 1
	done
	((10#$prefix <= max_prefix)) || return 1
}

calculate_pool() {
	local cidr=$1 ip prefix ip_int mask network broadcast
	ip=${cidr%/*}
	prefix=${cidr#*/}
	ip_int=$(ipv4_to_int "$ip")
	mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
	network=$((ip_int & mask))
	broadcast=$((network | ((~mask) & 0xFFFFFFFF)))
	SUBNET_IP_FIRST=$(int_to_ipv4 "$((network + 1))")
	SUBNET_IP_LAST=$(int_to_ipv4 "$((broadcast - 1))")
}

set_env_value() {
	local file=$1 name=$2 value=$3 temp
	temp=$(mktemp "${file}.XXXXXX")
	awk -v name="$name" -v value="$value" '
        BEGIN { updated = 0 }
        $0 ~ "^" name "=" {
            print name "=\"" value "\""
            updated = 1
            next
        }
        { print }
        END {
            if (!updated) {
                print name "=\"" value "\""
            }
        }
    ' "$file" >"$temp"
	mv "$temp" "$file"
}

validate_config() {
	[[ -n ${OPENVPN:-} ]] || fail "OPENVPN is empty"
	[[ $OPENVPN =~ ^/[a-zA-Z0-9._/-]+$ ]] || fail "OPENVPN must be a safe absolute path"
	[[ -n ${OVPN_IMAGE:-} ]] || fail "OVPN_IMAGE is empty"
	[[ -n ${OVPN_HOST:-} ]] || fail "OVPN_HOST is empty"
	[[ ${OVPN_PORT:-} =~ ^[0-9]+$ ]] || fail "OVPN_PORT must be numeric"
	((OVPN_PORT >= 1 && OVPN_PORT <= 65535)) || fail "OVPN_PORT is out of range"
	validate_cidr "${OVPN_CLIENT_SUBNET:-}" 29 || fail "invalid OVPN_CLIENT_SUBNET: ${OVPN_CLIENT_SUBNET:-}"
	case ${OVPN_NAT:-false} in
	true | false) ;;
	*) fail "OVPN_NAT must be true or false" ;;
	esac
	[[ ${OVPN_NATDEVICE:-eth0} =~ ^[a-zA-Z0-9_.:+-]{1,15}$ ]] ||
		fail "invalid OVPN_NATDEVICE: ${OVPN_NATDEVICE:-}"
	case ${OVPN_PROTO:-udp} in
	udp | udp6) OVPN_PORT_PROTO=udp ;;
	tcp | tcp6) OVPN_PORT_PROTO=tcp ;;
	*) fail "OVPN_PROTO must be udp, udp6, tcp or tcp6" ;;
	esac
	case ${OVPN_IPTABLES_BACKEND:-auto} in
	auto | nft | legacy) ;;
	*) fail "OVPN_IPTABLES_BACKEND must be auto, nft or legacy" ;;
	esac
	client_prefix=${OVPN_CLIENT_SUBNET#*/}
	((10#$client_prefix >= 1)) || fail "OVPN_CLIENT_SUBNET prefix must be between 1 and 29"

	if is_true "${LDAP:-false}" && { is_true "${OTP:-false}" || is_true "${PASSWORD_AUTH:-false}"; }; then
		fail "LDAP cannot be enabled together with OTP or PASSWORD_AUTH"
	fi
	if { is_true "${OTP:-false}" || is_true "${PASSWORD_AUTH:-false}"; } && [[ $OPENVPN != /etc/openvpn ]]; then
		fail "OPENVPN must be /etc/openvpn when OTP or PASSWORD_AUTH is enabled"
	fi
	if is_true "${LDAP:-false}"; then
		[[ -n ${LDAP_URL:-} ]] || fail "LDAP_URL is required when LDAP=true"
		[[ -n ${LDAP_BIND_DN:-} ]] || fail "LDAP_BIND_DN is required when LDAP=true"
		[[ -n ${LDAP_BASE_DN:-} ]] || fail "LDAP_BASE_DN is required when LDAP=true"
	fi
	if [[ -n ${OVPN_USER_SUFFIX:-} ]]; then
		[[ $OVPN_USER_SUFFIX =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] ||
			fail "OVPN_USER_SUFFIX contains unsupported characters"
	fi
}

confirm_config() {
	cat <<EOF
Environment:     $SERVER_ENV
Runtime path:    $OVPN_LOCAL_PATH
Image:           $OVPN_IMAGE
Endpoint:        $OVPN_HOST:$OVPN_PORT/$OVPN_PROTO
Client subnet:   $OVPN_CLIENT_SUBNET
OTP:             ${OTP:-false}
Password auth:   ${PASSWORD_AUTH:-false}
LDAP:            ${LDAP:-false}
User suffix:     ${OVPN_USER_SUFFIX:-$SERVER_ENV}
Device binding:  ${DEVICE_AUTH:-false}
Auto revoke:     ${AUTO_REVOKE:-false}
iptables backend: ${OVPN_IPTABLES_BACKEND:-auto}
EOF
	if [[ -t 0 ]]; then
		local answer
		read -r -p "Continue? [y/N]: " answer
		[[ $answer == "y" || $answer == "Y" ]] || exit 0
	fi
}

prepare_runtime() {
	local timestamp runtime_env connect_source
	timestamp=$(date '+%Y_%m%d_%H%M_%S')
	if [[ -d $OVPN_LOCAL_PATH ]]; then
		mv "$OVPN_LOCAL_PATH" "${OVPN_LOCAL_PATH}-${timestamp}"
	fi

	mkdir -p "$OVPN_LOCAL_PATH"/{auth,ccd,clients,config,hooks,logs/loginlog,maintenance,otp,state,templates/ccd}
	runtime_env="$OVPN_LOCAL_PATH/ovpn.env"
	cp "$SOURCE_ENV" "$runtime_env"
	set_env_value "$runtime_env" SUBNET_IP_FIRST "$SUBNET_IP_FIRST"
	set_env_value "$runtime_env" SUBNET_IP_LAST "$SUBNET_IP_LAST"
	set_env_value "$runtime_env" OVPN_HOOKS_PATH "${OPENVPN}/hooks"

	if is_true "${LDAP:-false}"; then
		connect_source="$SCRIPT_DIR/hooks/client-connect-ldap.sh"
	elif is_true "${DEVICE_AUTH:-false}"; then
		connect_source="$SCRIPT_DIR/hooks/client-connect-device.sh"
	else
		connect_source="$SCRIPT_DIR/hooks/client-connect-basic.sh"
	fi

	cp "$connect_source" "$OVPN_LOCAL_PATH/hooks/client-connect.sh"
	cp "$SCRIPT_DIR/hooks/connection-state.sh" "$OVPN_LOCAL_PATH/hooks/connection-state.sh"
	cp "$SCRIPT_DIR/hooks/client-disconnect.sh" "$OVPN_LOCAL_PATH/hooks/client-disconnect.sh"
	cp "$SCRIPT_DIR/hooks/ldap-authorize.sh" "$OVPN_LOCAL_PATH/hooks/ldap-authorize.sh"
	cp "$SCRIPT_DIR/maintenance/backup-host-network.sh" "$OVPN_LOCAL_PATH/maintenance/"
	cp "$SCRIPT_DIR/maintenance/revoke-inactive-clients.sh" "$OVPN_LOCAL_PATH/maintenance/"
	cp "$SCRIPT_DIR/maintenance/rotate-logs.sh" "$OVPN_LOCAL_PATH/maintenance/"
	sed "s|@OPENVPN@|$OPENVPN|g" "$SCRIPT_DIR/config/ulogd.conf" \
		>"$OVPN_LOCAL_PATH/config/ulogd.conf"
	cp "$SCRIPT_DIR/templates/ccd/default" "$OVPN_LOCAL_PATH/templates/ccd/default"
	cp "$SCRIPT_DIR/templates/compose.yaml" "$OVPN_LOCAL_PATH/compose.yaml"

	touch "$OVPN_LOCAL_PATH/state/client-ips.csv" "$OVPN_LOCAL_PATH/state/client-ip-history.csv"
	printf '%s, %s\n' "$OVPN_CONTAINER_NAME" "$SUBNET_IP_FIRST" >"$OVPN_LOCAL_PATH/state/client-ips.csv"
	cp "$OVPN_LOCAL_PATH/state/client-ips.csv" "$OVPN_LOCAL_PATH/state/client-ip-history.csv"
	touch "$OVPN_LOCAL_PATH/auth/static-password-users" "$OVPN_LOCAL_PATH/auth/static-passwords"
	chmod 600 "$runtime_env" "$OVPN_LOCAL_PATH/auth/static-password-users" \
		"$OVPN_LOCAL_PATH/auth/static-passwords"
	chmod +x "$OVPN_LOCAL_PATH"/hooks/*.sh "$OVPN_LOCAL_PATH"/maintenance/*.sh

	if is_true "${LDAP:-false}" && [[ ! -f $OVPN_LOCAL_PATH/auth/vpn_user.json ]]; then
		printf '{\n  "retain_user": [],\n  "LDAP_user": []\n}\n' >"$OVPN_LOCAL_PATH/auth/vpn_user.json"
	fi
}

generate_server() {
	local init_arg=()
	docker run --rm -v "$OVPN_LOCAL_PATH:$OPENVPN" \
		-e "OPENVPN=$OPENVPN" "$OVPN_IMAGE" ovpn_gen_server_conf

	if is_true "${CA_NOPASS:-true}"; then
		init_arg=(nopass)
	fi
	docker run --rm -i -v "$OVPN_LOCAL_PATH:$OPENVPN" \
		-e "OPENVPN=$OPENVPN" "$OVPN_IMAGE" ovpn_initpki "${init_arg[@]}"
}

install_maintenance() {
	install -m 755 "$SCRIPT_DIR/ovpn" /usr/local/bin/ovpn

	local existing
	existing=$(crontab -l 2>/dev/null || true)
	if ! grep -Fq "$OVPN_LOCAL_PATH/maintenance/rotate-logs.sh" <<<"$existing"; then
		existing+=$'\n'"0 0 * * * $OVPN_LOCAL_PATH/maintenance/rotate-logs.sh"
	fi
	if is_true "${AUTO_REVOKE:-false}" && ! grep -Fq "$OVPN_LOCAL_PATH/maintenance/revoke-inactive-clients.sh" <<<"$existing"; then
		existing+=$'\n'"15 0 * * * $OVPN_LOCAL_PATH/maintenance/revoke-inactive-clients.sh"
	fi
	printf '%s\n' "$existing" | awk 'NF' | crontab -
}

start_server() {
	export OPENVPN OVPN_IMAGE OVPN_PORT OVPN_PROTO OVPN_PORT_PROTO OVPN_CONTAINER_NAME OVPN_LOCAL_PATH
	docker compose -f "$OVPN_LOCAL_PATH/compose.yaml" up -d
	"$OVPN_LOCAL_PATH/maintenance/backup-host-network.sh"
	docker compose -f "$OVPN_LOCAL_PATH/compose.yaml" ps
}

[[ $# -ge 1 ]] || {
	usage
	exit 1
}
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"

SERVER_ENV=$1
SOURCE_ENV=${2:-$SCRIPT_DIR/ovpn.env}
[[ $SERVER_ENV =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || fail "invalid environment name: $SERVER_ENV"
[[ -f $SOURCE_ENV ]] || fail "env file not found: $SOURCE_ENV (copy ovpn.env.example first)"

# shellcheck source=/dev/null
source "$SOURCE_ENV"
OVPN_CONTAINER_NAME="openvpn-$SERVER_ENV"
OVPN_LOCAL_PATH="/opt/$OVPN_CONTAINER_NAME"

require_command docker
require_command crontab
require_command iptables-save
validate_config
calculate_pool "$OVPN_CLIENT_SUBNET"
confirm_config

if [[ -f $SCRIPT_DIR/vpnserverimage.tar ]]; then
	docker load -i "$SCRIPT_DIR/vpnserverimage.tar"
elif ! docker image inspect "$OVPN_IMAGE" >/dev/null 2>&1; then
	docker pull "$OVPN_IMAGE"
fi

prepare_runtime
generate_server
install_maintenance
chown -R 65534:65534 "$OVPN_LOCAL_PATH"
start_server
