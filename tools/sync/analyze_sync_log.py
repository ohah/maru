#!/usr/bin/env python3
"""maru .sync 관측 로그 분석기 — sync(2026) 게이트의 리더↔메인 desync를 데이터로 짚는다.

배경: docs/io-render-threading.md §11.6. `MARU_DEBUG=1`로 maru를 돌리면 app_session.zig의
`logSyncGateDiag`가 tick마다 다음 형식을 stderr(.sync 스코프)로 찍는다:

    info(sync): tick=N active=0/1 hold=H/T gproj=0/1 cproj=0/1 force=0/1 dirty=0/1 chrome=0/1 voff=V bsu=B esu=E out=O

의미:
  active = 이 tick에 메인이 per-tick 샘플한 sync_output(1=BSU 구간 관측)
  hold/T = sync_hold_ticks / timeout tick 수(H가 T에 도달하면 sync 중에도 강제 투영 = half-frame 위험)
  gproj  = 이 tick에 grid 전체 투영했는지
  bsu/esu= 리더(parser.feed)가 지금까지 처리한 BSU/ESU 누적(메인 관측과 무관한 ground truth)

이 스크립트가 짚는 실패 모드:
  (1) half-drawn frame = active=1(리더 기준 프레임 미완성=BSU 구간)인데 grid 투영(gproj=1)한 tick.
      bubbletea는 diff 렌더라 그 half-drawn 셀을 이후 안 고침 → 색·셀렉터 깨짐(Ctrl+L 무효). 원인별 분해:
        esu_edge = esu_advanced가 다음 프레임 BSU가 이미 시작된 시점에 투영(SSH 연속 조각 프레임서 빈발, 유력)
        timeout  = hold가 1초(sync_timeout) 초과해 강제 해제(느린 링크의 큰 프레임)
        scroll/force = 스크롤 면제·atlas repack(대개 무해)
  (2) 샘플링 누락 = 리더 BSU/ESU 누적 ≫ 메인 active=1 tick 수 — flush 창 < 1 tick라 per-tick 샘플링이
      transition을 놓침(esu_advanced 안전판이 커버해야 함).

사용: MARU_DEBUG=1 ./maru-macos-app 2> /tmp/maru-sync.log
      python3 tools/sync/analyze_sync_log.py /tmp/maru-sync.log
"""
import re
import sys

# .sync 로그 한 줄에서 key=value를 뽑는다. 프리픽스(info(sync): 등)·타임스탬프 유무와 무관하게
# tick=/bsu=/esu=를 모두 가진 줄만 sync 로그로 본다(다른 스코프 로그와 안 섞이게).
FIELD_RE = re.compile(r"(\w+)=(\d+)(?:/(\d+))?")


