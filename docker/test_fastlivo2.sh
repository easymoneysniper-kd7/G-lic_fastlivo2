#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME=${IMAGE_NAME:-gaussian-lic:cuda128}
CONTAINER_NAME=${CONTAINER_NAME:-gaussian-lic-test}
RESULT_ROOT_DIR=${RESULT_ROOT_DIR:-/home/cw/project/yjh_workspace/G-lic/result}
HOST_CKPT_DIR=${HOST_CKPT_DIR:-/home/cw/project/yjh_workspace/G-lic/ckpt}
BAG_PATH=${BAG_PATH:-${1:-}}
ROS_SETUP=${ROS_SETUP:-/opt/ros/noetic/setup.bash}
HOST_UID=${HOST_UID:-$(id -u)}
HOST_GID=${HOST_GID:-$(id -g)}
RUNTIME_HOME=${RUNTIME_HOME:-/tmp/gaussian-lic}

if [[ -z "${BAG_PATH}" ]]; then
  echo "Usage: BAG_PATH=/absolute/path/to/xxx.bag $0" >&2
  exit 1
fi

if [[ ! -f "${BAG_PATH}" ]]; then
  echo "Bag file not found: ${BAG_PATH}" >&2
  exit 1
fi

ENGINE_PATH="${HOST_CKPT_DIR}/spnet_512_640.engine"
if [[ ! -f "${ENGINE_PATH}" ]]; then
  echo "TensorRT engine not found: ${ENGINE_PATH}" >&2
  echo "To run with original depth completion enabled, place Large_300.pth in ${HOST_CKPT_DIR} and generate the engine with:" >&2
  echo "  cd ${HOST_CKPT_DIR} && ./setup_spnet.sh && ./export_onnx.sh && ./build_trt.sh" >&2
  exit 1
fi

HOST_BAG_DIR="$(cd "$(dirname "${BAG_PATH}")" && pwd)"
CONTAINER_BAG_PATH="/data/$(basename "${BAG_PATH}")"
BAG_STEM="$(basename "${BAG_PATH}")"
BAG_STEM="${BAG_STEM%.*}"
RUN_NAME=${RUN_NAME:-$(date +%Y%m%d_%H%M%S)"_${BAG_STEM}"}
HOST_RESULT_DIR="${RESULT_ROOT_DIR}/${RUN_NAME}"
HOST_COCOLIC_DIR="${HOST_RESULT_DIR}/cocolic_data"
CONTAINER_RESULT_ROOT="/opt/gaussian_lic_ws/src/Gaussian-LIC/result"
CONTAINER_RESULT_PATH="${CONTAINER_RESULT_ROOT}/${RUN_NAME}"

mkdir -p "${HOST_RESULT_DIR}" "${HOST_COCOLIC_DIR}"

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

docker run -d \
  --name "${CONTAINER_NAME}" \
  --user "${HOST_UID}:${HOST_GID}" \
  --gpus all \
  --ipc=host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -e "HOME=${RUNTIME_HOME}" \
  -e "ROS_HOME=${RUNTIME_HOME}/.ros" \
  -v "${RESULT_ROOT_DIR}:${CONTAINER_RESULT_ROOT}" \
  -v "${HOST_COCOLIC_DIR}:/opt/gaussian_lic_ws/src/Coco-LIC/data" \
  -v "${HOST_CKPT_DIR}:/opt/gaussian_lic_ws/src/Gaussian-LIC/ckpt:ro" \
  -v "${HOST_BAG_DIR}:/data:ro" \
  "${IMAGE_NAME}" \
  bash -lc "sleep infinity"

docker exec -d "${CONTAINER_NAME}" bash -lc "
  source ${ROS_SETUP}
  source /opt/gaussian_lic_ws/devel/setup.bash
  cd /opt/gaussian_lic_ws/src/Gaussian-LIC
  CONFIG_PATH=config/fastlivo2.runtime.yaml
  cp config/fastlivo2.yaml \${CONFIG_PATH}
  roslaunch gaussian_lic fastlivo2.launch config_path:=\${CONFIG_PATH} result_path:=${CONTAINER_RESULT_PATH} > /tmp/gaussian_lic.log 2>&1
"

sleep 8

docker exec -d "${CONTAINER_NAME}" bash -lc "
  source ${ROS_SETUP}
  source /opt/gaussian_lic_ws/devel/setup.bash
  cd /opt/gaussian_lic_ws
  /opt/gaussian_lic_ws/devel/lib/cocolic/odometry_node \
    _project_path:=/opt/gaussian_lic_ws/src/Coco-LIC \
    _config_path:=/opt/gaussian_lic_ws/src/Coco-LIC/config/ct_odometry_fastlivo2.yaml \
    _bag_path:=${CONTAINER_BAG_PATH} \
    _pasue_time:=-1 \
    _verbose:=true > /tmp/cocolic.log 2>&1
"

echo "Container: ${CONTAINER_NAME}"
echo "Bag: ${BAG_PATH}"
echo "Run name: ${RUN_NAME}"
echo "Gaussian-LIC log: docker exec -it ${CONTAINER_NAME} tail -f /tmp/gaussian_lic.log"
echo "Coco-LIC log: docker exec -it ${CONTAINER_NAME} tail -f /tmp/cocolic.log"
echo "Result dir: ${HOST_RESULT_DIR}"
