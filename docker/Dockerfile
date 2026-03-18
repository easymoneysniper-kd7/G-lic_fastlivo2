FROM nvidia/cuda:12.8.0-devel-ubuntu20.04

ARG DEBIAN_FRONTEND=noninteractive
ARG ROS_DISTRO=noetic
ARG ROS_APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ros/ubuntu
ARG UBUNTU_APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu
ARG OPENCV_VERSION=4.7.0
ARG LIBTORCH_URL=https://download.pytorch.org/libtorch/cu128/libtorch-cxx11-abi-shared-with-deps-2.7.1%2Bcu128.zip
ARG TENSORRT_PACKAGES="libnvinfer-dev libnvinfer-plugin-dev libnvonnxparsers-dev libnvinfer-bin"

ENV ROS_DISTRO=${ROS_DISTRO} \
    CUDA_HOME=/usr/local/cuda \
    CUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda \
    CATKIN_WS=/opt/gaussian_lic_ws \
    OPENCV_PREFIX=/opt/opencv/opencv-${OPENCV_VERSION} \
    OpenCV_DIR=/opt/opencv/opencv-${OPENCV_VERSION}/lib/cmake/opencv4 \
    TENSORRT_ROOT=/usr \
    LIBTORCH_ROOT=/opt/libtorch

SHELL ["/bin/bash", "-lc"]

RUN sed -i "s|http://archive.ubuntu.com/ubuntu|${UBUNTU_APT_MIRROR}|g; s|http://security.ubuntu.com/ubuntu|${UBUNTU_APT_MIRROR}|g" /etc/apt/sources.list \
 && printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' > /etc/apt/apt.conf.d/99network-retries

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg2 \
    lsb-release \
    software-properties-common \
    wget \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc \
    | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] ${ROS_APT_MIRROR} focal main" > /etc/apt/sources.list.d/ros1.list

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    ninja-build \
    pkg-config \
    rsync \
    unzip \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    python3-numpy \
    python3-empy \
    python3-catkin-tools \
    libboost-all-dev \
    libceres-dev \
    libeigen3-dev \
    libffi-dev \
    libgflags-dev \
    libgoogle-glog-dev \
    libgtk2.0-dev \
    libjpeg-dev \
    libopenblas-dev \
    liblapack-dev \
    libpcl-dev \
    libsuitesparse-dev \
    libtbb-dev \
    libtiff-dev \
    libyaml-cpp-dev \
    ros-${ROS_DISTRO}-catkin \
    ros-${ROS_DISTRO}-cv-bridge \
    ros-${ROS_DISTRO}-eigen-conversions \
    ros-${ROS_DISTRO}-geometry-msgs \
    ros-${ROS_DISTRO}-image-transport \
    ros-${ROS_DISTRO}-message-generation \
    ros-${ROS_DISTRO}-nav-msgs \
    ros-${ROS_DISTRO}-pcl-conversions \
    ros-${ROS_DISTRO}-pcl-ros \
    ros-${ROS_DISTRO}-rosbag \
    ros-${ROS_DISTRO}-roscpp \
    ros-${ROS_DISTRO}-roslib \
    ros-${ROS_DISTRO}-rospy \
    ros-${ROS_DISTRO}-sensor-msgs \
    ros-${ROS_DISTRO}-std-msgs \
    ros-${ROS_DISTRO}-tf \
    ros-${ROS_DISTRO}-visualization-msgs \
    ${TENSORRT_PACKAGES} \
 && rm -rf /var/lib/apt/lists/*

COPY docker/scripts /opt/gaussian-lic-docker/scripts
COPY . /opt/gaussian-lic-src

RUN chmod +x /opt/gaussian-lic-docker/scripts/*.sh \
 && /opt/gaussian-lic-docker/scripts/install_opencv.sh "${OPENCV_VERSION}"

RUN rm -rf "${LIBTORCH_ROOT}" \
 && for attempt in 1 2 3; do \
      rm -f /tmp/libtorch.zip; \
      wget -q --tries=5 --timeout=30 --waitretry=5 "${LIBTORCH_URL}" -O /tmp/libtorch.zip; \
      rm -rf "${LIBTORCH_ROOT}"; \
      (unzip -qo /tmp/libtorch.zip -d /opt || true); \
      if [[ -f "${LIBTORCH_ROOT}/share/cmake/Torch/TorchConfig.cmake" \
         && -f "${LIBTORCH_ROOT}/lib/libtorch.so" \
         && -f "${LIBTORCH_ROOT}/lib/libc10.so" ]]; then \
        break; \
      fi; \
      if [[ "${attempt}" -eq 3 ]]; then \
        echo "Failed to provision LibTorch from ${LIBTORCH_URL}" >&2; \
        exit 1; \
      fi; \
      sleep 5; \
    done \
 && rm -f /tmp/libtorch.zip

ENV Torch_DIR=${LIBTORCH_ROOT}/share/cmake/Torch \
    CMAKE_PREFIX_PATH=${LIBTORCH_ROOT} \
    LD_LIBRARY_PATH=${LIBTORCH_ROOT}/lib

RUN /opt/gaussian-lic-docker/scripts/build_workspace.sh

RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /etc/bash.bashrc \
 && echo "if [ -f ${CATKIN_WS}/devel/setup.bash ]; then source ${CATKIN_WS}/devel/setup.bash; fi" >> /etc/bash.bashrc

WORKDIR ${CATKIN_WS}

ENTRYPOINT ["/opt/gaussian-lic-docker/scripts/entrypoint.sh"]
CMD ["bash"]
