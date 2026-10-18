#!/bin/bash
# Heal model: the pinned 800 px package. The 1280 px conversion (heal-convert/) pushed Lumen past iOS's 3.4 GB
# per-app memory limit on the owner's iPhone (18 Oct); it stays available for later (HEAL_SIDE=1280 build-heal.sh).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
python3 "$here/get-model.py" heal "$1"
echo 800 > "$1/LaMa.mlmodelc/side.txt"
