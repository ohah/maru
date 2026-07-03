#!/usr/bin/env python3
"""maru .sync 관측 로그 분석기 — sync(2026) 게이트의 리더↔메인 desync를 데이터로 짚는다.

배경: docs/io-render-threading.md §11.6. `MARU_DEBUG=1`로 maru를 돌리면 app_session.zig의
`logSyncGateDiag`가 tick마다 다음 형식을 stderr(.sync 스코프)로 찍는다:

    info(sync): tick=N active=0/1 hold=H/T gproj=0/1 cproj=0/1 force=0/1 dirty=0/1 chrome=0/1 voff=V esuadv=0/1 scr=0/1 bsu=B esu=E out=O

의미:
  active = 이 tick에 메인이 per-tick 샘플한 sync_output(1=BSU 구간 관측)
  hold/T = sync_hold_ticks / timeout tick 수(H가 T에 도달하면 sync 중에도 강제 투영 = half-frame 위험)
  gproj  = 이 tick에 grid 전체 투영했는지
  esuadv/scr = 이 tick 투영을 unblock한 실제 게이트 이유(esu_advanced=완성 프레임 flush / view_scrolled=스크롤).
               active 중 투영을 esu_edge vs scroll로 추론 없이 가른다(로거가 shouldProjectFrame 입력을 그대로 실음).
  bsu/esu= 리더(parser.feed)가 지금까지 처리한 BSU/ESU 누적(메인 관측과 무관한 ground truth)

이 스크립트가 짚는 실패 모드:
  (1) half-drawn frame = active=1(리더 기준 프레임 미완성=BSU 구간)인데 grid 투영(gproj=1)한 tick.
      bubbletea는 diff 렌더라 그 half-drawn 셀을 이후 안 고침 → 색·셀렉터 깨짐(Ctrl+L 무효). 원인별 분해:
        esu_edge = esu_advanced가 다음 프레임 BSU가 이미 시작된 시점에 투영(SSH 연속 조각 프레임서 빈발, 유력)
        timeout  = hold가 1초(sync_timeout) 초과해 강제 해제(느린 링크의 큰 프레임)
        scroll/force = 스크롤 면제·atlas repack(대개 무해)
  (2) 샘플링 누락 = 리더 BSU/ESU 누적 ≫ 메인 active=1 tick 수 — flush 창 < 1 tick라 per-tick 샘플링이
      transition을 놓침(esu_advanced 안전판이 커버해야 함).

주의: bsu/esu/tick 카운터는 프로세스 시작마다 0으로 리셋된다 — 여러 run이 한 로그에 섞이면(append/재시작)
누적은 run별 양수 델타 합산으로 낸다(단순 마지막-처음 차이는 음수/쓰레기).

사용: MARU_DEBUG=1 ./maru-macos-app 2> /tmp/maru-sync.log
      python3 tools/sync/analyze_sync_log.py /tmp/maru-sync.log
"""
import re
import sys

# .sync 로그 한 줄에서 key=value를 뽑는다. 프리픽스(info(sync): 등)·타임스탬프 유무와 무관하게
# tick=/bsu=/esu=를 모두 가진 줄만 sync 로그로 본다(다른 스코프 로그와 안 섞이게).
FIELD_RE = re.compile(r"(\w+)=(\d+)(?:/(\d+))?")

CAUSE_LABELS = {
    "esu_edge": "esu_advanced가 다음 BSU 구간에서 투영 (SSH 빈발 half-frame 유력)",
    "timeout": "hold>=timeout 강제 해제 (느린 SSH 프레임, >1초)",
    "scroll": "스크롤 리페인트 (의도된 면제 — 무해할 가능성)",
    "force": "atlas repack 강제 (sync와 무관할 가능성)",
}


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


def is_timeout(r):
    return r.get("hold_timeout", 0) > 0 and r.get("hold", 0) >= r.get("hold_timeout", 0)


