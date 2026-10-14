#!/bin/bash
# Official XcodeGen 2.46.0 release, pinned and independently SHA-256 checked.
set -euo pipefail
version="2.46.0"
sha256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
destination="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lumen-xcodegen-${version}"
mkdir -p "$destination"
archive="$destination/xcodegen.zip"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --max-time 180 \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${version}/xcodegen.zip" -o "$archive"
printf '%s  %s\n' "$sha256" "$archive" | shasum -a 256 -c -
unzip -oq "$archive" -d "$destination"
chmod +x "$destination/xcodegen/bin/xcodegen"
"$destination/xcodegen/bin/xcodegen" --version | grep -F "Version: ${version}"
if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$destination/xcodegen/bin" >> "$GITHUB_PATH"
else
  echo "XcodeGen installed in $destination/xcodegen/bin"
fi
