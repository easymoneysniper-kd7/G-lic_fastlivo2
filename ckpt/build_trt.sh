#!/usr/bin/env bash
set -e

TENSORRT_ROOT=${TENSORRT_ROOT:-$HOME/Software/TensorRT-8.6.1.6}

if [[ -x "${TENSORRT_ROOT}/bin/trtexec" ]]; then
  TRT_BIN="${TENSORRT_ROOT}/bin/trtexec"
elif [[ -x "${TENSORRT_ROOT}/targets/x86_64-linux-gnu/bin/trtexec" ]]; then
  TRT_BIN="${TENSORRT_ROOT}/targets/x86_64-linux-gnu/bin/trtexec"
elif [[ -x "/usr/src/tensorrt/bin/trtexec" ]]; then
  TRT_BIN="/usr/src/tensorrt/bin/trtexec"
elif command -v trtexec >/dev/null 2>&1; then
  TRT_BIN="$(command -v trtexec)"
else
  echo "Cannot find trtexec. Set TENSORRT_ROOT or TRT_BIN." >&2
  exit 1
fi

TRT_LIB=""
for candidate in \
  "${TENSORRT_ROOT}/lib" \
  "${TENSORRT_ROOT}/lib64" \
  "${TENSORRT_ROOT}/targets/x86_64-linux-gnu/lib" \
  "/usr/lib/x86_64-linux-gnu"
do
  if [[ -d "${candidate}" ]]; then
    TRT_LIB="${TRT_LIB}:${candidate}"
  fi
done

if command -v conda >/dev/null 2>&1; then
  echo ">>> Deactivating conda env (if any)"
  conda deactivate || true
fi

echo ">>> Setting TensorRT LD_LIBRARY_PATH"
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$TRT_LIB

echo ">>> Building TensorRT engine: 512x640"
$TRT_BIN \
  --onnx=spnet_512_640.onnx \
  --saveEngine=spnet_512_640.engine \
  --fp16 \
  --optShapes=rgb:1x3x512x640,depth:1x1x512x640,mask:1x1x512x640

echo ">>> Building TensorRT engine: 480x640"
$TRT_BIN \
  --onnx=spnet_480_640.onnx \
  --saveEngine=spnet_480_640.engine \
  --fp16 \
  --optShapes=rgb:1x3x480x640,depth:1x1x480x640,mask:1x1x480x640

echo ">>> TensorRT engine build finished."
