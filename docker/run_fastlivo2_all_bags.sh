#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
DEFAULT_DATASET_ROOT="${REPO_ROOT}/data/fast-livo2_datasets"
DATASET_ROOT="${DATASET_ROOT:-${1:-${DEFAULT_DATASET_ROOT}}}"
MASTER_SUMMARY="${REPO_ROOT}/result/FAST-LIVO2_metrics_summary.csv"
RUNTIME_ROOT="${REPO_ROOT}/.runtime_configs"
START_FROM_BAG="${START_FROM_BAG:-}"

if [[ ! -d "${DATASET_ROOT}" ]]; then
  echo "Dataset root not found: ${DATASET_ROOT}" >&2
  exit 1
fi

echo "dataset_root=${DATASET_ROOT}"
echo "master_summary=${MASTER_SUMMARY}"

mapfile -t BAG_FILES < <(find "${DATASET_ROOT}" -type f -name '*.bag' | sort)

if [[ "${#BAG_FILES[@]}" -eq 0 ]]; then
  echo "No .bag files found under ${DATASET_ROOT}" >&2
  exit 1
fi

echo "run_name,bag_path,status,total_wall_seconds,training_view_psnr,training_view_ssim,training_view_lpips,in_sequence_novel_view_psnr,in_sequence_novel_view_ssim,in_sequence_novel_view_lpips" > "${MASTER_SUMMARY}"

extract_metric() {
  local file="$1"
  local key="$2"
  awk -F= -v k="${key}" '$1==k {print $2}' "${file}" | tail -n 1
}

extract_summary_value() {
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
}

