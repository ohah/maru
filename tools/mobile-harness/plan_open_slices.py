#!/usr/bin/env python3
"""계획서의 «열린 것» 이 머리말 목록과 같은지 본다.

**왜 이것이 필요한가.** 같은 문서 안에서 상태가 **두 곳**에 산다 — 표의 상태 칸과 아래 서술절.
측정은 서술절에 쌓이는데 사람이 먼저 읽는 것은 표라, 표만 낡으면 **끝난 일을 다시 하러 간다.**
2026-09-11 하루에 세 번 그랬다(M12 「미착수」·U2 「남은 것은 실기 확인뿐」·U1 「하나 남았다」 —
셋 다 실제로는 끝나 있었고, 그중 하나는 실제로 「다음 항목」 추천을 틀리게 만들었다).

**그 세 사고는 방향이 하나다** — 끝난 일이 «열려 있다» 고 적힌 것. 그 방향만 막는다.

규칙 둘:
  ① 상태 칸은 **정해진 낱말로 시작**한다 — 완료 · 착수 · 닫혔다 · 열림 · 막힘.
  ② `열림`·`막힘` 인 행의 집합이 머리말 「지금 열린 것」·「막힌 것」 목록과 **정확히 같다.**

②가 핵심이다: 행 하나를 열린 채로 두려면 **머리말에도 적어야** 하고, 머리말을 적으려면
「정말 열려 있나」를 한 번 보게 된다. 그리고 그 목록이 곧 「뭐가 남았나」의 답이 된다 —
지금까지는 그 답을 만들려고 문서를 통째로 뒤져야 했다.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "docs/plans/mobile-platform.md"
text = PLAN.read_text(encoding="utf-8")

ALLOWED = ("완료", "착수", "닫혔다", "열림", "막힘")
ROW = re.compile(r"^\|\s*\*{0,2}([MUS][0-9][A-Za-z0-9.\-]*)\*{0,2}\s*\|(.*)$")

bad = 0
open_rows, blocked_rows = set(), set()
for line in text.splitlines():
    m = ROW.match(line)
    if not m:
        continue
    rid, rest = m.group(1), m.group(2)
    cells = rest.split("|")
    status = cells[-2] if len(cells) >= 2 else cells[-1]
    head = re.sub(r"[*`]", "", status).strip()
    word = next((w for w in ALLOWED if head.startswith(w)), None)
    if word is None:
        print(f"  어휘   {rid} 의 상태가 {ALLOWED} 중 하나로 시작하지 않는다: {head[:30]!r}")
        bad += 1
        continue
    if word == "열림":
        open_rows.add(rid)
    elif word == "막힘":
        blocked_rows.add(rid)

def listed(title: str) -> set:
    """머리말 목록에서 그 절이 나열한 행 id."""
    i = text.find(title)
    if i < 0:
        return set()
    # **다음 제목까지다 — 수준을 가리지 않는다.** `\n## ` 만 찾으면 바로 뒤의 `###` 절을
    # 통째로 삼켜, 「열린 것」 목록이 「막힌 것」까지 든 것처럼 보인다(짜자마자 그렇게 틀렸다).
    j = text.find("\n#", i + 1)
    body = text[i : j if j > 0 else len(text)]
    return set(re.findall(r"^-\s+\*{0,2}([MUS][0-9][A-Za-z0-9.\-]*)\*{0,2}\s", body, re.M))

for title, rows, name in (
    ("### 지금 열린 것", open_rows, "열림"),
    ("### 막힌 것", blocked_rows, "막힘"),
):
    want = listed(title)
    for rid in sorted(rows - want):
        print(f"  누락   {rid} 의 상태가 «{name}» 인데 머리말 목록에 없다 — 「{title[4:]}」에 적어라")
        bad += 1
    for rid in sorted(want - rows):
        print(f"  잉여   머리말 「{title[4:]}」이 {rid} 를 드는데 그 행의 상태는 «{name}» 이 아니다")
        bad += 1

# **「여기까지」와 「열린 것」이 어긋나지 않게 한다.** 멈춤을 적어 둔 채 열린 행이 늘면 그 절이
# 곧 거짓이 된다 — 다시 열 때 사람이 제일 먼저 읽는 자리라 거기가 낡으면 판단이 통째로 틀린다.
# 재개(=행을 더 여는 일)는 그 절을 함께 고치게 만든다.
PARKED = "## 여기까지 — 모바일은 멈춘다"
if PARKED in text:
    parked_at = len(open_rows) + len(blocked_rows)
    if parked_at != 4:
        print(f"  멈춤   「여기까지」를 적어 둔 채 열림+막힘이 {parked_at} 개다(멈출 때는 4) — "
              "다시 여는 중이면 그 절을 함께 고쳐라")
        bad += 1

print(f"열림 {len(open_rows)}개 / 막힘 {len(blocked_rows)}개 / 어긋남 {bad}개")
sys.exit(1 if bad else 0)
