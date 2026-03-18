#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME=${IMAGE_NAME:-gaussian-lic:cuda128}
CONTAINER_NAME=${CONTAINER_NAME:-gaussian-lic}
HOST_RESULT_DIR=${HOST_RESULT_DIR:-/home/cw/project/yjh_workspace/G-lic/result}
HOST_DATA_ROOT=${HOST_DATA_ROOT:-}
HOST_UID=${HOST_UID:-$(id -u)}
HOST_GID=${HOST_GID:-$(id -g)}
RUNTIME_HOME=${RUNTIME_HOME:-/tmp/gaussian-lic}

mkdir -p "${HOST_RESULT_DIR}"

DOCKER_ARGS=(
  --rm
  -it
  --name "${CONTAINER_NAME}"
  --user "${HOST_UID}:${HOST_GID}"
  --gpus all
  --ipc=host
  --ulimit memlock=-1
  --ulimit stack=67108864
  -e "HOME=${RUNTIME_HOME}"
  -e "ROS_HOME=${RUNTIME_HOME}/.ros"
  -v "${HOST_RESULT_DIR}:/opt/gaussian_lic_ws/src/Gaussian-LIC/result"
)

if [[ -n "${HOST_DATA_ROOT}" ]]; then
  DOCKER_ARGS+=(-v "${HOST_DATA_ROOT}:/data:ro")
fi

docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" "$@"