write_runtime_configs() {
  local run_name="$1"
  local bag_base="$2"
  local runtime_dir="${RUNTIME_ROOT}/${run_name}"
  local avia_file="${runtime_dir}/avia.yaml"
  local camera_file="${runtime_dir}/camera_pinhole.yaml"
  local bridge_file="${runtime_dir}/bridge.yaml"
  local gs_file="${runtime_dir}/fastlivo2.yaml"

  local GS_WIDTH GS_HEIGHT GS_FX GS_FY GS_CX GS_CY
  GS_WIDTH="$(awk -v w="${CAM_WIDTH}" -v s="${CAM_SCALE}" 'BEGIN {printf "%d", int(w*s + 0.5)}')"
  GS_HEIGHT="$(awk -v h="${CAM_HEIGHT}" -v s="${CAM_SCALE}" 'BEGIN {printf "%d", int(h*s + 0.5)}')"
  GS_FX="$(awk -v x="${CAM_FX}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"
  GS_FY="$(awk -v x="${CAM_FY}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"
  GS_CX="$(awk -v x="${CAM_CX}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"
  GS_CY="$(awk -v x="${CAM_CY}" -v s="${CAM_SCALE}" 'BEGIN {printf "%.10f", x*s}')"

  IFS=',' read -r RCL0 RCL1 RCL2 RCL3 RCL4 RCL5 RCL6 RCL7 RCL8 <<< "${RCL}"
  IFS=',' read -r PCL0 PCL1 PCL2 <<< "${PCL}"

  mkdir -p "${runtime_dir}"

  cat > "${avia_file}" <<EOF
common:
  img_topic: "/left_camera/image"
  lid_topic: "/livox/lidar"
  imu_topic: "/livox/imu"
  img_en: 1
  lidar_en: 1
  ros_driver_bug_fix: false

extrin_calib:
  extrinsic_T: [0.04165, 0.02326, -0.0284]
  extrinsic_R: [1, 0, 0, 0, 1, 0, 0, 0, 1]
  Rcl: [${RCL0}, ${RCL1}, ${RCL2},
        ${RCL3}, ${RCL4}, ${RCL5},
        ${RCL6}, ${RCL7}, ${RCL8}]
  Pcl: [${PCL0}, ${PCL1}, ${PCL2}]

time_offset:
  imu_time_offset: 0.0
  img_time_offset: 0.1
  exposure_time_init: 0.0

preprocess:
  point_filter_num: 1
  filter_size_surf: 0.1
  lidar_type: 1
  scan_line: 6
  blind: 0.8

vio:
  max_iterations: 5
  outlier_threshold: 1000
  img_point_cov: 100
  patch_size: 8
  patch_pyrimid_level: 4
  normal_en: true
  raycast_en: false
  inverse_composition_en: false
  exposure_estimate_en: true
  inv_expo_cov: 0.1

imu:
  imu_en: true
  imu_int_frame: 30
  acc_cov: 0.5
  gyr_cov: 0.3
  b_acc_cov: 0.0001
  b_gyr_cov: 0.0001

lio:
  max_iterations: 5
  dept_err: 0.02
  beam_err: 0.05
  min_eigen_value: 0.0025
  voxel_size: 0.5
  max_layer: 2
  max_points_num: 50
  layer_init_num: [5, 5, 5, 5, 5]

local_map:
  map_sliding_en: false
  half_map_size: 100
  sliding_thresh: 8

uav:
  imu_rate_odom: false
  gravity_align_en: false

publish:
  dense_map_en: true
  pub_effect_point_en: false
  pub_plane_en: false
  pub_scan_num: 1
  blind_rgb_points: 0.0

evo:
  seq_name: "${bag_base}"
  pose_output_en: false

pcd_save:
  pcd_save_en: false
  type: 0
  colmap_output_en: false
  filter_size_pcd: 0.15
  interval: -1

image_save:
  img_save_en: false
  interval: 1
EOF

  cat > "${camera_file}" <<EOF
cam_model: Pinhole
cam_width: ${CAM_WIDTH}
cam_height: ${CAM_HEIGHT}
scale: ${CAM_SCALE}
cam_fx: ${CAM_FX}
cam_fy: ${CAM_FY}
cam_cx: ${CAM_CX}
cam_cy: ${CAM_CY}
cam_d0: ${CAM_D0}
cam_d1: ${CAM_D1}
cam_d2: ${CAM_D2}
cam_d3: ${CAM_D3}
EOF

  cat > "${bridge_file}" <<EOF
raw_image_topic: "/left_camera/image"
world_points_topic: "/cloud_registered"
imu_pose_topic: "/fastlivo2/vio_camera_pose"

output_image_topic: "/image_for_gs"
output_depth_topic: "/depth_for_gs"
output_pose_topic: "/pose_for_gs"
output_points_topic: "/points_for_gs"

world_frame_id: "map"
image_frame_id: "image_frame"
input_pose_is_camera_pose: true
camera_time_offset_sec: 0.1
sync_tolerance_sec: 0.15

width: ${GS_WIDTH}
height: ${GS_HEIGHT}
fx: ${GS_FX}
fy: ${GS_FY}
cx: ${GS_CX}
cy: ${GS_CY}

lidar_to_imu_translation: [0.04165, 0.02326, -0.0284]
lidar_to_imu_rotation: [1, 0, 0,
                        0, 1, 0,
                        0, 0, 1]

lidar_to_camera_translation: [${PCL0}, ${PCL1}, ${PCL2}]
lidar_to_camera_rotation: [${RCL0}, ${RCL1}, ${RCL2},
                           ${RCL3}, ${RCL4}, ${RCL5},
                           ${RCL6}, ${RCL7}, ${RCL8}]
EOF

  {
    echo "width: ${GS_WIDTH}"
    echo "height: ${GS_HEIGHT}"
    echo "fx: ${GS_FX}"
    echo "fy: ${GS_FY}"
    echo "cx: ${GS_CX}"
    echo "cy: ${GS_CY}"
    tail -n +8 "${REPO_ROOT}/config/fastlivo2.yaml"
  } > "${gs_file}"
}

index=0
start_enabled=1
if [[ -n "${START_FROM_BAG}" ]]; then
  start_enabled=0
