#!/bin/bash
# Immutable source package + pinned SHA-256 verification; compile afresh.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
python3 "$here/get-model.py" heal "$1"
