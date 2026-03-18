cmake_minimum_required(VERSION 3.0.2)
project(gaussian_lic)

SET(CMAKE_BUILD_TYPE "Release")
# SET(CMAKE_CXX_FLAGS_RELEASE "$ENV{CXXFLAGS} -O3")
set(CMAKE_CXX_STANDARD 17)
option(GAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER "Build TensorRT depth completion support" ON)
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -Wall -g -Wno-sign-compare -Wno-unused -Wno-comment -pthread")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -msse4.2")
set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} --std=c++17 -Wno-deprecated-gpu-targets -Xcudafe --diag_suppress=20012 -Xcudafe --diag_suppress=549")

find_package(catkin REQUIRED COMPONENTS
  roscpp
  rospy
  roslib
  std_msgs
  cv_bridge
  image_transport
  pcl_conversions
  pcl_ros
  std_msgs
  nav_msgs
  sensor_msgs
  geometry_msgs
  tf
  eigen_conversions
)

# Allow containerized builds to override the legacy README paths.
if(DEFINED ENV{OpenCV_DIR} AND NOT "$ENV{OpenCV_DIR}" STREQUAL "")
  set(OpenCV_DIR "$ENV{OpenCV_DIR}")
else()
  set(OpenCV_DIR "$ENV{HOME}/Software/opencv/opencv-4.7.0/build")
endif()
find_package(OpenCV 4 REQUIRED)

if(DEFINED ENV{Torch_DIR} AND NOT "$ENV{Torch_DIR}" STREQUAL "")
  set(Torch_DIR "$ENV{Torch_DIR}")
else()
  set(Torch_DIR "$ENV{HOME}/Software/libtorch/share/cmake/Torch")
endif()
find_package(Torch REQUIRED)

if(DEFINED ENV{TENSORRT_ROOT} AND NOT "$ENV{TENSORRT_ROOT}" STREQUAL "")
  set(TENSORRT_ROOT "$ENV{TENSORRT_ROOT}")
else()
  set(TENSORRT_ROOT "$ENV{HOME}/Software/TensorRT-8.6.1.6")
endif()

if(EXISTS "${TENSORRT_ROOT}/include/NvInfer.h")
  set(TENSORRT_INCLUDE_DIR "${TENSORRT_ROOT}/include")
elseif(EXISTS "${TENSORRT_ROOT}/include/x86_64-linux-gnu/NvInfer.h")
  set(TENSORRT_INCLUDE_DIR "${TENSORRT_ROOT}/include/x86_64-linux-gnu")
elseif(EXISTS "/usr/include/x86_64-linux-gnu/NvInfer.h")
  set(TENSORRT_INCLUDE_DIR "/usr/include/x86_64-linux-gnu")
else()
  set(TENSORRT_INCLUDE_DIR "${TENSORRT_ROOT}/include")
endif()

if(EXISTS "${TENSORRT_ROOT}/lib/libnvinfer.so")
  set(TENSORRT_LIB_DIR "${TENSORRT_ROOT}/lib")
elseif(EXISTS "${TENSORRT_ROOT}/lib64/libnvinfer.so")
  set(TENSORRT_LIB_DIR "${TENSORRT_ROOT}/lib64")
elseif(EXISTS "${TENSORRT_ROOT}/lib/x86_64-linux-gnu/libnvinfer.so")
  set(TENSORRT_LIB_DIR "${TENSORRT_ROOT}/lib/x86_64-linux-gnu")
elseif(EXISTS "/usr/lib/x86_64-linux-gnu/libnvinfer.so")
  set(TENSORRT_LIB_DIR "/usr/lib/x86_64-linux-gnu")
else()
  set(TENSORRT_LIB_DIR "${TENSORRT_ROOT}/lib")
endif()

if(DEFINED ENV{CUDA_TOOLKIT_ROOT_DIR} AND NOT "$ENV{CUDA_TOOLKIT_ROOT_DIR}" STREQUAL "")
  set(CUDA_TOOLKIT_ROOT_DIR "$ENV{CUDA_TOOLKIT_ROOT_DIR}")
