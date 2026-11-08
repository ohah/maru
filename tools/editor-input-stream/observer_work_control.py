"""관측기 검사를 그대로 수행하면서 서로 겹치지 않는 작업 구간을 기록한다."""
from pathlib import Path

PARTS=('local_focus','frontmost_app','global_source','view_source','header_copy','live_state')
MODES=('untimed','timed')


def driver(source,once):
    source=Path(__file__).with_name('observer_work.swift.inc').read_text()+source
    source=once(source,'''        !focusLost && NSApp.isActive && window.firstResponder === view && window.isVisible && !window.isMiniaturized &&
        NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid() &&
        SessionHostInputSourcePolicy.currentSourceID()==selected && view.inputContext?.selectedKeyboardInputSource==selected''','''        ObserverWork.measure(0) { !focusLost && NSApp.isActive && window.firstResponder === view && window.isVisible && !window.isMiniaturized } &&
        ObserverWork.measure(1) { NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid() } &&
        ObserverWork.measure(2) { SessionHostInputSourcePolicy.currentSourceID()==selected } &&
        ObserverWork.measure(3) { view.inputContext?.selectedKeyboardInputSource==selected }''')
    source=once(source,'        var header=[UInt64](repeating:0,count:9),flat=[UInt64](repeating:0,count:36*12);streamCopy(&header,&flat)','        var header=[UInt64](repeating:0,count:9),flat=[UInt64](repeating:0,count:36*12);ObserverWork.measure(4) { streamCopy(&header,&flat) }')
    source=once(source,'        var live=[UInt64](repeating:0,count:8);latencyState(session,&live)','        var live=[UInt64](repeating:0,count:8);ObserverWork.measure(5) { latencyState(session,&live) }')
    source=once(source,'            ObserverPosts.inputStart=ObserverPosts.snapshot()','            ObserverPosts.inputStart=ObserverPosts.snapshot()\n            ObserverWork.inputStart=ObserverWork.snapshot()')
    source=once(source,'ObserverPosts.idleStart=ObserverPosts.snapshot();','ObserverPosts.idleStart=ObserverPosts.snapshot();ObserverWork.idleStart=ObserverWork.snapshot();')
    source=once(source,'                ObserverPosts.idleEnd=ObserverPosts.snapshot()','                ObserverPosts.idleEnd=ObserverPosts.snapshot()\n                ObserverWork.idleEnd=ObserverWork.snapshot()')
    return once(source,'        record["initial_tail_sha256"]=', '''        record["observer_work_mode"]=ObserverWork.enabled ? "timed" : "untimed"
        record["work_input_start"]=ObserverWork.inputStart
        record["work_idle_start"]=ObserverWork.idleStart
        record["work_idle_end"]=ObserverWork.idleEnd
        record["work_errors"]=ObserverWork.errors
        record["work_events"]=ObserverWork.events
        record["initial_tail_sha256"]=''')


def analyze(app,meta,observer,posts,require):
    mode=meta.get('observer_work_control')
    require(mode in MODES and app.get('observer_work_mode')==mode,'observer work mode')
    require(meta.get('observer_posts_control')=='cached_posts' and meta.get('deferred_retry_control')=='with_retry','observer work fixed conditions')
    snapshots=[app.get(n) for n in ('work_input_start','work_idle_start','work_idle_end')]
    require(all(type(r) is list and len(r)==15 and all(type(v) is int and 0<=v<2**64 for v in r) and r[0]>0 and r[1]==0 for r in snapshots),'observer work snapshots')
    require(all(a[0]<b[0] and all(x<=y for x,y in zip(a[2:],b[2:])) for a,b in zip(snapshots,snapshots[1:])),'observer work counters backwards')
    require(type(app.get('work_errors')) is int and app['work_errors']==0,'observer work final error')
    events=app.get('work_events')
    require(type(events) is list and len(events)<=4096 and snapshots[-1][2]==len(events),'observer work event count')
    require(all(type(r) is list and len(r)==5 and all(type(v) is int and 0<=v<2**64 for v in r) and r[0]<6 and 0<r[1]<r[2] and r[3]<=r[2]-r[1] and r[4]>0 for r in events),'observer work event shape')
    require(all(a[2]<=b[1] for a,b in zip(events,events[1:])),'observer work intervals overlap')
    if mode=='untimed':require(not events and all(r[i]==0 for r in snapshots for i in range(4,15,2)),'untimed work measured')
    for part in range(6):
        own=[r for r in events if r[0]==part]
        require([r[4] for r in own]==list(range(1,len(own)+1)),'observer work ordinal')
    result=dict(mode=mode)
    for name,start,end in zip(('active','idle'),snapshots,snapshots[1:]):
        selected=[r for r in events if start[0]<=r[1]<end[0]]
        require(all(r[2]<=end[0] for r in selected) and len(selected)==end[2]-start[2],'observer work event boundaries')
        parts={}
        for part,label in enumerate(PARTS):
            calls=end[3+part*2]-start[3+part*2];cpu=end[4+part*2]-start[4+part*2]
            require(calls==observer[name]['completed_calls'] and calls>0,'observer work coverage')
            own=[r for r in selected if r[0]==part]
            if mode=='timed':require(len(own)==calls and sum(r[3] for r in own)==cpu,'observer work CPU accounting')
            parts[label]=dict(calls=calls,cpu_ms=cpu/1e6,wall_ms=sum(r[2]-r[1] for r in own)/1e6)
        measured=sum(p['cpu_ms'] for p in parts.values())
        residual=observer[name]['driver_cpu_ms']-posts[name]['posts_cpu_ms']-measured
        require(residual>=0,'observer work exceeds handler CPU')
        result[name]=dict(parts=parts,unattributed_driver_cpu_ms=residual if mode=='timed' else None)
    return result


def overlap(events,start,end):
    # 경계에 걸친 CPU는 비례 배분할 근거가 없다. wall 겹침과 완전히 든 구간의 CPU만 센다.
    if not 0<start<=end:raise ValueError('observer overlap bounds')
    chosen=[r for r in events if r[1]<end and r[2]>start] if start<end else []
    wall=sum(min(end,r[2])-max(start,r[1]) for r in chosen)
    if wall>end-start:raise ValueError('observer overlap exceeds window')
    return dict(window_ms=(end-start)/1e6,tracked_wall_overlap_ms=wall/1e6,
        fully_contained_cpu_ms=sum(r[3] for r in chosen if start<=r[1] and r[2]<=end)/1e6,
        boundary_events=sum(not(start<=r[1] and r[2]<=end) for r in chosen),
        unattributed_wall_ms=(end-start-wall)/1e6)
