#!/bin/bash
# 功能说明：处理 LDAP 用户连接，固化客户端 IP、初始化访问策略并记录登录事件。

set -euo pipefail

OPENVPN=${OPENVPN:-/etc/openvpn}
# shellcheck source=/dev/null
source "$OPENVPN/ovpn.env"

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

exec 200>"$lock_file"
flock -w 5 200 || { echo "Unable to lock client IP state" >&2; exit 1; }

if ! grep -q '^ifconfig-push ' "$ccd_file"; then
    [[ -n ${ifconfig_pool_remote_ip:-} && -n ${ifconfig_pool_netmask:-} ]] || exit 1
    temp=$(mktemp "${ccd_file}.XXXXXX")
    {
        printf 'ifconfig-push %s %s\n' "$ifconfig_pool_remote_ip" "$ifconfig_pool_netmask"
        cat "$ccd_file"
    } >"$temp"
    mv "$temp" "$ccd_file"
fi

if ! awk -F', ' -v user="$common_name" '$1 == user { found = 1 } END { exit !found }' "$db_path"; then
    record="$common_name, $ifconfig_pool_remote_ip, , , , , , $(date +%s)"
    printf '%s\n' "$record" >>"$db_path"
    printf '%s\n' "$record" >>"$history_path"
fi

if [[ ${IPTABLES_POLICY:-false} == true ]]; then
	ovpn_firewall sync-rules "$db_path" "$OPENVPN/ccd"
fi

flock -u 200
printf '%s User %s:%s from %s LOGGED IN\n' \
    "$log_time" "$common_name" "$ifconfig_pool_remote_ip" "${trusted_ip:-unknown}" | tee -a "$log_path"
