#!/usr/bin/env bash
set -euo pipefail

export ROS_MASTER_URI=${ROS_MASTER_URI:-http://localhost:11311}

source "/opt/ros/${ROS_DISTRO}/setup.bash"

GAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER=${GAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER:-ON}

if [[ -z "${Torch_DIR:-}" ]]; then
  export Torch_DIR
  Torch_DIR="$(python3 - <<'PY'
import os
import torch
print(os.path.join(os.path.dirname(torch.__file__), "share", "cmake", "Torch"))
PY
)"
fi

mkdir -p "${CATKIN_WS}/src"

copy_or_clone_dep() {
  local name="$1"
  local repo_url="$2"
  local src_dir="${CATKIN_WS}/src/${name}"
  local vendored_dir="/opt/gaussian-lic-src/.deps/${name}"

  rm -rf "${src_dir}"
  mkdir -p "${src_dir}"

  if [[ -d "${vendored_dir}" ]]; then
    rsync -a --delete --exclude .git "${vendored_dir}/" "${src_dir}/"
  else
    git clone --depth 1 "${repo_url}" "${src_dir}"
  fi
}

copy_or_clone_dep "livox_ros_driver" "https://github.com/Livox-SDK/livox_ros_driver.git"
copy_or_clone_dep "Coco-LIC" "https://github.com/APRIL-ZJU/Coco-LIC.git"

rm -rf "${CATKIN_WS}/src/Gaussian-LIC"
mkdir -p "${CATKIN_WS}/src/Gaussian-LIC"
rsync -a --delete \
  --exclude .git \
  --exclude .deps \
  /opt/gaussian-lic-src/ "${CATKIN_WS}/src/Gaussian-LIC/"

sed -i '/ov_core/d' "${CATKIN_WS}/src/Coco-LIC/package.xml"

pushd "${CATKIN_WS}" >/dev/null
catkin_make --pkg livox_ros_driver -DPYTHON_EXECUTABLE=/usr/bin/python3
catkin_make \
  -DPYTHON_EXECUTABLE=/usr/bin/python3 \
  -DGAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER="${GAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER}"
popd >/dev/null
