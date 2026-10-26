"""Independently validate actual formatting edits and the save/Undo wire order."""
from pathlib import Path
from oracle import require, offset, apply_edits


def verify(case, native, records, process_code=0):
    require(process_code == 0, 'product process failed')
    require(case.get('scenario') == native.get('scenario') == 'format-save', 'scenario mismatch')
    require(case.get('language') in ('rust','go') and native.get('language') == case['language'], 'language mismatch')
    require(native.get('schema') == 'maru.lsp-real.product.v1' and native.get('stage') == 'complete' and native.get('failure') is None, 'native incomplete')
    n = native.get('result', {})
    require(isinstance(n,dict) and n.get('stage') == 'complete' and n.get('failure') is None, 'native detail incomplete')
    for key, expected in dict(applied=1,stale=1,timeouts=1,format_requests=3,saves=4).items():
        require(type(n.get(key)) is int and n[key] == expected, 'incorrect native count: '+key)
    for flag in ('duplicate_commands_suppressed','stale_response_observed','timeout_response_observed','disabled_no_request'):
        require(n.get(flag) is True, 'native assertion absent: '+flag)
    for key in ('timeout_ms','timeout_deadline_ms','timeout_response_seen_ms','timeout_hold_end_ms'):
        require(type(n.get(key)) is int and n[key] > 0, 'invalid timeout clock: '+key)
    require(n['timeout_ms'] == 1000 and n['timeout_response_seen_ms'] < n['timeout_deadline_ms'] <= n['timeout_hold_end_ms'], 'timeout was not an early response held until the real deadline')
    ids = n.get('request_ids')
    require(isinstance(ids,list) and len(ids)==3 and all(type(x) is int and x>0 for x in ids) and len(set(ids))==3, 'invalid formatting ids')
    root, path = Path(case['root']), Path(case['path'])
    require(path.parent == root, 'unowned document path')
    uri = path.as_uri()
    good, before, formatted, local, timed, disabled = [case[k] for k in ('good','before_save','formatted','local','timeout_source','disabled_source')]
    require(all(isinstance(x,str) for x in (good,before,formatted,local,timed,disabled)) and len({good,before,formatted,local,timed,disabled})==6, 'fixture stages are not distinct')
    samples = n.get('samples', [])
    require(isinstance(samples,list) and len(samples)==10 and all(isinstance(x,dict) for x in samples), 'sample inventory incomplete')
    expected = [
        ('before',good,good,0,False), ('dirty',before,good,1,True), ('waiting_normal',before,good,1,True),
        ('saved_normal',formatted,formatted,2,False), ('undone',before,formatted,1,True),
        ('waiting_stale',before,formatted,1,True), ('saved_stale',local,local,2,False),
        ('waiting_timeout',timed,local,3,True), ('saved_timeout',timed,timed,3,False), ('saved_disabled',disabled,disabled,4,False),
    ]
    base_undo = samples[0].get('undo_len')
    require(type(base_undo) is int and base_undo >= 0, 'invalid initial history')
    for sample,(phase,buffer,disk,undo,dirty) in zip(samples,expected):
        require(sample.get('phase')==phase and sample.get('buffer')==buffer and sample.get('disk')==disk, 'sample text mismatch: '+phase)
        require(type(sample.get('version')) is int and sample['version']>0 and type(sample.get('undo_len')) is int and sample['undo_len']==base_undo+undo, 'version/history mismatch: '+phase)
        require(sample.get('dirty') is dirty, 'incorrect dirty state: '+phase)

    docs, pending, formatting, definitions, changes, saves = {}, {}, {}, [], [], []
    request_ids, init_count, initialized, capable = [], 0, False, False
    encoding = 'utf-16'
    times = []
    for index,row in enumerate(records):
        stamp = row.get('time_ns')
        require(type(stamp) is int and stamp > 0 and (not times or stamp >= times[-1]), 'invalid wire monotonic timestamp')
        times.append(stamp)
        direction,m = row.get('direction'),row.get('message')
        require(direction in ('client','server') and isinstance(m,dict) and m.get('jsonrpc')=='2.0', 'invalid wire record')
        identity,method = m.get('id'),m.get('method')
        require(identity is None or type(identity) in (str,int), 'invalid request id')
        key = (type(identity).__name__,identity)
        if direction=='client' and method:
            p=m.get('params',{})
            if method=='initialize':
                init_count+=1
                require(p.get('rootUri')==root.as_uri(), 'wrong workspace root')
            elif method=='initialized':initialized=True
            elif method=='textDocument/didOpen':
                d=p.get('textDocument',{})
                require(d.get('uri')==uri and uri not in docs and d.get('text')==good and type(d.get('version')) is int and d['version']==samples[0]['version'], 'wrong initial document')
                docs[uri]=(d['version'],d['text'])
            elif method=='textDocument/didChange':
                d=p.get('textDocument',{})
                require(d.get('uri')==uri and uri in docs and type(d.get('version')) is int and d['version']>docs[uri][0], 'unknown or stale document change')
                text=docs[uri][1]
                edits=p.get('contentChanges')
                require(isinstance(edits,list) and edits, 'empty document change')
                for edit in edits:
                    require(isinstance(edit.get('text'),str), 'invalid document change')
                    text=apply_edits(text,[dict(range=edit['range'],newText=edit['text'])],encoding) if 'range' in edit else edit['text']
                docs[uri]=(d['version'],text);changes.append((index,d['version'],text))
            elif method=='textDocument/didSave':
                require(p.get('textDocument',{}).get('uri')==uri and uri in docs, 'unknown saved document')
                require('text' not in p or p['text']==docs[uri][1], 'didSave text differs from current buffer')
                saves.append((index,*docs[uri]))
            elif method=='textDocument/didClose':require(False,'unexpected document close')
            elif method=='textDocument/formatting':
                require(type(identity) is int and identity in ids and p.get('textDocument',{}).get('uri')==uri and uri in docs, 'wrong formatting request')
                options=p.get('options',{})
                require(type(options.get('tabSize')) is int and 1<=options['tabSize']<=64 and type(options.get('insertSpaces')) is bool, 'invalid formatting options')
                request_ids.append(identity)
            elif method in ('textDocument/codeAction','workspace/executeCommand'):
                require(False,'unexpected code action in formatting-only scenario')
            if identity is not None:
                require(key not in pending, 'reused pending client request')
                pending[key]=(m,dict(docs),index)
        elif direction=='server' and not method and identity is not None and key in pending:
            request,snapshot,request_index=pending.pop(key)
            if request['method']=='initialize':
                require(not m.get('error') and isinstance(m.get('result'),dict), 'initialize failed')
                caps=m['result'].get('capabilities',{})
                capable=caps.get('documentFormattingProvider') is True or isinstance(caps.get('documentFormattingProvider'),dict)
                encoding=caps.get('positionEncoding','utf-16')
                require(encoding in ('utf-8','utf-16'),'unsupported position encoding')
            elif request['method']=='textDocument/formatting':
                require(identity not in formatting,'duplicate formatting response')
                formatting[identity]=(request,m,snapshot,request_index,index)
            elif request['method']=='textDocument/definition':
                definitions.append((request,m,snapshot,request_index,index))
    require(init_count==1 and initialized and capable and set(docs)=={uri}, 'formatting handshake incomplete')
    require(request_ids==ids and set(formatting)==set(ids), 'format request/response inventory incomplete')
    require([x[2] for x in changes]==[before,formatted,before,local,timed,disabled], 'document changes differ from format/Undo/stale/timeout/disabled flow')
    version_indices=[None,0,0,1,2,2,3,4,4,5]
    for sample,i in zip(samples,version_indices):
        if i is not None:require(sample['version']==changes[i][1], 'native/wire version mismatch')
    require([x[2] for x in saves]==[formatted,local,timed,disabled], 'didSave sequence differs from the actual saved text')
    require([x[1] for x in saves]==[samples[i]['version'] for i in (3,6,8,9)], 'didSave version mismatch')
    symbol='probe_add' if case['language']=='rust' else 'probeAdd'
    for ordinal,identity in enumerate(ids):
        request,response,snapshot,request_index,response_index=formatting[identity]
        require(not response.get('error') and isinstance(response.get('result'),list) and response['result'], 'server did not return meaningful formatting edits')
        source=before if ordinal<2 else timed
        require(snapshot.get(uri,(0,''))[1]==source, 'formatting used the wrong source snapshot')
        after=apply_edits(source,response['result'],encoding)
        require(after==formatted if ordinal<2 else after!=source, 'server formatting differs from expected meaningful edit')
        resolved=False
        for dq,dr,context,_,di in definitions:
            if dr.get('error') or not dr.get('result') or di>=request_index or context.get(uri)!=snapshot.get(uri):continue
            p=dq.get('params',{})
            if p.get('textDocument',{}).get('uri')!=uri or offset(source,p.get('position'),encoding)!=case['definition_offset']:continue
            targets=dr['result'] if isinstance(dr['result'],list) else [dr['result']]
            for target in targets:
                if not isinstance(target,dict) or target.get('targetUri',target.get('uri'))!=uri:continue
                selected=target.get('targetSelectionRange',target.get('range',{}))
                lo,hi=offset(source,selected.get('start'),encoding),offset(source,selected.get('end'),encoding)
                resolved|=symbol.encode() in source.encode()[lo:hi]
        require(resolved,'current document definition not observed before formatting')
    first,stale,timeout=[formatting[x] for x in ids]
    require(changes[0][0]<first[3]<first[4]<changes[1][0]<saves[0][0]<changes[2][0]<stale[3]<stale[4]<changes[3][0]<saves[1][0]<changes[4][0]<timeout[3]<timeout[4]<saves[2][0]<changes[5][0]<saves[3][0], 'format/Undo/save order mismatch')
    # Both directions share the observer's monotonic clock. The response may
    # precede native observation, so its wire-to-save gap must cover at least
    # the remaining native hold (allowing 10 ms for clock quantization).
    required_ns = max(0, n['timeout_deadline_ms'] - n['timeout_response_seen_ms'] - 10) * 1_000_000
    require(times[saves[2][0]] - times[timeout[4]] >= required_ns, 'wire does not prove the claimed timeout hold')
    return dict(format_save=True,one_undo=True,stale_saved_current=True,timeout_ignored_late=True,disabled_saved_without_format=True)
