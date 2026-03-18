#!/usr/bin/env bash
set -e

SPNET_ENV_MODE=${SPNET_ENV_MODE:-venv}
SPNET_ENV_NAME=${SPNET_ENV_NAME:-spnet}
SPNET_ENV_DIR=${SPNET_ENV_DIR:-$PWD/.spnet-venv}
PYTHON_BIN=${PYTHON_BIN:-python3}
TORCH_INDEX_URL=${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}

if [[ "${SPNET_ENV_MODE}" == "conda" ]]; then
  if ! command -v conda >/dev/null 2>&1; then
    echo "Conda was requested but is not installed." >&2
    exit 1
  fi
  echo ">>> Creating conda env: ${SPNET_ENV_NAME}"
  conda create -n "${SPNET_ENV_NAME}" python=3.8 -y
  echo ">>> Activating conda env: ${SPNET_ENV_NAME}"
  source "$(conda info --base)/etc/profile.d/conda.sh"
  conda activate "${SPNET_ENV_NAME}"
else
  echo ">>> Creating venv: ${SPNET_ENV_DIR}"
  "${PYTHON_BIN}" -m venv "${SPNET_ENV_DIR}"
  # shellcheck disable=SC1090
  source "${SPNET_ENV_DIR}/bin/activate"
fi

echo ">>> Upgrading pip"
pip install --upgrade pip setuptools wheel

echo ">>> Installing PyTorch from ${TORCH_INDEX_URL}"
pip install torch torchvision torchaudio --index-url "${TORCH_INDEX_URL}"

echo ">>> Installing ONNX & ONNXRuntime"
pip install onnx onnxruntime

echo ">>> Done. SPNet environment is ready."
