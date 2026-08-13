#!/bin/bash
# 功能说明：校验客户端上报的设备信息，维护设备绑定记录并记录登录结果。

OPENVPN=${OPENVPN:-/etc/openvpn}
# shellcheck source=/dev/null
source "$OPENVPN/ovpn.env"
# shellcheck source=/dev/null
source "$OVPN_HOOKS_PATH/connection-state.sh"

# get variables from environment
# common_name: user name
# ifconfig_pool_remote_ip: user client ip
# trusted_ip: user public ip
# IV_PLAT: user client platform
# IV_INFO: client device UUID_SN or SN_UUID
# IV_CPU: client device CPU ID or CPU INFO
# IV_USER: client system Logged in USER
# IV_DISK: client DISK UUID

day=$(date +%F)
log_date=$(date '+%F %H:%M:%S')

# file path
# Login log path
# shellcheck disable=SC2153  # Loaded from ovpn.env.
log_path="$LOG_PATH/loginlog/login-${day}.log"
# DB path
db_path="$OPENVPN/state/client-ips.csv"
# Historical DB path
db_hist_path="$OPENVPN/state/client-ip-history.csv"

# create log file daily
mkdir -p "$(dirname "$log_path")"
touch "$log_path"

# Check whether the user has records in the DB, return user_info
check_user() {
    # shellcheck disable=SC2154  # Injected by OpenVPN.
    user_cip="${common_name}, ${ifconfig_pool_remote_ip}"
    user_info=$(awk -F', ' -v user="$common_name" '$1 == user { print; exit }' "$db_path")
    # Exit when the user info cannot be found in the DB.
    # shellcheck disable=SC2154  # Injected by OpenVPN.
    [[ -z $user_info ]] &&
        echo "${log_date} [DEV_AUTH] [DNIED] Can't find USER ${user_cip} INFO in DB" | tee -a "${log_path}" &&
        echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}" &&
        exit 1
}
# Check SYSTEM PLAT, a
# Check user device info
# add user_info when user first login
check_info() {
    user_verify_info=$(echo "$user_info" | awk -F', ' '{for (i=3; i<8; i++) printf $i}')
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
        # win "\" in IV_USER needs to be replaced with "\\"
        # shellcheck disable=SC2154  # Set by update_login_time in connection-state.sh.
        add_info=$(echo "${user_cip}, ${IV_PLAT}, ${IV_PLAT_VER}, ${IV_USER}, ${IV_INFO}, ${IV_DISK}, ${login_time}" |
            sed 's.\\.\\\\.g')
        sed -i "/^$user_cip/c $add_info" "${db_path}"
        echo "$add_info" >>"${db_hist_path}"
        echo -e "${log_date} [DEV_AUTH] [ACCESS] USER ${user_cip} from $trusted_ip LOGGED IN\n" | tee -a "${log_path}"
        exit 0
    fi
}
# Check Custom Columns
# Usage: check_items item_var_name item_column_in_db item_describe
check_items() {
    item=$1
    item_col=$2
    item_desc=$3
    item_in_db=$(echo "$user_info" | awk -F', ' '{print $'"$item_col"'}')
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
    # Deny user connection when IV_PLAT is empty
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
        # Verify the client device information according to the platform
        case "${IV_PLAT}" in
        # Data Format: $common_name,$ifconfig_pool_remote_ip,$IV_PLAT,$IV_PLAT_VER,$IV_USER,$IV_INFO,$IV_DISK
        win | mac | linux)
            # win & mac Verify IV_PLAT IV_USER IV_INFO IV_DISK
            # Check whether the information has been uploaded
            if [[ -z $IV_USER ]]; then
                echo "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} did not return SYSTEM USER" | tee -a "${log_path}"
                echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}"
                exit 1
            elif [[ -z $IV_INFO ]]; then
                echo "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} did not return DEVICE UUID/SN" | tee -a "${log_path}"
                echo -e "${log_date} [DEV_AUTH] [DNIED] USER ${user_cip} from $trusted_ip LOGIN DENIED\n" | tee -a "${log_path}"
                exit 1
            fi
            # Verification Start
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
            echo -e "${log_date} [DEV_AUTH] [ACCESS] USER ${user_cip} from $trusted_ip LOGGED IN\n" | tee -a "${log_path}"
            exit 0
            ;;
        android | ios)
            # android & ios Verify IV_PLAT UV_UUID IV_HWADDR
            # IV_INFO = UV_UUID + IV_HWADDR
            # Check whether the information has been uploaded
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
            # Verification Start
            check_info
            check_items "$IV_PLAT" "3" "SYSTEM PLAT"
            check_items "$IV_INFO" "6" "DEVICE UUID"
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


# MAIN
check_user
update_login_time "$common_name" "$db_path"
main
