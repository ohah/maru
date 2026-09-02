#!/usr/bin/env python3
"""SVG 아이콘을 coverage(alpha) 마스터로 변환해 Zig 데이터(src/renderer/icon_coverage_data.zig)로 출력한다.

rsvg-convert(투명 배경 PNG) → PIL alpha 추출 → MASTER×MASTER u8 배열. alpha가 곧 coverage다
(셰이더가 alpha를 coverage로 읽어 전경색으로 칠한다 — braille_glyph 등과 동일).

**개발 시 실행하고 결과를 커밋한다.** 제품 빌드·런타임은 이 도구(rsvg-convert/PIL)에 의존하지
않고 커밋된 Zig 데이터만 쓴다. 외부 dev/test 의존성은 프로젝트 규칙에 따라 opt-in이며 기본 CI는
Zig test로 SVG SHA-256 manifest와 C/Zig registry를 검증한다. `--check`는 로컬 재생성 drift 확인용이다.

**세 산출물을 만든다(같은 ICONS 소스):** (1) Zig coverage 데이터를 `src/renderer/icon_coverage_data.zig`로, (2) 등록 codepoint
집합을 C 헤더 `src/platform/macos/icon_codepoints.h`로, (3) semantic 이름 registry를 중립 leaf
`src/icons.zig`로 파일 쓰기. C 셰이핑 게이트
(coretext_smoke.m `maru_is_synthesized_glyph`)와 Zig 래스터(`icon_glyph.isRegisteredIcon`)가
**같은 등록 집합**을 봐야 일치하므로(미등록 in-range는 폰트로 폴백 — Nerd Fonts v3 MDI 겹침), 둘을
한 소스에서 생성한다. (3)은 소비처가 `"\\u{F0023}"`·`0xF0023` 같은 codepoint 리터럴 대신 이름
(`icons.utf8Fit(.chevron_down, .tight)`)을 쓰게 해, 어느 SVG인지 코드에서 읽히고 자산이 재배치돼도
조용히 어긋나지 않게 한다(docs/chrome-strategy.md §9.7).

사용: python3 tools/svg_to_coverage.py
  (세 산출물을 모두 파일로 쓴다 — 생성이 **전부 성공한 뒤에만** 쓰므로 실패해도 커밋된 데이터가 안 깨진다)
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

# coverage(alpha) 마스터가 쓰이는 경로.
COVERAGE_ZIG_PATH = "src/renderer/icon_coverage_data.zig"

# 등록 아이콘 → C 헤더(아래)에 codepoint 집합·이름 매크로로 emit되는 경로.
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

# 각 fit이 **무엇을 약속하는가**. 생성물 enum의 독스트링이 되며, 설명 없는 fit은 생성기가 거부한다.
# tight의 수단이 자산마다 다르다는 사실을 여기 못박는다 — 실측: search는 viewBox만 조였고(path 동일),
# chevron_*는 viewBox가 standard와 같은 대신 path를 굵고 크게 다시 그렸다(stroke .75 → 1).
FIT_DOCS = {
    FIT_STANDARD: ["자산이 준 기본 비율(대개 Octicon viewBox 0 0 16 16)."],
    FIT_TIGHT: [
        "같은 슬롯을 더 채우는 변형. **수단은 자산마다 다르다** — `search`는 viewBox를 조였고(path 동일),",
        "`chevron_*`는 viewBox가 같은 대신 path를 굵고 크게 다시 그렸다(stroke .75 → 1). 이 축이 약속하는",
        "것은 \"슬롯을 더 채운다\"이지 특정 수단이 아니다.",
    ],
}
ICONS = [
    ("git_branch", FIT_STANDARD, 0xF0001, "assets/icons/git-branch.svg"),
    ("gear", FIT_STANDARD, 0xF0002, "assets/icons/gear.svg"),
    ("plus", FIT_STANDARD, 0xF0003, "assets/icons/plus.svg"),
    ("search", FIT_STANDARD, 0xF0004, "assets/icons/search.svg"),
    ("bell", FIT_STANDARD, 0xF0005, "assets/icons/bell.svg"),
    ("sidebar_collapse", FIT_STANDARD, 0xF0006, "assets/icons/sidebar-collapse.svg"),
    ("sparkle", FIT_STANDARD, 0xF0007, "assets/icons/sparkle.svg"),
    ("diamond", FIT_STANDARD, 0xF0008, "assets/icons/diamond.svg"),
    ("mark_github", FIT_STANDARD, 0xF0009, "assets/icons/mark-github.svg"),
    ("folder", FIT_STANDARD, 0xF000A, "assets/icons/folder.svg"),
    ("reset", FIT_STANDARD, 0xF000B, "assets/icons/reset.svg"),
    ("recent", FIT_STANDARD, 0xF000C, "assets/icons/recent.svg"),
    ("folder_open", FIT_STANDARD, 0xF000D, "assets/icons/folder-open.svg"),
    ("file", FIT_STANDARD, 0xF000E, "assets/icons/file.svg"),
    ("file_code", FIT_STANDARD, 0xF000F, "assets/icons/file-code.svg"),
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
    # reset-tight.svg는 reset.svg와 **path가 완전히 동일**하고 viewBox만 `0 0 16 16` → `1 1 14 14`로
    # 조여져 있다(실측) — search 쌍과 같은 형태다. 그래서 새 이름이 아니라 `reset`의 tight 변형이다.
    # 도크는 이 그림을 "새로고침", 설정은 "되돌리기"로 쓰지만 **이름은 그림을 가리킨다**(용도가 아니라).
    ("reset", FIT_TIGHT, 0xF0021, "assets/icons/reset-tight.svg"),
    ("search", FIT_TIGHT, 0xF0022, "assets/icons/search-tight.svg"),
    ("chevron_down", FIT_TIGHT, 0xF0023, "assets/icons/chevron-down-tight.svg"),
    ("chevron_right", FIT_TIGHT, 0xF0024, "assets/icons/chevron-right-tight.svg"),
    ("host", FIT_STANDARD, 0xF0025, "assets/icons/host.svg"),
    ("hourglass", FIT_STANDARD, 0xF0026, "assets/icons/hourglass.svg"),
    # 모바일 보조 키바의 방향키. **폰트 글리프로는 안 됐다** — `↑↓←→`(U+2190~2193)는 폰트마다
    # 작게 디자인돼 44px 키캡 안에서 `esc`·`tab` 보다 훨씬 작아 보였다(화면으로 확인). 합성
    # 아이콘은 슬롯을 가장자리까지 채우므로 크기가 라벨과 무관하다. Maru 자작(chevron 획 굵기
    # .75 를 맞췄다).
    ("arrow_up", FIT_STANDARD, 0xF0027, "assets/icons/arrow-up.svg"),
    ("arrow_down", FIT_STANDARD, 0xF0028, "assets/icons/arrow-down.svg"),
    ("arrow_left", FIT_STANDARD, 0xF0029, "assets/icons/arrow-left.svg"),
    ("arrow_right", FIT_STANDARD, 0xF002A, "assets/icons/arrow-right.svg"),
    # 탐색기 헤더의 "전체 접기". **기존 자산으로는 읽히지 않았다** — chevron 하나(`>`)는 "다음/펼치기"로
    # 읽히고(방향이 반대다), `sidebar_collapse`는 사이드바를 접는 다른 동작이다. 마주 보는 chevron 둘이
    # "모은다"를 그려 접기를 가리킨다. Maru 자작(획 굵기는 arrow_* 와 같은 결로 맞췄다).
    ("collapse_all", FIT_STANDARD, 0xF002B, "assets/icons/collapse-all.svg"),
    # 소스 컨트롤의 **원격에서 받아오기**(fetch). `reset`(⟳)을 쓰지 않는 이유는 그 글리프가 같은 패널에서
    # 이미 **로컬 다시 읽기**(저장소 머리 줄 새로고침)를 뜻하기 때문이다 — 같은 그림이 두 동작이면 어느
    # 쪽이 네트워크를 타는지 화면으로 알 수 없다. `arrow_down`도 안 쓴다: 브랜치 줄에 이미 `↓ N`(behind
    # 개수)이 있어 화살표가 두 뜻이 된다. 구름 + 아래 화살표가 "원격에서 내려받는다"를 그린다.
    ("cloud_download", FIT_STANDARD, 0xF002C, "assets/icons/cloud-download.svg"),
    # 폰이 세션을 좁혀 둔 상태를 상태줄이 말할 때 쓴다(S11-6). 직접 그린 자산이다.
    ("phone", FIT_STANDARD, 0xF002D, "assets/icons/phone.svg"),
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


# Zig 키워드 — semantic 이름이 이걸 밟으면 생성물이 컴파일되지 않는다. `zig fmt`가 뱉는 진단은 파이썬
# 트레이스백에 묻혀 원인이 안 보이므로(적대적 검증에서 실측), 매니페스트 단계에서 이름으로 막는다.
# (`test`가 Zig 키워드라 한때 `test_icon`이라는 우회 이름을 손으로 골랐었다 — 그 자산은 소비처가 없어 삭제됐다.)
ZIG_KEYWORDS = frozenset("""
addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const
continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline
nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union
unreachable usingnamespace var volatile while
""".split())

# Zig primitive 타입 — 키워드는 아니지만 같은 이름의 const가 primitive를 가려 생성물이 컴파일되지 않는다.
# `u8`류는 접두사+숫자로, 나머지는 목록으로 막는다(적대적 검증: `bool`·`usize`가 세 산출물을 다 쓴 뒤
# "shadows primitive"로 깨져, 커밋 가능한 상태의 망가진 생성물이 남았다).
ZIG_PRIMITIVE_PREFIXES = ("u", "i", "f", "c_")
ZIG_PRIMITIVE_NAMES = frozenset(
    """bool void type anyerror anytype noreturn comptime_int comptime_float isize usize
    c_char c_short c_ushort c_int c_uint c_long c_ulong c_longlong c_ulonglong c_longdouble""".split()
)

# 등록 아이콘 codepoint가 있어야 하는 범위(Plane 15 PUA). 벗어나면 합성 게이트가 **터미널 콘텐츠**를
# 가로챈다 — 적대적 검증에서 `0x2588`(█ FULL BLOCK)을 등록하자 터미널의 블록 문자가 gear로 합성됐다.
PUA_MIN = 0xF0000
PUA_MAX = 0xFFFFF


def expected_asset_path(name, fit, fits):
    """이름+fit에서 **파생되는** 자산 경로. 이게 이름↔그림을 잇는 유일한 ground truth다.

    파생 규칙이 없으면 매니페스트의 이름과 경로를 함께 맞바꾸는 편집을 아무 가드도 못 잡는다(세 산출물이
    같은 소스에서 나오므로 일관된 편집은 정의상 전부 통과 — 적대적 검증에서 실증). 규칙:
    `<이름의 _를 ->[-<fit>].svg`, 기본 fit은 접미사 없음."""
    stem = name.replace("_", "-")
    if fit != default_fit(fits):
        stem = f"{stem}-{fit}"
    return f"assets/icons/{stem}.svg"


def zig_fmt(source):
    """생성한 Zig 소스를 포맷한다. **zig의 진단을 삼키지 않는다** — 예전엔 `capture_output=True`가 stderr를
    통째로 버려, 이름 하나가 Zig 키워드일 때 파이썬 트레이스백만 남고 정작 원인(`expected '.', found '='`)이
    사라졌다(적대적 검증 실측)."""
    result = subprocess.run(["zig", "fmt", "--stdin"], input=source, text=True, capture_output=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        sys.exit(f"zig fmt failed ({result.returncode}) — 생성된 소스가 유효한 Zig가 아니다")
    return result.stdout


def validate_manifest():
    """생성 전에 매니페스트 자체의 함정을 막는다. **여기서 죽는 편이 낫다** — 통과시키면 실패가 zig fmt
    트레이스백(이름)·clang 경고(심볼 충돌)·런타임 오작동(cp 중복)으로 흩어져 원인이 안 보인다."""
    seen_cp = {}
    seen_symbol = {}
    variants = {}
    for name, fit, cp, path in ICONS:
        for label, value in (("icon name", name), ("fit", fit)):
            if value in ZIG_KEYWORDS:
                raise SystemExit(f"{label} is a Zig keyword: {value!r} ({path})")
            if value in ZIG_PRIMITIVE_NAMES or (value.startswith(ZIG_PRIMITIVE_PREFIXES) and value[1:].isdigit()):
                raise SystemExit(f"{label} shadows a Zig primitive type: {value!r} ({path})")
            if not value.replace("_", "").isalnum() or value[0].isdigit():
                raise SystemExit(f"{label} is not a plain Zig identifier: {value!r} ({path})")
        if fit in variants.get(name, {}):
            raise SystemExit(f"duplicate fit for icon: {name} {fit}")
        if cp in seen_cp:
            raise SystemExit(f"duplicate codepoint 0x{cp:X}: {seen_cp[cp]} and {name}/{fit}")
        if not PUA_MIN <= cp <= PUA_MAX:
            raise SystemExit(
                f"codepoint 0x{cp:X} for {name}/{fit} is outside Plane-15 PUA "
                f"(0x{PUA_MIN:X}~0x{PUA_MAX:X}) — 합성 게이트가 터미널 콘텐츠를 가로챈다"
            )
        seen_cp[cp] = f"{name}/{fit}"
        variants.setdefault(name, {})[fit] = (cp, path)
    # 심볼 유일성은 (name, fit)이 유일해도 깨질 수 있다: semantic 이름 `search_tight`를 새로 등록하면
    # `search`의 tight 변형이 만드는 심볼과 같아진다. Zig는 중복 const로 잡지만 **C는 매크로 재정의를
    # 경고만 하고 나중 값이 이겨** 도크 아이콘이 조용히 엉뚱한 cp가 된다(적대적 검증에서 clang 실측).
    for name, fits in variants.items():
        for fit, (_, path) in fits.items():
            symbol = symbol_name(name, fit, fits)
            # **대소문자를 무시해** 비교한다 — C 매크로는 대문자라 `gear`와 `Gear`가 같은 `MARU_ICON_GEAR`가
            # 되고, clang은 재정의를 경고만 하며 나중 값이 이긴다(적대적 검증에서 실측). Zig만 보면 안 걸린다.
            key = symbol.upper()
            if key in seen_symbol:
                raise SystemExit(f"symbol collision: {symbol!r} from {seen_symbol[key]} and {name}/{fit}")
            seen_symbol[key] = f"{name}/{fit}"
            # 경로는 이름+fit에서 파생돼야 한다 — 이름과 경로를 함께 맞바꾸는 편집을 막는 유일한 규칙이다.
            expected = expected_asset_path(name, fit, fits)
            if path != expected:
                raise SystemExit(
                    f"asset path for {name}/{fit} must be derived from its name: {expected!r} (got {path!r})"
                )
            if not os.path.exists(path):
                raise SystemExit(f"asset does not exist: {path}")
    return variants


def icon_variants():
    """semantic 이름 → {fit: (cp, path)}. 선언 순서를 유지한다(생성물 순서 = ICONS 순서)."""
    return validate_manifest()


def fit_names():
    """매니페스트에 실제로 등장하는 fit들(선언 순서). `Fit` enum과 lookup 갈래가 여기서 파생된다 —
    하드코딩하면 새 fit이 enum에 없는 채 switch에만 나와 컴파일 에러가 매니페스트가 아닌 생성물을 가리킨다."""
    ordered = []
    for _, fit, _, _ in ICONS:
        if fit not in ordered:
            ordered.append(fit)
    return ordered


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
        "/// 같은 그림이 슬롯을 **얼마나 채우는가** 축(docs/chrome-strategy.md §9.7). coverage 마스터는 alpha 한",
        "/// 채널이라 여백·stroke가 **빌드타임에 굳고** 런타임에 못 바꾼다 — 그래서 변형은 자산을 하나 더 굽고",
        "/// 이 축으로 고른다(소비처마다 새 이름으로 등록하던 `session_dock_*`를 대체한다).",
        "pub const Fit = enum {",
    ]
    for fit in fit_names():
        doc = FIT_DOCS.get(fit)
        if doc is None:
            # 의미를 모르는 fit을 이름만 뱉으면 생성물이 "무엇을 고르는 축인지" 설명 없는 enum이 된다.
            raise SystemExit(f"unknown fit {fit!r}: FIT_DOCS에 설명을 추가하라")
        for line in doc:
            lines.append(f"    /// {line}")
        lines.append(f"    {fit},")
    lines += [
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
        "/// 이 아이콘에 그 fit의 **자산이 실재하는가**. `codepointFit`은 없는 조합을 기본으로 폴백하므로,",
        "/// \"요청한 fit을 실제로 받았는가\"를 알려면 이걸 봐야 한다 — 폴백이 조용한 거짓말이 되지 않게 하는",
        "/// 유일한 수단이다 — 없는 조합을 물으면 조용히 기본 자산이 오므로, 변형이 필요한 자리는 이걸로 확인한다.",
        "pub fn hasFit(icon: Icon, fit: Fit) bool {",
        "    return switch (icon) {",
    ])
    for name, fits in variants.items():
        present = " or ".join(f"fit == .{f}" for f in fits)
        lines.append(f"        .{name} => {present},")
    lines.extend([
        "    };",
        "}",
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
    ])
    for fit in fit_names():
        overrides = [
            (name, fits[fit][0]) for name, fits in variants.items() if fit in fits and default_fit(fits) != fit
        ]
        if overrides.__len__() == 0:
            lines.append(f"        .{fit} => codepoint(icon),")
            continue
        lines.append(f"        .{fit} => switch (icon) {{")
        for name, cp in overrides:
            lines.append(f"            .{name} => 0x{cp:X},")
        lines.append("            else => codepoint(icon),")
        lines.append("        },")
    lines.extend([
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
    ])
    for fit in fit_names():
        overrides = [
            (name, fits[fit][0]) for name, fits in variants.items() if fit in fits and default_fit(fits) != fit
        ]
        if overrides.__len__() == 0:
            lines.append(f"        .{fit} => utf8(icon),")
            continue
        lines.append(f"        .{fit} => switch (icon) {{")
        for name, cp in overrides:
            lines.append(f"            .{name} => \"\\u{{{cp:X}}}\",")
        lines.append("            else => utf8(icon),")
        lines.append("        },")
    lines.extend([
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
        "        // fit도 **comptime 전수**한다 — 배열에 손으로 적으면 새 fit이 조용히 검증 밖에 남는다",
        "        // (적대적 검증 실측: 세 번째 fit이 미등록 cp를 가리켜도 전부 통과했다).",
        "        inline for (@typeInfo(Fit).@\"enum\".fields) |fit_field| {",
        "            const fit: Fit = @enumFromInt(fit_field.value);",
        "            const cp = codepointFit(icon, fit);",
        "            const resolved = fromCodepoint(cp) orelse return error.TestUnexpectedResult;",
        "            try std.testing.expectEqual(icon, resolved.icon); // 폴백해도 같은 아이콘이다",
        "            // **fit 계약**: 자산이 있으면 그 fit을 그대로 받고, 없으면 기본 fit으로 떨어진다. 이걸 안 보면",
        "            // `.standard`를 요청했는데 tight 자산을 받는 침묵이 어떤 테스트에도 안 걸린다(적대적 검증 지적).",
        "            if (hasFit(icon, fit)) {",
        "                try std.testing.expectEqual(fit, resolved.fit);",
        "            } else {",
        "                try std.testing.expectEqual(codepoint(icon), cp);",
        "                try std.testing.expect(hasFit(icon, resolved.fit));",
        "            }",
        "            var buf: [4]u8 = undefined;",
        "            const len = try std.unicode.utf8Encode(cp, &buf);",
        "            try std.testing.expectEqualStrings(buf[0..len], utf8Fit(icon, fit));",
        "        }",
        "    }",
        "}",
        "",
        "test \"icons: 변형이 등록된 아이콘은 기본과 다른 codepoint를 주고, 없으면 기본으로 폴백한다\" {",
        "    const std = @import(\"std\");",
        "    // 도크가 쓰는 tight 변형 — 기본과 달라야 변형이 실제로 등록된 것이다.",
        "    try std.testing.expect(codepointFit(.chevron_down, .tight) != codepoint(.chevron_down));",
        "    try std.testing.expect(codepointFit(.search, .tight) != codepoint(.search));",
        "    // 변형이 없는 아이콘은 기본으로 떨어진다(소비처가 조합마다 분기하지 않게).",
        "    try std.testing.expectEqual(codepoint(.gear), codepointFit(.gear, .tight));",
        "}",
        "",
        "test \"icons: 모든 아이콘이 standard 자산을 갖는다(기본 fit 뒤집힘 방지)\" {",
        "    const std = @import(\"std\");",
        "    // standard 자산이 없는 아이콘은 **변형이 기본이 된다**. 그 상태에서 나중에 standard를 추가하면",
        "    // 기본이 뒤집혀 fit 없이 부르던 소비처가 조용히 다른 그림을 그린다(적대적 검증이 짚은 default flip).",
        "    // 지금은 그런 아이콘이 없다 — 새로 만들려면 의도적 결정이어야 하므로, 그때 이 단언이 깨져",
        "    // 소비처가 fit을 명시했는지 확인하게 한다.",
        "    inline for (@typeInfo(Icon).@\"enum\".fields) |field| {",
        "        const icon: Icon = @enumFromInt(field.value);",
        "        try std.testing.expect(hasFit(icon, .standard));",
        "    }",
        "}",
    ])
    raw_zig = "\n".join(lines) + "\n"
    return zig_fmt(raw_zig)


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
            svg_digest = hashlib.sha256(asset.read()).hexdigest()
        # coverage 픽셀 자체의 해시도 싣는다. 이게 **cp ↔ 그림**을 잇는다 — 없으면 생성물에서
        # `.data = &gear`와 `&plus`를 손으로 맞바꿔도 어떤 테스트도 못 잡는다(적대적 검증에서 실증).
        coverage_digest = hashlib.sha256(bytes(cov)).hexdigest()
        manifest.append((symbol, cp, path, svg_digest, coverage_digest))
    lines.append("")
    lines.append("pub const Entry = struct { cp: u32, data: []const u8 };")
    lines.append("")
    lines.append("pub const icons = [_]Entry{")
    for cp, name in entries:
        lines.append(f"    .{{ .cp = 0x{cp:X}, .data = &{name} }},")
    lines.append("};")
    lines.extend([
        "",
        "/// `sha256`은 원본 SVG의 해시, `coverage_sha256`은 그 SVG에서 구운 alpha 마스터의 해시다.",
        "/// 앞은 \"자산 파일이 안 바뀌었나\", 뒤는 \"이 codepoint가 그 그림을 가리키나\"를 증명한다.",
        "pub const Asset = struct {",
        "    name: []const u8,",
        "    cp: u32,",
        "    path: []const u8,",
        "    sha256: []const u8,",
        "    coverage_sha256: []const u8,",
        "};",
        "",
        "pub const asset_manifest = [_]Asset{",
    ])
    for name, cp, path, digest, coverage_digest in manifest:
        lines.append(
            f'    .{{ .name = "{name}", .cp = 0x{cp:X}, .path = "{path}", '
            f'.sha256 = "{digest}", .coverage_sha256 = "{coverage_digest}" }},'
        )
    lines.append("};")
    raw_zig = "\n".join(lines) + "\n"
    return zig_fmt(raw_zig), c_header(entries), icons_zig()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when committed Zig coverage, C registry, name registry, asset manifest, or hashes drift",
    )
    args = parser.parse_args()
    zig_source, header, ids_source = generate()
    targets = (
        (COVERAGE_ZIG_PATH, zig_source),
        (C_HEADER_PATH, header),
        (ICONS_ZIG_PATH, ids_source),
    )
    if args.check:
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
    # **세 산출물 모두 직접 쓴다.** 예전엔 coverage만 stdout으로 내보내 `> src/renderer/icon_coverage_data.zig`로
    # 받게 했는데, 셸이 파이썬 실행 **전에** 타깃을 비우므로 생성이 실패하면 커밋된 데이터가 0바이트로 남았다
    # (적대적 검증에서 재현). 파일 쓰기는 생성이 전부 성공한 뒤에만 일어난다.
    for path, source in targets:
        with open(path, "w") as output:
            output.write(source)
        print(f"wrote {path}", file=sys.stderr)


if __name__ == "__main__":
    main()
