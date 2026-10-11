#!/bin/bash
# Heal model: LaMa (large-mask inpainting, Apache-2.0) converted to Core ML (Hugging Face mlboydaisuke/LaMa-CoreML,
# ~216 MB), downloaded and compiled to <out dir>/LaMa.mlmodelc.
# usage: get-heal-model.sh <out dir>
set -e
out="$1"
if [ -d "$out/LaMa.mlmodelc" ]; then echo "heal model already there (cache)"; exit 0; fi
base="https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/main/LaMa.mlpackage"
pkg="$(mktemp -d)/LaMa.mlpackage"
mkdir -p "$pkg/Data/com.apple.CoreML/weights" "$out"
here="$(dirname "$0")"
bash "$here/get.sh" "$pkg/Manifest.json" "$base/Manifest.json" 100
bash "$here/get.sh" "$pkg/Data/com.apple.CoreML/model.mlmodel" "$base/Data/com.apple.CoreML/model.mlmodel" 100000
bash "$here/get.sh" "$pkg/Data/com.apple.CoreML/weights/weight.bin" "$base/Data/com.apple.CoreML/weights/weight.bin" 200000000
xcrun coremlcompiler compile "$pkg" "$out"
ls -la "$out/LaMa.mlmodelc"
