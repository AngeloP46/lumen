#!/bin/bash
# Heal model: Big LaMa converted in CI at 1280 px (see heal-convert/), falling back to the pinned 800 px package.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bash "$here/heal-convert/build-heal.sh" "$1"
