"""외부 게시·native 도착·실제 프레임 접두부를 연결한다. 실패 실행은 통째로 거절한다."""
import hashlib
import json
import pathlib
import protocol
import summary_control
import fold_control


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def uint(value):
    return type(value) is int and 0 <= value < 2**64


def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def validate(app, producer, meta):
    n = protocol.count(meta['count'])
    require(meta['mode'] in ('sync', 'async') and type(meta['shared']) is bool, 'requested view')
    require(meta['kind'] in ('normal', 'main-pause'), 'control population')
    require(all(uint(meta[k]) and meta[k] > 0 for k in ['app_pid', 'producer_pid', 'fixture_bytes']), 'requested identity')
    digest = meta['fixture_tail_sha256']
    require(type(digest) is str and len(digest) == 64 and all(c in '0123456789abcdef' for c in digest), 'fixture digest')
    require(type(app['schema']) is int and app['schema'] == 1 and app['protocol'] == protocol.NAME, 'app schema')
    require(type(producer['schema']) is int and producer['schema'] == 1 and producer['protocol'] == protocol.NAME, 'producer schema')
    require(app['error'] is None and app['restored'] is True and app['foreground'] is True, 'app failure')
    require(uint(app['suppressed_frames']) and app['suppressed_frames'] == 0, 'suppression mixed into measurements')
    require(producer['error'] is None and producer['transport'] == 'CGEventPostToPid', 'producer failure')
    require(uint(app['pid']) and app['pid'] == meta['app_pid'], 'app identity')
    require(uint(producer['pid']) and producer['pid'] == meta['producer_pid'] and producer['pid'] != app['pid'], 'independent producer')
    require(producer['target_pid'] == app['pid'] and app['mode'] == meta['mode'] and app['shared'] is meta['shared'], 'target identity')
    period, tolerance = meta['period_ns'], meta['lateness_ns']
    require(uint(period) and period > 0 and uint(tolerance) and tolerance <= period, 'schedule parameters')
    require(all(uint(producer[k]) for k in ['period_ns', 'lateness_ns', 'count', 'target_pid']) and producer['period_ns'] == period and producer['lateness_ns'] == tolerance and producer['count'] == n, 'producer parameters')
    require(uint(producer['start_ns']) and producer['start_ns'] > 0 and uint(producer['finished_ns']), 'producer clocks')
    require(len(producer['events']) == len(app['keys']) == n, 'missing input')
    header, base, final = app['header'], app['baseline'], app['state']
    require(len(header) == protocol.HEADER_WIDTH and len(base) == len(final) == 8 and all(uint(x) for x in header+base+final), 'state types')
    mode, views = int(meta['mode'] == 'async'), 2 if meta['shared'] else 1
    require(header[0] == 0 and header[1:4] == [n, n, n] and header[6] == n and header[7] == mode and header[8] == 0, 'observer incomplete')
    require(base[1] == base[2] == base[7] == 0 and base[3:5] == [1, views] and base[5] == meta['fixture_bytes'] and base[6] == 1+mode*2, 'baseline state')
    require(final[1] == n and final[2] == 0 and final[3:5] == [1, views] and final[5] == base[5]+n and final[6] == 1+mode*2 and final[7] == n, 'final state')
    require(app['document_verified'] is True and app['initial_tail_sha256'] == meta['fixture_tail_sha256'], 'document tail')
    require(app['visible_line'] == '// '+protocol.TEXT[:n], 'document prefix')
    require(len(app['memory']) == len(app['baseline_memory']) == 2 and all(uint(x) and x > 0 for x in app['memory']+app['baseline_memory']), 'memory counters')
    require(app['memory'][0] >= app['baseline_memory'][0], 'peak counter reversed')
    groups, post_times, arrivals, shown_times = {}, [], [], []
    for i, (event, key) in enumerate(zip(producer['events'], app['keys'])):
        seq, token, code = i+1, protocol.MAGIC|i+1, protocol.CODES[i]
        require(len(key) == protocol.ROW_WIDTH and all(uint(x) for x in key), 'key types')
        require(all(uint(event[k]) for k in ['seq', 'token', 'code', 'ascii', 'scheduled_ns', 'post_ns', 'after_post_ns', 'frontmost_pid']), 'post types')
        require(event['seq'] == key[0] == seq and event['token'] == key[1] == token and event['code'] == key[4] == code and event['ascii'] == ord(protocol.TEXT[i]), 'key identity')
        require(key[5] == 0 and key[11] == 1 and event['frontmost_pid'] == app['pid'] and event['source_verified'] is True, 'key admission')
        require(event['scheduled_ns'] == producer['start_ns']+i*period, 'absolute schedule')
        posted = event['post_ns']
        require(event['scheduled_ns'] <= posted <= event['scheduled_ns']+tolerance and posted <= event['after_post_ns'] <= producer['finished_ns'], 'producer lateness')
        require(0 < key[2] <= key[3] and posted <= key[3] <= key[6], 'input/present clocks')
        require(base[0] < key[7] <= final[0] and seq <= key[8] <= n and key[9] in (0, 1) and key[10] in (0, 1) and key[10] <= key[9], 'frame prefix')
        stamp = (key[6], key[8], key[9], key[10])
        require(key[7] not in groups or groups[key[7]] == stamp, 'frame conflict')
        groups[key[7]] = stamp
        last_in_prefix = app['keys'][key[8]-1]
        require(last_in_prefix[6] == key[6] and last_in_prefix[7] == key[7], 'coalesced prefix')
        if i:
            require(post_times[-1] < posted and arrivals[-1] <= key[3] and shown_times[-1] <= key[6] and app['keys'][i-1][7] <= key[7], 'input order')
        post_times.append(posted);arrivals.append(key[3]);shown_times.append(key[6])
    require(header[4] >= max(shown_times) and app['keys'][-1][7] <= header[5] <= final[0], 'final color')
    require(uint(app['pause_start_ns']) and uint(app['pause_end_ns']), 'pause clocks')
    inside = []
    if meta['kind'] == 'normal':
        require(app['pause_start_ns'] == app['pause_end_ns'] == 0, 'pause mixed into measurements')
    else:
        begin, end = app['pause_start_ns'], app['pause_end_ns']
        require(0 < begin < end, 'main pause missing')
        inside = [i for i, at in enumerate(post_times) if begin < at < end]
        require(len(inside) >= 2 and not any(begin < at < end for at in arrivals), 'producer waited for main')
        require(all(arrivals[i] >= end and shown_times[i] >= end for i in inside), 'paused input delivery')
    return {'post_to_present_ms': [(x-p)/1e6 for x,p in zip(shown_times,post_times)],
            'post_to_native_ms': [(x-p)/1e6 for x,p in zip(arrivals,post_times)],
            'native_to_present_ms': [(x-a)/1e6 for x,a in zip(shown_times,arrivals)],
            'first_frames': len(groups), 'coalesced_keys': n-len(groups), 'pause_posted_count': len(inside),
            'final_color_after_last_post_ms': (header[4]-post_times[-1])/1e6,
            'max_producer_lateness_ms': max((r['post_ns']-r['scheduled_ns'])/1e6 for r in producer['events'])}


