"""Download the denoiser's weights from an immutable Hugging Face revision and verify size and SHA-256.

The mirror (WAS/was-node-suite-weights) re-hosts the official checkpoints; the hashes below are the LFS SHA-256 OIDs
of that revision. Changing either is an explicit, reviewed code change.
Usage: python fetch.py scunet <dest.pth>
"""
import hashlib
import sys
import urllib.request

REVISION = 'dcc864eaa1478f7b82b97b682543117cc8c6d632'
FILES = {
    'scunet': ('denoise/scunet_color_real_psnr.pth', 71982841,
               'fa78899ba2caec9d235a900e91d96c689da71c42029230c2028b00f09f809c2e'),
}

name, dest = sys.argv[1], sys.argv[2]
path, size, sha = FILES[name]
url = f'https://huggingface.co/WAS/was-node-suite-weights/resolve/{REVISION}/{path}'
with urllib.request.urlopen(url, timeout=300) as r:
    data = r.read()
if len(data) != size or hashlib.sha256(data).hexdigest() != sha:
    raise SystemExit(f'{name}: downloaded weights failed the pinned size/SHA-256 check')
with open(dest, 'wb') as f:
    f.write(data)
print(f'{name}: verified {path} ({size} bytes)')
