#!/bin/bash
# Scene segmentation model for the Sky and Landscape masks: Apple's Core ML conversion of DETR ResNet-50 semantic
# segmentation (COCO panoptic classes: sky, water, trees, grass, mountain, building, road, ...; float16, ~86 MB),
# downloaded from Hugging Face and compiled to <out dir>/DETRResnet50SemanticSegmentationF16.mlmodelc.
# usage: get-seg-model.sh <out dir>
set -e
out="$1"
name="DETRResnet50SemanticSegmentationF16"
if [ -d "$out/$name.mlmodelc" ]; then echo "segmentation model already there (cache)"; exit 0; fi
base="https://huggingface.co/apple/coreml-detr-semantic-segmentation/resolve/main/$name.mlpackage"
pkg="$(mktemp -d)/$name.mlpackage"
mkdir -p "$pkg/Data/com.apple.CoreML/weights" "$out"
here="$(dirname "$0")"
bash "$here/get.sh" "$pkg/Manifest.json" "$base/Manifest.json" 100
bash "$here/get.sh" "$pkg/Data/com.apple.CoreML/model.mlmodel" "$base/Data/com.apple.CoreML/model.mlmodel" 100000
bash "$here/get.sh" "$pkg/Data/com.apple.CoreML/weights/weight.bin" "$base/Data/com.apple.CoreML/weights/weight.bin" 80000000
xcrun coremlcompiler compile "$pkg" "$out"
ls -la "$out/$name.mlmodelc"
