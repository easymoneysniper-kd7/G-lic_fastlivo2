# FAST-LIVO2 GS Bridge

This bridge keeps the `Gaussian-LIC` backend topics unchanged while replacing
the Coco-LIC frontend with `FAST-LIVO2`.

It consumes:

- a raw camera image topic
- FAST-LIVO2 world-frame RGB points
- a small FAST-LIVO2 VIO-time IMU pose topic

It republishes:

- `/image_for_gs`
- `/depth_for_gs`
- `/pose_for_gs`
- `/points_for_gs`

Key design choices:

- The bridge computes `T_map_cam` explicitly from the FAST-LIVO2 IMU pose and
  the LiDAR-to-IMU / LiDAR-to-camera extrinsics.
- Depth is generated as a sparse `TYPE_32FC1` image by projecting the world
  RGB cloud into the current camera frame.
- Topic names stay compatible with the existing Gaussian-LIC backend.
- The backend result directory layout is unchanged.
