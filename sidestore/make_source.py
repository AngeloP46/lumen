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
RAW = "https://raw.githubusercontent.com/AngeloP46/lumen/main/sidestore/"
ICON = RAW + "icon.png"
TINT = "#5B96FF"   # Lumen's blue, as on the website
WEBSITE = "https://lumen-raweditor.netlify.app/"
# The App Store screenshots (Angelo's own iPhone screens), 660 x 1434 copies kept in sidestore/screenshots
SHOTS = ["01-colour-lambo", "02-lensblur-car", "03-heal-person", "04-denoise", "05-grade-tree", "06-presets-tree"]
DESCRIPTION = """Lumen edits the RAW files from your camera and iPhone on the phone itself, with nothing uploaded.

Light, colour and tone: exposure, highlights, shadows, whites, blacks, white balance, curves, a colour mixer and colour grading wheels.
Masks: subject, people, sky, landscape parts, depth, brush, linear, radial, colour and luminance range.
Heal and Remove people: paint over something, or tap a person, and Lumen fills the gap.
AI Denoise for high-ISO photos, Lens Blur, HDR editing and export.
Crop, straighten, perspective, presets, copy and paste edits, and batch export to JPEG, HEIC or 16-bit TIFF.

Opens Sony ARW, Canon CR2/CR3, Nikon NEF, Fujifilm RAF, DNG and iPhone ProRAW, plus JPEG and HEIC. Edits never change the original."""

ipa, download_url, out = sys.argv[1:4]

with zipfile.ZipFile(ipa) as z:
    plist_name = next(n for n in z.namelist()
                      if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist"))
    info = plistlib.loads(z.read(plist_name))

data = open(ipa, "rb").read()
ent_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Lumen.entitlements")
entitlements = sorted(plistlib.load(open(ent_file, "rb")).keys()) if os.path.exists(ent_file) else []
privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}
lines = [l.strip() for l in (os.environ.get("COMMIT_MSG") or "").strip().splitlines() if l.strip()]
# a merge commit's first line is "Merge pull request #N from ..."; the pull request's title follows it
if lines and lines[0].startswith("Merge pull request") and len(lines) > 1:
    lines = lines[1:]
notes = [l for l in lines if not l.startswith("Co-Authored-By")]

version = {
    "version": info["CFBundleShortVersionString"],
    "buildVersion": info["CFBundleVersion"],
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": "\n".join(notes[:6]) if notes else "New build from GitHub.",
    "downloadURL": download_url,
    "size": len(data),
    "sha256": hashlib.sha256(data).hexdigest(),
    "minOSVersion": info.get("MinimumOSVersion", "17.0"),
}

source = {
    "name": "Lumen",
    "identifier": "io.github.angelop46.lumen",
    "subtitle": "Angelo's RAW photo editor for iPhone",
    "description": "Every new build of Lumen, published as soon as it passes its checks on GitHub.",
    "iconURL": ICON,
    "website": WEBSITE,
    "tintColor": TINT,
    "apps": [{
        "name": "Lumen",
        "bundleIdentifier": info["CFBundleIdentifier"],
        "developerName": "Angelo Parodi",
        "subtitle": "RAW photo editor for iPhone",
        "localizedDescription": DESCRIPTION,
        "iconURL": ICON,
        "screenshotURLs": [RAW + "screenshots/" + n + ".jpg" for n in SHOTS],
        "screenshots": {"iphone": [{"imageURL": RAW + "screenshots/" + n + ".jpg", "width": 660, "height": 1434} for n in SHOTS]},
        "tintColor": TINT,
        "category": "photo-video",
        "versions": [version],
        # Build IPA signs the app ad hoc with Lumen.entitlements; SideStore checks the feed lists the same ones.
        "appPermissions": {"entitlements": entitlements, "privacy": privacy},
    }],
    "news": [{
        "identifier": "build-" + info["CFBundleVersion"],
        "title": "Lumen " + info["CFBundleShortVersionString"],
        "caption": notes[0] if notes else "A new build is ready.",
        "date": version["date"],
        "tintColor": TINT,
        "appID": info["CFBundleIdentifier"],
        "notify": False,
    }],
}

with open(out, "w") as f:
    json.dump(source, f, indent=2)
print(f"{info['CFBundleIdentifier']} {version['version']} ({version['buildVersion']}), "
      f"{version['size']} bytes, sha256 {version['sha256']}, privacy keys: {sorted(privacy)}")