def classify(app, producer, meta):
    require(type(meta['app_exit']) is int and meta['app_exit'] == 0 and meta['disk_unchanged'] is True, 'process/disk failure')
    require(type(meta['provider_before']) is dict and len(meta['provider_before'])==3 and meta['provider_before']==meta['provider_after'], 'provider configuration changed')
    if meta['kind'] in ('normal', 'main-pause'):
        require(meta['producer_exit'] == 0, 'producer exit')
        summary_control.validate(app,meta,require)
        fold_control.validate(app,meta,require)
        return validate(app, producer, meta)
    n = protocol.count(meta['count'])
    require(app['pid'] == meta['app_pid'] and producer['pid'] == meta['producer_pid'] and producer['target_pid'] == app['pid'] and app['pid'] != producer['pid'], 'control identity')
    require(type(app['schema']) is type(producer['schema']) is int and app['schema'] == producer['schema'] == 1 and app['protocol'] == producer['protocol'] == protocol.NAME, 'control schema')
    require(app['restored'] is True and app['foreground'] is True and app['initial_tail_sha256'] == meta['fixture_tail_sha256'], 'control context')
    h, keys = app['header'], app['keys']
    require(len(h) == protocol.HEADER_WIDTH and len(keys) == n and all(len(k) == protocol.ROW_WIDTH for k in keys) and all(uint(x) for x in h+[x for row in keys for x in row]), 'control shape')
    require(producer['transport']=='CGEventPostToPid' and producer['count']==n and producer['period_ns']==meta['period_ns'] and producer['lateness_ns']==meta['lateness_ns'], 'control producer parameters')
    require(uint(producer['start_ns']) and uint(producer['finished_ns']) and producer['finished_ns']>=producer['start_ns'], 'control producer clocks')
    sequences = [e['seq'] for e in producer['events']]
    allowed = list(range(1,n+1)) if meta['kind']=='drop-present' else [i for i in range(1,n+1) if i!=3]
    require(sequences==allowed[:len(sequences)] and len(sequences)>0, 'control post order')
    for event in producer['events']:
        seq=event['seq']
        require(all(uint(event[k]) for k in ['seq','token','code','ascii','scheduled_ns','post_ns','after_post_ns','frontmost_pid']), 'control post types')
        require(event['token']==protocol.MAGIC|seq and event['code']==protocol.CODES[seq-1] and event['ascii']==ord(protocol.TEXT[seq-1]), 'control post identity')
        require(event['source_verified'] is True and event['frontmost_pid']==app['pid'], 'control post owner')
        require(event['scheduled_ns']==producer['start_ns']+(seq-1)*meta['period_ns'] and event['scheduled_ns']<=event['post_ns']<=event['scheduled_ns']+meta['lateness_ns'] and event['post_ns']<=event['after_post_ns']<=producer['finished_ns'], 'control post schedule')
        row=keys[seq-1]
        if row[11]:
            require(row[0]==seq and row[1]==event['token'] and row[4]==event['code'] and row[5]==0 and row[11]==1 and event['post_ns']<=row[3], 'control native identity')
    if meta['kind'] == 'drop-present':
        require(meta['producer_exit'] == 0 and producer['error'] is None and len(producer['events']) == n, 'drop producer')
        require(app['error'] == 'stream_timeout' and h[0] == 0 and h[1:4] == [n,n,0] and h[4] == h[8] == 0 and app['document_verified'] is True and uint(app['suppressed_frames']) and app['suppressed_frames']>0, 'wrong drop control failure')
        require(all(k[3] > 0 and k[6] == 0 and k[11] == 1 for k in keys), 'drop native/present boundary')
        return {'expected_failure': 'missing_presentation'}
    require(meta['kind'] == 'skip' and n >= 4, 'unknown negative control')
    require(producer['error'] in (None,'app_stopped') and meta['producer_exit']==int(producer['error'] is not None) and len(sequences)>=3 and keys[3][11]==1, 'skip producer')
    require(app['error'] == 'observer_error' and h[0]&2 and not h[0]&~18 and keys[2][11] == 0 and app['document_verified'] is False and app['suppressed_frames']==0, 'wrong skipped input failure')
    return {'expected_failure': 'missing_input_id'}


