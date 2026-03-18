#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include <Eigen/Dense>

#include <cv_bridge/cv_bridge.h>
#include <geometry_msgs/PoseStamped.h>
#include <image_transport/image_transport.h>
#include <pcl/point_cloud.h>
#include <pcl/point_types.h>
#include <pcl_conversions/pcl_conversions.h>
#include <ros/ros.h>
#include <sensor_msgs/Image.h>
#include <sensor_msgs/PointCloud2.h>

namespace
{
Eigen::Matrix3d matrixFromRowMajor(const std::vector<double> &values, const Eigen::Matrix3d &fallback)
{
    if (values.size() != 9)
    {
        return fallback;
    }

    Eigen::Matrix3d mat;
    mat << values[0], values[1], values[2],
           values[3], values[4], values[5],
           values[6], values[7], values[8];
    return mat;
}

Eigen::Vector3d vectorFromList(const std::vector<double> &values, const Eigen::Vector3d &fallback)
{
    if (values.size() != 3)
    {
        return fallback;
    }
    return Eigen::Vector3d(values[0], values[1], values[2]);
}
} // namespace

class FastLivo2GsBridge
{
public:
    FastLivo2GsBridge()
        : nh_(),
          pnh_("~"),
          it_(nh_)
    {
        loadParams();

        image_sub_ = it_.subscribe(raw_image_topic_, 100, &FastLivo2GsBridge::imageCallback, this);
        points_sub_ = nh_.subscribe(world_points_topic_, 100, &FastLivo2GsBridge::pointsCallback, this);
        imu_pose_sub_ = nh_.subscribe(imu_pose_topic_, 100, &FastLivo2GsBridge::imuPoseCallback, this);

        image_pub_ = it_.advertise(output_image_topic_, 10);
        depth_pub_ = it_.advertise(output_depth_topic_, 10);
        pose_pub_ = nh_.advertise<geometry_msgs::PoseStamped>(output_pose_topic_, 10);
        points_pub_ = nh_.advertise<sensor_msgs::PointCloud2>(output_points_topic_, 10);
    }

private:
    struct ImageEntry
    {
        ros::Time stamp;
        cv::Mat image_bgr;
    };

    void loadParams()
    {
        pnh_.param<std::string>("raw_image_topic", raw_image_topic_, std::string("/left_camera/image"));
        pnh_.param<std::string>("world_points_topic", world_points_topic_, std::string("/cloud_registered"));
        pnh_.param<std::string>("imu_pose_topic", imu_pose_topic_, std::string("/fastlivo2/vio_imu_pose"));
        pnh_.param<std::string>("output_image_topic", output_image_topic_, std::string("/image_for_gs"));
        pnh_.param<std::string>("output_depth_topic", output_depth_topic_, std::string("/depth_for_gs"));
        pnh_.param<std::string>("output_pose_topic", output_pose_topic_, std::string("/pose_for_gs"));
        pnh_.param<std::string>("output_points_topic", output_points_topic_, std::string("/points_for_gs"));
        pnh_.param<std::string>("world_frame_id", world_frame_id_, std::string("map"));
        pnh_.param<std::string>("image_frame_id", image_frame_id_, std::string("image_frame"));
        pnh_.param<double>("camera_time_offset_sec", camera_time_offset_sec_, 0.0);
        pnh_.param<double>("sync_tolerance_sec", sync_tolerance_sec_, 0.01);
        pnh_.param<int>("width", width_, 640);
        pnh_.param<int>("height", height_, 512);
        pnh_.param<double>("fx", fx_, 0.0);
        pnh_.param<double>("fy", fy_, 0.0);
        pnh_.param<double>("cx", cx_, 0.0);
        pnh_.param<double>("cy", cy_, 0.0);

        std::vector<double> lidar_to_imu_t;
        std::vector<double> lidar_to_imu_r;
        std::vector<double> lidar_to_camera_t;
        std::vector<double> lidar_to_camera_r;
        pnh_.getParam("lidar_to_imu_translation", lidar_to_imu_t);
        pnh_.getParam("lidar_to_imu_rotation", lidar_to_imu_r);
        pnh_.getParam("lidar_to_camera_translation", lidar_to_camera_t);
        pnh_.getParam("lidar_to_camera_rotation", lidar_to_camera_r);

        const Eigen::Vector3d t_li = vectorFromList(lidar_to_imu_t, Eigen::Vector3d::Zero());
        const Eigen::Matrix3d r_li = matrixFromRowMajor(lidar_to_imu_r, Eigen::Matrix3d::Identity());
        const Eigen::Vector3d p_cl = vectorFromList(lidar_to_camera_t, Eigen::Vector3d::Zero());
        const Eigen::Matrix3d r_cl = matrixFromRowMajor(lidar_to_camera_r, Eigen::Matrix3d::Identity());

        const Eigen::Matrix3d r_il = r_li.transpose();
        const Eigen::Vector3d p_il = -r_il * t_li;
        r_ci_ = r_cl * r_il;
        p_ci_ = r_cl * p_il + p_cl;
    }

