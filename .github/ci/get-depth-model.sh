#!/bin/bash
# Depth model for the Depth mask: Apple's Core ML conversion of Depth Anything V2 (small, float16, ~50 MB),
# downloaded from Hugging Face and compiled to <out dir>/DepthAnythingV2SmallF16.mlmodelc.
# usage: get-depth-model.sh <out dir>
set -e
out="$1"
if [ -d "$out/DepthAnythingV2SmallF16.mlmodelc" ]; then echo "depth model already there (cache)"; exit 0; fi
base="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlpackage"
pkg="$(mktemp -d)/DepthAnythingV2SmallF16.mlpackage"
mkdir -p "$pkg/Data/com.apple.CoreML/weights" "$out"
here="$(dirname "$0")"
bash "$here/get.sh" "$pkg/Manifest.json" "$base/Manifest.json" 100
bash "$here/get.sh" "$pkg/Data/com.apple.CoreML/model.mlmodel" "$base/Data/com.apple.CoreML/model.mlmodel" 100000
bash "$here/get.sh" "$pkg/Data/com.apple.CoreML/weights/weight.bin" "$base/Data/com.apple.CoreML/weights/weight.bin" 40000000
xcrun coremlcompiler compile "$pkg" "$out"
ls -la "$out/DepthAnythingV2SmallF16.mlmodelc"
