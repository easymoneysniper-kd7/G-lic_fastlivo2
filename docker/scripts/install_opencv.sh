#!/usr/bin/env bash
set -euo pipefail

OPENCV_VERSION=${1:-4.7.0}
OPENCV_SRC_ROOT=/tmp/opencv-src
OPENCV_PREFIX=${OPENCV_PREFIX:-/opt/opencv/opencv-${OPENCV_VERSION}}
OPENCV_BUILD_LIST=${OPENCV_BUILD_LIST:-core,imgproc,imgcodecs,highgui,calib3d,features2d,videoio}

mkdir -p "${OPENCV_SRC_ROOT}" "${OPENCV_PREFIX}"
pushd "${OPENCV_SRC_ROOT}" >/dev/null

wget -q "https://github.com/opencv/opencv/archive/refs/tags/${OPENCV_VERSION}.tar.gz" -O opencv.tar.gz
tar -xzf opencv.tar.gz

cmake -S "opencv-${OPENCV_VERSION}" -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${OPENCV_PREFIX}" \
  -DWITH_CUDA=OFF \
  -DWITH_CUDNN=OFF \
  -DOPENCV_DNN_CUDA=OFF \
  -DBUILD_LIST="${OPENCV_BUILD_LIST}" \
  -DBUILD_JAVA=OFF \
  -DBUILD_opencv_apps=OFF \
  -DBUILD_opencv_python3=OFF \
  -DBUILD_TESTS=OFF \
  -DBUILD_PERF_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DWITH_QT=OFF \
  -DWITH_VTK=OFF

cmake --build build -j"$(nproc)"
cmake --install build

popd >/dev/null
rm -rf "${OPENCV_SRC_ROOT}"
