#!/bin/bash
# 功能说明：校验客户端上报的设备信息，维护设备绑定记录并记录登录结果。

OPENVPN=${OPENVPN:-/etc/openvpn}
# shellcheck source=/dev/null
source "$OPENVPN/ovpn.env"
# shellcheck source=/dev/null
source "$OVPN_HOOKS_PATH/connection-state.sh"

# 以下变量由 OpenVPN 或客户端注入。
# common_name: 用户名
# ifconfig_pool_remote_ip: VPN 客户端 IP
# trusted_ip: 客户端公网 IP
# IV_PLAT / IV_PLAT_VER: 平台及版本
# IV_GUI_VER: 客户端版本和签名信息
# IV_INFO / IV_CPU / IV_USER / IV_DISK: 设备标识、CPU、系统用户和磁盘 UUID
# UV_UUID / IV_HWADDR: 移动端设备 UUID 和硬件地址

day=$(date +%F)
log_date=$(date '+%F %H:%M:%S')

# shellcheck disable=SC2153  # Loaded from ovpn.env.
log_path="$LOG_PATH/loginlog/login-${day}.log"
db_path="$OPENVPN/state/client-ips.csv"
db_hist_path="$OPENVPN/state/client-ip-history.csv"

mkdir -p "$(dirname "$log_path")"
touch "$log_path"

check_user() {
	# shellcheck disable=SC2154  # Injected by OpenVPN.
	user_cip="${common_name}, ${ifconfig_pool_remote_ip}"
	user_info=$(awk -F', ' -v user="$common_name" '$1 == user { print; exit }' "$db_path")
	# shellcheck disable=SC2154  # Injected by OpenVPN.
	[[ -z $user_info ]] &&
		echo "${log_date} [DEV_AUTH] [DNIED] Can't find USER ${user_cip} INFO in DB" | tee -a "${log_path}" &&
		echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}" &&
		exit 1
}

check_info() {
	local line temp
	user_verify_info=$(awk -F', ' '{for (i=3; i<8; i++) printf $i}' <<<"$user_info")
	if [[ -z $user_verify_info ]]; then
		echo "${log_date} [DEV_AUTH] [ACCESS] USER ${user_cip} first login, add user INFO to DB" | tee -a "${log_path}"
		echo -e "${log_date} [DEV_AUTH] ${user_cip} [ADD INFO]\n\
${log_date} [DEV_AUTH] ${user_cip} CLIENT NAME:=${common_name}\n\
${log_date} [DEV_AUTH] ${user_cip} CLIENT IP:=${ifconfig_pool_remote_ip}\n\
${log_date} [DEV_AUTH] ${user_cip} SYSTEM PLAT:=${IV_PLAT}\n\
${log_date} [DEV_AUTH] ${user_cip} SYSTEM PLAT VER:=${IV_PLAT_VER}\n\
${log_date} [DEV_AUTH] ${user_cip} SYSTEM USER:=${IV_USER}\n\
${log_date} [DEV_AUTH] ${user_cip} DEVICE UUID/SN:=${IV_INFO}\n\
${log_date} [DEV_AUTH] ${user_cip} DISK UUID:=${IV_DISK}" |
			column -s '=' -t
		login_time=$(date +%s)
		add_info="${user_cip}, ${IV_PLAT}, ${IV_PLAT_VER}, ${IV_USER}, ${IV_INFO}, ${IV_DISK}, ${login_time}"
		temp=$(mktemp "${db_path}.XXXXXX")
		while IFS= read -r line; do
			if [[ ${line%%, *} == "$common_name" ]]; then
				printf '%s\n' "$add_info"
			else
				printf '%s\n' "$line"
			fi
		done <"$db_path" >"$temp"
		mv "$temp" "$db_path"
		echo "$add_info" >>"${db_hist_path}"
		echo -e "${log_date} [DEV_AUTH] [ACCESS] USER ${user_cip} from $trusted_ip LOGGED IN\n" | tee -a "${log_path}"
		exit 0
	fi
}

check_items() {
	item=$1
	item_col=$2
	item_desc=$3
	item_in_db=$(awk -F', ' -v column="$item_col" '{print $column}' <<<"$user_info")
	if [[ -z $item_in_db ]]; then
		echo "${log_date} [DEV_AUTH] [DNIED] Can't find ${item_desc} ${common_name}:${ifconfig_pool_remote_ip} in DB" | tee -a "${log_path}"
		echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}"
		exit 1
	else
		if [[ $item == "$item_in_db" ]]; then
			echo "${log_date} [DEV_AUTH] [ACCESS] USER ${user_cip} ${item_desc} MATCHED"
		else
			echo "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} ${item_desc} MISMATCHED" | tee -a "${log_path}"
			echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}"
			exit 1
		fi
	fi
}

