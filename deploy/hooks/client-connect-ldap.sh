#!/bin/bash
# 功能说明：处理 LDAP 用户连接，固化客户端 IP、初始化访问策略并记录登录事件。

set -euo pipefail

OPENVPN=${OPENVPN:-/etc/openvpn}
# shellcheck source=/dev/null
source "$OPENVPN/ovpn.env"
# shellcheck source=/dev/null
source "${OVPN_HOOKS_PATH:-$OPENVPN/hooks}/connection-state.sh"

[[ ${common_name:-} =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,30}$ ]] || exit 1

log_time=$(date '+%F %H:%M:%S')
# shellcheck disable=SC2153  # Loaded from ovpn.env.
log_path="$LOG_PATH/loginlog/login-$(date +%F).log"
db_path="$OPENVPN/state/client-ips.csv"
history_path="$OPENVPN/state/client-ip-history.csv"
ccd_file="$OPENVPN/ccd/$common_name"
lock_file="$OPENVPN/state/.client-ip.lock"

mkdir -p "$(dirname "$log_path")" "$OPENVPN/ccd"
touch "$log_path" "$db_path" "$history_path" "$ccd_file"
[[ -n ${ifconfig_pool_remote_ip:-} && -n ${ifconfig_pool_netmask:-} ]] || exit 1

{
	flock -w 5 200 || {
		echo "Unable to lock client IP state" >&2
		exit 1
	}

	if ! grep -q '^ifconfig-push ' "$ccd_file"; then
		temp=$(mktemp "${ccd_file}.XXXXXX")
		{
			printf 'ifconfig-push %s %s\n' "$ifconfig_pool_remote_ip" "$ifconfig_pool_netmask"
			cat "$ccd_file"
		} >"$temp"
		mv "$temp" "$ccd_file"
	fi

	client_ip=$(awk -F', ' -v user="$common_name" '$1 == user { print $2; exit }' "$db_path")
	if [[ -z $client_ip ]]; then
		client_ip=$ifconfig_pool_remote_ip
		record="$common_name, $client_ip, , , , , , $(date +%s)"
		printf '%s\n' "$record" >>"$db_path"
		printf '%s\n' "$record" >>"$history_path"
	else
		update_login_time_unlocked "$common_name" "$db_path"
	fi
} 200>"$lock_file"

if [[ ${IPTABLES_POLICY:-false} == true ]]; then
	ovpn_firewall ensure-user "$common_name" "$client_ip" "$ccd_file"
fi

printf '%s User %s:%s from %s LOGGED IN\n' \
	"$log_time" "$common_name" "$client_ip" "${trusted_ip:-unknown}" | tee -a "$log_path"
