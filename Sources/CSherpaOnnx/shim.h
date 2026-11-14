// sherpa-onnx 的 C 接口头文件由 Scripts/fetch-deps.sh 下载到 Vendor/
// macOS 用动态库包里的头文件；只下了 iOS 依赖（fetch-deps.sh --ios）时用 iOS 静态 xcframework 里的同一份
#if __has_include("../../Vendor/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h")
#include "../../Vendor/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h"
#else
#include "../../Vendor/sherpa-onnx-ios/sherpa-onnx.xcframework/ios-arm64/SherpaOnnxC.framework/Headers/sherpa-onnx/c-api/c-api.h"
#endif