def read(root):
    """기록한 요약을 믿지 않고 원시 파일·빌드·전체 요청 행렬을 다시 검사한다."""
    root = pathlib.Path(root).resolve()
    manifest = json.loads((root/'manifest.json').read_text())
    require(type(manifest['schema']) is int and manifest['schema'] == 1 and manifest['protocol'] == protocol.NAME, 'manifest schema')
    protocol.count(manifest['count'])
    require(type(manifest['repetitions']) is int and manifest['repetitions'] > 0, 'matrix repetitions')
    require(all(xs and len(xs)==len(set(xs)) for xs in [manifest['sizes'],manifest['periods'],manifest['flows'],manifest['modes']]), 'matrix dimensions')
    require(all(type(x) is int and x in (3000,50000) for x in manifest['sizes']) and all(type(x) is int and 20<=x<=200 for x in manifest['periods']), 'matrix size/period')
    require(set(manifest['flows'])<={'typing','shared'} and set(manifest['modes'])<={'sync','async'}, 'matrix mode/flow')
    fixture_kind=manifest.get('fixture_kind','flat')
    require(type(fixture_kind) is str and fixture_kind in ('flat','multiline'),'fixture kind')
    source = manifest['source']
    require(source['harness'] == protocol.NAME and source['optimize'] == 'ReleaseFast', 'source harness')
    build = pathlib.Path(manifest['build'])
    require(sha(build/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app') == source['app_sha256'], 'app drift')
    require(sha(build/'producer') == source['producer_sha256'] and sha(build/'producer.swift') == source['producer_source_sha256'], 'producer drift')
    for name, digest in source['instrumented'].items():
        require(sha(build/'source'/name) == digest, 'instrumentation drift')
    expected = {(s,p,f,r,m) for s in manifest['sizes'] for p in manifest['periods'] for f in manifest['flows'] for r in range(manifest['repetitions']) for m in manifest['modes']}
    require(len(manifest['runs']) == len(expected) and len({r['path'] for r in manifest['runs']}) == len(expected), 'incomplete matrix')
    found, results = set(), []
    last_finished = 0
    for entry in manifest['runs']:
        path = (root/entry['path']).resolve()
        require(path.is_relative_to(root), 'run path escape')
        require(sha(path/'record.json') == entry['record_sha256'], 'record drift')
        record = json.loads((path/'record.json').read_text())
        require(record.get('diagnostic',False) is False, 'diagnostic cohort is not baseline performance')
        require(record.get('fixture_kind','flat')==fixture_kind,'fixture cohort differs')
        require(record.get('fold_control')==manifest.get('fold_control'),'fold experiment label differs')
        require(bool(record.get('fold_control'))==bool(source.get('fold_control')),'fold experiment source differs')
        require(not (record.get('summary_control') and record.get('fold_control')),'mixed cache experiments')
        require(record.get('summary_control')==manifest.get('summary_control'),'summary experiment label differs')
        require(bool(record.get('summary_control'))==bool(source.get('summary_control')),'summary experiment source differs')
        require(record['error'] is None and record['count'] == manifest['count'] and record['kind'] == manifest['kind'], 'run failure')
        identity = (record['size'], record['period_ns']//1_000_000, record['flow'], record['repeat'], record['mode'])
        require(identity in expected and identity not in found and record['shared'] is (record['flow']=='shared') and record['period_ns']==identity[1]*1_000_000, 'matrix identity')
        found.add(identity)
        for name in ['app.json','posts.json','app.log','producer.log','config','ready.json','source-record.json','source-recovery.json']:
            require(sha(path/name) == record[name+'_sha256'], 'receipt drift: '+name)
        document = (path/'document.zig').read_bytes()
        require(hashlib.sha256(document).hexdigest() == record['fixture_sha256'] and len(document) == record['fixture_bytes'] and hashlib.sha256(document[3:]).hexdigest() == record['fixture_tail_sha256'], 'fixture drift')
        require(document==protocol.fixture(record['size'],fixture_kind), 'fixture workload')
        ready=json.loads((path/'ready.json').read_text());origin=json.loads((path/'source-record.json').read_text());recovery=json.loads((path/'source-recovery.json').read_text())
        require(ready['pid']==origin['pid']==record['app_pid'] and ready['count']==record['count'] and ready['initial_tail_sha256']==record['fixture_tail_sha256'] and ready['source']==origin['selected']=='com.apple.keylayout.ABC', 'ready/source identity')
        require(type(recovery['exit']) is int and recovery['exit']==0, 'source recovery failure')
        app = json.loads((path/'app.json').read_text());producer = json.loads((path/'posts.json').read_text())
        result = classify(app,producer,record)
        require(producer['start_ns'] > last_finished, 'reused/overlapping process')
        last_finished = max(producer['finished_ns'], app['header'][4])
        if manifest['verifier_sha256'] == sha(__file__): require(record['validation'] == result, 'derived metrics drift')
        results.append({'path':entry['path'],'identity':list(identity),'metrics':result,'app_sha256':record['app.json_sha256'],'posts_sha256':record['posts.json_sha256']})
    require(found == expected, 'missing matrix member')
    return {'schema':1,'protocol':protocol.NAME,'kind':manifest['kind'],'head':source['head'],'app_sha256':source['app_sha256'],
            'fixture_kind':fixture_kind,'summary_control':manifest.get('summary_control'),'fold_control':manifest.get('fold_control'),
            'producer_sha256':source['producer_sha256'],'verifier_sha256':sha(__file__),'runs':results}


def main():
    import argparse
    p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);p.add_argument('--output',type=pathlib.Path)
    a=p.parse_args();result=read(a.root)
    if a.output:
        require(not a.output.exists(), 'new output required');a.output.write_text(json.dumps(result,indent=2)+'\n')
    else: print(json.dumps(result,indent=2))


if __name__=='__main__': main()
