#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_DATASET_ROOT="${REPO_ROOT}/data/fast-livo2_datasets"
DATASET_ROOT="${DATASET_ROOT:-${1:-${DEFAULT_DATASET_ROOT}}}"
MASTER_SUMMARY="${REPO_ROOT}/result/COCO_metrics_summary.csv"
RUNTIME_ROOT="${REPO_ROOT}/.runtime_configs"
START_FROM_BAG="${START_FROM_BAG:-}"
IMAGE_NAME="${IMAGE_NAME:-gaussian-lic:cuda128}"
HOST_CKPT_DIR="${HOST_CKPT_DIR:-${REPO_ROOT}/ckpt}"
HOST_UID="${HOST_UID:-$(id -u)}"
HOST_GID="${HOST_GID:-$(id -g)}"
RUNTIME_HOME="${RUNTIME_HOME:-/tmp/gaussian-lic}"

BAG_NAMES=(
  CBD_Building_01
  CBD_Building_02
  HKU_Campus
  Red_Sculpture
  Retail_Street
  SYSU_01
)

if [[ ! -d "${DATASET_ROOT}" ]]; then
  echo "Dataset root not found: ${DATASET_ROOT}" >&2
  exit 1
fi

if [[ ! -f "${HOST_CKPT_DIR}/spnet_512_640.engine" ]]; then
  echo "TensorRT engine not found: ${HOST_CKPT_DIR}/spnet_512_640.engine" >&2
  exit 1
fi

mkdir -p "${REPO_ROOT}/result" "${RUNTIME_ROOT}"

echo "dataset_root=${DATASET_ROOT}"
echo "master_summary=${MASTER_SUMMARY}"

CSV_HEADER="run_name,bag_path,status,total_wall_seconds,training_view_psnr,training_view_ssim,training_view_lpips,in_sequence_novel_view_psnr,in_sequence_novel_view_ssim,in_sequence_novel_view_lpips"
if [[ -n "${START_FROM_BAG}" && -f "${MASTER_SUMMARY}" ]]; then
  if [[ ! -s "${MASTER_SUMMARY}" ]]; then
    echo "${CSV_HEADER}" > "${MASTER_SUMMARY}"
  fi
else
  echo "${CSV_HEADER}" > "${MASTER_SUMMARY}"
fi

extract_metric() {
  local file="$1"
  local key="$2"
  awk -F= -v k="${key}" '$1==k {print $2}' "${file}" | tail -n 1
}

set_profile_by_bag() {
  local bag_base="$1"
  case "${bag_base}" in
    CBD_Building_01|Retail_Street)
      RCL="0.00610193,-0.999863,-0.0154172,-0.00615449,0.0153796,-0.999863,0.999962,0.00619598,-0.0060598"
      PCL="0.0194384,0.104689,-0.0251952"
      CAM_FX="1293.56944"
      CAM_FY="1293.3155"
      CAM_CX="626.91359"
      CAM_CY="522.799224"
      CAM_D0="-0.076160"
      CAM_D1="0.123001"
      CAM_D2="-0.00113"
      CAM_D3="0.000251"
      ;;
    CBD_Building_02|HKU_Campus)
      RCL="-0.00200,-0.99975,-0.02211,-0.00366,0.02212,-0.99975,0.99999,-0.00192,-0.00371"
      PCL="0.00260,0.05057,-0.00587"
      CAM_FX="1176.2874292149932"
      CAM_FY="1176.21585445307"
      CAM_CX="592.1187382755453"
      CAM_CY="509.0864309628322"
      CAM_D0="-0.13218037625958456"
      CAM_D1="0.15360732717073536"
      CAM_D2="0.00036918417348059815"
      CAM_D3="-0.00031715324469463964"
      ;;
    Red_Sculpture)
      RCL="-0.00668,-0.99965,-0.02543,-0.01151,0.02550,-0.99961,0.99991,-0.00638,-0.01168"
      PCL="-0.00077,0.04809,-0.00133"
      CAM_FX="1294.7265716372897"
      CAM_FY="1294.8678078910468"
      CAM_CX="626.663267153558"
      CAM_CY="531.0334324363173"
      CAM_D0="-0.07592763180373921"
      CAM_D1="0.12857252741674535"
      CAM_D2="0.0002726821691221157"
      CAM_D3="0.0002504335037343933"
      ;;
    SYSU_01|HIT_Graffiti_Wall_01)
      RCL="-0.0036250,-0.9998907,-0.0143360,0.0075568,0.0143083,-0.9998690,0.9999649,-0.0037329,0.0075041"
      PCL="0.00549469,0.0712101,0.0322054"
      CAM_FX="1311.89517127580"
      CAM_FY="1311.36488586115"
      CAM_CX="656.523841857393"
      CAM_CY="504.136322840350"
      CAM_D0="-0.0780830982640722"
      CAM_D1="0.146382433670493"
      CAM_D2="-0.00110111633050301"
      CAM_D3="-0.00110752991013068"
      ;;
    *)
      echo "No calibration profile for bag: ${bag_base}" >&2
      return 1
      ;;
  esac
  CAM_WIDTH="1280"
  CAM_HEIGHT="1024"
  CAM_SCALE="0.5"
  LIDAR_TO_IMU_T="0.04165,0.02326,-0.0284"
}

