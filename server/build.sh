#!/bin/bash
# 功能说明：使用 Docker Buildx 构建 OpenVPN 服务端镜像，并按参数加载镜像或推送到仓库。

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
IMAGE=${1:-openvpn-integration:local}
ACTION=${2:---load}
PLATFORM=${OVPN_BUILD_PLATFORM:-linux/amd64}

case $ACTION in
--load) output=(--load) ;;
--push) output=(--push) ;;
*)
	echo "Usage: $0 [image] [--load|--push]" >&2
	exit 1
	;;
esac

docker buildx build --platform "$PLATFORM" -t "$IMAGE" "${output[@]}" "$SCRIPT_DIR"
