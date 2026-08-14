#!/bin/bash
# 功能说明：触发容器内日志轮转，并在磁盘占用超限时清理最早的压缩日志。

set -euo pipefail

local_path=$(dirname "$(dirname "$(readlink -f "$0")")")
env_name=${local_path##*/openvpn-}
# shellcheck source=/dev/null
source "$local_path/ovpn.env"

docker exec "openvpn-$env_name" ovpn_logrotate >/dev/null

log_dir="$local_path/logs"
disk_limit=${LOG_DISK_LIMIT:-90}
log_names=(iptables.log openvpn.log)

while (($(df -P "$log_dir" | awk 'NR == 2 { gsub("%", "", $5); print $5 }') >= disk_limit)); do
	removed=false
	for log_name in "${log_names[@]}"; do
		oldest=$(find "$log_dir" -maxdepth 1 -type f -name "${log_name}-*.gz" -print | sort | head -n 1)
		if [[ -n $oldest ]]; then
			rm -f "$oldest"
			removed=true
		fi
	done
	$removed || break
done
