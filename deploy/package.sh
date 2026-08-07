#!/bin/bash
# 功能说明：将部署脚本、配置模板及可选镜像打包为可迁移的 tar.gz 离线包。

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUTPUT=${1:-openvpn-deploy.tar.gz}
IMAGE=${2:-}
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR"
cp "$SCRIPT_DIR/ovpn.env.example" "$TEMP_DIR/"
cp "$SCRIPT_DIR/ovpn" "$TEMP_DIR/"
cp "$SCRIPT_DIR/install.sh" "$TEMP_DIR/"
cp -R "$SCRIPT_DIR/config" "$SCRIPT_DIR/helpers" "$SCRIPT_DIR/hooks" \
    "$SCRIPT_DIR/maintenance" "$SCRIPT_DIR/templates" "$TEMP_DIR/"

if [[ -n $IMAGE ]]; then
    docker image inspect "$IMAGE" >/dev/null
    docker save -o "$TEMP_DIR/vpnserverimage.tar" "$IMAGE"
fi

tar -C "$TEMP_DIR" -czf "$SCRIPT_DIR/$OUTPUT" .
echo "Created: $SCRIPT_DIR/$OUTPUT"