def total_positive_delta(rows, key):
    # 누적 카운터의 전 구간 증가분. 리셋(값 감소)이 끼면 그 음수 델타는 버리고 새 run의 증가만 더한다
    # (프로세스 재시작으로 bsu/esu가 0으로 되돌아가도 정확 — rows[-1]-rows[0]의 음수/쓰레기 회피).
    total = 0
    prev = None
    for r in rows:
        v = r.get(key, 0)
        if prev is not None and v >= prev:
            total += v - prev
        prev = v
    return total


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    rows = []
    try:
        with open(argv[1], "r", errors="replace") as fh:
            for line in fh:
                row = parse_line(line)
                if row is not None:
                    rows.append(row)
    except OSError as e:
        print(f"로그 파일을 못 엶: {argv[1]} — {e}")
        return 1
    if not rows:
        print("sync 로그 줄을 못 찾음 — MARU_DEBUG=1로 실행했고 .sync 라인이 있는지 확인하세요.")
        return 1

    n = len(rows)
    active_ticks = sum(1 for r in rows if r.get("active", 0) == 1)
    total_bsu = total_positive_delta(rows, "bsu")
    total_esu = total_positive_delta(rows, "esu")
    timeout = max((r.get("hold_timeout", 0) for r in rows), default=0)
    max_hold = max((r.get("hold", 0) for r in rows), default=0)
    # 프로세스 재시작/리셋 감지(tick 또는 bsu가 직전 행보다 감소) — 여러 run이 한 로그에 섞였는지 경고.
    restarts = sum(
        1 for i in range(1, n)
        if rows[i].get("tick", 0) < rows[i - 1].get("tick", 0)
        or rows[i].get("bsu", 0) < rows[i - 1].get("bsu", 0)
    )

    # half-drawn 위험 tick(active=1 & gproj=1)의 원인을 각 행에 1회 계산해 저장(r["_cause"]).
    def classify(r):
        # active=1 & gproj=1이면 sync_blocks=false여야 하고(shouldProjectFrame), 그 unblock 원인을 게이트가 남긴
        # **실제 이유**로 가른다: timeout(hold>=timeout) > force(force_reproject) > scroll(scr=view_scrolled) >
        # esu_edge(잔여=esu_advanced). scr/esuadv는 로거가 shouldProjectFrame 입력을 그대로 실은 진실이라 추론이 없다.
        if is_timeout(r):
            return "timeout"
        if r.get("force", 0) == 1:
            return "force"
        if r.get("scr", 0) == 1:
            return "scroll"
        return "esu_edge"

    by_cause = {"esu_edge": 0, "timeout": 0, "scroll": 0, "force": 0}
    active_gproj = []
    for r in rows:
        if r.get("active", 0) == 1 and r.get("gproj", 0) == 1:
            r["_cause"] = classify(r)
            by_cause[r["_cause"]] += 1
            active_gproj.append(r)

    # episode = active=1 연속 구간(단일 패스). 각 episode가 timeout(hold>=timeout, gproj 무관)에 도달했는지 세고,
    # capture 끝에서 열린 채(=ESU 미도착, 진짜 미해소)인지 본다. active→0 flip은 리더가 ESU를 처리해 sync가
    # 꺼진 것이라 **닫힌 episode는 ESU로 종료**된다(timeout 도달했어도 이후 ESU로 복구) — timeout_eps는 그걸
    # "ESU 없는 종료"로 오도하지 않고 "timeout에 도달"로만 센다.
    episode_count = 0
    timeout_eps = 0  # timeout에 도달한 episode 수(닫힌 것 기준)
    cur_active = False
    cur_hit = False  # 현재 episode가 timeout에 도달했는지(episode 내 어느 tick에서든)
    for r in rows:
        a = r.get("active", 0) == 1
        if a and not cur_active:  # episode 시작
            episode_count += 1
            cur_hit = False
        if a and is_timeout(r):
            cur_hit = True
        if cur_active and not a:  # episode 종료(active→0 = ESU)
            timeout_eps += 1 if cur_hit else 0
        cur_active = a
    open_at_end = cur_active  # capture가 sync episode 중에 끝남 = 마지막 episode 열린 채(미해소)
    open_ep_hit_timeout = open_at_end and cur_hit

    # ── 출력 ──
    print(f"== maru .sync 로그 분석: {argv[1]} ==")
    if restarts:
        print(f"⚠️  프로세스 재시작/카운터 리셋 {restarts}회 감지 — BSU/ESU 누적은 run별 양수 델타 합산값이다.")
    print(f"sync 로그 tick 수          : {n}")
    print(f"active=1 tick 수           : {active_ticks}")
    print(f"리더 처리 BSU / ESU 누적   : {total_bsu} / {total_esu}")
    print(f"sync episode 수(active 구간): {episode_count}")
    print(f"timeout(tick)              : {timeout}")
    print(f"최대 hold 지속(tick)       : {max_hold}"
          + (f"  ← timeout({timeout})에 근접/도달!" if timeout and max_hold >= timeout else ""))
    print()

    # sync 활동이 전혀 없으면(active·BSU 모두 0) 판정 불가 — '정상'으로 오인시키지 않는다.
    if active_ticks == 0 and total_bsu == 0:
        print("── sync 활동 없음 ──")
        print("  이 캡처엔 sync(2026) 프레임이 없다(active=0 & 리더 BSU 델타=0). 원격 Sync-cap TUI가 실제로")
        print("  2026을 쓰는 상태에서 캡처했는지 확인 — 스피너(cproj)만 있는 로그로는 desync를 판정할 수 없다.")
        return 0

    # 실패 모드 (1) — half-drawn frame (active 중 grid 투영), 원인별 분해
    print("── 실패 모드 (1): active 중 grid 투영 = half-drawn frame (SSH desync 본체) ──")
    if active_gproj:
        print(f"  ⚠️  {len(active_gproj)}개 tick에서 active=1(프레임 미완성) & gproj=1(투영) → half-drawn 위험.")
        print("     원인별:")
        for c in ("esu_edge", "timeout", "scroll", "force"):
            if by_cause[c]:
                print(f"       {by_cause[c]:5d}  {CAUSE_LABELS[c]}")
        print("     예시 tick:")
        for r in active_gproj[:5]:
            print(f"       tick={r.get('tick')} [{r['_cause']}] hold={r.get('hold')}/{r.get('hold_timeout')} "
                  f"bsu={r.get('bsu')} esu={r.get('esu')} dirty={r.get('dirty')} out={r.get('out')}")
    else:
        print("  ✓ 없음 — active 중 grid 투영이 안 일어남(이 desync 모드는 미재현이거나 원인이 다름).")
    if timeout_eps:
        print(f"     · {timeout_eps}개 episode가 timeout(hold>=timeout)에 도달 — 그 tick에서 half-frame 강제 투영."
              " (도달 후 ESU로 복구됐을 수 있음 — episode 종료 자체는 ESU로 일어남.)")
    if open_at_end:
        print("     · ⚠️ capture 끝에 sync episode가 **열린 채**(ESU 미도착) — 진짜 freeze/미해소 가능(마지막 프레임)."
              + ("  timeout까지 도달." if open_ep_hit_timeout else ""))
    print()

    # 실패 모드 (2) — 빠른 episode / 샘플링 누락
    print("── 실패 모드 (2): 리더 transition ≫ 메인 active 관측 (flush<tick 샘플링 누락) ──")
    if total_bsu == 0:
        print("  – 리더 BSU 델타 0 — 이 캡처엔 판정할 sync 프레임 완성 사이클이 없다(데이터 부족 or 캡처가 episode")
        print("    중간에서 시작·끝). 샘플링 누락 여부는 판단 보류.")
    elif active_ticks < total_bsu:
        print(f"  ⚠️  리더 BSU={total_bsu}인데 active=1 tick은 {active_ticks} — 일부 episode가 1 tick보다 짧아")
        print("     per-tick 샘플링이 놓쳤을 수 있다(esu_advanced 안전판이 커버하는지 위 esu_edge 수로 확인).")
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
    print("  · active 중 gproj가 0이고 화면이 깨지면 → half-frame이 아니라 다른 계층(atlas/색 해석/diff 적용) 의심.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
