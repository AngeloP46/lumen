"""Write the SideStore source (source.json) for the IPA that CI just built.

SideStore on the phone reads this feed from the repo's `sidestore` release and
rejects a download unless its bundle id, version, build number, size, sha256 and
privacy usage keys all match what is listed here, so every value is read from
the IPA itself rather than typed in.

Usage: python3 sidestore/make_source.py <ipa> <ipa download URL> <output json>
Optional env: COMMIT_MSG (shown as the version's notes in SideStore).
"""
import datetime
import hashlib
import json
import os
import plistlib
import sys
import zipfile

REPO = "https://github.com/AngeloP46/lumen"
ICON = "https://raw.githubusercontent.com/AngeloP46/lumen/main/sidestore/icon.png"
TINT = "#F5A623"

ipa, download_url, out = sys.argv[1:4]

with zipfile.ZipFile(ipa) as z:
    plist_name = next(n for n in z.namelist()
                      if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist"))
    info = plistlib.loads(z.read(plist_name))

data = open(ipa, "rb").read()
privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}
notes = (os.environ.get("COMMIT_MSG") or "").strip().splitlines()

version = {
    "version": info["CFBundleShortVersionString"],
    "buildVersion": info["CFBundleVersion"],
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": notes[0] if notes else "New build from GitHub.",
    "downloadURL": download_url,
    "size": len(data),
    "sha256": hashlib.sha256(data).hexdigest(),
    "minOSVersion": info.get("MinimumOSVersion", "17.0"),
}

source = {
    "name": "Lumen",
    "identifier": "io.github.angelop46.lumen",
    "subtitle": "Builds of Lumen straight from GitHub",
    "iconURL": ICON,
    "website": REPO,
    "tintColor": TINT,
    "apps": [{
        "name": "Lumen",
        "bundleIdentifier": info["CFBundleIdentifier"],
        "developerName": "AngeloP46",
        "subtitle": "RAW photo editor",
        "localizedDescription": "A free, subscription-less RAW photo editor for iPhone: "
                                "Lightroom-style sliders, curves, colour grading and masks.",
        "iconURL": ICON,
        "tintColor": TINT,
        "category": "photo-video",
        "versions": [version],
        # The build is unsigned, so it carries no entitlements of its own.
        "appPermissions": {"entitlements": [], "privacy": privacy},
    }],
    "news": [],
}

with open(out, "w") as f:
    json.dump(source, f, indent=2)
print(f"{info['CFBundleIdentifier']} {version['version']} ({version['buildVersion']}), "
      f"{version['size']} bytes, sha256 {version['sha256']}, privacy keys: {sorted(privacy)}")
