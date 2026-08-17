#!/bin/bash
# 功能说明：处理无设备认证的客户端连接，更新最后登录时间并记录登录事件。

set -euo pipefail

OPENVPN=${OPENVPN:-/etc/openvpn}
# shellcheck source=/dev/null
source "$OPENVPN/ovpn.env"
# shellcheck source=/dev/null
source "$OVPN_HOOKS_PATH/connection-state.sh"

db_path="$OPENVPN/state/client-ips.csv"
day=$(date +%F)
log_date=$(date '+%F %H:%M:%S')
# shellcheck disable=SC2153  # Loaded from ovpn.env.
log_path="$LOG_PATH/loginlog/login-${day}.log"
# shellcheck disable=SC2154  # Injected by OpenVPN.
update_login_time "$common_name" "$db_path" || exit 1
mkdir -p "$(dirname "$log_path")"
# shellcheck disable=SC2154  # Injected by OpenVPN.
echo "$log_date User $common_name IP $trusted_ip is logged in" >>"$log_path"
