# Gaussian-LIC Docker

This container layout targets a ROS Noetic workspace and keeps the project
source in this repository while cloning Coco-LIC and `livox_ros_driver` during
the image build.

Key choices:

- Base image: `nvidia/cuda:12.8.0-devel-ubuntu20.04`
- ROS: Noetic on Ubuntu 20.04
- OpenCV: 4.7.0 built from source with CUDA enabled
- PyTorch: installed from the official `cu128` wheel index
- TensorRT: installed from NVIDIA apt packages in the CUDA repo

Build the image:

```bash
cd /home/cw/project/yjh_workspace/G-lic
./docker/build.sh
```

Run the FAST-LIVO2 frontend + bridge + Gaussian-LIC backend with one command:

```bash
cd /home/cw/project/yjh_workspace/G-lic
./docker/run_fastlivo2_compose.sh
```

The default bag is `/home/cw/project/yjh_workspace/data/CBD_Building_01.bag`.
You can override it with:

```bash
BAG_PATH=/home/cw/project/yjh_workspace/data/CBD_Building_01.bag ./docker/run_fastlivo2_compose.sh
```

The script uses `docker compose`, saves per-service logs into the per-run result
folder, writes a timing summary to `timing_summary.txt`, and tears the stack
down after the run finishes.

Run an interactive container:

```bash
cd /home/cw/project/yjh_workspace/G-lic
./docker/run.sh
```

Inside the container the catkin workspace lives at:

```bash
/opt/gaussian_lic_ws
```

Useful locations:

- `Gaussian-LIC`: `/opt/gaussian_lic_ws/src/Gaussian-LIC`
- `Coco-LIC`: `/opt/gaussian_lic_ws/src/Coco-LIC`
- `livox_ros_driver`: `/opt/gaussian_lic_ws/src/livox_ros_driver`

If you want to export the image after everything is working:

```bash
docker save -o gaussian-lic-cuda128.tar gaussian-lic:cuda128
```

And load it on another machine:

```bash
docker load -i gaussian-lic-cuda128.tar
```

Manage per-run result folders on the host:

```bash
cd /home/cw/project/yjh_workspace/G-lic
./docker/resultctl.sh list
./docker/resultctl.sh rename 20260318_132450_CBD_Building_01 cbd_depth_on
./docker/resultctl.sh delete cbd_depth_on
./docker/resultctl.sh fix-ownership all
```
