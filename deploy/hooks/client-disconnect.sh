#!/bin/bash
# 功能说明：在客户端断开连接时记录用户、虚拟地址和来源地址等退出信息。

set -euo pipefail

OPENVPN=${OPENVPN:-/etc/openvpn}
# shellcheck source=/dev/null
source "$OPENVPN/ovpn.env"

# shellcheck disable=SC2153  # Loaded from ovpn.env.
log_path="$LOG_PATH/loginlog/logout-$(date +%F).log"
mkdir -p "$(dirname "$log_path")"
touch "$log_path"

printf '%s User %s:%s from %s LOGGED OUT\n' \
	"$(date '+%F %H:%M:%S')" \
	"${common_name:-unknown}" \
	"${ifconfig_pool_remote_ip:-unknown}" \
	"${trusted_ip:-unknown}" | tee -a "$log_path"
