#!/usr/bin/env python3
"""SVG 아이콘을 coverage(alpha) 마스터로 변환해 Zig 데이터(src/renderer/icon_coverage_data.zig)로 출력한다.

rsvg-convert(투명 배경 PNG) → PIL alpha 추출 → MASTER×MASTER u8 배열. alpha가 곧 coverage다
(셰이더가 alpha를 coverage로 읽어 전경색으로 칠한다 — braille_glyph 등과 동일).

**개발 시 1회 실행하고 결과를 커밋한다.** 빌드·CI·런타임은 이 도구(rsvg-convert/PIL)에 의존하지
않는다 — 커밋된 Zig 데이터만 쓴다(nerd_font_attributes가 "생성된 파일"인 것과 같은 패턴).

사용: python3 tools/svg_to_coverage.py > src/renderer/icon_coverage_data.zig && zig fmt src/renderer/icon_coverage_data.zig
사전: brew install librsvg  (rsvg-convert), python3 -m pip install Pillow
"""
import os
import subprocess
import sys

from PIL import Image

# 마스터 coverage 크기(px). 헤더(slot ~1.7×셀)·카드(셀) 어디서 그려져도 다운스케일=선명하도록
# 실제 렌더 슬롯보다 크게 둔다. 정사각 마스터를 런타임에 슬롯 종횡비로 맞춰 그린다(icon_glyph.zig).
MASTER = 48

# (zig_이름, codepoint, svg경로). codepoint는 Plane 15 PUA(0xF0000~)로 둬 터미널 콘텐츠·Nerd Font와
# 안 겹친다(isSynthesizedCodepoint가 전역이라 BMP PUA를 쓰면 터미널의 그 글리프까지 가로챈다).
ICONS = [
    ("git_branch", 0xF0001, "assets/icons/git-branch.svg"),
    ("gear", 0xF0002, "assets/icons/gear.svg"),
    ("plus", 0xF0003, "assets/icons/plus.svg"),
    ("search", 0xF0004, "assets/icons/search.svg"),
    ("bell", 0xF0005, "assets/icons/bell.svg"),
    ("sidebar", 0xF0006, "assets/icons/sidebar-collapse.svg"),
    ("sparkle", 0xF0007, "assets/icons/sparkle.svg"),
    ("diamond", 0xF0008, "assets/icons/diamond.svg"),
    ("mark_github", 0xF0009, "assets/icons/mark-github.svg"),
]


def svg_to_coverage(svg_path, size):
    png = svg_path + ".tmp.png"
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), svg_path, "-o", png],
        check=True,
    )
    im = Image.open(png).convert("RGBA")
    alpha = list(im.split()[3].getdata())  # row-major, len = size*size
    os.remove(png)
    if len(alpha) != size * size:
        sys.exit(f"unexpected size for {svg_path}: {len(alpha)} != {size*size}")
    return alpha


def main():
    lines = [
        "//! 생성된 파일 — tools/svg_to_coverage.py가 assets/icons/*.svg를 coverage(alpha)로 변환해 만든다.",
        "//! 직접 수정하지 말 것(스크립트 재실행으로 갱신). 빌드·런타임은 rsvg-convert/PIL에 의존하지 않는다",
        "//! — 이 커밋된 데이터만 쓴다. 셰이더가 alpha를 coverage로 읽어 전경색으로 칠한다(단색·테마색 자동).",
        "",
        f"pub const master_size: u32 = {MASTER};",
        "",
    ]
    entries = []
    for name, cp, path in ICONS:
        cov = svg_to_coverage(path, MASTER)
        arr = ",".join(str(v) for v in cov)
        lines.append(f"const {name}: [{MASTER * MASTER}]u8 = .{{ {arr} }};")
        entries.append((cp, name))
    lines.append("")
    lines.append("pub const Entry = struct { cp: u32, data: []const u8 };")
    lines.append("")
    lines.append("pub const icons = [_]Entry{")
    for cp, name in entries:
        lines.append(f"    .{{ .cp = 0x{cp:X}, .data = &{name} }},")
    lines.append("};")
    sys.stdout.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
