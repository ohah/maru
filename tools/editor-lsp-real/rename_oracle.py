"""Independently apply real rename responses; never generate server messages."""
from pathlib import Path
from oracle import require, offset, apply_edits


def verify(case, native, records, process_code=0):
    require(process_code == 0, 'product process failed')
    require(case.get('scenario') == native.get('scenario') == 'rename', 'scenario mismatch')
    require(case.get('language') in ('rust', 'go') and native.get('language') == case['language'], 'language mismatch')
    require(native.get('schema') == 'maru.lsp-real.product.v1' and native.get('stage') == 'complete' and native.get('failure') is None, 'native judge incomplete')
    n = native.get('result', {})
    require(isinstance(n, dict) and n.get('stage') == native['stage'] and n.get('failure') is None, 'native detail incomplete')
    for name, expected in dict(applied_files=3, saved_files=3, record_files=3, undone_files=3, stale_refusals=1, rejected_refusals=1).items():
        require(type(n.get(name)) is int and n[name] == expected, 'incorrect native count: ' + name)
    for flag in ('baseline_definition', 'stale_response_observed', 'rejected_response_observed', 'closed_missing_at_apply'):
        require(n.get(flag) is True, 'native condition absent: ' + flag)
    ids = n.get('request_ids')
    require(isinstance(ids, list) and len(ids) == 3 and all(type(x) is int and x > 0 for x in ids) and len(set(ids)) == 3, 'invalid rename request ids')
    files = case.get('files')
    require(isinstance(files, list) and len(files) == 3, 'three files required')
    paths = [f['path'] for f in files]
    require(len(set(paths)) == 3 and all(Path(p).parent == Path(case['root']) for p in paths) and case['path'] == paths[0], 'unowned document paths')
    require(files[0]['good'] == case['good'], 'main input mismatch')
    uris = [Path(p).as_uri() for p in paths]
    samples = n.get('samples', [])
    phases = ('before', 'applied', 'undone', 'stale', 'rejected')
    require(len(samples) == 15, 'sample inventory incomplete')
    observed = {}
    for index, sample in enumerate(samples):
        phase, i = phases[index // 3], index % 3
        require(sample.get('phase') == phase and sample.get('path') == paths[i], 'sample identity mismatch')
        disk = files[i]['renamed'] if phase == 'applied' else files[i]['good']
        require(sample.get('disk') == disk, 'disk contents mismatch: ' + phase)
        if i == 2:
            require(all(sample.get(k) is None for k in ('buffer', 'version', 'undo_len', 'dirty')), 'closed file became open')
        else:
            expected = case['local'] if phase == 'stale' and i == 0 else disk
            require(sample.get('buffer') == expected, 'open buffer mismatch: ' + phase)
            require(type(sample.get('version')) is int and sample['version'] > 0 and type(sample.get('undo_len')) is int and sample['undo_len'] >= 0, 'invalid sample version/history')
            require(sample.get('dirty') is (phase == 'stale' and i == 0), 'incorrect dirty state')
        observed[(phase, i)] = sample
    for i in range(2):
        require(observed[('applied', i)]['undo_len'] == observed[('before', i)]['undo_len'] + 1, 'rename is not one undo entry per open document')

    docs, pending, pairs, changes, saves = {}, {}, {}, {u: [] for u in uris}, {u: [] for u in uris}
    encoding, initialized, initialize_count, capable = 'utf-16', False, 0, False
    rename_requests = []
    definitions = []
    for index, row in enumerate(records):
        direction, m = row.get('direction'), row.get('message')
        require(direction in ('client', 'server') and isinstance(m, dict) and m.get('jsonrpc') == '2.0', 'invalid wire record')
        identity, method = m.get('id'), m.get('method')
        require(identity is None or type(identity) in (str, int), 'invalid request id')
        key = (type(identity).__name__, identity)
        if direction == 'client' and method:
            p = m.get('params', {})
            if method == 'initialize':
                initialize_count += 1
                require(p.get('rootUri') == Path(case['root']).as_uri(), 'wrong workspace root')
            elif method == 'initialized':
                initialized = True
            elif method == 'textDocument/didOpen':
                d = p.get('textDocument', {}); u = d.get('uri')
                require(u in uris[:2] and u not in docs, 'unexpected opened document')
                i = uris.index(u)
                require(d.get('text') == files[i]['good'] and type(d.get('version')) is int and d['version'] == observed[('before', i)]['version'], 'wrong initial document')
                docs[u] = (d['version'], d['text'])
            elif method == 'textDocument/didChange':
                d = p.get('textDocument', {}); u = d.get('uri')
                require(u in docs and type(d.get('version')) is int and d['version'] > docs[u][0], 'unknown or stale document change')
                text = docs[u][1]
                for edit in p.get('contentChanges', []):
                    require(isinstance(edit.get('text'), str), 'invalid text change')
                    text = apply_edits(text, [dict(range=edit['range'], newText=edit['text'])], encoding) if 'range' in edit else edit['text']
                docs[u] = (d['version'], text)
                changes[u].append((index, d['version'], text))
            elif method == 'textDocument/didSave':
                u = p.get('textDocument', {}).get('uri')
                require(u in docs, 'save for an unopened document')
                saves[u].append((index, docs[u][1]))
            elif method == 'textDocument/didClose':
                require(False, 'unexpected document close')
            elif method == 'textDocument/rename':
                require(type(identity) is int and identity in ids, 'unexpected rename request')
                require(p.get('textDocument', {}).get('uri') == uris[0] and p.get('newName') == case['new_name'] and docs.get(uris[0], (0, ''))[1] == case['good'], 'wrong rename input')
                at = offset(case['good'], p.get('position'), encoding)
                # F2 seeds the whole word and sends its start, not the interior caret.
                require(at == case['good'].encode().index(b'produce'), 'wrong rename position')
                rename_requests.append(identity)
            if identity is not None:
                require(key not in pending, 'reused pending client id')
                pending[key] = (m, dict(docs), index)
        elif direction == 'server' and not method and identity is not None and key in pending:
            request, snapshot, request_index = pending.pop(key)
            if request['method'] == 'initialize':
                require(not m.get('error') and isinstance(m.get('result'), dict), 'initialize failed')
                caps = m['result'].get('capabilities', {})
                capable = caps.get('renameProvider') is True or isinstance(caps.get('renameProvider'), dict)
                encoding = caps.get('positionEncoding', 'utf-16')
                require(encoding in ('utf-8', 'utf-16'), 'unsupported encoding')
            elif request['method'] == 'textDocument/definition':
                definitions.append((request, m, snapshot, index))
            elif request['method'] == 'textDocument/rename':
                require(type(identity) is int and identity not in pairs, 'duplicate rename response')
                pairs[identity] = (m, snapshot, request_index, index)
    require(initialize_count == 1 and initialized and capable and set(docs) == set(uris[:2]), 'rename handshake incomplete')
    require(rename_requests == ids and set(pairs) == set(ids), 'rename request/response inventory incomplete')

    for identity in ids:
        response, snapshot, _, _ = pairs[identity]
        require(not response.get('error') and isinstance(response.get('result'), dict), 'rename server did not return an edit')
        result = response['result']
        edits = {}
        require(not ('changes' in result and 'documentChanges' in result), 'ambiguous workspace edit')
        if 'changes' in result:
            require(isinstance(result['changes'], dict), 'invalid changes map')
            edits = result['changes']
        elif 'documentChanges' in result:
            require(isinstance(result['documentChanges'], list), 'invalid document changes')
            for entry in result['documentChanges']:
                require(isinstance(entry, dict) and 'kind' not in entry and isinstance(entry.get('textDocument'), dict) and isinstance(entry.get('edits'), list), 'unsupported resource operation')
                d = entry['textDocument']; u = d.get('uri'); version = d.get('version')
                require(version is None or type(version) is int and u in snapshot and version == snapshot[u][0] or type(version) is int and u == uris[2] and version == 0, 'wrong response document version')
                edits.setdefault(u, []).extend(entry['edits'])
        require(set(edits) == set(uris), 'response does not cover exactly three owned files')
        for i, u in enumerate(uris):
            require(isinstance(edits[u], list) and edits[u], 'empty file edit')
            before = snapshot[u][1] if u in snapshot else files[i]['good']
            require(before == files[i]['good'] and apply_edits(before, edits[u], encoding) == files[i]['renamed'], 'real server edit differs from observed rename')
    definition_seen = False
    for request, response, snapshot, index in definitions:
        if response.get('error') or not response.get('result'):
            continue
        p = request.get('params', {})
        if p.get('textDocument', {}).get('uri') != uris[0] or snapshot.get(uris[0], (0, ''))[1] != case['good'] or index >= pairs[ids[0]][2]:
            continue
        if offset(case['good'], p.get('position'), encoding) != case['rename_offset']:
            continue
        targets = response['result'] if isinstance(response['result'], list) else [response['result']]
        for target in targets:
            if not isinstance(target, dict) or target.get('targetUri', target.get('uri')) != uris[1]:
                continue
            selected = target.get('targetSelectionRange', target.get('range', {}))
            lo, hi = offset(files[1]['good'], selected.get('start'), encoding), offset(files[1]['good'], selected.get('end'), encoding)
            definition_seen |= b'produce' in files[1]['good'].encode()[lo:hi]
    require(definition_seen, 'baseline definition not observed before rename')
    expected_main = [files[0]['renamed'], files[0]['good'], case['local'], files[0]['good']]
    expected_peer = [files[1]['renamed'], files[1]['good']]
    require([x[2] for x in changes[uris[0]]] == expected_main and [x[2] for x in changes[uris[1]]] == expected_peer and not changes[uris[2]], 'unexpected open document edits')
    for i in range(2):
        sequence = changes[uris[i]]
        for phase, change_index in [('applied', 0), ('undone', 1)]:
            require(observed[(phase, i)]['version'] == sequence[change_index][1], 'native/wire version mismatch')
        for phase, change_index in [('applied', 0), ('undone', 1)]:
            target = observed[(phase, i)]['buffer']
            lower = sequence[change_index][0]
            upper = sequence[1][0] if phase == 'applied' else pairs[ids[1]][2]
            require(any(lower < index < upper and text == target for index, text in saves[uris[i]]), 'rename/undo save missing in its phase')
        for phase in ('stale', 'rejected'):
            if i == 1:
                require(observed[(phase, i)]['version'] == sequence[1][1], 'peer version changed after undo')
    require(observed[('stale', 0)]['version'] == changes[uris[0]][2][1] and observed[('rejected', 0)]['version'] == changes[uris[0]][3][1], 'stale/restore version mismatch')
    first, stale, rejected = [pairs[x] for x in ids]
    require(first[3] < min(changes[u][0][0] for u in uris[:2]), 'applied before rename response')
    require(max(changes[u][1][0] for u in uris[:2]) < stale[2] < stale[3] < changes[uris[0]][2][0] < changes[uris[0]][3][0] < rejected[2] < rejected[3], 'response/local-invalidation order mismatch')
    require(not any(index > rejected[3] for u in uris[:2] for index, _, _ in changes[u]), 'rejected response changed a document')
    return dict(rename=True, open_and_closed=True, autosave=True, undo_rename=True, stale_rejected=True, missing_file_rejected=True)