write_runtime_camera_yaml() {
  local out_file="$1"

  local W H FX FY CX CY
  W="$(awk -v w="${CAM_WIDTH}" -v s="${CAM_SCALE}" 'BEGIN {printf "%d", int(w*s + 0.5)}')"
  H="$(awk -v h="${CAM_HEIGHT}" -v s="${CAM_SCALE}" 'BEGIN {printf "%d", int(h*s + 0.5)}')"
  FX="$(awk -v x="${CAM_FX}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"
  FY="$(awk -v x="${CAM_FY}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"
  CX="$(awk -v x="${CAM_CX}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"
  CY="$(awk -v x="${CAM_CY}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"

  IFS=',' read -r R00 R01 R02 R10 R11 R12 R20 R21 R22 <<< "${RCL}"
  IFS=',' read -r TX TY TZ <<< "${PCL}"
  IFS=',' read -r LTX LTY LTZ <<< "${LIDAR_TO_IMU_T}"

  # Camera->LiDAR rotation is transpose of LiDAR->Camera rotation.
  local CR00="${R00}" CR01="${R10}" CR02="${R20}"
  local CR10="${R01}" CR11="${R11}" CR12="${R21}"
  local CR20="${R02}" CR21="${R12}" CR22="${R22}"

  # t_cl = -R_cl * t_lc, t_ci = t_li + t_cl (R_li is identity in this setup).
  local TCLX TCLY TCLZ TCIX TCIY TCIZ
  TCLX="$(awk -v r00="${CR00}" -v r01="${CR01}" -v r02="${CR02}" -v tx="${TX}" -v ty="${TY}" -v tz="${TZ}" 'BEGIN {printf "%.10f", -(r00*tx + r01*ty + r02*tz)}')"
  TCLY="$(awk -v r10="${CR10}" -v r11="${CR11}" -v r12="${CR12}" -v tx="${TX}" -v ty="${TY}" -v tz="${TZ}" 'BEGIN {printf "%.10f", -(r10*tx + r11*ty + r12*tz)}')"
  TCLZ="$(awk -v r20="${CR20}" -v r21="${CR21}" -v r22="${CR22}" -v tx="${TX}" -v ty="${TY}" -v tz="${TZ}" 'BEGIN {printf "%.10f", -(r20*tx + r21*ty + r22*tz)}')"
  TCIX="$(awk -v a="${LTX}" -v b="${TCLX}" 'BEGIN {printf "%.10f", a+b}')"
  TCIY="$(awk -v a="${LTY}" -v b="${TCLY}" 'BEGIN {printf "%.10f", a+b}')"
  TCIZ="$(awk -v a="${LTZ}" -v b="${TCLZ}" 'BEGIN {printf "%.10f", a+b}')"

  cat > "${out_file}" <<EOF
%YAML:1.0

image_topic: /left_camera/image

image_width: ${W}
image_height: ${H}
cam_fx: ${FX}
cam_fy: ${FY}
cam_cx: ${CX}
cam_cy: ${CY}
cam_d0: ${CAM_D0}
cam_d1: ${CAM_D1}
cam_d2: ${CAM_D2}
cam_d3: ${CAM_D3}
cam_d4: 0.0

CameraExtrinsics:
    Trans: [${TCIX}, ${TCIY}, ${TCIZ}]
    Rot: [ ${CR00}, ${CR01}, ${CR02},
           ${CR10}, ${CR11}, ${CR12},
           ${CR20}, ${CR21}, ${CR22}]

img_time_offset: 0.1
EOF
}

