#include "caffe2/operators/dropout_op.h"
#include "caffe2/core/context_gpu.h"

namespace caffe2 {

namespace {
__global__ void DropoutKernel(const int N, const float ratio,
                              const float* Xdata, float* Ydata,
                              bool* maskdata) {
  const float scale = 1. / (1. - ratio);
  CUDA_1D_KERNEL_LOOP(i, N) {
    maskdata[i] = (Ydata[i] > ratio);
    Ydata[i] = Xdata[i] * scale * maskdata[i];
  }
}
}  // namespace

template <>
bool DropoutOp<float, CUDAContext>::RunOnDevice() {
  auto& X = Input(0);
  auto* Y = Output(0);
  auto* mask = Output(1);
  Y->Resize(X.dims());
  mask->Resize(X.dims());
  DCHECK_GT(X.size(), 0);
  if (is_test_) {
    if (Y != &X) {
      context_.Copy<float, CUDAContext, CUDAContext>(
          X.size(), X.data<float>(), Y->mutable_data<float>());
    }
    return true;
  } else {
    // We do a simple trick here: since curand cannot generate random
    // boolean numbers, we will generate into dY and write the result to
    // mask.
    float* Ydata = Y->mutable_data<float>();
    CURAND_CHECK(curandGenerateUniform(
        context_.curand_generator(), Ydata, X.size()));
    DropoutKernel<<<CAFFE_GET_BLOCKS(X.size()), CAFFE_CUDA_NUM_THREADS,
                    0, context_.cuda_stream()>>>(
        X.size(), ratio_, X.data<float>(), Ydata, mask->mutable_data<bool>());
    return true;
  }
}

namespace {
__global__ void DropoutGradientKernel(const int N, const float* dYdata,
                                      const bool* maskdata,
                                      const float scale, float* dXdata) {
  CUDA_1D_KERNEL_LOOP(i, N) {
    dXdata[i] = dYdata[i] * maskdata[i] * scale;
  }
}
}  // namespace

template <>
bool DropoutGradientOp<float, CUDAContext>::RunOnDevice() {
  auto& dY = Input(0);
  auto& mask = Input(1);
  auto* dX = Output(0);
  DCHECK_GT(dY.size(), 0);
  DCHECK_EQ(dY.size(), mask.size());
  dX->Resize(dY.dims());
  if (is_test_) {
    if (dX != &dY) {
      context_.Copy<float, CUDAContext, CUDAContext>(
          dY.size(), dY.data<float>(), dX->mutable_data<float>());
    }
    return true;
  } else {
    const float scale = 1. / (1. - ratio_);
    DropoutGradientKernel<<<CAFFE_GET_BLOCKS(dY.size()),
                            CAFFE_CUDA_NUM_THREADS,
                            0, context_.cuda_stream()>>>(
        dY.size(), dY.data<float>(), mask.data<bool>(), scale,
        dX->mutable_data<float>());
    return true;
  }
}


namespace {
REGISTER_CUDA_OPERATOR(Dropout, DropoutOp<float, CUDAContext>);
REGISTER_CUDA_OPERATOR(DropoutGrad, DropoutGradientOp<float, CUDAContext>);
}  // namespace
}  // namespace caffe2
