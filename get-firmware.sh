#!/bin/sh
# Downloads PowerA's Enhanced Wired Controller v1.15 repair updater, extracts the firmware image
# embedded in it, and saves it as firmware/LBX902_V1.1.5_1.bin. The image isn't redistributed here.
set -eu

URL="https://www.powera.com/siteassets/firmware-updaters/xb1_enhanced_controller_v1.15_20191221_1628797827.exe"
SHA256="62d7011a2e3918a830ec4b6156866fb245fe8e3234ef0a2f34ab18e11ee31829"
OUT="$(cd "$(dirname "$0")" && pwd)/firmware/LBX902_V1.1.5_1.bin"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading PowerA's updater..."
curl -fsSL -o "$work/updater.exe" "$URL"

# The updater is a RAR self-extractor. Cut the archive out so macOS's tar (libarchive) can read it.
python3 -I -c '
import sys
data = open(sys.argv[1], "rb").read()
start = data.find(b"Rar!\x1a\x07")
if start < 0:
    sys.exit("No RAR archive found in the updater.")
open(sys.argv[2], "wb").write(data[start:])
' "$work/updater.exe" "$work/updater.rar"
(cd "$work" && tar -xf updater.rar HIDUpgradeDownload.exe)

# The firmware is a zlib-compressed Qt resource inside HIDUpgradeDownload.exe. Take the block that
# decompresses to 64 KB with the expected checksum.
mkdir -p "$(dirname "$OUT")"
python3 -I -c '
import hashlib, re, sys, zlib
exe, out, want = sys.argv[1:4]
data = open(exe, "rb").read()
for m in re.finditer(rb"\x78[\x01\x5e\x9c\xda]", data):
    try:
        image = zlib.decompressobj().decompress(data[m.start():m.start() + 0x20000])
    except zlib.error:
        continue
    if len(image) == 0x10000 and hashlib.sha256(image).hexdigest() == want:
        open(out, "wb").write(image)
        print("Saved", out)
        break
else:
    sys.exit("Firmware image with the expected checksum not found.")
' "$work/HIDUpgradeDownload.exe" "$OUT" "$SHA256"
