#!/usr/bin/env bash
set -e

SPNET_ENV_MODE=${SPNET_ENV_MODE:-venv}
SPNET_ENV_NAME=${SPNET_ENV_NAME:-spnet}
SPNET_ENV_DIR=${SPNET_ENV_DIR:-$PWD/.spnet-venv}

if [[ "${SPNET_ENV_MODE}" == "conda" ]]; then
  echo ">>> Activating conda env: ${SPNET_ENV_NAME}"
  source "$(conda info --base)/etc/profile.d/conda.sh"
  conda activate "${SPNET_ENV_NAME}"
else
  echo ">>> Activating venv: ${SPNET_ENV_DIR}"
  # shellcheck disable=SC1090
  source "${SPNET_ENV_DIR}/bin/activate"
fi

echo ">>> Export ONNX (512x640)"
python export_onnx_512_640.py

echo ">>> Export ONNX (480x640)"
python export_onnx_480_640.py

echo ">>> All ONNX exports finished successfully."
