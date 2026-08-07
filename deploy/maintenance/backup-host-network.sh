#!/bin/bash
# 功能说明：原子保存宿主机 iptables 网络策略到当前 OpenVPN 环境的状态目录。

set -euo pipefail

local_path=$(dirname "$(dirname "$(readlink -f "$0")")")
state_dir="$local_path/state"

save_rules() {
	local command_name=$1 target=$2 temp
	temp=$(mktemp "${target}.XXXXXX")
	if ! "$command_name" >"$temp"; then
		rm -f "$temp"
		return 1
	fi
	if ! chmod 600 "$temp" || ! mv "$temp" "$target"; then
		rm -f "$temp"
		return 1
	fi
}

command -v iptables-save >/dev/null 2>&1 || {
	echo "Error: required command not found: iptables-save" >&2
	exit 1
}

mkdir -p "$state_dir"
save_rules iptables-save "$state_dir/host-iptables.rules"

if command -v ip6tables-save >/dev/null 2>&1; then
	save_rules ip6tables-save "$state_dir/host-ip6tables.rules"
fi

echo "Host network policy backup created: $state_dir"
