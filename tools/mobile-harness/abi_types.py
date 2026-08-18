#!/usr/bin/env python3
"""ABI 헤더 선언과 Zig export 의 **타입**이 맞는지 본다.

지금 판정자는 이름 집합만 대조한다 — 타입이 어긋나도 C 는 컴파일되고 값만 조용히 깨진다
(예: `unsigned long long` 자리에 `u32`, 포인터 자리에 정수).
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
h = (ROOT / "src/platform/mobile/mobile_host_abi.h").read_text(encoding="utf-8")
# **Zig 쪽은 한 파일이 아니다.** SSH ABI 는 `mobile_ssh.zig` 에 있고, 여기 안 넣으면 그 진입점
# 전부가 "헤더에만 있다" 로 보이거나(더 나쁘게는) 새 파일을 통째로 안 보게 된다 — 게이트가
# 조용히 절반만 지키는 상태가 이 저장소에서 여러 번 났다.
z = "\n".join(
    (ROOT / name).read_text(encoding="utf-8")
    for name in (
        "src/platform/mobile/mobile_bridge.zig",
        "src/platform/mobile/mobile_ssh.zig",
    )
)

# C 선언: 반환형 이름(인자...);
#
# **포인터를 빼먹으면 안 된다.** 예전 정규식은 반환형을 `[A-Za-z ]` 로 잡아 `*` 가 있는 선언을
# 통째로 건너뛰었고(`const char *`·`const MaruQuad *`·`const unsigned char *`), Zig 쪽 정규식도
# 공백이 없어 `[*:0]const u8` 을 못 잡았다. **양쪽에서 같은 셋이 빠져 서로 상쇄돼** 검사기가
# "어긋난 선언 0개" 라고 답했다 — 하필 그 셋이 포인터 반환이라, 정수와 뒤바뀌면 C 는 그 정수를
# 주소로 읽는 가장 위험한 자리다.
c_decls = {}
for m in re.finditer(
    r"^([A-Za-z_][A-Za-z0-9_ ]*?)\s*(\*?)\s*(maru_mobile_[a-z_]+)\s*\(([^;]*)\);", h, re.M
):
    base, star, name, args = m.group(1).strip(), m.group(2), m.group(3), m.group(4).strip()
    c_decls[name] = (f"{base} *" if star else base, args)

z_decls = {}
for m in re.finditer(r"pub export fn (maru_mobile_[a-z_]+)\(([^)]*)\)\s*([^{]+?)\s*\{", z):
    z_decls[m.group(1)] = (" ".join(m.group(3).split()), m.group(2).strip())

C2Z = {
    "unsigned int": {"u32"},
    "int": {"c_int", "i32"},
    "void": {"void"},
    "unsigned long": {"usize"},
    "unsigned long long": {"u64"},
    "float": {"f32"},
    "const char *": {"[*:0]const u8", "[*]const u8"},
    "unsigned char *": {"[*]u8"},
    "const unsigned char *": {"[*]const u8"},
    "const MaruQuad *": {"[*]const MaruQuad", "[*]const draw"},
}

bad = 0
for name, (cret, cargs) in sorted(c_decls.items()):
    if name not in z_decls:
        print(f"  없음   {name} — 헤더에만 있다")
        bad += 1
        continue
    zret, zargs = z_decls[name]
    # **모르는 C 타입은 통과가 아니라 실패다.** 예전에는 표에 없으면 `{zret}` 로 폴백해 **Zig 가
    # 뭐라고 하든 받아들였다** — 새 타입을 쓴 선언이 들어오면 그때부터 그 함수는 검사에서 조용히
    # 빠진다(`const unsigned char *` 가 실제로 그렇게 새고 있었다). 표를 늘리라고 말하게 한다.
    if cret not in C2Z:
        print(f"  모름   {name}: C 반환형 '{cret}' 가 C2Z 표에 없다 — 표에 더한다")
        bad += 1
        continue
    ok = zret in C2Z[cret]
    # 인자 개수만 센다(이름·순서는 사람이 본다)
    cn = 0 if cargs in ("", "void") else len([a for a in cargs.split(",") if a.strip()])
    zn = 0 if not zargs else len([a for a in zargs.split(",") if a.strip()])
    if not ok or cn != zn:
        print(f"  다름   {name}: C({cret}, 인자{cn}) vs Zig({zret}, 인자{zn})")
        bad += 1

for name in sorted(set(z_decls) - set(c_decls)):
    print(f"  없음   {name} — Zig 에만 있다(헤더가 안 실었다)")
    bad += 1

print(f"어긋난 선언 {bad}개 / 헤더 {len(c_decls)}개")
raise SystemExit(1 if bad else 0)