write_runtime_gs_yaml() {
  local out_file="$1"

  local W H FX FY CX CY
  W="$(awk -v w="${CAM_WIDTH}" -v s="${CAM_SCALE}" 'BEGIN {printf "%d", int(w*s + 0.5)}')"
  H="$(awk -v h="${CAM_HEIGHT}" -v s="${CAM_SCALE}" 'BEGIN {printf "%d", int(h*s + 0.5)}')"
  FX="$(awk -v x="${CAM_FX}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"
  FY="$(awk -v x="${CAM_FY}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"
  CX="$(awk -v x="${CAM_CX}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"
  CY="$(awk -v x="${CAM_CY}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"

  {
    echo "width: ${W}"
    echo "height: ${H}"
    echo "fx: ${FX}"
    echo "fy: ${FY}"
    echo "cx: ${CX}"
    echo "cy: ${CY}"
    tail -n +8 "${REPO_ROOT}/config/fastlivo2.yaml"
  } > "${out_file}"
}

cleanup_container() {
  local name="$1"
  docker rm -f "${name}" >/dev/null 2>&1 || true
}

index=0
start_enabled=1
if [[ -n "${START_FROM_BAG}" ]]; then
  start_enabled=0
fi

for bag_base in "${BAG_NAMES[@]}"; do
  bag="${DATASET_ROOT}/${bag_base}.bag"
  if [[ ! -f "${bag}" ]]; then
    echo "Missing bag file: ${bag}" >&2
    exit 1
  fi

  if [[ "${start_enabled}" -eq 0 ]]; then
    if [[ "${bag_base}" == "${START_FROM_BAG}" || "$(basename "${bag}")" == "${START_FROM_BAG}" ]]; then
      start_enabled=1
    else
      echo "[skip] ${bag_base} (waiting for START_FROM_BAG=${START_FROM_BAG})"
      continue
    fi
  fi

  index=$((index + 1))
  run_name="COCO_${bag_base}"
  result_dir="${REPO_ROOT}/result/${run_name}"
  runtime_dir="${RUNTIME_ROOT}/${run_name}"
  runtime_cam="${runtime_dir}/camera.yaml"
  runtime_gs="${runtime_dir}/fastlivo2.yaml"
  timing_file="${result_dir}/timing_summary.txt"
  metrics_file="${result_dir}/metrics.txt"
  cloud_file="${result_dir}/point_cloud.ply"
  renamed_cloud_file="${result_dir}/${run_name}.ply"
  container_name="gaussian-lic-coco-${bag_base,,}"

  set_profile_by_bag "${bag_base}"

  rm -rf "${result_dir}" "${runtime_dir}"
  mkdir -p "${result_dir}" "${runtime_dir}"
  write_runtime_camera_yaml "${runtime_cam}"
  write_runtime_gs_yaml "${runtime_gs}"

  echo
  echo "[${index}/${#BAG_NAMES[@]}] running bag: ${bag}"
  echo "run_name=${run_name}"

  total_start="$(date +%s.%N)"
  status="ok"

  cleanup_container "${container_name}"

  docker run -d \
    --name "${container_name}" \
    --user "${HOST_UID}:${HOST_GID}" \
    --gpus all \
    --ipc=host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    -e "HOME=${RUNTIME_HOME}" \
    -e "ROS_HOME=${RUNTIME_HOME}/.ros" \
    -v "${REPO_ROOT}/result:/opt/gaussian_lic_ws/src/Gaussian-LIC/result" \
    -v "${HOST_CKPT_DIR}:/opt/gaussian_lic_ws/src/Gaussian-LIC/ckpt:ro" \
    -v "$(dirname "${bag}"):/data:ro" \
    -v "${runtime_cam}:/opt/gaussian_lic_ws/src/Coco-LIC/config/fastlivo2/camera.yaml:ro" \
    -v "${runtime_gs}:/opt/gaussian_lic_ws/src/Gaussian-LIC/config/fastlivo2.runtime.yaml:ro" \
    "${IMAGE_NAME}" \
    bash -lc "sleep infinity" >/dev/null

  docker exec -d "${container_name}" bash -lc '
    source /opt/ros/noetic/setup.bash
    source /opt/gaussian_lic_ws/devel/setup.bash
    cd /opt/gaussian_lic_ws/src/Gaussian-LIC
    roslaunch gaussian_lic fastlivo2.launch \
      config_path:=config/fastlivo2.runtime.yaml \
      result_path:=/opt/gaussian_lic_ws/src/Gaussian-LIC/result/'"${run_name}"' \
      > /tmp/gaussian_lic.log 2>&1
  '

  sleep 8

  set +e
  docker exec "${container_name}" bash -lc '
    source /opt/ros/noetic/setup.bash
    source /opt/gaussian_lic_ws/devel/setup.bash
    /opt/gaussian_lic_ws/devel/lib/cocolic/odometry_node \
      _project_path:=/opt/gaussian_lic_ws/src/Coco-LIC \
      _config_path:=/opt/gaussian_lic_ws/src/Coco-LIC/config/ct_odometry_fastlivo2.yaml \
      _bag_path:=/data/'"$(basename "${bag}")"' \
      _pasue_time:=-1 \
      _verbose:=true \
      > /tmp/cocolic.log 2>&1
  '
  coco_exit=$?
  set -e

  if [[ "${coco_exit}" -ne 0 ]]; then
    echo "warning: cocolic exited with code ${coco_exit}, waiting for backend metrics..."
  fi

  for _ in $(seq 1 720); do
    [[ -f "${metrics_file}" ]] && break
    sleep 5
  done

  if [[ ! -f "${metrics_file}" ]]; then
    status="failed"
    docker exec "${container_name}" bash -lc 'cat /tmp/gaussian_lic.log' > "${result_dir}/gaussian_lic.log" 2>&1 || true
    docker exec "${container_name}" bash -lc 'cat /tmp/cocolic.log' > "${result_dir}/cocolic.log" 2>&1 || true
    cleanup_container "${container_name}"
    echo "metrics file missing after timeout, stop batch at ${run_name}" >&2
    exit 1
  fi

  total_end="$(date +%s.%N)"
  total_wall_seconds="$(python3 - <<PY
