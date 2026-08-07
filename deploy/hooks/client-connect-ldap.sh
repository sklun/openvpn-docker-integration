#!/bin/bash
# 功能说明：处理 LDAP 用户连接，固化客户端 IP、初始化访问策略并记录登录事件。

set -euo pipefail

OPENVPN=${OPENVPN:-/etc/openvpn}
# shellcheck source=/dev/null
source "$OPENVPN/ovpn.env"

[[ ${common_name:-} =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,30}$ ]] || exit 1

mask_to_cidr() {
    local mask=$1 octet bits=0
    IFS=. read -ra octets <<<"$mask"
    for octet in "${octets[@]}"; do
        case $octet in
            255) bits=$((bits + 8)) ;;
            254) bits=$((bits + 7)) ;;
            252) bits=$((bits + 6)) ;;
            248) bits=$((bits + 5)) ;;
            240) bits=$((bits + 4)) ;;
            224) bits=$((bits + 3)) ;;
            192) bits=$((bits + 2)) ;;
            128) bits=$((bits + 1)) ;;
            0) ;;
            *) return 1 ;;
        esac
    done
    printf '%d\n' "$bits"
}

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
    ipset create "$common_name" hash:net -exist
    if ! iptables -C FORWARD -s "$ifconfig_pool_remote_ip" -m set --match-set "$common_name" dst \
        -m comment --comment "allow $common_name route group" -j ACCEPT 2>/dev/null; then
        insert_line=$(iptables -nvL FORWARD --line-numbers | awk '/reject all vpc subnet/ {print $1; exit}')
        if [[ -n $insert_line ]]; then
            iptables -I FORWARD "$insert_line" -s "$ifconfig_pool_remote_ip" -m set --match-set "$common_name" dst \
                -m comment --comment "allow $common_name route group" -j ACCEPT
        else
            iptables -A FORWARD -s "$ifconfig_pool_remote_ip" -m set --match-set "$common_name" dst \
                -m comment --comment "allow $common_name route group" -j ACCEPT
        fi
    fi
    while read -r route_ip route_mask; do
        [[ -n ${route_ip:-} && -n ${route_mask:-} ]] || continue
        route_prefix=$(mask_to_cidr "$route_mask")
        ipset add "$common_name" "$route_ip/$route_prefix" -exist
    done < <(awk '/^push "route / { gsub(/"/, ""); print $3, $4 }' "$ccd_file")
    iptables-save >"$OPENVPN/state/iptables.rules"
    ipset save >"$OPENVPN/state/ipset.rules"
fi

flock -u 200
printf '%s User %s:%s from %s LOGGED IN\n' \
    "$log_time" "$common_name" "$ifconfig_pool_remote_ip" "${trusted_ip:-unknown}" | tee -a "$log_path"
