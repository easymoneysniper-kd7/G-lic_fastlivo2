#!/usr/bin/env bash
set -euo pipefail

RESULT_ROOT_DIR=${RESULT_ROOT_DIR:-/home/cw/project/yjh_workspace/G-lic/result}
IMAGE_NAME=${IMAGE_NAME:-gaussian-lic:cuda128}
HOST_UID=${HOST_UID:-$(id -u)}
HOST_GID=${HOST_GID:-$(id -g)}

usage() {
  cat <<'EOF'
Usage:
  ./docker/resultctl.sh list
  ./docker/resultctl.sh path <run_name>
  ./docker/resultctl.sh rename <old_name> <new_name>
  ./docker/resultctl.sh delete <run_name>
  ./docker/resultctl.sh fix-ownership [run_name|all]

Examples:
  ./docker/resultctl.sh list
  ./docker/resultctl.sh rename 20260318_132450_CBD_Building_01 scan24_depth_on
  ./docker/resultctl.sh delete scan24_depth_on
  ./docker/resultctl.sh fix-ownership all
EOF
}

require_basename() {
  local value="$1"
  if [[ -z "${value}" || "${value}" == "." || "${value}" == ".." || "${value}" == */* ]]; then
    echo "Only direct child folder names under ${RESULT_ROOT_DIR} are supported: ${value}" >&2
    exit 1
  fi
}

cmd=${1:-}

case "${cmd}" in
  list)
    mkdir -p "${RESULT_ROOT_DIR}"
    find "${RESULT_ROOT_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
    ;;
  path)
    run_name=${2:-}
    require_basename "${run_name}"
    echo "${RESULT_ROOT_DIR}/${run_name}"
    ;;
  rename)
    old_name=${2:-}
    new_name=${3:-}
    require_basename "${old_name}"
    require_basename "${new_name}"
    if [[ ! -d "${RESULT_ROOT_DIR}/${old_name}" ]]; then
      echo "Result folder not found: ${RESULT_ROOT_DIR}/${old_name}" >&2
      exit 1
    fi
    if [[ -e "${RESULT_ROOT_DIR}/${new_name}" ]]; then
      echo "Target already exists: ${RESULT_ROOT_DIR}/${new_name}" >&2
      exit 1
    fi
    mv "${RESULT_ROOT_DIR}/${old_name}" "${RESULT_ROOT_DIR}/${new_name}"
    echo "Renamed to ${RESULT_ROOT_DIR}/${new_name}"
    ;;
  delete)
    run_name=${2:-}
    require_basename "${run_name}"
    if [[ ! -e "${RESULT_ROOT_DIR}/${run_name}" ]]; then
      echo "Result folder not found: ${RESULT_ROOT_DIR}/${run_name}" >&2
      exit 1
    fi
    rm -rf "${RESULT_ROOT_DIR:?}/${run_name}"
    echo "Deleted ${RESULT_ROOT_DIR}/${run_name}"
    ;;
  fix-ownership)
    target_name=${2:-all}
    target_path=/results
    if [[ "${target_name}" != "all" ]]; then
      require_basename "${target_name}"
      if [[ ! -e "${RESULT_ROOT_DIR}/${target_name}" ]]; then
        echo "Result folder not found: ${RESULT_ROOT_DIR}/${target_name}" >&2
        exit 1
      fi
      target_path="/results/${target_name}"
    fi
    docker run --rm \
      --user 0:0 \
      -v "${RESULT_ROOT_DIR}:/results" \
      --entrypoint bash \
      "${IMAGE_NAME}" \
      -lc "chown -R ${HOST_UID}:${HOST_GID} '${target_path}' && chmod -R u+rwX '${target_path}'"
    echo "Ownership fixed for ${target_name}"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
