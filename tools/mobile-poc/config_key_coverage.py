#!/usr/bin/env python3
"""데스크톱 config 키가 **모바일 문서에서 하나도 빠짐없이 판정됐는지** 본다.

`docs/mobile-config.md` 는 "데스크톱 키를 전부 훑어 갈랐다" 고 주장한다. 그 주장은 **셀 수 있다** —
`docs/configuration.md` 의 키 표를 읽어 각 키가 모바일 문서에 실렸는지(싣는다/나중에/안 가져온다
중 어디든) 확인하면 된다. 적대적 검증에서 13개가 어디에도 없는 채로 통과하고 있었다.

이 판정자는 **앞으로 데스크톱에 키가 늘 때도** 문다 — 새 키를 더하는 PR 이 "이건 모바일에서
어떻게 하나" 를 한 번은 적게 만든다. 그게 두 문서가 갈리지 않는 유일한 방법이다.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
desktop = (ROOT / "docs/configuration.md").read_text(encoding="utf-8")
mobile = (ROOT / "docs/mobile-config.md").read_text(encoding="utf-8")

# 키 표의 행: `| \`key\` | ...`
keys = sorted({m.group(1) for m in re.finditer(r"^\|\s*`([a-z0-9.-]+)`", desktop, re.M)})

# 모바일 문서가 쓰는 표기: 정확한 키(`font.size`) 또는 접두어 묶음(`window.*`).
wild = {m.group(1) for m in re.finditer(r"`([a-z0-9-]+)\.\*`", mobile)}
exact = {m.group(1) for m in re.finditer(r"`([a-z0-9.-]+)`", mobile)}

# **와일드카드가 개별 판정을 삼키지 못하게 한다.** `input.*` 한 줄로 13개를 덮어 버리면 이
# 판정자가 하려던 일("키마다 한 번은 결정하게")이 통째로 무력해진다(적대적 검증에서 그렇게
# 뚫렸다). 묶어서 **빼는** 것은 되지만, 그 계열에 개별 판정이 하나라도 있으면 겹친 것이다 —
# 같은 키에 판정이 둘이면 어느 쪽이 참인지 문서만 봐서는 모른다.
overlap = []
for w in sorted(wild):
    individual = [k for k in keys if k.startswith(w + ".") and k in exact]
    if individual:
        overlap.append((w, individual))

missing = []
for k in keys:
    if k in exact:
        continue
    if k.split(".")[0] in wild:
        continue
    # `theme.palette.0` 처럼 계열 키는 대표 표기(`theme.palette.N`)로 덮인 것으로 본다.
    if any(e.rstrip(".N0123456789") == k.rstrip(".N0123456789") for e in exact if "." in e):
        continue
    missing.append(k)

for k in missing:
    print(f"  없음   {k} 가 모바일 문서 어디에도 없다 — 싣는지 아닌지 적어야 한다")
for w, ind in overlap:
    print(f"  겹침   `{w}.*` 가 개별 판정을 삼킨다: {', '.join(ind)}")
bad = len(missing) + len(overlap)
print(f"데스크톱 키 {len(keys)}개 / 판정 안 된 키 {len(missing)}개 / 겹친 묶음 {len(overlap)}개")
sys.exit(1 if bad else 0)
