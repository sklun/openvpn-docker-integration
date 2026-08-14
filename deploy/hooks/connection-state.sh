#!/bin/bash
# 功能说明：提供客户端连接 Hook 共用的状态更新函数。

update_login_time_unlocked() {
	local user_name=$1 db_path=$2 temp
	login_time=$(date +%s)

	temp=$(mktemp "${db_path}.XXXXXX")
	awk -F', ' -v OFS=', ' -v user="$user_name" -v value="$login_time" \
		'$1 == user { $8 = value } { print }' "$db_path" >"$temp"
	mv "$temp" "$db_path"
}

update_login_time() {
	local user_name=$1 db_path=$2
	{
		flock -w 3 200 || {
			echo "Unable to lock client IP state" >&2
			return 1
		}
		update_login_time_unlocked "$user_name" "$db_path"
	} 200>"$OPENVPN/state/.client-ip.lock"
}
