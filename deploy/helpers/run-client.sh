#!/bin/bash
# 功能说明：使用指定配置启动 OpenVPN 客户端，并按需写入认证信息和连接日志。

# openvpn --daemon --cd /path/to/config --config config-name --log-append log-name --auth-user-pass pass

CONF_PATH=$1
CONF_NAME=$2

USER=$3
PASS=$4
DATE=$(date +"%Y%m%d")
LOG_NAME="$USER"_"$DATE".log

help_info() {
    echo
    cat <<EOF
使用方法: bash run-client.sh <config_path> <config_name> (<user> <pass>)
	<config_path>: 必选, 配置文件路径
    <config_name>: 必选, 配置文件名称
    <user>: 需要双因子认证时必选, 用户名
    <pass>: 需要双因子认证时必选, 动态密码
EOF
}
if [[ -z $CONF_PATH ]]; then
    help_info
    exit 1
elif [[ -z $USER && -n $PASS ]] || [[ -n $USER && -z $PASS ]]; then
    help_info
    exit 1
fi

pids=$(pgrep -fl "${CONF_PATH##*/}" | grep -v '.*.sh')
if [ -n "$pids" ]; then
    # 循环遍历进程 ID 并终止它们
    for pid in $pids; do
        pid=$(echo "$pid" | awk '{print $1}')
        echo "终止进程 $pid"
        kill -9 "$pid"
    done
fi

if [[ -n "$USER" && -n "$PASS" ]]; then
    pass_path="$CONF_PATH"/"$USER"-pass
    echo -e "$USER\n$PASS" >"$pass_path"
    openvpn --daemon --cd "$CONF_PATH" --config "$CONF_NAME" --log-append "$LOG_NAME" --auth-user-pass "$USER"-pass
else
    openvpn --daemon --cd "$CONF_PATH" --config "$CONF_NAME" --log-append "$LOG_NAME"
fi
echo "======================="
echo "日志路径: ${CONF_PATH}/${LOG_NAME}"
tail -20 "$CONF_PATH"/"$LOG_NAME"