echo_login_info() {
	echo
	echo -e "${log_date} [DEV_AUTH] ${user_cip} [LOGIN INFO]\n\
${log_date} [DEV_AUTH] ${user_cip} CLIENT NAME:=${common_name}\n\
${log_date} [DEV_AUTH] ${user_cip} CLIENT IP:=${ifconfig_pool_remote_ip}\n\
${log_date} [DEV_AUTH] ${user_cip} SYSTEM PLAT:=${IV_PLAT}\n\
${log_date} [DEV_AUTH] ${user_cip} SYSTEM PLAT VER:=${IV_PLAT_VER}\n\
${log_date} [DEV_AUTH] ${user_cip} SYSTEM USER:=${IV_USER}\n\
${log_date} [DEV_AUTH] ${user_cip} DEVICE UUID/SN:=${IV_INFO}\n\
${log_date} [DEV_AUTH] ${user_cip} DISK UUID:=${IV_DISK}" |
		column -s '=' -t
	echo
}
main() {
	if [[ -z $IV_PLAT ]]; then
		echo "${log_date} [DEV_AUTH] [DNIED] USER ${common_name} did not return PLAT" | tee -a "${log_path}"
		echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${common_name} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}"
		exit 1
	else
		if [[ $IV_GUI_VER == *Unsigned* ]]; then
			echo "${log_date} [DEV_AUTH] [DNIED] USER ${common_name} Using unsigned version $IV_GUI_VER" | tee -a "${log_path}"
			exit 1
		fi
		echo_login_info
		case "${IV_PLAT}" in
		win | mac | linux)
			if [[ -z $IV_USER ]]; then
				echo "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} did not return SYSTEM USER" | tee -a "${log_path}"
				echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}"
				exit 1
			elif [[ -z $IV_INFO ]]; then
				echo "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} did not return DEVICE UUID/SN" | tee -a "${log_path}"
				echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}"
				exit 1
			fi
			check_info
			check_items "$IV_PLAT" "3" "SYSTEM PLAT"
			check_items "$IV_USER" "5" "SYSTEM USER"
			check_items "$IV_INFO" "6" "DEVICE UUID"
			if [[ $IV_CPU != *MacBookPro11,4* ]]; then
				if [[ -z $IV_DISK ]]; then
					echo "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} did not return DISK UUID" | tee -a "${log_path}"
					echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}"
					exit 1
				fi
				check_items "$IV_DISK" "7" "DISK UUID"
			fi
			update_login_time_unlocked "$common_name" "$db_path"
			echo -e "${log_date} [DEV_AUTH] [ACCESS] USER ${user_cip} from $trusted_ip LOGGED IN\n" | tee -a "${log_path}"
			exit 0
			;;
		android | ios)
			if [[ -z $UV_UUID ]]; then
				echo "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} did not return DEVICE UUID" | tee -a "${log_path}"
				echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}"
				exit 1
			elif [[ -z $IV_HWADDR ]]; then
				echo "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} did not return DEVICE HWADDR" | tee -a "${log_path}"
				echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}"
				exit 1
			fi
			IV_INFO="$UV_UUID"_"$IV_HWADDR"
			check_info
			check_items "$IV_PLAT" "3" "SYSTEM PLAT"
			check_items "$IV_INFO" "6" "DEVICE UUID"
			update_login_time_unlocked "$common_name" "$db_path"
			echo -e "${log_date} [DEV_AUTH] [ACCESS] USER ${user_cip} from $trusted_ip LOGGED IN\n" | tee -a "${log_path}"
			exit 0
			;;
		*)
			echo "${log_date} [DEV_AUTH] [DNIED] USER ${common_name} login from UNDEFINED PLATFORMS: $IV_PLAT" | tee -a "${log_path}"
			echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${common_name} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}"
			exit 1
			;;
		esac
	fi
}

{
	flock -w 3 200 || {
		echo "Unable to lock client IP state" >&2
		exit 1
	}
	check_user
	main
} 200>"$OPENVPN/state/.client-ip.lock"
