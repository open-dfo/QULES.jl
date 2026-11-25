"""Write +qules/private/bundles.m with the SHA-256 of each bundle archive.

Usage: python matlab_write_bundles.py VERSION OUTPUT qules-bundle-<platform>.zip...
"""
import hashlib
import sys
from pathlib import Path

PLATFORMS = ["windows-x86_64", "linux-x86_64", "macos-x86_64", "macos-arm64"]

version, output, *archives = sys.argv[1:]
digests = dict.fromkeys(PLATFORMS, "")
for archive in map(Path, archives):
    platform = archive.stem.removeprefix("qules-bundle-")
    assert platform in digests, archive
    digests[platform] = hashlib.sha256(archive.read_bytes()).hexdigest()

fields = ", ...\n    ".join(f"'{p.replace('-', '_')}', '{d}'" for p, d in digests.items())
Path(output).write_text(f"""function manifest = bundles()
%BUNDLES Release version and SHA-256 of each platform's bundle archive.
%   Written by .github/scripts/matlab_write_bundles.py.

manifest.version = '{version}';
manifest.sha256 = struct({fields});
end
""", encoding="utf-8")