    void imageCallback(const sensor_msgs::ImageConstPtr &msg)
    {
        cv_bridge::CvImageConstPtr cv_ptr;
        try
        {
            cv_ptr = cv_bridge::toCvShare(msg, sensor_msgs::image_encodings::BGR8);
        }
        catch (const cv_bridge::Exception &e)
        {
            ROS_ERROR_STREAM_THROTTLE(1.0, "[fastlivo2_gs_bridge] Failed to convert image: " << e.what());
            return;
        }

        ImageEntry entry;
        entry.stamp = msg->header.stamp + ros::Duration(camera_time_offset_sec_);
        entry.image_bgr = cv_ptr->image;
        if (entry.image_bgr.cols != width_ || entry.image_bgr.rows != height_)
        {
            cv::resize(entry.image_bgr, entry.image_bgr, cv::Size(width_, height_), 0.0, 0.0, cv::INTER_LINEAR);
        }

        std::lock_guard<std::mutex> lock(mutex_);
        image_buf_.push_back(std::move(entry));
        trimBuffers();
        tryPublishLocked();
    }

    void pointsCallback(const sensor_msgs::PointCloud2ConstPtr &msg)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        points_buf_.push_back(msg);
        trimBuffers();
        tryPublishLocked();
    }

    void imuPoseCallback(const geometry_msgs::PoseStampedConstPtr &msg)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        imu_pose_buf_.push_back(msg);
        trimBuffers();
        tryPublishLocked();
    }

    void trimBuffers()
    {
        constexpr std::size_t kMaxQueueSize = 50;
        while (image_buf_.size() > kMaxQueueSize) image_buf_.pop_front();
        while (points_buf_.size() > kMaxQueueSize) points_buf_.pop_front();
        while (imu_pose_buf_.size() > kMaxQueueSize) imu_pose_buf_.pop_front();
    }

    void tryPublishLocked()
    {
        while (!image_buf_.empty() && !points_buf_.empty() && !imu_pose_buf_.empty())
        {
            const ros::Time base_stamp = imu_pose_buf_.front()->header.stamp;
            const double base_time = base_stamp.toSec();

            while (!image_buf_.empty() && image_buf_.front().stamp.toSec() < base_time - sync_tolerance_sec_)
            {
                image_buf_.pop_front();
            }
            while (!points_buf_.empty() && points_buf_.front()->header.stamp.toSec() < base_time - sync_tolerance_sec_)
            {
                points_buf_.pop_front();
            }

            if (image_buf_.empty() || points_buf_.empty())
            {
                return;
            }

            const double image_time = image_buf_.front().stamp.toSec();
            const double point_time = points_buf_.front()->header.stamp.toSec();
            if (image_time > base_time + sync_tolerance_sec_ || point_time > base_time + sync_tolerance_sec_)
            {
                imu_pose_buf_.pop_front();
                continue;
            }

            const ImageEntry image_entry = image_buf_.front();
            const sensor_msgs::PointCloud2ConstPtr points_msg = points_buf_.front();
            const geometry_msgs::PoseStampedConstPtr imu_pose_msg = imu_pose_buf_.front();
            image_buf_.pop_front();
            points_buf_.pop_front();
            imu_pose_buf_.pop_front();

            publishAligned(image_entry, points_msg, imu_pose_msg);
        }
    }

    void publishAligned(const ImageEntry &image_entry,
                        const sensor_msgs::PointCloud2ConstPtr &points_msg,
                        const geometry_msgs::PoseStampedConstPtr &imu_pose_msg)
    {
        pcl::PointCloud<pcl::PointXYZRGB>::Ptr cloud(new pcl::PointCloud<pcl::PointXYZRGB>);
        pcl::fromROSMsg(*points_msg, *cloud);
        if (cloud->empty())
        {
            ROS_WARN_STREAM_THROTTLE(1.0, "[fastlivo2_gs_bridge] Skip empty world point cloud.");
            return;
        }

        const auto &q_msg = imu_pose_msg->pose.orientation;
        const auto &t_msg = imu_pose_msg->pose.position;
        Eigen::Quaterniond q_wi(q_msg.w, q_msg.x, q_msg.y, q_msg.z);
        q_wi.normalize();
        const Eigen::Matrix3d r_wi = q_wi.toRotationMatrix();
        const Eigen::Vector3d p_wi(t_msg.x, t_msg.y, t_msg.z);

        const Eigen::Matrix3d r_wc = r_wi * r_ci_.transpose();
        const Eigen::Vector3d p_wc = p_wi - r_wi * r_ci_.transpose() * p_ci_;
        const Eigen::Matrix3d r_cw = r_wc.transpose();
        const Eigen::Vector3d p_cw = -r_cw * p_wc;

        geometry_msgs::PoseStamped pose_out;
        pose_out.header.stamp = imu_pose_msg->header.stamp;
        pose_out.header.frame_id = world_frame_id_;
        Eigen::Quaterniond q_wc(r_wc);
        q_wc.normalize();
        pose_out.pose.position.x = p_wc.x();
        pose_out.pose.position.y = p_wc.y();
        pose_out.pose.position.z = p_wc.z();
        pose_out.pose.orientation.x = q_wc.x();
        pose_out.pose.orientation.y = q_wc.y();
        pose_out.pose.orientation.z = q_wc.z();
        pose_out.pose.orientation.w = q_wc.w();

        cv_bridge::CvImage image_out;
        image_out.header.stamp = imu_pose_msg->header.stamp;
        image_out.header.frame_id = image_frame_id_;
        image_out.encoding = sensor_msgs::image_encodings::BGR8;
        image_out.image = image_entry.image_bgr;

        cv::Mat depth = cv::Mat::zeros(height_, width_, CV_32FC1);
        for (const auto &pt : cloud->points)
        {
            const Eigen::Vector3d p_w(pt.x, pt.y, pt.z);
            const Eigen::Vector3d p_c = r_cw * p_w + p_cw;
            const double depth_value = p_c.z();
            if (depth_value <= 0.0)
            {
                continue;
            }

            const double u = fx_ * (p_c.x() / depth_value) + cx_;
            const double v = fy_ * (p_c.y() / depth_value) + cy_;
            const int u_i = static_cast<int>(std::round(u));
            const int v_i = static_cast<int>(std::round(v));
            if (u_i < 0 || u_i >= width_ || v_i < 0 || v_i >= height_)
            {
                continue;
            }

            float &pixel_depth = depth.at<float>(v_i, u_i);
            if (pixel_depth == 0.0f || depth_value < pixel_depth)
            {
                pixel_depth = static_cast<float>(depth_value);
            }
        }

        cv_bridge::CvImage depth_out;
        depth_out.header.stamp = imu_pose_msg->header.stamp;
        depth_out.header.frame_id = image_frame_id_;
        depth_out.encoding = sensor_msgs::image_encodings::TYPE_32FC1;
        depth_out.image = depth;

        sensor_msgs::PointCloud2 points_out = *points_msg;
        points_out.header.stamp = imu_pose_msg->header.stamp;
        points_out.header.frame_id = world_frame_id_;

        pose_pub_.publish(pose_out);
        image_pub_.publish(image_out.toImageMsg());
        depth_pub_.publish(depth_out.toImageMsg());
        points_pub_.publish(points_out);
    }

    ros::NodeHandle nh_;
    ros::NodeHandle pnh_;
    image_transport::ImageTransport it_;

    image_transport::Subscriber image_sub_;
    ros::Subscriber points_sub_;
    ros::Subscriber imu_pose_sub_;

    image_transport::Publisher image_pub_;
    image_transport::Publisher depth_pub_;
    ros::Publisher pose_pub_;
    ros::Publisher points_pub_;

    std::mutex mutex_;
    std::deque<ImageEntry> image_buf_;
    std::deque<sensor_msgs::PointCloud2ConstPtr> points_buf_;
    std::deque<geometry_msgs::PoseStampedConstPtr> imu_pose_buf_;

    std::string raw_image_topic_;
    std::string world_points_topic_;
    std::string imu_pose_topic_;
    std::string output_image_topic_;
    std::string output_depth_topic_;
    std::string output_pose_topic_;
    std::string output_points_topic_;
    std::string world_frame_id_;
    std::string image_frame_id_;

    double camera_time_offset_sec_ = 0.0;
    double sync_tolerance_sec_ = 0.01;
    int width_ = 640;
    int height_ = 512;
    double fx_ = 0.0;
    double fy_ = 0.0;
    double cx_ = 0.0;
    double cy_ = 0.0;

    Eigen::Matrix3d r_ci_ = Eigen::Matrix3d::Identity();
    Eigen::Vector3d p_ci_ = Eigen::Vector3d::Zero();
};

int main(int argc, char **argv)
{
    ros::init(argc, argv, "fastlivo2_gs_bridge");
    FastLivo2GsBridge bridge;
    ros::spin();
    return 0;
}
