#!/usr/bin/env python3
"""SVG 아이콘을 coverage(alpha) 마스터로 변환해 Zig 데이터(src/renderer/icon_coverage_data.zig)로 출력한다.

rsvg-convert(투명 배경 PNG) → PIL alpha 추출 → MASTER×MASTER u8 배열. alpha가 곧 coverage다
(셰이더가 alpha를 coverage로 읽어 전경색으로 칠한다 — braille_glyph 등과 동일).

**개발 시 실행하고 결과를 커밋한다.** 제품 빌드·런타임은 이 도구(rsvg-convert/PIL)에 의존하지
않고 커밋된 Zig 데이터만 쓴다. 외부 dev/test 의존성은 프로젝트 규칙에 따라 opt-in이며 기본 CI는
Zig test로 SVG SHA-256 manifest와 C/Zig registry를 검증한다. `--check`는 로컬 재생성 drift 확인용이다.

**두 산출물을 만든다(같은 ICONS 소스):** (1) Zig coverage 데이터를 stdout으로, (2) 등록 codepoint
집합을 C 헤더 `src/platform/macos/icon_codepoints.h`로 파일 쓰기. C 셰이핑 게이트
(coretext_smoke.m `maru_is_synthesized_glyph`)와 Zig 래스터(`icon_glyph.isRegisteredIcon`)가
**같은 등록 집합**을 봐야 일치하므로(미등록 in-range는 폰트로 폴백 — Nerd Fonts v3 MDI 겹침), 둘을
한 소스에서 생성한다.

사용: python3 tools/svg_to_coverage.py > src/renderer/icon_coverage_data.zig && zig fmt src/renderer/icon_coverage_data.zig
  (icon_codepoints.h는 같은 실행에서 파일로 갱신된다)
검사: python3 tools/svg_to_coverage.py --check
사전: brew install librsvg  (rsvg-convert), python3 -m pip install Pillow
"""
import argparse
import hashlib
import os
import subprocess
import sys
import tempfile

from PIL import Image

# 마스터 coverage 크기(px). 헤더(slot ~1.7×셀)·카드(셀) 어디서 그려져도 다운스케일=선명하도록
# 실제 렌더 슬롯보다 크게 둔다. 정사각 마스터를 런타임에 슬롯 종횡비로 맞춰 그린다(icon_glyph.zig).
MASTER = 48

# 등록 아이콘 → C 헤더(아래)에 codepoint 집합으로 emit되는 경로.
C_HEADER_PATH = "src/platform/macos/icon_codepoints.h"

# (zig_이름, codepoint, svg경로). codepoint는 Plane 15 PUA(0xF0000~). **주의**: Nerd Fonts v3가 Material
# Design Icons를 Plane-15 PUA(U+F0001~)로 옮겨 이 범위와 겹친다 — 그래서 합성 게이트는 **등록된 cp만**
# 가로채고(isRegisteredIcon / maru_is_registered_icon_cp) 미등록 in-range는 폰트로 폴백한다.
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
    ("folder", 0xF000A, "assets/icons/folder.svg"),
    ("reset", 0xF000B, "assets/icons/reset.svg"),
    ("recent", 0xF000C, "assets/icons/recent.svg"),
    ("folder_open", 0xF000D, "assets/icons/folder-open.svg"),
    ("file", 0xF000E, "assets/icons/file.svg"),
    ("file_code", 0xF000F, "assets/icons/file-code.svg"),
    ("test_icon", 0xF0010, "assets/icons/test.svg"),
    ("document", 0xF0011, "assets/icons/document.svg"),
    ("image", 0xF0012, "assets/icons/image.svg"),
    ("file_config", 0xF0013, "assets/icons/file-config.svg"),
    ("archive", 0xF0014, "assets/icons/archive.svg"),
    ("package", 0xF0015, "assets/icons/package.svg"),
    ("web", 0xF0016, "assets/icons/web.svg"),
    ("data", 0xF0017, "assets/icons/data.svg"),
    ("folder_source", 0xF0018, "assets/icons/folder-source.svg"),
    ("folder_test", 0xF0019, "assets/icons/folder-test.svg"),
    ("folder_docs", 0xF001A, "assets/icons/folder-docs.svg"),
    ("folder_assets", 0xF001B, "assets/icons/folder-assets.svg"),
    ("folder_config", 0xF001C, "assets/icons/folder-config.svg"),
    ("folder_dependency", 0xF001D, "assets/icons/folder-dependency.svg"),
    ("folder_output", 0xF001E, "assets/icons/folder-output.svg"),
    ("chevron_down", 0xF001F, "assets/icons/chevron-down.svg"),
    ("chevron_right", 0xF0020, "assets/icons/chevron-right.svg"),
    ("session_dock_refresh", 0xF0021, "assets/icons/session-dock-refresh.svg"),
    ("session_dock_search", 0xF0022, "assets/icons/session-dock-search.svg"),
    ("session_dock_chevron_down", 0xF0023, "assets/icons/session-dock-chevron-down.svg"),
    ("session_dock_chevron_right", 0xF0024, "assets/icons/session-dock-chevron-right.svg"),
    ("session_dock_host", 0xF0025, "assets/icons/session-dock-host.svg"),
]


