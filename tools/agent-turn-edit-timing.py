#!/usr/bin/env python3
"""AT3d 착수 전 실측(계획 AT3d 표 ①~⑥) — Claude 트랜스크립트(최근 14일)에서:
 ① 같은 파일의 Read → 첫 Edit/Write 간격 분포(원격 before 를 뜰 시간 여유)
 ② 500 ms 창(훅 폴링 배치)당 새 경로 수 분포(배치당 ssh 왕복 1회의 payload)
 ③ 캡처 대상 파일의 현재 크기 분포·1 MiB 초과 비율
 ④ 턴당 셸 호출 수 분포(셸 호출마다 스냅샷 대안의 비용)
"""
import glob, json, os, sys, statistics, collections, time
from datetime import datetime, timezone
EDIT={"Edit","Write","MultiEdit","NotebookEdit"}; CAP=EDIT|{"Read"}; SHELL={"Bash","Monitor"}
def _fresh(f):
    try: return time.time()-os.path.getmtime(f)<14*86400
    except OSError: return False
files=[f for f in glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"),recursive=True) if _fresh(f)]
gaps=[]; gaps_edit_no_read=0; edits=0
bucket_counts=[]; sizes=[]; over=0; shell_per_turn=[]; turns=0
seen_paths=set()
def ts(e):
    t=e.get("timestamp");
    if not t: return None
    try: return datetime.fromisoformat(t.replace("Z","+00:00")).timestamp()
    except: return None
for f in files:
    last_read={}   # path -> ts of last Read
    cur_bucket=None; cur_paths=set(); turn_shell=0; in_turn=False
    for line in open(f,encoding="utf-8",errors="replace"):
        try: e=json.loads(line)
        except: continue
        t=ts(e)
        if e.get("type")=="user" and isinstance(e.get("message",{}).get("content"),str):
            # 사용자 프롬프트 = 턴 경계
            if in_turn: shell_per_turn.append(turn_shell); turns+=1
            in_turn=True; turn_shell=0
        if e.get("type")!="assistant": continue
        for c in e.get("message",{}).get("content",[]) or []:
            if not isinstance(c,dict) or c.get("type")!="tool_use": continue
            name=c.get("name"); inp=c.get("input",{}) or {}
            if name in SHELL: turn_shell+=1
            if name not in CAP: continue
            p=inp.get("file_path") or inp.get("notebook_path")
            if not p or t is None: continue
            if name=="Read": last_read[p]=t
            else:
                edits+=1
                if p in last_read: gaps.append(t-last_read[p])
                else: gaps_edit_no_read+=1
            # 500 ms 창
            b=int(t*2)
            if b!=cur_bucket:
                if cur_bucket is not None and cur_paths: bucket_counts.append(len(cur_paths))
                cur_bucket=b; cur_paths=set()
            if p not in seen_paths:
                seen_paths.add(p)
                try:
                    st=os.stat(p); sizes.append(st.st_size); over+= st.st_size>1024*1024
                except FileNotFoundError: pass
            cur_paths.add(p)
    if cur_paths: bucket_counts.append(len(cur_paths))
    if in_turn: shell_per_turn.append(turn_shell); turns+=1
def q(xs,p): 
    xs=sorted(xs); return xs[min(len(xs)-1,int(len(xs)*p))] if xs else None
print(f"transcripts {len(files)} · turns {turns}")
print(f"① Read→Edit 같은 파일 간격: n={len(gaps)} (Read 없이 Edit {gaps_edit_no_read}/{edits} = {100*gaps_edit_no_read/max(1,edits):.1f}%)")
for p in (0.05,0.1,0.25,0.5,0.9): print(f"   p{int(p*100)} = {q(gaps,p):.1f} s")
print(f"   < 0.7 s(폴링 500+스트리머 200): {sum(1 for g in gaps if g<0.7)} ({100*sum(1 for g in gaps if g<0.7)/max(1,len(gaps)):.1f}%) · < 2 s: {100*sum(1 for g in gaps if g<2)/max(1,len(gaps)):.1f}%")
print(f"② 500 ms 창당 새 경로 수: n={len(bucket_counts)} 중앙 {q(bucket_counts,0.5)} p90 {q(bucket_counts,0.9)} p99 {q(bucket_counts,0.99)} max {max(bucket_counts)}")
print(f"③ 캡처 파일 크기(현재 존재 {len(sizes)}): 중앙 {q(sizes,0.5)} B · p90 {q(sizes,0.9)} · p99 {q(sizes,0.99)} · >1 MiB {over} ({100*over/max(1,len(sizes)):.2f}%) · 합(중앙 창 기준) ≈ {q(sizes,0.5)*(q(bucket_counts,0.5) or 1)} B")
print(f"④ 턴당 셸 호출: 중앙 {q(shell_per_turn,0.5)} p90 {q(shell_per_turn,0.9)} p99 {q(shell_per_turn,0.99)} max {max(shell_per_turn)} · 0회 턴 {100*sum(1 for s in shell_per_turn if s==0)/max(1,len(shell_per_turn)):.1f}%")
