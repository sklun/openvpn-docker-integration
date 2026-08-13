#!/bin/bash
# 功能说明：提供客户端连接 Hook 共用的状态文件更新函数。

update_login_time() {
    local user_name=$1 db_path=$2 lock_file temp attempts=0
    login_time=$(date +%s)
    lock_file="$OPENVPN/state/.client-ip.lock"

    exec 200>"$lock_file"
    until flock -n 200; do
        attempts=$((attempts + 1))
        if ((attempts >= 3)); then
            echo "Unable to lock client IP state" >&2
            return 1
        fi
        sleep 1
    done

    temp=$(mktemp "${db_path}.XXXXXX")
    awk -F', ' -v OFS=', ' -v user="$user_name" -v value="$login_time" \
        '$1 == user { $8 = value } { print }' "$db_path" >"$temp"
    mv "$temp" "$db_path"
    flock -u 200
}
