#!/usr/bin/env python3
"""계약 문서가 인용한 계획 슬라이스가 계획 표에 실제로 있는지 본다.

예전 판정자는 **슬라이스 이름을 스크립트에 손으로 적어** 뒀다(`for m in M4a2 M4a3 ... M10`).
그러면 계획을 쪼개거나 이름을 바꿀 때마다 판정자도 같이 고쳐야 하고, 안 고치면 **없는 슬라이스를
계속 찾거나**(오탐) **새 인용을 아예 안 보게 된다**(누락). 인용을 훑어 대조한다.

접두어를 인정한다 — `M3` 는 `M3a`·`M3b`·`M3c` 를 묶어 부르는 이름이라 그 가족이 있으면 맞다.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
plan = (ROOT / "docs/plans/mobile-platform.md").read_text(encoding="utf-8")
rows = set(re.findall(r"^\|\s*\*{0,2}(M[0-9]+[a-z0-9.]*|U[0-9]+)\*{0,2}\s*\|", plan, re.M))

CONTRACTS = ["docs/mobile-platform.md", "docs/mobile-ux.md", "docs/mobile-config.md"]
bad = 0
cited_n = 0
for rel in CONTRACTS:
    text = (ROOT / rel).read_text(encoding="utf-8")
    for m in re.finditer(
        r"\[\*{0,2}(M[0-9]+[a-z0-9.]*|U[0-9]+)\*{0,2}\]\((?:\.\./)?plans/mobile-platform\.md", text
    ):
        cited_n += 1
        slice_id = m.group(1)
        if not any(r == slice_id or r.startswith(slice_id) for r in rows):
            print(f"  없음   {rel} 이 {slice_id} 를 가리키는데 계획 표에 그런 행이 없다")
            bad += 1

print(f"인용 {cited_n}개 / 계획 행 {len(rows)}개 / 없는 인용 {bad}개")
sys.exit(1 if bad else 0)