def parse_line(line):
    if "tick=" not in line or "bsu=" not in line or "esu=" not in line:
        return None
    fields = {}
    for m in FIELD_RE.finditer(line):
        key, val, second = m.group(1), int(m.group(2)), m.group(3)
        fields[key] = val
        if second is not None:  # hold=H/T → hold, hold_timeout
            fields[key + "_timeout"] = int(second)
    if "tick" not in fields or "active" not in fields:
        return None
    return fields


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    rows = []
    with open(argv[1], "r", errors="replace") as fh:
        for line in fh:
            row = parse_line(line)
            if row is not None:
                rows.append(row)
    if not rows:
        print("sync 로그 줄을 못 찾음 — MARU_DEBUG=1로 실행했고 .sync 라인이 있는지 확인하세요.")
        return 1

    n = len(rows)
    active_ticks = sum(1 for r in rows if r.get("active", 0) == 1)
    total_bsu = rows[-1].get("bsu", 0) - rows[0].get("bsu", 0)
    total_esu = rows[-1].get("esu", 0) - rows[0].get("esu", 0)
    timeout = max((r.get("hold_timeout", 0) for r in rows), default=0)

    # 핵심: active=1(리더 기준 프레임 미완성=BSU 구간)인데 grid 투영(gproj=1)한 tick = **half-drawn frame 위험**.
    # shouldProjectFrame상 active=1 & gproj=1이면 sync_blocks=false여야 하고, 그 원인은 아래 넷 중 하나다.
    # bubbletea diff 렌더면 half-drawn 셀이 이후 안 고쳐져 색·셀렉터가 깨진다(Ctrl+L 무효) — SSH desync 본체.
    prev_voff = None
    for r in rows:  # voff 변화(scroll) 판정을 위해 직전 voff를 각 행에 붙인다.
        r["_scrolled"] = (prev_voff is not None and r.get("voff") != prev_voff)
        prev_voff = r.get("voff")
    active_gproj = [r for r in rows if r.get("active", 0) == 1 and r.get("gproj", 0) == 1]

    def cause(r):
        if r.get("hold_timeout", 0) > 0 and r.get("hold", 0) >= r.get("hold_timeout", 0):
            return "timeout"      # (a) 1초 초과 강제 해제(느린 SSH 프레임)
        if r.get("force", 0) == 1:
            return "force"        # (c) atlas repack 강제(무관할 가능성 높음)
        if r.get("_scrolled"):
            return "scroll"       # (d) 스크롤 리페인트(의도된 면제)
        return "esu_edge"         # (b) esu_advanced가 다음 BSU 구간에서 투영 — SSH 빈발 half-frame 유력

    by_cause = {"timeout": [], "esu_edge": [], "scroll": [], "force": []}
    for r in active_gproj:
        by_cause[cause(r)].append(r)
    timeout_forced = by_cause["timeout"]
    # 최대 hold 지속(1 episode가 얼마나 오래 붙잡혔나 — timeout에 근접하면 SSH 지연 증거).
    max_hold = max((r.get("hold", 0) for r in rows), default=0)

    # sync episode = active=1이 이어진 구간. 각 episode의 시작 tick·최대 hold·종료 사유를 낸다.
    episodes = []
    cur = None
    for r in rows:
        if r.get("active", 0) == 1:
            if cur is None:
                cur = {"start": r.get("tick"), "max_hold": 0, "forced": False, "gproj_in": 0}
            cur["max_hold"] = max(cur["max_hold"], r.get("hold", 0))
            if r in timeout_forced:
                cur["forced"] = True
            if r.get("gproj", 0) == 1:
                cur["gproj_in"] += 1
        else:
            if cur is not None:
                episodes.append(cur)
                cur = None
    if cur is not None:
        episodes.append(cur)

    print(f"== maru .sync 로그 분석: {argv[1]} ==")
    print(f"sync 로그 tick 수         : {n}")
    print(f"active=1 tick 수           : {active_ticks}")
    print(f"리더 처리 BSU / ESU 누적   : {total_bsu} / {total_esu}")
    print(f"sync episode 수(active 구간): {len(episodes)}")
    print(f"timeout(tick)              : {timeout}")
    print(f"최대 hold 지속(tick)       : {max_hold}"
          + (f"  ← timeout({timeout})에 근접/도달!" if timeout and max_hold >= timeout else ""))
    print()

    # 실패 모드 (1) — half-drawn frame (active 중 grid 투영), 원인별 분해
    print("── 실패 모드 (1): active 중 grid 투영 = half-drawn frame (SSH desync 본체) ──")
    if active_gproj:
        print(f"  ⚠️  {len(active_gproj)}개 tick에서 active=1(프레임 미완성) & gproj=1(투영) → half-drawn 위험.")
        print("     원인별:")
        labels = {
            "esu_edge": "esu_advanced가 다음 BSU 구간에서 투영 (SSH 빈발 half-frame 유력)",
            "timeout":  "hold>=timeout 강제 해제 (느린 SSH 프레임, >1초)",
            "scroll":   "스크롤 리페인트 (의도된 면제 — 무해할 가능성)",
            "force":    "atlas repack 강제 (sync와 무관할 가능성)",
        }
        for c in ("esu_edge", "timeout", "scroll", "force"):
            if by_cause[c]:
                print(f"       {len(by_cause[c]):5d}  {labels[c]}")
        print("     예시 tick:")
        for r in active_gproj[:5]:
            print(f"       tick={r.get('tick')} [{cause(r)}] hold={r.get('hold')}/{r.get('hold_timeout')} "
                  f"bsu={r.get('bsu')} esu={r.get('esu')} dirty={r.get('dirty')} out={r.get('out')}")
        if timeout_forced:
            forced_eps = sum(1 for e in episodes if e["forced"])
            print(f"     → {forced_eps}/{len(episodes)} episode가 ESU 없이 timeout으로 강제 종료됨.")
    else:
        print("  ✓ 없음 — active 중 grid 투영이 안 일어남(이 desync 모드는 미재현이거나 원인이 다름).")
    print()

    # 실패 모드 (2) — 빠른 episode / 샘플링 누락
    print("── 실패 모드 (2): 리더 transition ≫ 메인 active 관측 (flush<tick 샘플링 누락) ──")
    # 리더가 처리한 episode(≈bsu) 대비 메인이 active로 본 tick이 현저히 적으면 샘플링이 놓친 것.
    if total_bsu > 0 and active_ticks < total_bsu:
        print(f"  ⚠️  리더 BSU={total_bsu}인데 active=1 tick은 {active_ticks} — 일부 episode가 1 tick보다 짧아")
        print("     per-tick 샘플링이 놓쳤을 수 있다(esu_advanced 안전판이 커버하는지 아래 확인).")
    else:
        print(f"  ✓ active=1 tick({active_ticks}) >= 리더 BSU({total_bsu}) — episode가 tick보다 길어 샘플링 누락 아님"
              " (SSH 조각 전달 = 느린 episode 쪽).")
    print()

    print("해석 가이드:")
    print("  · esu_edge가 다수면 → esu_advanced가 '다음 프레임 BSU가 이미 시작된' 시점에 투영해 half-drawn.")
    print("    로컬은 다음 ESU가 곧 교정하지만 bubbletea diff는 그 셀을 다시 안 보내 영구 stale. 픽스 방향:")
    print("    esu_advanced 투영을 '리더가 지금 BSU 안이 아닐 때만'으로 제한(방금 본 esu가 그 사이 새 BSU로")
    print("    덮이지 않았는지) 하거나, 강제 투영 시 원격에 full-redraw 유도.")
    print("  · timeout이 다수면 → 느린 링크에서 1초 초과 프레임. sync_timeout_ms 상향은 freeze 위험이라 비권장;")
    print("    근본은 '리더가 보는 바이트 경계로 sync 추적(byte replay)'. docs/io-render-threading.md §11.6.")
    print("  · 둘 다 0인데 화면이 깨지면 → half-frame이 아니라 다른 계층(atlas/색 해석/diff 적용) 의심.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
