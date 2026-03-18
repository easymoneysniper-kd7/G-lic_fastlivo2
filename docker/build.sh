#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME=${IMAGE_NAME:-gaussian-lic:cuda128}
BASE_IMAGE=${BASE_IMAGE:-gaussian-lic:base}
OPENCV_IMAGE=${OPENCV_IMAGE:-gaussian-lic:opencv}
LIBTORCH_IMAGE=${LIBTORCH_IMAGE:-gaussian-lic:libtorch}

docker build \
  --progress=plain \
  -f docker/Dockerfile.base \
  -t "${BASE_IMAGE}" \
  .

docker build \
  --progress=plain \
  -f docker/Dockerfile.opencv \
  --build-arg BASE_IMAGE="${BASE_IMAGE}" \
  -t "${OPENCV_IMAGE}" \
  .

docker build \
  --progress=plain \
  -f docker/Dockerfile.libtorch \
  --build-arg BASE_IMAGE="${OPENCV_IMAGE}" \
  -t "${LIBTORCH_IMAGE}" \
  .

docker build \
  --progress=plain \
  -f docker/Dockerfile.final \
  --build-arg BASE_IMAGE="${LIBTORCH_IMAGE}" \
  -t "${IMAGE_NAME}" \
  .
