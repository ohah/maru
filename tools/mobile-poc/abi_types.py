#!/usr/bin/env python3
"""ABI 헤더 선언과 Zig export 의 **타입**이 맞는지 본다.

지금 판정자는 이름 집합만 대조한다 — 타입이 어긋나도 C 는 컴파일되고 값만 조용히 깨진다
(예: `unsigned long long` 자리에 `u32`, 포인터 자리에 정수).
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
h = (ROOT / "src/platform/mobile/mobile_host_abi.h").read_text(encoding="utf-8")
z = (ROOT / "src/platform/mobile/mobile_bridge.zig").read_text(encoding="utf-8")

# C 선언: 반환형 이름(인자...);
c_decls = {}
for m in re.finditer(r"^([A-Za-z][A-Za-z ]*?)\s+(maru_mobile_[a-z_]+)\s*\(([^;]*)\);", h, re.M):
    ret, name, args = m.group(1).strip(), m.group(2), m.group(3).strip()
    c_decls[name] = (ret, args)

z_decls = {}
for m in re.finditer(r"pub export fn (maru_mobile_[a-z_]+)\(([^)]*)\)\s*([A-Za-z0-9_\[\]\*\.]+)\s*\{", z):
    z_decls[m.group(1)] = (m.group(3).strip(), m.group(2).strip())

C2Z = {
    "unsigned int": {"u32"},
    "int": {"c_int", "i32"},
    "void": {"void"},
    "unsigned long long": {"u64"},
    "float": {"f32"},
    "const char *": {"[*:0]const u8", "[*]const u8"},
    "unsigned char *": {"[*]u8"},
    "const MaruQuad *": {"[*]const MaruQuad", "[*]const draw"},
}

bad = 0
for name, (cret, cargs) in sorted(c_decls.items()):
    if name not in z_decls:
        print(f"  없음   {name} — 헤더에만 있다")
        bad += 1
        continue
    zret, zargs = z_decls[name]
    ok = zret in C2Z.get(cret, {zret})
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
