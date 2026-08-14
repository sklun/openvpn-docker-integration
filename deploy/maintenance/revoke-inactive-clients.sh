#!/bin/bash
# 功能说明：根据最后登录时间识别长期不活跃用户，并调用管理命令自动吊销。

set -euo pipefail

local_path=$(dirname "$(dirname "$(readlink -f "$0")")")
env_name=${local_path##*/openvpn-}
# shellcheck source=/dev/null
source "$local_path/ovpn.env"

db_path="$local_path/state/client-ips.csv"
log_path="$local_path/logs/revoke.log"
max_months=${AUTO_REVOKE_MONTHS:-3}
max_seconds=$((max_months * 30 * 24 * 60 * 60))
now=$(date +%s)

mkdir -p "$(dirname "$log_path")"
[[ -r $db_path ]] || exit 0

while IFS=', ' read -r user_name _ _ _ _ _ _ last_login _; do
	[[ -n $user_name && $user_name != "openvpn-$env_name" ]] || continue
	[[ ${last_login:-} =~ ^[0-9]+$ ]] || continue
	if ((now - last_login > max_seconds)); then
		printf '%s Revoke inactive user %s (last login: %s)\n' \
			"$(date '+%F %H:%M:%S')" "$user_name" "$(date -d "@$last_login" '+%F')" | tee -a "$log_path"
		ovpn deluser "$env_name" "$user_name"
	fi
done <"$db_path"
