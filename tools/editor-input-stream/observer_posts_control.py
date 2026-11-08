"""동일 사본에서 완료 JSON 재읽기만 줄이며 CPU와 실제 호출 수를 검증한다."""
import base64
import hashlib
from pathlib import Path

MODES=('repeated_posts','cached_posts')


def driver(source,once):
    source=Path(__file__).with_name('observer_posts.swift.inc').read_text()+source
    source=once(source,'''        if let path=InputStream.env["MARU_STREAM_POSTS"],let data=try? Data(contentsOf:URL(fileURLWithPath:path)),
           let posts=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
            if !(posts["error"] is NSNull)''','''        if let path=InputStream.env["MARU_STREAM_POSTS"],let producerComplete=ObserverPosts.complete(path,cache:InputStream.env["MARU_STREAM_CACHE_POSTS"]=="1") {
            if !producerComplete''')
    source=once(source,'            DeferredRetry.inputStart=DeferredRetry.snapshot()','            DeferredRetry.inputStart=DeferredRetry.snapshot()\n            ObserverPosts.inputStart=ObserverPosts.snapshot()')
    source=once(source,'DeferredRetry.idleStart=DeferredRetry.snapshot();','DeferredRetry.idleStart=DeferredRetry.snapshot();ObserverPosts.idleStart=ObserverPosts.snapshot();')
    source=once(source,'                DeferredRetry.idleEnd=DeferredRetry.snapshot()','                DeferredRetry.idleEnd=DeferredRetry.snapshot()\n                ObserverPosts.idleEnd=ObserverPosts.snapshot()')
    return once(source,'        record["initial_tail_sha256"]=', '''        ObserverPosts.finish(env["MARU_STREAM_POSTS"])
        record["observer_posts_mode"]=env["MARU_STREAM_CACHE_POSTS"]=="1" ? "cached_posts" : "repeated_posts"
        record["posts_input_start"]=ObserverPosts.inputStart
        record["posts_idle_start"]=ObserverPosts.idleStart
        record["posts_idle_end"]=ObserverPosts.idleEnd
        record["posts_errors"]=ObserverPosts.errors
        record["posts_accepted_base64"]=ObserverPosts.accepted?.base64EncodedString() ?? ""
        record["initial_tail_sha256"]=''')


def analyze(app,meta,observer,require):
    mode=meta.get('observer_posts_control')
    require(mode in MODES and app.get('observer_posts_mode')==mode,'posts mode')
    snapshots=[app.get(n) for n in ('posts_input_start','posts_idle_start','posts_idle_end')]
    require(all(type(row) is list and len(row)==8 and all(type(n) is int and 0<=n<2**64 for n in row) and row[0]>0 and row[7]==0 for row in snapshots),'posts snapshots')
    require(all(a[0]<b[0] and all(x<=y for x,y in zip(a[1:],b[1:])) for a,b in zip(snapshots,snapshots[1:])),'posts counters backwards')
    require(type(app.get('posts_errors')) is int and app['posts_errors']==0,'posts final error')
    require(type(app.get('posts_accepted_base64')) is str,'posts bytes type')
    data=base64.b64decode(app['posts_accepted_base64'],validate=True)
    require(data and hashlib.sha256(data).hexdigest()==meta['posts.json_sha256'],'cached posts differ from producer')
    for row in snapshots:
        require(row[1]==row[2]+row[5] and row[4]<=row[3]<=row[2],'posts counter accounting')
    result=dict(mode=mode)
    for name,start,end in zip(('active','idle'),snapshots,snapshots[1:]):
        checks,attempts,reads,parses,hits,cpu=[b-a for a,b in zip(start[1:7],end[1:7])]
        require(checks>0 and checks==attempts+hits and parses<=reads<=attempts,'posts interval accounting')
        require(0<=cpu/1e6<=observer[name]['driver_cpu_ms'],'posts CPU exceeds observer')
        require(checks==observer[name]['completed_calls'],'posts checks/handler calls differ')
        if mode=='repeated_posts':require(hits==0 and attempts==checks,'repeated posts branch')
        else:
            require(parses<=1 and reads<=1,'cache reloaded after success')
            if name=='idle':require(attempts==reads==parses==0 and hits==checks,'idle cache not reused')
        if name=='idle' and mode=='repeated_posts':require(parses==reads==checks,'idle repeated reads missing')
        result[name]=dict(checks=checks,read_attempts=attempts,reads=reads,parses=parses,cache_hits=hits,posts_cpu_ms=cpu/1e6,other_driver_cpu_ms=observer[name]['driver_cpu_ms']-cpu/1e6)
    if mode=='cached_posts':require(result['active']['parses']==1,'cache load not exercised')
    return result