def svg_to_coverage(svg_path, size):
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        png = tmp.name
    try:
        subprocess.run(
            ["rsvg-convert", "-w", str(size), "-h", str(size), svg_path, "-o", png],
            check=True,
        )
        with Image.open(png) as image:
            im = image.convert("RGBA")
            alpha = list(im.split()[3].getdata())  # row-major, len = size*size
    finally:
        os.remove(png)
    if len(alpha) != size * size:
        sys.exit(f"unexpected size for {svg_path}: {len(alpha)} != {size*size}")
    return alpha


def c_header(entries):
    """등록 codepoint 집합을 C 헤더(maru_is_registered_icon_cp)로 쓴다 — coretext_smoke.m의 셰이핑 게이트가
    Zig 래스터(isRegisteredIcon)와 같은 등록 집합을 보게 한다(미등록 in-range는 폰트 폴백)."""
    lines = [
        "// 생성된 파일 — tools/svg_to_coverage.py가 ICONS 목록에서 만든다. 직접 수정 말 것(스크립트 재실행으로 갱신).",
        "// 등록된 maru chrome 아이콘(icon_glyph)의 Plane-15 PUA codepoint 집합. coretext_smoke.m의",
        "// maru_is_synthesized_glyph가 이걸 써서 **등록 아이콘만** 합성으로 본다 — 미등록 in-range(Nerd Fonts v3가",
        "// Plane-15 PUA로 옮긴 Material Design Icons U+F0001~ 등)는 폰트 글리프로 폴백한다. renderer/icon_glyph.zig의",
        "// isRegisteredIcon과 동일 집합(같은 ICONS 소스 생성)이라 Zig 래스터와 C 셰이핑 게이트가 항상 일치한다.",
        "#ifndef MARU_ICON_CODEPOINTS_H",
        "#define MARU_ICON_CODEPOINTS_H",
        "",
        "#include <stdbool.h>",
        "#include <stdint.h>",
        "",
        "static inline bool maru_is_registered_icon_cp(uint32_t cp) {",
        "    switch (cp) {",
    ]
    for cp, _ in entries:
        lines.append(f"        case 0x{cp:X}u:")
    lines.append("            return true;")
    lines.append("        default:")
    lines.append("            return false;")
    lines.append("    }")
    lines.append("}")
    lines.append("")
    lines.append("#endif  // MARU_ICON_CODEPOINTS_H")
    return "\n".join(lines) + "\n"


def generate():
    lines = [
        "//! 생성된 파일 — tools/svg_to_coverage.py가 assets/icons/*.svg를 coverage(alpha)로 변환해 만든다.",
        "//! 직접 수정하지 말 것(스크립트 재실행으로 갱신). 빌드·런타임은 rsvg-convert/PIL에 의존하지 않는다",
        "//! — 이 커밋된 데이터만 쓴다. 셰이더가 alpha를 coverage로 읽어 전경색으로 칠한다(단색·테마색 자동).",
        "",
        f"pub const master_size: u32 = {MASTER};",
        "",
    ]
    entries = []
    manifest = []
    for name, cp, path in ICONS:
        cov = svg_to_coverage(path, MASTER)
        arr = ",".join(str(v) for v in cov)
        lines.append(f"const {name}: [{MASTER * MASTER}]u8 = .{{ {arr} }};")
        entries.append((cp, name))
        with open(path, "rb") as asset:
            manifest.append((name, cp, path, hashlib.sha256(asset.read()).hexdigest()))
    lines.append("")
    lines.append("pub const Entry = struct { cp: u32, data: []const u8 };")
    lines.append("")
    lines.append("pub const icons = [_]Entry{")
    for cp, name in entries:
        lines.append(f"    .{{ .cp = 0x{cp:X}, .data = &{name} }},")
    lines.append("};")
    lines.extend([
        "",
        "pub const Asset = struct { name: []const u8, cp: u32, path: []const u8, sha256: []const u8 };",
        "",
        "pub const asset_manifest = [_]Asset{",
    ])
    for name, cp, path, digest in manifest:
        lines.append(f'    .{{ .name = "{name}", .cp = 0x{cp:X}, .path = "{path}", .sha256 = "{digest}" }},')
    lines.append("};")
    raw_zig = "\n".join(lines) + "\n"
    formatted = subprocess.run(
        ["zig", "fmt", "--stdin"], input=raw_zig, text=True, capture_output=True, check=True
    ).stdout
    return formatted, c_header(entries)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when committed Zig coverage, C registry, asset manifest, or hashes drift",
    )
    args = parser.parse_args()
    zig_source, header = generate()
    if args.check:
        targets = (
            ("src/renderer/icon_coverage_data.zig", zig_source),
            (C_HEADER_PATH, header),
        )
        drift = False
        for path, expected in targets:
            try:
                with open(path) as existing:
                    actual = existing.read()
            except FileNotFoundError:
                actual = ""
            if actual != expected:
                print(f"generated icon artifact is stale: {path}", file=sys.stderr)
                drift = True
        if drift:
            sys.exit(1)
        return
    with open(C_HEADER_PATH, "w") as output:
        output.write(header)
    sys.stdout.write(zig_source)


if __name__ == "__main__":
    main()
