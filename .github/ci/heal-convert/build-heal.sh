#!/bin/bash
# The Heal model: Big LaMa converted to Core ML at HEAL_SIDE px in CI (cached), then compiled afresh.
# Weights: IOPaint's big-lama.pt, verified against IOPaint's published MD5. If the conversion fails the build
# falls back to the pinned 800 px package (get-model.py heal) so a release never ships without Heal.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$1"; side="${HEAL_SIDE:-1280}"
key="$(cat "$here/convert.py" "$here/requirements.txt" "$here/build-heal.sh" | shasum -a 256 | cut -c1-16)-$side"
cache="$out/.verified-packages/heal-convert/$key"
pkg="$cache/LaMa.mlpackage"
mkdir -p "$out"
if [ ! -d "$pkg" ]; then
  echo "Converting Big LaMa at ${side}px (not cached)"
  py=""
  for v in 3.11 3.12; do
    c=$(ls -d "${RUNNER_TOOL_CACHE:-/Users/runner/hostedtoolcache}"/Python/$v*/*/bin/python3 2>/dev/null | head -1 || true)
    if [ -n "$c" ]; then py="$c"; break; fi
  done
  [ -n "$py" ] || py="$(command -v python3.11 || command -v python3.12 || true)"
  work="$(mktemp -d)"
  if [ -n "$py" ] && "$py" -m venv "$work/venv" \
     && "$work/venv/bin/pip" install -q --only-binary :all: -r "$here/requirements.txt" \
     && curl -fsSL --retry 3 -o "$work/big-lama.pt" "https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt" \
     && [ "$(md5 -q "$work/big-lama.pt")" = "e3aa4aaa15225a33ec84f9f4bc47e500" ] \
     && echo "big-lama.pt sha256 $(shasum -a 256 "$work/big-lama.pt" | cut -d' ' -f1)" \
     && "$work/venv/bin/python" "$here/convert.py" "$side" "$work/big-lama.pt" "$work/LaMa.mlpackage"; then
    mkdir -p "$cache"; rm -rf "$pkg"; mv "$work/LaMa.mlpackage" "$pkg"
  else
    echo "::warning::Big LaMa ${side}px conversion failed: using the pinned 800 px Heal model"
    rm -rf "$work"
    python3 "$here/../get-model.py" heal "$out"
    echo 800 > "$out/LaMa.mlmodelc/side.txt"
    exit 0
  fi
  rm -rf "$work"
fi
rm -rf "$out/LaMa.mlmodelc" "$out/.heal-compile"; mkdir -p "$out/.heal-compile"
xcrun coremlcompiler compile "$pkg" "$out/.heal-compile"
mv "$out/.heal-compile/LaMa.mlmodelc" "$out/LaMa.mlmodelc"; rm -rf "$out/.heal-compile"
echo "$side" > "$out/LaMa.mlmodelc/side.txt"
echo "Compiled Heal model: Big LaMa ${side}px ($key)"
