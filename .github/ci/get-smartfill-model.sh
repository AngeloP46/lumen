#!/bin/bash
# Smart fill model files (engine test only; the app downloads them itself on first use): Stable Diffusion 1.5
# inpainting, CyberRealistic V8 Inpaint, Core ML 6-bit (Hugging Face LocalMuseAI/coreml-cyberrealistic-v8-inpaint-6bit).
# usage: get-smartfill-model.sh <out dir>
set -e
out="$1"
base="https://huggingface.co/LocalMuseAI/coreml-cyberrealistic-v8-inpaint-6bit/resolve/main"
here="$(dirname "$0")"
while read -r path size; do
  [ -z "$path" ] && continue
  dest="$out/$path"
  if [ -f "$dest" ] && [ "$(wc -c < "$dest" | tr -d ' ')" = "$size" ]; then continue; fi
  mkdir -p "$(dirname "$dest")"
  bash "$here/get.sh" "$dest" "$base/$path" "$size"
done <<'LIST'
TextEncoder.mlmodelc/analytics/coremldata.bin 243
TextEncoder.mlmodelc/coremldata.bin 992
TextEncoder.mlmodelc/metadata.json 3089
TextEncoder.mlmodelc/model.mil 187497
TextEncoder.mlmodelc/weights/weight.bin 139910080
Unet.mlmodelc/analytics/coremldata.bin 243
Unet.mlmodelc/coremldata.bin 1425
Unet.mlmodelc/metadata.json 4039
Unet.mlmodelc/model.mil 3136987
Unet.mlmodelc/weights/weight.bin 645336256
VAEDecoder.mlmodelc/analytics/coremldata.bin 243
VAEDecoder.mlmodelc/coremldata.bin 919
VAEDecoder.mlmodelc/metadata.json 2726
VAEDecoder.mlmodelc/model.mil 194902
VAEDecoder.mlmodelc/weights/weight.bin 98993280
VAEEncoder.mlmodelc/analytics/coremldata.bin 243
VAEEncoder.mlmodelc/coremldata.bin 923
VAEEncoder.mlmodelc/metadata.json 2710
VAEEncoder.mlmodelc/model.mil 149284
VAEEncoder.mlmodelc/weights/weight.bin 68338112
merges.txt 524619
vocab.json 1059962
LIST
du -sh "$out"
