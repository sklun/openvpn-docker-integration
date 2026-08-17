#!/bin/bash
# 功能说明：在 LDAP 认证后校验本地 JSON 授权名单，并为获准用户初始化 CCD 文件。

set -euo pipefail

OPENVPN=${OPENVPN:-/etc/openvpn}
# shellcheck source=/dev/null
source "$OPENVPN/ovpn.env"

credential_file=${1:-}
[[ -r $credential_file ]] || exit 1
user_name=$(head -n 1 "$credential_file")
[[ -n $user_name ]] || exit 1
[[ $user_name =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,30}$ ]] || exit 1

authz_file=${LDAP_AUTHZ_FILE:-$OPENVPN/auth/vpn_user.json}
if [[ ! -r $authz_file ]]; then
	echo "LDAP authorization file not found: $authz_file" >&2
	exit 1
fi

if jq -e --arg user "$user_name" '.LDAP_user[]? | select(.user == $user)' "$authz_file" >/dev/null; then
	ccd_file="$OPENVPN/ccd/$user_name"
	{
		flock -w 5 200 || exit 1
		if [[ ! -f $ccd_file ]]; then
			cp "$OPENVPN/templates/ccd/default" "$ccd_file"
		fi
	} 200>"$OPENVPN/state/.client-ip.lock"
	exit 0
fi

if [[ -n ${auth_failed_reason_file:-} ]]; then
	printf 'User %s is not authorized for VPN access\n' "$user_name" >"$auth_failed_reason_file"
fi
exit 1
