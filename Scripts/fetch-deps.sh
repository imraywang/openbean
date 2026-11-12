#!/bin/zsh
# 下载语音输入需要的第三方依赖（都不进仓库）：
#   Vendor/sherpa-onnx-*      sherpa-onnx C 接口动态库 + 头文件（Apache-2.0）
#   ~/Library/Application Support/openbean/models
#     sensevoice/             SenseVoice-Small int8（每句定稿）
#     vad/silero_vad.onnx     Silero VAD（切句）
set -e
ROOT="${0:A:h}/.."
VER=v2.0.1
NAME=sherpa-onnx-$VER-osx-arm64-shared-no-tts-lib
GH=https://github.com/k2-fsa/sherpa-onnx/releases/download

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
echo "依赖就绪：$ROOT/Vendor/sherpa-onnx，模型在 $M"
