#!/usr/bin/env python3
"""계약 문서가 인용한 계획 슬라이스가 계획 표에 실제로 있는지 본다.

예전 판정자는 **슬라이스 이름을 스크립트에 손으로 적어** 뒀다(`for m in M4a2 M4a3 ... M10`).
그러면 계획을 쪼개거나 이름을 바꿀 때마다 판정자도 같이 고쳐야 하고, 안 고치면 **없는 슬라이스를
계속 찾거나**(오탐) **새 인용을 아예 안 보게 된다**(누락). 인용을 훑어 대조한다.

접두어를 인정한다 — `M3` 는 `M3a`·`M3b`·`M3c` 를 묶어 부르는 이름이라 그 가족이 있으면 맞다.

**링크만 보지 않는다.** 계약 문서는 슬라이스를 산문으로도 부른다(`M0`·`M9`·`M4a3` 이 그렇다).
링크된 것만 보면 이름을 바꿨을 때 그 언급들이 조용히 썩는다 — 적대적 검증에서 드러난 구멍이다.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
plan = (ROOT / "docs/plans/mobile-platform.md").read_text(encoding="utf-8")
rows = set(re.findall(r"^\|\s*\*{0,2}(M[0-9]+[a-z0-9.]*|U[0-9]+)\*{0,2}\s*\|", plan, re.M))

# **여기를 넓히지 말 것.** `verification-matrix.md` 도 `plans/mobile-platform.md` 를 가리키지만
# 그 문서의 M/U 토큰은 **다른 이니셔티브의 축**이다(M0a·M2a·M3d·U3… 은 모바일 계획에 없다).
# 넣으면 오탐이 쏟아진다 — 산문까지 훑는 판정이라 "이 문서의 M/U 는 전부 모바일 슬라이스" 가
# 성립하는 문서만 대상이 된다. 적대적 검증에서 넓히려다 반증됐다.
CONTRACTS = ["docs/mobile-platform.md", "docs/mobile-ux.md", "docs/mobile-config.md"]
bad = 0
cited_n = 0
for rel in CONTRACTS:
    text = (ROOT / rel).read_text(encoding="utf-8")
    # 링크(`[M10](plans/...)`)와 산문(`M4a3`) 둘 다. 코드블록 안은 뺀다 — 예시 코드에 든 토큰은
    # 계획 인용이 아니다.
    prose = re.sub(r"```.*?```", "", text, flags=re.S)
    for slice_id in sorted(set(re.findall(r"\b(M[0-9]+(?:\.[0-9]+)?[a-z]?[0-9]?|U[0-9])\b", prose))):
        cited_n += 1
        if not any(r == slice_id or r.startswith(slice_id) for r in rows):
            print(f"  없음   {rel} 이 {slice_id} 를 가리키는데 계획 표에 그런 행이 없다")
            bad += 1

# ── SSH 축 ──────────────────────────────────────────────────────────────────
# 같은 결함(없는 슬라이스를 가리키는 계약 문서)이 SSH 쪽에도 있는데 아무도 안 쟀다.
# 다른 점 하나: SSH 계획은 하위 슬라이스를 표의 행이 아니라 **셀 산문**에 적는다
# (`**S9b-1**(완료)`). 그래서 행 머리말이 아니라 계획 문서 전체에서 토큰을 걷는다.
# 그리고 **정확히 일치**를 요구한다 — 접두 매칭을 허용하면 계획에 없는 우산 이름
# (`S9b-2`; 실제 이름은 `S9b-2a`·`S9b-2b-1`·`S9b-2b-2`)이 통과한다(실제로 그렇게 새 나갔다).
ssh_plan = (ROOT / "docs/plans/ssh-client.md").read_text(encoding="utf-8")
SSH_TOKEN = r"\b(S[0-9]+[a-z]?(?:-[0-9]+)?[a-z]?)\b"
ssh_known = set(re.findall(SSH_TOKEN, ssh_plan))
for rel in ["docs/ssh-client.md", "docs/control-plane.md", "docs/mobile-ux.md", "docs/mobile-platform.md"]:
    prose = re.sub(r"```.*?```", "", (ROOT / rel).read_text(encoding="utf-8"), flags=re.S)
    for slice_id in sorted(set(re.findall(SSH_TOKEN, prose))):
        cited_n += 1
        if slice_id not in ssh_known:
            print(f"  없음   {rel} 이 {slice_id} 를 가리키는데 SSH 계획에 그런 슬라이스가 없다")
            bad += 1

print(f"인용 {cited_n}개 / 계획 행 {len(rows)}개 / 없는 인용 {bad}개")
sys.exit(1 if bad else 0)
