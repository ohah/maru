#!/usr/bin/env python3
"""SVG 아이콘을 coverage(alpha) 마스터로 변환해 Zig 데이터(src/renderer/icon_coverage_data.zig)로 출력한다.

rsvg-convert(투명 배경 PNG) → PIL alpha 추출 → MASTER×MASTER u8 배열. alpha가 곧 coverage다
(셰이더가 alpha를 coverage로 읽어 전경색으로 칠한다 — braille_glyph 등과 동일).

**개발 시 실행하고 결과를 커밋한다.** 제품 빌드·런타임은 이 도구(rsvg-convert/PIL)에 의존하지
않고 커밋된 Zig 데이터만 쓴다. 외부 dev/test 의존성은 프로젝트 규칙에 따라 opt-in이며 기본 CI는
Zig test로 SVG SHA-256 manifest와 C/Zig registry를 검증한다. `--check`는 로컬 재생성 drift 확인용이다.

**세 산출물을 만든다(같은 ICONS 소스):** (1) Zig coverage 데이터를 stdout으로, (2) 등록 codepoint
집합을 C 헤더 `src/platform/macos/icon_codepoints.h`로, (3) semantic 이름 registry를 중립 leaf
`src/icons.zig`로 파일 쓰기. C 셰이핑 게이트
(coretext_smoke.m `maru_is_synthesized_glyph`)와 Zig 래스터(`icon_glyph.isRegisteredIcon`)가
**같은 등록 집합**을 봐야 일치하므로(미등록 in-range는 폰트로 폴백 — Nerd Fonts v3 MDI 겹침), 둘을
한 소스에서 생성한다. (3)은 소비처가 `"\\u{F0023}"`·`0xF0023` 같은 codepoint 리터럴 대신 이름
(`icons.Icon.session_dock_chevron_down`)을 쓰게 해, 어느 SVG인지 코드에서 읽히고 자산이 재배치돼도
조용히 어긋나지 않게 한다(docs/chrome-strategy.md §9.7).

사용: python3 tools/svg_to_coverage.py > src/renderer/icon_coverage_data.zig && zig fmt src/renderer/icon_coverage_data.zig
  (icon_codepoints.h와 src/icons.zig는 같은 실행에서 파일로 갱신된다)
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

# 등록 아이콘 → semantic 이름 registry(Zig enum)로 emit되는 경로. 레이어 중립 leaf라 chrome(L3)·
# renderer(L1)·platform이 함께 import한다(color.zig·width.zig와 같은 자리 — chrome은 renderer를
# import할 수 없다, tests/boundary/imports.zig).
ICONS_ZIG_PATH = "src/icons.zig"

# (semantic 이름, fit, codepoint, svg경로). codepoint는 Plane 15 PUA(0xF0000~). **주의**: Nerd Fonts v3가 Material
# Design Icons를 Plane-15 PUA(U+F0001~)로 옮겨 이 범위와 겹친다 — 그래서 합성 게이트는 **등록된 cp만**
# 가로채고(isRegisteredIcon / maru_is_registered_icon_cp) 미등록 in-range는 폰트로 폴백한다.
#
# **fit = 같은 그림의 optical 변형**(docs/chrome-strategy.md §9.7). 소비처마다 아이콘을 새 이름으로 등록하던
# 것(`session_dock_chevron_down`)을 직교 축으로 바꾼 자리다. coverage 마스터는 alpha 한 채널이라 여백·stroke는
# **빌드타임에 굽는 값**이고 런타임에 못 바꾼다 — 그래서 변형은 자산을 하나 더 굽고 축으로 고른다.
#   - standard: viewBox 0 0 16 16(Octicon 기본 여백).
#   - tight:    viewBox를 1~1.5 만큼 조여 같은 슬롯을 더 채운다. 축소돼도 형태가 버티도록 stroke를 함께 올린 것도
#               있다(chevron .75 → 1). search는 **path가 standard와 완전히 동일**하고 viewBox만 다르다 — 이 축이
#               "굵기"가 아니라 optical fit인 증거다.
# fit이 하나뿐인 아이콘은 그것이 기본이고, 없는 fit을 물으면 기본으로 폴백한다(icons.zig `codepointFit`).
FIT_STANDARD = "standard"
FIT_TIGHT = "tight"
ICONS = [
    ("git_branch", FIT_STANDARD, 0xF0001, "assets/icons/git-branch.svg"),
    ("gear", FIT_STANDARD, 0xF0002, "assets/icons/gear.svg"),
    ("plus", FIT_STANDARD, 0xF0003, "assets/icons/plus.svg"),
    ("search", FIT_STANDARD, 0xF0004, "assets/icons/search.svg"),
    ("bell", FIT_STANDARD, 0xF0005, "assets/icons/bell.svg"),
    ("sidebar", FIT_STANDARD, 0xF0006, "assets/icons/sidebar-collapse.svg"),
    ("sparkle", FIT_STANDARD, 0xF0007, "assets/icons/sparkle.svg"),
    ("diamond", FIT_STANDARD, 0xF0008, "assets/icons/diamond.svg"),
    ("mark_github", FIT_STANDARD, 0xF0009, "assets/icons/mark-github.svg"),
    ("folder", FIT_STANDARD, 0xF000A, "assets/icons/folder.svg"),
    ("reset", FIT_STANDARD, 0xF000B, "assets/icons/reset.svg"),
    ("recent", FIT_STANDARD, 0xF000C, "assets/icons/recent.svg"),
    ("folder_open", FIT_STANDARD, 0xF000D, "assets/icons/folder-open.svg"),
    ("file", FIT_STANDARD, 0xF000E, "assets/icons/file.svg"),
    ("file_code", FIT_STANDARD, 0xF000F, "assets/icons/file-code.svg"),
    ("test_icon", FIT_STANDARD, 0xF0010, "assets/icons/test.svg"),
    ("document", FIT_STANDARD, 0xF0011, "assets/icons/document.svg"),
    ("image", FIT_STANDARD, 0xF0012, "assets/icons/image.svg"),
    ("file_config", FIT_STANDARD, 0xF0013, "assets/icons/file-config.svg"),
    ("archive", FIT_STANDARD, 0xF0014, "assets/icons/archive.svg"),
    ("package", FIT_STANDARD, 0xF0015, "assets/icons/package.svg"),
    ("web", FIT_STANDARD, 0xF0016, "assets/icons/web.svg"),
    ("data", FIT_STANDARD, 0xF0017, "assets/icons/data.svg"),
    ("folder_source", FIT_STANDARD, 0xF0018, "assets/icons/folder-source.svg"),
    ("folder_test", FIT_STANDARD, 0xF0019, "assets/icons/folder-test.svg"),
    ("folder_docs", FIT_STANDARD, 0xF001A, "assets/icons/folder-docs.svg"),
    ("folder_assets", FIT_STANDARD, 0xF001B, "assets/icons/folder-assets.svg"),
    ("folder_config", FIT_STANDARD, 0xF001C, "assets/icons/folder-config.svg"),
    ("folder_dependency", FIT_STANDARD, 0xF001D, "assets/icons/folder-dependency.svg"),
    ("folder_output", FIT_STANDARD, 0xF001E, "assets/icons/folder-output.svg"),
    ("chevron_down", FIT_STANDARD, 0xF001F, "assets/icons/chevron-down.svg"),
    ("chevron_right", FIT_STANDARD, 0xF0020, "assets/icons/chevron-right.svg"),
    # 아래 다섯은 세션 도크가 쓰던 자산이다. 이름이 소비처를 가리키던 것을 semantic 이름 + fit으로 바꿨다 —
    # 그림·codepoint·coverage는 그대로라 **렌더 결과는 불변**이다(도크는 계속 tight를 쓴다).
    ("refresh", FIT_TIGHT, 0xF0021, "assets/icons/session-dock-refresh.svg"),
    ("search", FIT_TIGHT, 0xF0022, "assets/icons/session-dock-search.svg"),
    ("chevron_down", FIT_TIGHT, 0xF0023, "assets/icons/session-dock-chevron-down.svg"),
    ("chevron_right", FIT_TIGHT, 0xF0024, "assets/icons/session-dock-chevron-right.svg"),
    ("host", FIT_STANDARD, 0xF0025, "assets/icons/session-dock-host.svg"),
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
        "// 이름 매크로 — Objective-C 렌더 경로도 codepoint 리터럴 대신 이름으로 아이콘을 고른다(Zig의",
        "// src/icons.zig와 같은 규율). 자산이 재배치되면 이름은 그대로 새 cp를 가리키므로 조용히 어긋나지 않는다.",
    ]
    for cp, symbol in entries:
        lines.append(f"#define MARU_ICON_{symbol.upper()} 0x{cp:X}u")
    lines.extend([
        "",
        "static inline bool maru_is_registered_icon_cp(uint32_t cp) {",
        "    switch (cp) {",
    ])
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


def icon_variants():
    """semantic 이름 → {fit: (cp, path)}. 선언 순서를 유지한다(생성물 순서 = ICONS 순서)."""
    variants = {}
    for name, fit, cp, path in ICONS:
        if fit in variants.get(name, {}):
            raise SystemExit(f"duplicate fit for icon: {name} {fit}")
        variants.setdefault(name, {})[fit] = (cp, path)
    return variants


def default_fit(fits):
    """fit이 하나뿐이면 그것이 기본이고, 여럿이면 standard가 기본이다."""
    return FIT_STANDARD if FIT_STANDARD in fits else next(iter(fits))


def symbol_name(name, fit, fits):
    """coverage 배열·매니페스트에서 쓸 **유일한** 식별자. 기본 fit은 이름 그대로, 나머지는 `_<fit>` 접미사."""
    return name if fit == default_fit(fits) else f"{name}_{fit}"


def icons_zig():
    """semantic 이름 registry를 중립 leaf Zig 모듈로 쓴다 — 소비처가 codepoint 리터럴 대신 이름을 쓰게 한다.

    래스터가 필요 없으므로 ICONS 목록만으로 만든다(rsvg-convert·PIL 불필요)."""
    variants = icon_variants()
    lines = [
        "//! 생성된 파일 — tools/svg_to_coverage.py가 ICONS 목록에서 만든다. 직접 수정 말 것(스크립트 재실행으로 갱신).",
        "//!",
        "//! **아이콘의 semantic 이름이 단일 출처다.** 소비처는 `\"\\u{F0023}\"`·`0xF0023` 같은 codepoint 리터럴 대신",
        "//! 이 enum을 쓴다 — 리터럴은 어느 그림인지 코드에서 읽히지 않고, 자산이 재배치되면 조용히 어긋난다",
        "//! (같은 의미의 아이콘이 서브시스템마다 새 이름으로 등록되던 문제 — docs/chrome-strategy.md §9.7).",
        "//!",
        "//! **레이어 중립 leaf다.** chrome(L3)은 renderer(L1)를 import할 수 없으므로(tests/boundary/imports.zig)",
        "//! 이름↔codepoint 대응은 color.zig·width.zig처럼 최상위에 둔다. 등록 집합의 **렌더 계약**(합성 게이트·",
        "//! 폰트 폴백·다운스케일)은 renderer/icon_glyph.zig가 계속 소유하고, 이 파일은 대응 표만 갖는다.",
        "",
        "/// 같은 그림의 optical 변형 축(docs/chrome-strategy.md §9.7). coverage 마스터는 alpha 한 채널이라 여백·stroke는",
        "/// **빌드타임에 굽는 값**이고 런타임에 못 바꾼다 — 그래서 변형은 자산을 하나 더 굽고 이 축으로 고른다",
        "/// (소비처마다 새 이름으로 등록하던 `session_dock_*`를 대체한다).",
        "pub const Fit = enum {",
        "    /// Octicon 기본 여백(viewBox 0 0 16 16).",
        "    standard,",
        "    /// 여백을 조여 같은 슬롯을 더 채운다(축소돼도 형태가 버티도록 stroke를 올린 자산도 있다).",
        "    tight,",
        "};",
        "",
        "/// 등록된 maru chrome 아이콘의 semantic 이름. 태그 값 = **기본 fit**의 Plane 15 PUA codepoint다.",
        "pub const Icon = enum(u21) {",
    ]
    for name, fits in variants.items():
        base = default_fit(fits)
        cp, path = fits[base]
        for fit, (vcp, vpath) in fits.items():
            lines.append(f"    /// {fit}: {vpath} (0x{vcp:X})")
        lines.append(f"    {name} = 0x{cp:X},")
    lines.extend([
        "};",
        "",
        "/// 이 아이콘의 **기본 fit** codepoint. fit을 고르려면 `codepointFit`을 쓴다.",
        "pub fn codepoint(icon: Icon) u21 {",
        "    return @intFromEnum(icon);",
        "}",
        "",
        "/// 요청한 fit의 codepoint. **그 fit이 없으면 기본 fit으로 폴백한다** — 변형은 큐레이션된 소수라,",
        "/// 없는 조합마다 소비처가 분기하는 것보다 기본으로 떨어지는 편이 호출부를 단순하게 유지한다.",
        "pub fn codepointFit(icon: Icon, fit: Fit) u21 {",
        "    return switch (fit) {",
        "        .standard => codepoint(icon),",
        "        .tight => switch (icon) {",
    ])
    for name, fits in variants.items():
        if FIT_TIGHT in fits and default_fit(fits) != FIT_TIGHT:
            lines.append(f"            .{name} => 0x{fits[FIT_TIGHT][0]:X},")
    lines.extend([
        "            else => codepoint(icon),",
        "        },",
        "    };",
        "}",
        "",
        "/// 셀 텍스트(ChromeDraw.Run·제목 문자열)에 그대로 넣는 UTF-8 인코딩 — 소비처가 escape 리터럴을 손으로",
        "/// 적지 않게 한다. 반환은 정적 문자열이라 수명 걱정이 없다.",
        "pub fn utf8(icon: Icon) []const u8 {",
        "    return switch (icon) {",
    ])
    for name, fits in variants.items():
        cp = fits[default_fit(fits)][0]
        lines.append(f"        .{name} => \"\\u{{{cp:X}}}\",")
    lines.extend([
        "    };",
        "}",
        "",
        "/// `codepointFit`의 UTF-8 판(같은 폴백 규칙).",
        "pub fn utf8Fit(icon: Icon, fit: Fit) []const u8 {",
        "    return switch (fit) {",
        "        .standard => utf8(icon),",
        "        .tight => switch (icon) {",
    ])
    for name, fits in variants.items():
        if FIT_TIGHT in fits and default_fit(fits) != FIT_TIGHT:
            lines.append(f"            .{name} => \"\\u{{{fits[FIT_TIGHT][0]:X}}}\",")
    lines.extend([
        "            else => utf8(icon),",
        "        },",
        "    };",
        "}",
        "",
        "/// 등록 codepoint를 이름+fit으로 되읽는다. **렌더 게이트가 아니다** — 합성 여부 판정은",
        "/// `renderer.icon_glyph.isRegisteredIcon`이 단일 출처이고, 이건 lower된 cp가 어느 아이콘인지 확인할 때",
        "/// 쓴다(예: 도크 view가 낸 draw op을 테스트가 검사).",
        "pub const Resolved = struct { icon: Icon, fit: Fit };",
        "pub fn fromCodepoint(cp: u21) ?Resolved {",
        "    return switch (cp) {",
    ])
    for name, fits in variants.items():
        for fit, (vcp, _) in fits.items():
            lines.append(f"        0x{vcp:X} => .{{ .icon = .{name}, .fit = .{fit} }},")
    lines.extend([
        "        else => null,",
        "    };",
        "}",
        "",
        "test \"icons: 이름·fit·codepoint·UTF-8·역참조가 서로 일치한다\" {",
        "    const std = @import(\"std\");",
        "    inline for (@typeInfo(Icon).@\"enum\".fields) |field| {",
        "        const icon: Icon = @enumFromInt(field.value);",
        "        try std.testing.expectEqual(@as(u21, field.value), codepoint(icon));",
        "        for ([_]Fit{ .standard, .tight }) |fit| {",
        "            const cp = codepointFit(icon, fit);",
        "            const resolved = fromCodepoint(cp) orelse return error.TestUnexpectedResult;",
        "            try std.testing.expectEqual(icon, resolved.icon); // 폴백해도 같은 아이콘이다",
        "            var buf: [4]u8 = undefined;",
        "            const len = try std.unicode.utf8Encode(cp, &buf);",
        "            try std.testing.expectEqualStrings(buf[0..len], utf8Fit(icon, fit));",
        "        }",
        "    }",
        "}",
        "",
        "test \"icons: tight 변형이 있으면 기본과 다른 codepoint이고, 없으면 기본으로 폴백한다\" {",
        "    const std = @import(\"std\");",
        "    // 도크가 쓰는 tight 변형(같은 그림, 조인 여백) — 기본과 달라야 변형이 실제로 등록된 것이다.",
        "    try std.testing.expect(codepointFit(.chevron_down, .tight) != codepoint(.chevron_down));",
        "    try std.testing.expect(codepointFit(.search, .tight) != codepoint(.search));",
        "    // 변형이 없는 아이콘은 기본으로 떨어진다(소비처가 조합마다 분기하지 않게).",
        "    try std.testing.expectEqual(codepoint(.gear), codepointFit(.gear, .tight));",
        "}",
    ])
    raw_zig = "\n".join(lines) + "\n"
    return subprocess.run(
        ["zig", "fmt", "--stdin"], input=raw_zig, text=True, capture_output=True, check=True
    ).stdout


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
    variants = icon_variants()
    for name, fit, cp, path in ICONS:
        # 변형이 생기며 이름이 겹치므로(같은 `search`의 standard·tight) 배열·매니페스트 식별자는
        # 기본 fit만 이름 그대로 쓰고 나머지에 `_<fit>`를 붙인다.
        symbol = symbol_name(name, fit, variants[name])
        cov = svg_to_coverage(path, MASTER)
        arr = ",".join(str(v) for v in cov)
        lines.append(f"const {symbol}: [{MASTER * MASTER}]u8 = .{{ {arr} }};")
        entries.append((cp, symbol))
        with open(path, "rb") as asset:
            manifest.append((symbol, cp, path, hashlib.sha256(asset.read()).hexdigest()))
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
    return formatted, c_header(entries), icons_zig()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when committed Zig coverage, C registry, name registry, asset manifest, or hashes drift",
    )
    args = parser.parse_args()
    zig_source, header, ids_source = generate()
    if args.check:
        targets = (
            ("src/renderer/icon_coverage_data.zig", zig_source),
            (C_HEADER_PATH, header),
            (ICONS_ZIG_PATH, ids_source),
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
    with open(ICONS_ZIG_PATH, "w") as output:
        output.write(ids_source)
    sys.stdout.write(zig_source)


if __name__ == "__main__":
    main()