elseif(DEFINED ENV{CUDA_HOME} AND NOT "$ENV{CUDA_HOME}" STREQUAL "")
  set(CUDA_TOOLKIT_ROOT_DIR "$ENV{CUDA_HOME}")
else()
  set(CUDA_TOOLKIT_ROOT_DIR "/usr/local/cuda")
endif()
set(CUDA_INCLUDE_DIRS "${CUDA_TOOLKIT_ROOT_DIR}/include")
set(CUDA_LIB_DIR "${CUDA_TOOLKIT_ROOT_DIR}/lib64")
find_package(CUDA REQUIRED)
find_library(FFI_LIB ffi)
find_library(CUDA_CUDART_LIB cudart HINTS ${CUDA_LIB_DIR} REQUIRED)
find_library(TENSORRT_NVINFER_LIB nvinfer HINTS ${TENSORRT_LIB_DIR} REQUIRED)
find_library(TENSORRT_PLUGIN_LIB nvinfer_plugin HINTS ${TENSORRT_LIB_DIR} REQUIRED)

find_package(PkgConfig REQUIRED)
pkg_check_modules(YAML_CPP REQUIRED yaml-cpp>=0.5)

find_package(Python3 COMPONENTS Interpreter Development NumPy REQUIRED)

catkin_package(
#  INCLUDE_DIRS include
#  LIBRARIES gaussian_lic
#  CATKIN_DEPENDS roscpp rospy std_msgs
#  DEPENDS system_lib
)

include_directories(
# include
  src
  ${catkin_INCLUDE_DIRS}
  ${OpenCV_INCLUDE_DIRS}
  ${YAML_INCLUDE_DIRS}
  ${Python3_INCLUDE_DIRS}
  ${TENSORRT_INCLUDE_DIR}
  ${CUDA_INCLUDE_DIRS}
)

if(GAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER)
  set(GAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER_VALUE 1)
else()
  set(GAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER_VALUE 0)
endif()

set(GS_MAPPING_SOURCES
    ${PROJECT_SOURCE_DIR}/src/mapping.cpp 
    ${PROJECT_SOURCE_DIR}/src/gaussian.cpp
    ${PROJECT_SOURCE_DIR}/src/tinyply.cpp
    ${PROJECT_SOURCE_DIR}/src/simple-knn/spatial.cu
    ${PROJECT_SOURCE_DIR}/src/simple-knn/simple_knn.cu
    ${PROJECT_SOURCE_DIR}/src/fused-ssim/ssim.cu
    ${PROJECT_SOURCE_DIR}/src/rasterizer/renderer.cpp
    ${PROJECT_SOURCE_DIR}/src/rasterizer/rasterizer.cpp
    ${PROJECT_SOURCE_DIR}/src/rasterizer/rasterize_points.cu
    ${PROJECT_SOURCE_DIR}/src/rasterizer/cuda_rasterizer/adam.cu
    ${PROJECT_SOURCE_DIR}/src/rasterizer/cuda_rasterizer/forward.cu
    ${PROJECT_SOURCE_DIR}/src/rasterizer/cuda_rasterizer/backward.cu
    ${PROJECT_SOURCE_DIR}/src/rasterizer/cuda_rasterizer/rasterizer_impl.cu)

if(GAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER)
  list(APPEND GS_MAPPING_SOURCES ${PROJECT_SOURCE_DIR}/src/depth_completer.cpp)
endif()

add_executable(gs_mapping ${GS_MAPPING_SOURCES})
target_compile_definitions(gs_mapping PRIVATE GAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER=${GAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER_VALUE})
target_link_libraries(gs_mapping 
                      ${catkin_LIBRARIES} 
                      ${OpenCV_LIBS} 
                      ${TORCH_LIBRARIES} 
                      ${YAML_CPP_LIBRARIES} 
                      ${Python3_LIBRARIES}
                      ${FFI_LIB}
                      ${CUDA_CUDART_LIB})

if(GAUSSIAN_LIC_ENABLE_DEPTH_COMPLETER)
  target_link_libraries(gs_mapping
                        ${TENSORRT_NVINFER_LIB}
                        ${TENSORRT_PLUGIN_LIB})
endif()
