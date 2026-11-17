#!/bin/zsh
# 下载语音输入需要的第三方依赖（都不进仓库）：
#   Vendor/sherpa-onnx-*      sherpa-onnx C 接口动态库 + 头文件（Apache-2.0）
#   ~/Library/Application Support/openbean/models
#     sensevoice/             SenseVoice-Small int8（每句定稿）
#     vad/silero_vad.onnx     Silero VAD（切句）
#     speaker/…campplus…onnx  3D-Speaker CAM++ zh_en（认出佩戴者的声音，Apache-2.0，28 MB）
#
# Scripts/fetch-deps.sh --ios：只下 iOS 版要的静态 xcframework（bin/build-ios 会调用），不下模型：
#   Vendor/sherpa-onnx-ios/sherpa-onnx.xcframework   sherpa-onnx C 接口静态库（SherpaOnnxC.framework）
#   Vendor/sherpa-onnx-ios/onnxruntime.xcframework   onnxruntime 静态库（sherpa-onnx 的 build-ios.sh 用的那个版本）
# iOS 上的模型由 App 首次使用时下载到自己的 Application Support/models（App/Shared/ModelStore.swift）
set -e
ROOT="${0:A:h}/.."
VER=v2.0.1
GH=https://github.com/k2-fsa/sherpa-onnx/releases/download

if [[ "$1" == --ios ]]; then
  # sherpa-onnx 的 iOS 构建不在 $VER 的 release 里，而在单独的 xcframework release 里
  ORT=1.28.2
  D="$ROOT/Vendor/sherpa-onnx-$VER-ios-static"
  mkdir -p "$D"
  if [[ ! -f "$D/sherpa-onnx.xcframework/ios-arm64/SherpaOnnxC.framework/SherpaOnnxC" ]]; then
    echo "下载 sherpa-onnx $VER iOS 静态 xcframework（约 16 MB）"
    tmp=$(mktemp -d)
    curl -sSL --fail -o "$tmp/s.zip" "$GH/xcframework/sherpa-onnx-$VER-ios-static.xcframework.zip"
    rm -rf "$D/sherpa-onnx.xcframework"
    unzip -q "$tmp/s.zip" -d "$D"
    rm -rf "$tmp"
  fi
  if [[ ! -f "$D/onnxruntime.xcframework/ios-arm64/onnxruntime.framework/onnxruntime" ]]; then
    echo "下载 onnxruntime $ORT iOS 静态 xcframework（约 34 MB）"
    tmp=$(mktemp -d)
    curl -sSL --fail -o "$tmp/o.zip" \
      "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v$ORT/onnxruntime-ios-static-xcframework-$ORT.xcframework.zip"
    unzip -q "$tmp/o.zip" -d "$tmp/o"
    rm -rf "$D/onnxruntime.xcframework"
    mv "$(find "$tmp/o" -name onnxruntime.xcframework -maxdepth 3 | head -1)" "$D/"
    rm -rf "$tmp"
  fi
  ln -sfn "${D:t}" "$ROOT/Vendor/sherpa-onnx-ios"
  echo "iOS 依赖就绪：$ROOT/Vendor/sherpa-onnx-ios"
  exit 0
fi

NAME=sherpa-onnx-$VER-osx-arm64-shared-no-tts-lib
mkdir -p "$ROOT/Vendor"
if [[ ! -f "$ROOT/Vendor/$NAME/lib/libsherpa-onnx-c-api.dylib" ]]; then
  echo "下载 sherpa-onnx $VER"
  curl -sSL --fail "$GH/$VER/$NAME.tar.bz2" | tar xj -C "$ROOT/Vendor"
fi
H="$ROOT/Vendor/$NAME/include/sherpa-onnx/c-api/c-api.h"
if [[ ! -f "$H" ]]; then
  mkdir -p "${H:h}"
  curl -sSL --fail -o "$H" "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$VER/sherpa-onnx/c-api/c-api.h"
fi
ln -sfn "$NAME" "$ROOT/Vendor/sherpa-onnx"

M="$HOME/Library/Application Support/openbean/models"
mkdir -p "$M/vad"
if [[ ! -f "$M/sensevoice/model.int8.onnx" ]]; then
  echo "下载 SenseVoice-Small（约 230 MB）"
  tmp=$(mktemp -d)
  curl -sSL --fail "$GH/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2" | tar xj -C "$tmp"
  mkdir -p "$M/sensevoice"
  cp "$tmp"/*/model.int8.onnx "$tmp"/*/tokens.txt "$tmp"/*/LICENSE "$M/sensevoice/"
  rm -rf "$tmp"
fi
[[ -f "$M/vad/silero_vad.onnx" ]] || curl -sSL --fail -o "$M/vad/silero_vad.onnx" "$GH/asr-models/silero_vad.onnx"
SPK=3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx
if [[ ! -f "$M/speaker/$SPK" ]]; then
  echo "下载声纹模型 CAM++（约 28 MB）"
  mkdir -p "$M/speaker"
  # sherpa-onnx 的 release 标签就叫 speaker-recongition-models（原文拼写）
  curl -sSL --fail -o "$M/speaker/$SPK.part" "$GH/speaker-recongition-models/$SPK" && mv "$M/speaker/$SPK.part" "$M/speaker/$SPK"
fi
echo "依赖就绪：$ROOT/Vendor/sherpa-onnx，模型在 $M"
