#!/bin/bash
# 功能说明：处理无设备认证的客户端连接，更新最后登录时间并记录登录事件。

OPENVPN=${OPENVPN:-/etc/openvpn}
# shellcheck source=/dev/null
source "$OPENVPN/ovpn.env"

modify_colmun() {
    # Usage: modify_colmun "$search_str" "$clumn" "$replace_str" "$file_path" "$separator"
    local search_str=$1
    local colmun=$2
    local replace_str=$3
    local file_path=$4
    local separator=$5
    local file_path_tmp
    file_path_tmp=${file_path}_$(date +%s)
    awk -F"$separator" -v search="$search_str" -v colmun="$colmun" -v replace="$replace_str" -v OFS="$separator" '{
        if ($0 ~ search) {
            if (NF < colmun) {
                for (i = NF + 1; i < colmun; i++) {
                    $i = ""
                }
                $colmun = replace
            } else {
                $colmun = replace
            }
        }
        print $0
    }' "$file_path" >"$file_path_tmp"
    mv "$file_path_tmp" "$file_path"
}

db_path="$OPENVPN/state/client-ips.csv"
day=$(date +%F)
log_date=$(date '+%F %H:%M:%S')
login_time=$(date +%s)
# shellcheck disable=SC2153  # Loaded from ovpn.env.
log_path="$LOG_PATH/loginlog/login-${day}.log"
# shellcheck disable=SC2154  # Injected by OpenVPN.
user_cip="${common_name}, ${ifconfig_pool_remote_ip}"
try_time=3
wait_time=1
lock_file="$OPENVPN/state/.client-ip.lock"

lock_retries=0
exec 200>"$lock_file"

flock -n 200 || {
    while [ $lock_retries -lt $try_time ]; do
        sleep $wait_time
        flock -n 200 && break
        lock_retries=$((lock_retries + 1))
    done
    if [ $lock_retries -eq $try_time ]; then
        echo "${log_date} ${user_cip} Unable to update login time"
        exit 1
    fi

}
modify_colmun "$user_cip" 8 "$login_time" "$db_path" ', '
flock -u 200

if [ -f "$log_path" ]; then
    # shellcheck disable=SC2154  # Injected by OpenVPN.
    echo "$log_date User $common_name IP $trusted_ip is logged in" >>"$log_path"
else
    touch "$LOG_PATH/loginlog/login-$day.log"
    echo "$log_date User $common_name IP $trusted_ip is logged in" >>"$log_path"
fi
