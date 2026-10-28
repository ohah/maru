"""Pack the existing desktop PNG representations into a Windows ICO, without redrawing them."""
from pathlib import Path
import struct

root = Path(__file__).resolve().parents[2]
data = (root / "assets/icon/Maru.icns").read_bytes()
if data[:4] != b"icns" or struct.unpack_from(">I", data, 4)[0] != len(data):
    raise ValueError("Invalid desktop icon container")
images = {}
at = 8
while at < len(data):
    size = struct.unpack_from(">I", data, at + 4)[0]
    if size < 8 or at + size > len(data):
        raise ValueError("Truncated desktop icon entry")
    png = data[at + 8:at + size]
    if png.startswith(b"\x89PNG\r\n\x1a\n"):
        width, height = struct.unpack_from(">II", png, 16)
        if width == height and width in (32, 64, 128, 256):
            images[width] = png
    at += size
if set(images) != {32, 64, 128, 256}:
    raise ValueError("Missing desktop PNG representations")
header = struct.pack("<HHH", 0, 1, len(images))
offset = 6 + 16 * len(images)
entries = []
for width, png in sorted(images.items()):
    entries.append(struct.pack("<BBBBHHII", width % 256, width % 256, 0, 0, 1, 32, len(png), offset))
    offset += len(png)
(root / "assets/icon/Maru.ico").write_bytes(header + b"".join(entries) + b"".join(png for _, png in sorted(images.items())))
