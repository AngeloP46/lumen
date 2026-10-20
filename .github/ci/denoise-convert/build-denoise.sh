#!/bin/bash
# AI Denoise model: SCUNet (real noise) converted to Core ML at 512 px tiles in CI (cached), then compiled afresh.
# Weights pinned by revision + SHA-256 (fetch.py). If anything fails, an empty Denoise.mlmodelc is left so the Xcode
# project still builds; the app then treats Denoise as not available (no coremldata.bin) and hides the slider.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$1"; tile=512
key="$(cat "$here"/*.py "$here/requirements.txt" "$here/build-denoise.sh" | shasum -a 256 | cut -c1-16)-$tile"
cache="$out/.verified-packages/denoise-convert/$key"
pkg="$cache/Denoise.mlpackage"
mkdir -p "$out"
fallback() { echo "::warning::AI Denoise model unavailable ($1): building without it"; rm -rf "$out/Denoise.mlmodelc"; mkdir -p "$out/Denoise.mlmodelc"; exit 0; }
if [ ! -d "$pkg" ]; then
  echo "Converting SCUNet at ${tile}px (not cached)"
  py=""
  for v in 3.11 3.12; do
    c=$(ls -d "${RUNNER_TOOL_CACHE:-/Users/runner/hostedtoolcache}"/Python/$v*/*/bin/python3 2>/dev/null | head -1 || true)
    if [ -n "$c" ]; then py="$c"; break; fi
  done
  [ -n "$py" ] || py="$(command -v python3.11 || command -v python3.12 || true)"
  [ -n "$py" ] || fallback "no Python 3.11/3.12"
  work="$(mktemp -d)"
  "$py" -m venv "$work/venv" || fallback "venv"
  "$work/venv/bin/pip" install -q --only-binary :all: -r "$here/requirements.txt" || fallback "pip"
  (cd "$here" && "$work/venv/bin/python" fetch.py scunet "$work/scunet.pth") || fallback "weights"
  (cd "$here" && "$work/venv/bin/python" convert.py scunet "$work/scunet.pth" $tile "$work/Denoise.mlpackage") || fallback "conversion"
  mkdir -p "$cache"; rm -rf "$pkg"; mv "$work/Denoise.mlpackage" "$pkg"; rm -rf "$work"
fi
rm -rf "$out/Denoise.mlmodelc" "$out/.denoise-compile"; mkdir -p "$out/.denoise-compile"
xcrun coremlcompiler compile "$pkg" "$out/.denoise-compile" || fallback "compile"
mv "$out/.denoise-compile/Denoise.mlmodelc" "$out/Denoise.mlmodelc"; rm -rf "$out/.denoise-compile"
echo "Compiled AI Denoise model: SCUNet ${tile}px ($key)"
