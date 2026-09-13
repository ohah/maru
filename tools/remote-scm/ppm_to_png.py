"""앱이 쓰는 P6(PPM)를 PNG 로 바꾼다.

`MARU_SCREENSHOT` 은 확장자와 무관하게 **P6** 를 쓴다. macOS 의 `sips` 는 PPM 을 못 읽고, 이 저장소는
런타임 의존성을 0 으로 두므로(프로젝트 규칙) 변환기를 붙이지 않는다 — PNG 는 zlib 한 번이면 되니
표준 라이브러리로 쓴다.
"""

import struct
import sys
import zlib


def read_ppm(path):
    raw = open(path, "rb").read()
    fields, i = [], 0
    while len(fields) < 4:  # magic, width, height, maxval
        while raw[i : i + 1].isspace():
            i += 1
        if raw[i : i + 1] == b"#":  # 주석 줄은 통째로 건너뛴다
            while raw[i : i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while not raw[j : j + 1].isspace():
            j += 1
        fields.append(raw[i:j])
        i = j
    if fields[0] != b"P6":
        raise SystemExit(f"ppm_to_png: P6 가 아니다: {fields[0]!r}")
    return int(fields[1]), int(fields[2]), raw[i + 1 :]


def write_png(path, width, height, pixels):
    need = width * height * 3
    if len(pixels) < need:
        raise SystemExit(f"ppm_to_png: 픽셀이 모자란다 {len(pixels)} < {need}")
    rows = b"".join(
        b"\x00" + pixels[y * width * 3 : (y + 1) * width * 3] for y in range(height)
    )

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 6))
        + chunk(b"IEND", b"")
    )
    open(path, "wb").write(png)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: ppm_to_png.py <in.ppm> <out.png>")
    w, h, px = read_ppm(sys.argv[1])
    write_png(sys.argv[2], w, h, px)
    print(f"ppm_to_png: {w}x{h} -> {sys.argv[2]}")
