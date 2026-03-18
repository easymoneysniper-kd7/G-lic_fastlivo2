/*
 * Gaussian-LIC2: LiDAR-Inertial-Camera Gaussian Splatting SLAM
 * Copyright (C) 2025 Xiaolei Lang
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include <fstream>
#include <stdexcept>
#include "cuda_runtime_api.h"
#include "depth_completer.h"

void DepthCompleter::Logger::log(nvinfer1::ILogger::Severity severity, const char* msg) noexcept 
{
    if (severity <= nvinfer1::ILogger::Severity::kWARNING) 
    {
        std::cout << "[TensorRT] " << msg << std::endl;
    }
}

template <typename T> 
void DepthCompleter::InferDeleter::operator()(T* obj) const 
{ 
    if (obj) delete obj; 
}

DepthCompleter::DepthCompleter(const std::string& enginePath, 
                               int inputWidth, int inputHeight)
    : mInputWidth(inputWidth), 
      mInputHeight(inputHeight) 
{
    initEngine(enginePath);
}

DepthCompleter::~DepthCompleter() 
{
    mContext.reset();
    mEngine.reset();
    mRuntime.reset();
    
    for (auto& buf : mDeviceBuffers) 
    {
        if (buf) cudaFree(buf);
    }
}

cv::Mat DepthCompleter::complete(const cv::Mat& rgbImage, const cv::Mat& depthImage) 
{
    cv::Mat processedRgb, processedDepth;
    // rgbImage.convertTo(processedRgb, CV_32F, 1.0f / 255.0f);
    processedRgb = rgbImage;
    depthImage.convertTo(processedDepth, CV_32F, 1.0f / 200.0f);
    prepareInputs(processedRgb, processedDepth);
    
    if (!mContext->executeV2(mDeviceBuffers.data())) 
    {
        throw std::runtime_error("Failed to execute inference");
    }
    
    return processOutput();
}

void DepthCompleter::initEngine(const std::string& enginePath) 
{
    auto engineData = readFile(enginePath);
    mRuntime.reset(nvinfer1::createInferRuntime(mLogger));
    mEngine.reset(mRuntime->deserializeCudaEngine(engineData.data(), engineData.size()));
    if (!mEngine) throw std::runtime_error("Failed to deserialize engine");
    mContext.reset(mEngine->createExecutionContext());
    if (!mContext) throw std::runtime_error("Failed to create execution context");
    
    allocateBuffers();
}

std::vector<char> DepthCompleter::readFile(const std::string& filename) 
{
    std::ifstream file(filename, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("Unable to open file: " + filename);
    
    size_t size = file.tellg();
    file.seekg(0, std::ios::beg);
    
    std::vector<char> buffer(size);
    if (!file.read(buffer.data(), size)) throw std::runtime_error("Failed to read file: " + filename);
    
    return buffer;
}

void DepthCompleter::allocateBuffers() 
{
    auto setInputShape = [this](char const* tensorName, int channels)
    {
        nvinfer1::Dims dims{};
        dims.nbDims = 4;
        dims.d[0] = 1;
        dims.d[1] = channels;
        dims.d[2] = mInputHeight;
        dims.d[3] = mInputWidth;
        if (!mContext->setInputShape(tensorName, dims))
        {
            throw std::runtime_error(std::string("Failed to set TensorRT input shape for tensor: ") + tensorName);
        }
    };

    setInputShape("rgb", 3);
    setInputShape("depth", 1);
    setInputShape("mask", 1);

    const int numTensors = mEngine->getNbIOTensors();
    mTensorNames.resize(numTensors);
    mDeviceBuffers.resize(numTensors, nullptr);
    mHostBuffers.resize(numTensors);

    for (int i = 0; i < numTensors; i++) 
    {
        char const* tensorName = mEngine->getIOTensorName(i);
        if (tensorName == nullptr)
        {
            throw std::runtime_error("Encountered unnamed TensorRT IO tensor");
        }
        mTensorNames[i] = tensorName;

        if (mTensorNames[i] == "rgb") mRgbTensorIndex = i;
        else if (mTensorNames[i] == "depth") mDepthTensorIndex = i;
        else if (mTensorNames[i] == "mask") mMaskTensorIndex = i;
        else if (mTensorNames[i] == "pred") mOutputTensorIndex = i;

        nvinfer1::Dims dims = mContext->getTensorShape(tensorName);
        bool has_dynamic_dim = false;
        for (int dim = 0; dim < dims.nbDims; ++dim)
        {
            if (dims.d[dim] < 0)
            {
                has_dynamic_dim = true;
                break;
            }
        }
        if (has_dynamic_dim && mTensorNames[i] == "pred")
        {
            dims.nbDims = 4;
            dims.d[0] = 1;
            dims.d[1] = 1;
            dims.d[2] = mInputHeight;
            dims.d[3] = mInputWidth;
        }

        size_t elementCount = volume(dims);
        if (elementCount == 0)
        {
            throw std::runtime_error(std::string("TensorRT tensor has invalid shape: ") + tensorName);
        }
        mHostBuffers[i].resize(elementCount);
        if (cudaMalloc(&mDeviceBuffers[i], elementCount * sizeof(float)) != cudaSuccess) 
        {
            throw std::runtime_error("CUDA memory allocation failed");
        }
    }

    if (mRgbTensorIndex < 0 || mDepthTensorIndex < 0 || mMaskTensorIndex < 0 || mOutputTensorIndex < 0)
    {
        throw std::runtime_error("Failed to locate expected TensorRT IO tensors: rgb/depth/mask/pred");
    }
}

size_t DepthCompleter::volume(const nvinfer1::Dims& dims) 
{
    size_t v = 1;
    for (int i = 0; i < dims.nbDims; i++) v *= dims.d[i];
    return v;
}

void DepthCompleter::prepareInputs(const cv::Mat& rgbImage, const cv::Mat& depthImage) 
{
    // RGB (HWC -> CHW)
    std::vector<cv::Mat> rgbChannels(3);
    cv::split(rgbImage, rgbChannels);
    for (int c = 0; c < 3; c++) 
    {
        std::memcpy(mHostBuffers[mRgbTensorIndex].data() + c * mInputHeight * mInputWidth,
                    rgbChannels[c].data,
                    mInputHeight * mInputWidth * sizeof(float));
    }

    // Depth
    std::memcpy(mHostBuffers[mDepthTensorIndex].data(), depthImage.data, mInputHeight * mInputWidth * sizeof(float));

    // Mask
    cv::Mat mask = depthImage > 0;  // CV_8U  0｜255
    mask.convertTo(mask, CV_32F, 1.0/255.0);
    std::memcpy(mHostBuffers[mMaskTensorIndex].data(), mask.data, mInputHeight * mInputWidth * sizeof(float));

    // Copy to device
    for (int idx : {mRgbTensorIndex, mDepthTensorIndex, mMaskTensorIndex}) 
    {
        if (cudaMemcpy(mDeviceBuffers[idx], mHostBuffers[idx].data(), 
                       mHostBuffers[idx].size() * sizeof(float),
                       cudaMemcpyHostToDevice) != cudaSuccess) 
        {
            throw std::runtime_error("CUDA memcpy failed");
        }
    }
}

cv::Mat DepthCompleter::processOutput() 
{
    if (cudaMemcpy(mHostBuffers[mOutputTensorIndex].data(), mDeviceBuffers[mOutputTensorIndex],
                   mHostBuffers[mOutputTensorIndex].size() * sizeof(float),
                   cudaMemcpyDeviceToHost) != cudaSuccess) 
    {
        throw std::runtime_error("CUDA memcpy failed");
    }
    
    cv::Mat result(mInputHeight, mInputWidth, CV_32F, mHostBuffers[mOutputTensorIndex].data());

    return result * 200.0f;
}
