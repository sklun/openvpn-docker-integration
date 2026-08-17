#!/bin/bash
# 功能说明：使用指定配置启动 OpenVPN 客户端，并按需写入认证信息和连接日志。

set -euo pipefail
umask 077

CONF_PATH=${1:-}
CONF_NAME=${2:-}
USER_INPUT=${3:-}
PASS=${4:-}

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

fail() {
	echo "Error: $*" >&2
	exit 1
}

stop_existing_client() {
	local pid attempt index config_matches=false directory_matches=false
	local -a process_args=()
	[[ -r $PID_PATH ]] || return 0
	pid=""
	read -r pid <"$PID_PATH" || true
	if [[ ! $pid =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
		rm -f "$PID_PATH"
		return 0
	fi

	if [[ ! -r /proc/$pid/cmdline ]]; then
		if ! kill -0 "$pid" 2>/dev/null; then
			rm -f "$PID_PATH"
			return 0
		fi
		fail "cannot verify process ownership for PID: $pid"
	fi
	mapfile -d '' -t process_args <"/proc/$pid/cmdline"
	((${#process_args[@]} > 0)) || fail "cannot read process arguments for PID: $pid"
	[[ ${process_args[0]##*/} == openvpn ]] ||
		fail "PID file points to a process not owned by OpenVPN: $pid"
	for ((index = 1; index + 1 < ${#process_args[@]}; index++)); do
		case ${process_args[index]} in
			--config)
				[[ ${process_args[index + 1]} == "$CONF_NAME" ]] && config_matches=true
				;;
			--cd)
				[[ ${process_args[index + 1]} == "$CONF_PATH" ]] && directory_matches=true
				;;
		esac
	done
	$config_matches || fail "PID file points to a different OpenVPN configuration: $pid"
	$directory_matches || fail "PID file points to a different OpenVPN configuration directory: $pid"

	echo "停止现有 OpenVPN 客户端进程 $pid"
	kill "$pid"
	for attempt in {1..5}; do
		kill -0 "$pid" 2>/dev/null || break
		sleep 1
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill -9 "$pid"
	fi
	rm -f "$PID_PATH"
}

if [[ -z $CONF_PATH || -z $CONF_NAME ]]; then
	help_info
	exit 1
elif [[ -z $USER_INPUT && -n $PASS ]] || [[ -n $USER_INPUT && -z $PASS ]]; then
	help_info
	exit 1
fi

[[ -d $CONF_PATH ]] || fail "配置目录不存在: $CONF_PATH"
CONF_PATH=$(cd "$CONF_PATH" && pwd)
[[ -f $CONF_PATH/$CONF_NAME ]] || fail "配置文件不存在: $CONF_PATH/$CONF_NAME"

CONF_STEM=${CONF_NAME%.*}
SAFE_STEM=${CONF_STEM//[!a-zA-Z0-9_.-]/_}
LOG_ID=${USER_INPUT:-$SAFE_STEM}
SAFE_LOG_ID=${LOG_ID//[!a-zA-Z0-9_.@-]/_}
DATE=$(date +"%Y%m%d")
LOG_NAME="${SAFE_LOG_ID}_${DATE}.log"
PID_PATH="$CONF_PATH/.${SAFE_STEM}.pid"
AUTH_PATH="$CONF_PATH/.${SAFE_STEM}.auth"

stop_existing_client

openvpn_args=(
	--daemon
	--writepid "$PID_PATH"
	--cd "$CONF_PATH"
	--config "$CONF_NAME"
	--log-append "$LOG_NAME"
)

if [[ -n $USER_INPUT ]]; then
	printf '%s\n%s\n' "$USER_INPUT" "$PASS" >"$AUTH_PATH"
	chmod 600 "$AUTH_PATH"
	openvpn_args+=(--auth-user-pass "$AUTH_PATH")
fi

openvpn "${openvpn_args[@]}"
echo "======================="
echo "日志路径: ${CONF_PATH}/${LOG_NAME}"
for attempt in {1..5}; do
	[[ -f $CONF_PATH/$LOG_NAME ]] && break
	sleep 1
done
[[ ! -f $CONF_PATH/$LOG_NAME ]] || tail -20 "$CONF_PATH/$LOG_NAME"