print(${total_end} - ${total_start})
PY
)"

  {
    echo "run_name=${run_name}"
    echo "total_wall_seconds=${total_wall_seconds}"
  } > "${timing_file}"

  docker exec "${container_name}" bash -lc 'cat /tmp/gaussian_lic.log' > "${result_dir}/gaussian_lic.log" 2>&1 || true
  docker exec "${container_name}" bash -lc 'cat /tmp/cocolic.log' > "${result_dir}/cocolic.log" 2>&1 || true

  if [[ -f "${cloud_file}" ]]; then
    mv -f "${cloud_file}" "${renamed_cloud_file}"
  fi

  training_view_psnr=""
  training_view_ssim=""
  training_view_lpips=""
  in_sequence_novel_view_psnr=""
  in_sequence_novel_view_ssim=""
  in_sequence_novel_view_lpips=""

  if [[ -f "${metrics_file}" ]]; then
    training_view_psnr="$(extract_metric "${metrics_file}" "training_view_psnr")"
    training_view_ssim="$(extract_metric "${metrics_file}" "training_view_ssim")"
    training_view_lpips="$(extract_metric "${metrics_file}" "training_view_lpips")"
    in_sequence_novel_view_psnr="$(extract_metric "${metrics_file}" "in_sequence_novel_view_psnr")"
    in_sequence_novel_view_ssim="$(extract_metric "${metrics_file}" "in_sequence_novel_view_ssim")"
    in_sequence_novel_view_lpips="$(extract_metric "${metrics_file}" "in_sequence_novel_view_lpips")"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${run_name}" "${bag}" "${status}" "${total_wall_seconds}" \
    "${training_view_psnr}" "${training_view_ssim}" "${training_view_lpips}" \
    "${in_sequence_novel_view_psnr}" "${in_sequence_novel_view_ssim}" "${in_sequence_novel_view_lpips}" \
    >> "${MASTER_SUMMARY}"

  cleanup_container "${container_name}"

  echo "status=${status}"
  echo "metrics_file=${metrics_file}"
done

if [[ "${index}" -eq 0 ]]; then
  echo "No bag executed. Check START_FROM_BAG=${START_FROM_BAG}" >&2
  exit 1
fi

echo
echo "all bags finished"
echo "master_summary=${MASTER_SUMMARY}"
