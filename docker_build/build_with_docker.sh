#!/usr/bin/env bash
# Copyright 2025 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Docker Desktop builds inside a VM; 127.0.0.1 is not the host. Use host.docker.internal
# (requires proxy to accept LAN/bridge connections, e.g. Clash "Allow LAN").
# Native Linux Docker: PROXY_HOST=127.0.0.1 NETWORK_MODE=host ./build_with_docker.sh
PROXY_HOST="${PROXY_HOST:-host.docker.internal}"
PROXY_PORT="${PROXY_PORT:-7897}"
NETWORK_MODE="${NETWORK_MODE:-}"

export https_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
export http_proxy="${https_proxy}"
export all_proxy="socks5://${PROXY_HOST}:${PROXY_PORT}"
export HTTPS_PROXY="${https_proxy}"
export HTTP_PROXY="${http_proxy}"
export ALL_PROXY="${all_proxy}"
export NO_PROXY="localhost,127.0.0.1,host.docker.internal,mirrors.aliyun.com,pypi.tuna.tsinghua.edu.cn"
export no_proxy="${NO_PROXY}"

BUILD_ARGS=(
  --add-host=host.docker.internal:host-gateway
  --build-arg "PROXY_HOST=${PROXY_HOST}"
  --build-arg "PROXY_PORT=${PROXY_PORT}"
  -t litert_build_env
  -f "${SCRIPT_DIR}/hermetic_build.Dockerfile"
  "${SCRIPT_DIR}"
)
if [[ -n "${NETWORK_MODE}" ]]; then
  BUILD_ARGS=(--network="${NETWORK_MODE}" "${BUILD_ARGS[@]}")
fi

docker build "${BUILD_ARGS[@]}"

RUN_ARGS=(
  --rm
  --name litert_build_container
  --add-host=host.docker.internal:host-gateway
  -e http_proxy -e https_proxy -e all_proxy
  -e HTTP_PROXY -e HTTPS_PROXY -e ALL_PROXY
  -e NO_PROXY -e no_proxy
  -v "${REPO_ROOT}:/litert_build"
  litert_build_env
)
if [[ -n "${NETWORK_MODE}" ]]; then
  RUN_ARGS=(--network="${NETWORK_MODE}" "${RUN_ARGS[@]}")
fi

docker run "${RUN_ARGS[@]}"
