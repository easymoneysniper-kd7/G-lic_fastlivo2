#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose.fastlivo2.yml"
PROJECT_NAME="${PROJECT_NAME:-gaussian-lic-fastlivo2}"
DEFAULT_BAG="${REPO_ROOT}/data/fast-livo2_datasets/CBD_Building_01.bag"
BAG_PATH="${BAG_PATH:-${1:-${DEFAULT_BAG}}}"
PLAY_RATE="${PLAY_RATE:-1}"
RUN_NAME="${RUN_NAME:-$(date +%Y%m%d_%H%M%S)_$(basename "${BAG_PATH}" .bag)}"
RESULT_DIR="${REPO_ROOT}/result/${RUN_NAME}"
SUMMARY_PATH="${RESULT_DIR}/timing_summary.txt"
STOP_CONFLICTING_CONTAINERS="${STOP_CONFLICTING_CONTAINERS:-1}"
CONFLICTING_CONTAINERS=(
  gaussian-lic-backend-gpu
  gaussian-lic-test
)

if [[ ! -f "${BAG_PATH}" ]]; then
  echo "Bag file not found: ${BAG_PATH}" >&2
  exit 1
fi

case "${BAG_PATH}" in
  "${WORKSPACE_ROOT}"/*) ;;
  *)
    echo "Bag file must live under ${WORKSPACE_ROOT} so docker compose can access it: ${BAG_PATH}" >&2
    exit 1
    ;;
esac

mkdir -p "${RESULT_DIR}"

export WORKSPACE_ROOT
export RUN_NAME
export PLAY_RATE
export BAG_PATH="/workspace/${BAG_PATH#${WORKSPACE_ROOT}/}"

compose() {
  docker compose -f "${COMPOSE_FILE}" -p "${PROJECT_NAME}" "$@"
}

cleanup_bag_player_runs() {
  docker ps -a --format '{{.Names}}' \
    | grep -E "^${PROJECT_NAME}-bag_player-run-" \
    | xargs -r docker rm -f >/dev/null 2>&1 || true
}

cleanup() {
  compose down --remove-orphans >/dev/null 2>&1 || true
  cleanup_bag_player_runs
}

stop_conflicting_containers() {
  local name
  if [[ "${STOP_CONFLICTING_CONTAINERS}" != "1" ]]; then
    return 0
  fi
  for name in "${CONFLICTING_CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' | grep -Fxq "${name}"; then
      echo "Stopping conflicting container: ${name}"
      docker stop "${name}" >/dev/null
    fi
  done
}

wait_for_service_running() {
  local service="$1"
  local retries="${2:-40}"
  local i
  for ((i = 0; i < retries; ++i)); do
    if compose ps --status running --services | grep -Fxq "${service}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_ros_node() {
  local pattern="$1"
  local retries="${2:-40}"
  local i
  local node
  for ((i = 0; i < retries; ++i)); do
    node="$(compose exec -T roscore bash -lc "source /opt/ros/noetic/setup.bash && export ROS_MASTER_URI=http://127.0.0.1:11311 && rosnode list 2>/dev/null | grep -E '${pattern}' | head -n 1" | tr -d '\r')"
    if [[ -n "${node}" ]] && compose exec -T roscore bash -lc "source /opt/ros/noetic/setup.bash && export ROS_MASTER_URI=http://127.0.0.1:11311 && rosnode ping -c 1 '${node}' >/dev/null 2>&1"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_topic() {
  local topic="$1"
  local retries="${2:-40}"
  local i
  for ((i = 0; i < retries; ++i)); do
    if compose exec -T roscore bash -lc "source /opt/ros/noetic/setup.bash && export ROS_MASTER_URI=http://127.0.0.1:11311 && rostopic list | grep -q '^${topic}\$'"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

collect_logs() {
  compose logs roscore > "${RESULT_DIR}/roscore.log" 2>&1 || true
  compose logs frontend > "${RESULT_DIR}/frontend.log" 2>&1 || true
  compose logs bridge > "${RESULT_DIR}/bridge.log" 2>&1 || true
  compose logs backend > "${RESULT_DIR}/backend.log" 2>&1 || true
}

parse_summary() {
  python3 - "${RESULT_DIR}" "${bag_wall}" "${total_wall}" <<'PY'
import pathlib
import re
import sys

result_dir = pathlib.Path(sys.argv[1])
bag_wall = float(sys.argv[2])
total_wall = float(sys.argv[3])
post_bag = max(total_wall - bag_wall, 0.0)

frontend_log = (result_dir / "frontend.log").read_text(errors="ignore")
backend_log = (result_dir / "backend.log").read_text(errors="ignore")
bridge_log = (result_dir / "bridge.log").read_text(errors="ignore")
metrics_txt = (result_dir / "metrics.txt").read_text(errors="ignore")

def last_float(pattern, text):
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    return matches[-1] if matches else None

current_section = None
lio_avg = None
vio_avg = None
for line in frontend_log.splitlines():
    if "LIO Mapping Time" in line:
        current_section = "lio"
    elif "VIO Time" in line:
        current_section = "vio"
    elif "Average Total Time" in line:
        m = re.search(r"Average Total Time\s*\|\s*([0-9.]+)", line)
        if m:
            if current_section == "lio":
                lio_avg = m.group(1)
            elif current_section == "vio":
                vio_avg = m.group(1)

summary_lines = [
    f"run_name={result_dir.name}",
    f"bag_play_wall_seconds={bag_wall:.2f}",
    f"post_bag_finalize_wall_seconds={post_bag:.2f}",
    f"total_wall_seconds={total_wall:.2f}",
]

if lio_avg is not None:
    summary_lines.append(f"frontend_lio_average_seconds={lio_avg}")
if vio_avg is not None:
    summary_lines.append(f"frontend_vio_average_seconds={vio_avg}")

for key, pattern in [
    ("backend_total_mapping_seconds", r"\[Total Mapping Time\]\s+([0-9.]+)s"),
    ("backend_forward_seconds", r"1\) Forward\s+([0-9.]+)s"),
    ("backend_backward_seconds", r"2\) Backward\s+([0-9.]+)s"),
    ("backend_step_seconds", r"3\) Step\s+([0-9.]+)s"),
    ("backend_cpu2gpu_seconds", r"4\) CPU2GPU\s+([0-9.]+)s"),
    ("backend_total_adding_seconds", r"\[Total Adding Time\]\s+([0-9.]+)s"),
    ("backend_total_extending_seconds", r"\[Total Extending Time\]\s+([0-9.]+)s"),
]:
    value = last_float(pattern, backend_log)
    if value is not None:
        summary_lines.append(f"{key}={value}")

bridge_publish_count = len(re.findall(r"Published aligned frame stamp=", bridge_log))
summary_lines.append(f"bridge_published_frame_logs={bridge_publish_count}")

for line in metrics_txt.splitlines():
    if "=" in line:
        summary_lines.append(line.strip())

summary = "\n".join(summary_lines) + "\n"
print(summary, end="")
(result_dir / "timing_summary.txt").write_text(summary)
PY
}

trap cleanup EXIT

echo "Run name: ${RUN_NAME}"
echo "Bag: ${BAG_PATH}"
echo "Result dir: ${RESULT_DIR}"

cleanup
cleanup_bag_player_runs
stop_conflicting_containers

compose up -d roscore
wait_for_service_running roscore
wait_for_topic "/rosout"

compose up -d frontend bridge backend
wait_for_service_running frontend
wait_for_service_running bridge
wait_for_service_running backend
wait_for_ros_node '^/fastlivo2_gs_bridge$'
wait_for_ros_node '^/gs_mapping_'
wait_for_topic "/points_for_gs"
wait_for_topic "/pose_for_gs"
wait_for_topic "/image_for_gs"
wait_for_topic "/depth_for_gs"

total_start="$(date +%s.%N)"
bag_start="${total_start}"
compose run --rm bag_player > "${RESULT_DIR}/bag_player.log" 2>&1
bag_end="$(date +%s.%N)"

metrics_path="${RESULT_DIR}/metrics.txt"
for _ in $(seq 1 240); do
  if [[ -f "${metrics_path}" ]]; then
    break
  fi
  sleep 5
done

if [[ ! -f "${metrics_path}" ]]; then
  collect_logs
  echo "Timed out waiting for metrics file: ${metrics_path}" >&2
  exit 1
fi

total_end="$(date +%s.%N)"

collect_logs
bash "${SCRIPT_DIR}/resultctl.sh" fix-ownership "${RUN_NAME}" >/dev/null 2>&1 || true

bag_wall="$(python3 - <<PY
print(${bag_end} - ${bag_start})
PY
)"
total_wall="$(python3 - <<PY
print(${total_end} - ${total_start})
PY
)"

parse_summary
