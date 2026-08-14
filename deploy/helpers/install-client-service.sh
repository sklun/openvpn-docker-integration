#!/bin/bash
# 功能说明：根据客户端配置生成并启用对应的 systemd OpenVPN 客户端服务。

if [[ -z $1 ]]; then
	echo "Usage: $0 <openvpn_config_path> (Must be an absolute path)"
	exit 1
fi

if [[ ! -f $1 ]]; then
	echo "Config file $1 not found"
	exit 1
fi

config_path=$(dirname "$1")
config_basename=$(basename "$1")
conf_name=${config_basename%.*}
sys_file_name=openvpn-client@"$conf_name".service
sys_file_path=/etc/systemd/system/$sys_file_name

echo "Generate systemd configuration file: $sys_file_path"

cat >"$sys_file_path" <<EOF
[Unit]
Description=OpenVPN connection to "$conf_name"
After=network.target

[Service]
ExecStart=/usr/sbin/openvpn --daemon --cd $config_path --config $config_basename --log $conf_name.log
Restart=on-failure
Type=forking

[Install]
WantedBy=multi-user.target
EOF

echo "Start Service: $sys_file_name"
systemctl daemon-reload
systemctl start "$sys_file_name" &&
	systemctl enable "$sys_file_name"
