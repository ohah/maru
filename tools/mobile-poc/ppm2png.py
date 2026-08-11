#!/usr/bin/env python3
"""PPM(P6) → PNG. Android 에 인코더가 없어 호스트에서 변환한다."""
import struct
import sys
import zlib
import pathlib

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
raw = src.read_bytes()

# 헤더 파싱: P6\n<w> <h>\n255\n
parts = raw.split(b"\n", 3)
assert parts[0] == b"P6", parts[0]
w, h = map(int, parts[1].split())
data = parts[3]

rows = b"".join(b"\x00" + data[y * w * 3:(y + 1) * w * 3] for y in range(h))


def chunk(tag, payload):
    return (struct.pack(">I", len(payload)) + tag + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))


png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows, 9))
       + chunk(b"IEND", b""))
dst.write_bytes(png)
print(f"{dst.name}  {w}x{h}  {len(png)} bytes")