fi
for bag in "${BAG_FILES[@]}"; do
  bag_base="$(basename "${bag}" .bag)"
  if [[ "${start_enabled}" -eq 0 ]]; then
    if [[ "${bag_base}" == "${START_FROM_BAG}" || "$(basename "${bag}")" == "${START_FROM_BAG}" ]]; then
      start_enabled=1
    else
      echo "[skip] ${bag_base} (waiting for START_FROM_BAG=${START_FROM_BAG})"
      continue
    fi
  fi

  index=$((index + 1))
  run_name="FAST-LIVO2_${bag_base}"
  result_dir="${REPO_ROOT}/result/${run_name}"
  runtime_dir="${RUNTIME_ROOT}/${run_name}"
  timing_file="${result_dir}/timing_summary.txt"
  metrics_file="${result_dir}/metrics.txt"
  cloud_file="${result_dir}/point_cloud.ply"
  renamed_cloud_file="${result_dir}/${run_name}.ply"

  set_profile_by_bag "${bag_base}"
  write_runtime_configs "${run_name}" "${bag_base}"

  rm -rf "${result_dir}"
  mkdir -p "${result_dir}"

  frontend_avia_cfg="/workspace/G-lic/.runtime_configs/${run_name}/avia.yaml"
  frontend_camera_cfg="/workspace/G-lic/.runtime_configs/${run_name}/camera_pinhole.yaml"
  bridge_cfg="/workspace/G-lic/.runtime_configs/${run_name}/bridge.yaml"
  gs_cfg="/workspace/G-lic/.runtime_configs/${run_name}/fastlivo2.yaml"

  echo
  echo "[$index/${#BAG_FILES[@]}] running bag: ${bag}"
  echo "run_name=${run_name}"
  echo "profile_rcl=${RCL}"
  echo "profile_pcl=${PCL}"

  status="ok"
  run_exit=0
  RUN_NAME="${run_name}" \
  BAG_PATH="${bag}" \
  FRONTEND_AVIA_CONFIG="${frontend_avia_cfg}" \
  FRONTEND_CAMERA_CONFIG="${frontend_camera_cfg}" \
  BRIDGE_CONFIG_FILE="${bridge_cfg}" \
  GS_CONFIG_PATH="${gs_cfg}" \
  "${SCRIPT_DIR}/run_fastlivo2_compose.sh" || run_exit=$?
  if [[ "${run_exit}" -eq 130 || "${run_exit}" -eq 143 ]]; then
    echo "Interrupted by user, stopping batch."
    exit "${run_exit}"
  fi
  if [[ "${run_exit}" -ne 0 ]]; then
    status="failed"
  fi

  total_wall_seconds=""
  training_view_psnr=""
  training_view_ssim=""
  training_view_lpips=""
  in_sequence_novel_view_psnr=""
  in_sequence_novel_view_ssim=""
  in_sequence_novel_view_lpips=""

  if [[ -f "${timing_file}" ]]; then
    total_wall_seconds="$(extract_summary_value "${timing_file}" "total_wall_seconds")"
  fi

  if [[ -f "${metrics_file}" ]]; then
    training_view_psnr="$(extract_metric "${metrics_file}" "training_view_psnr")"
    training_view_ssim="$(extract_metric "${metrics_file}" "training_view_ssim")"
    training_view_lpips="$(extract_metric "${metrics_file}" "training_view_lpips")"
    in_sequence_novel_view_psnr="$(extract_metric "${metrics_file}" "in_sequence_novel_view_psnr")"
    in_sequence_novel_view_ssim="$(extract_metric "${metrics_file}" "in_sequence_novel_view_ssim")"
    in_sequence_novel_view_lpips="$(extract_metric "${metrics_file}" "in_sequence_novel_view_lpips")"
  else
    status="failed"
  fi

  if [[ -f "${cloud_file}" ]]; then
    mv -f "${cloud_file}" "${renamed_cloud_file}"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${run_name}" "${bag}" "${status}" "${total_wall_seconds}" \
    "${training_view_psnr}" "${training_view_ssim}" "${training_view_lpips}" \
    "${in_sequence_novel_view_psnr}" "${in_sequence_novel_view_ssim}" "${in_sequence_novel_view_lpips}" \
    >> "${MASTER_SUMMARY}"

  echo "status=${status}"
  echo "timing_file=${timing_file}"
  echo "metrics_file=${metrics_file}"
done

if [[ "${index}" -eq 0 ]]; then
  echo "No bag executed. Check START_FROM_BAG=${START_FROM_BAG}" >&2
  exit 1
fi

echo
echo "all bags finished"
echo "master_summary=${MASTER_SUMMARY}"
