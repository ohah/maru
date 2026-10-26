"""Independent multi-document wire/native evidence checks; never an LSP client."""
import copy
from pathlib import Path
import re
from oracle import require, offset, apply_edits


def verify(case, native, records, process_code=0):
    require(process_code == 0, 'product process failed')
    require(case.get('scenario') == native.get('scenario') == 'multi-file', 'scenario mismatch')
    language = case.get('language')
    require(language in ('rust', 'go') and native.get('language') == language, 'language mismatch')
    require(native.get('schema') == 'maru.lsp-real.product.v1' and native.get('stage') == 'complete' and native.get('failure') is None, 'native judge incomplete')
    n = native.get('result', {})
    require(isinstance(n, dict), 'native result missing')
    for name in ('target_line', 'main_initial_version', 'main_dependency_version', 'peer_bad_version',
                 'peer_fixed_version', 'undo_before', 'undo_after', 'undo_after_undo', 'selected_kind'):
        require(type(n.get(name)) is int and n[name] >= 0, 'invalid native integer: ' + name)
    for name in ('definition_offset', 'definition_line', 'completion_start', 'completion_offset'):
        require(type(case.get(name)) is int and case[name] >= 0, 'invalid case integer: ' + name)
    for flag in ('definition_navigated', 'navigation_returned', 'dependency_raised', 'dependency_cleared',
                 'completion_applied', 'completion_undone', 'main_unchanged_during_dependency', 'peer_unchanged_by_completion'):
        require(n.get(flag) is True, 'native assertion missing: ' + flag)
    root, path, peer_path = map(Path, (case['root'], case['path'], case['peer_path']))
    require(path.parent == root and peer_path.parent == root and path != peer_path, 'unowned document paths')
    uri, peer = path.as_uri(), peer_path.as_uri()
    require(n.get('target_path') == str(peer_path) and n.get('target_line') == case['definition_line'], 'native definition target mismatch')
    require(n.get('after_dependency') == case['good'], 'main changed during dependency refresh')
    require(type(n.get('main_initial_version')) is int and n['main_initial_version'] > 0 and n.get('main_dependency_version') == n['main_initial_version'], 'main version changed during dependency refresh')
    require(type(n.get('peer_bad_version')) is int and type(n.get('peer_fixed_version')) is int and n['peer_fixed_version'] > n['peer_bad_version'] > 1, 'invalid peer versions')
    require(n.get('peer_after_completion') == case['peer_good'], 'completion changed peer')
    require(n.get('before_completion') == n.get('after_undo') == case['partial'], 'completion undo text mismatch')
    require(type(n.get('undo_before')) is int and n.get('undo_after') == n['undo_before'] + 1 and n.get('undo_after_undo') == n['undo_before'], 'completion is not one undo')
    require(n['selected_kind'] < 255, 'buffer word replaced server completion')
    after = n.get('after_completion', '')
    require(case['expected_usage'] in after, 'completed usage missing')
    if language == 'rust':
        imported = re.search(r'(?m)^use\s+(?:crate::)?types::ImportedToken\s*;', after)
    else:
        imported = re.search(r'(?m)^import[ \t]+"time"[ \t]*(?:\n|$)', after) or any(
            re.search(r'(?m)^[ \t]*"time"[ \t]*$', block) for block in re.findall(r'(?ms)^import\s*\((.*?)^\)', after))
    require(imported, 'auto import declaration missing')

    docs, opened, pending, pairs, publications = {}, set(), {}, [], []
    main_changes, peer_changes, main_saves = [], [], []
    encoding, client_pull, pull = 'utf-16', False, False
    initialized, init_count = False, 0

    def snapshot():
        return dict(docs)

    def publication(items, context, index, transport, version=None):
        require(isinstance(items, list), 'diagnostics not an array')
        if uri not in context or peer not in context:
            return
        mv, main_text = context[uri]
        if version is not None:
            require(type(version) is int and version == mv, 'stale main diagnostic version')
        if main_text == case['good']:
            pv, peer_text = context[peer]
            publications.append((index, mv, pv, peer_text, items, transport))

    for index, record in enumerate(records):
        direction, m = record.get('direction'), record.get('message')
        require(direction in ('client', 'server') and isinstance(m, dict) and m.get('jsonrpc') == '2.0', 'invalid wire record')
        method, identity = m.get('method'), m.get('id')
        require(identity is None or type(identity) in (str, int), 'invalid request id')
        key = (type(identity).__name__, identity)
        if direction == 'client' and method:
            p = m.get('params', {})
            if method == 'initialize':
                init_count += 1
                require(p.get('rootUri') == root.as_uri(), 'wrong workspace root')
                client_pull = isinstance(p.get('capabilities', {}).get('textDocument', {}).get('diagnostic'), dict)
            elif method == 'initialized':
                initialized = True
            elif method == 'textDocument/didOpen':
                d = p.get('textDocument', {})
                target = d.get('uri')
                require(target in (uri, peer) and target not in docs, 'unexpected opened document')
                require(d.get('text') == (case['good'] if target == uri else case['peer_good']), 'wrong initial document text')
                require(type(d.get('version')) is int and d['version'] > 0, 'invalid open version')
                docs[target] = (d['version'], d['text'])
                opened.add(target)
                if target == uri:
                    require(d['version'] == n['main_initial_version'], 'native/open version mismatch')
            elif method == 'textDocument/didChange':
                d = p.get('textDocument', {})
                target = d.get('uri')
                require(target in docs and type(d.get('version')) is int and d['version'] > docs[target][0], 'unknown or stale document change')
                source = docs[target][1]
                for edit in p.get('contentChanges', []):
                    require(isinstance(edit.get('text'), str), 'invalid document change')
                    source = apply_edits(source, [dict(range=edit['range'], newText=edit['text'])], encoding) if 'range' in edit else edit['text']
                docs[target] = (d['version'], source)
                (main_changes if target == uri else peer_changes).append((index, d['version'], source))
            elif method == 'textDocument/didClose':
                docs.pop(p.get('textDocument', {}).get('uri'), None)
            elif method == 'textDocument/didSave' and p.get('textDocument', {}).get('uri') == uri:
                main_saves.append(index)
            if identity is not None:
                require(key not in pending, 'reused pending client request id')
                pending[key] = (m, snapshot(), index)
        elif direction == 'server' and method == 'textDocument/publishDiagnostics':
            p = m.get('params', {})
            if p.get('uri') == uri and not pull:
                publication(p.get('diagnostics'), snapshot(), index, 'push', p.get('version'))
        elif direction == 'server' and not method and identity is not None and key in pending:
            request, context, request_index = pending.pop(key)
            pairs.append((request, m, context, index))
            if request['method'] == 'initialize':
                require(not m.get('error') and isinstance(m.get('result'), dict), 'initialize failed')
                caps = m['result'].get('capabilities', {})
                for name in ('definitionProvider', 'completionProvider'):
                    require(caps.get(name) is not None and caps.get(name) is not False, 'required capability absent')
                encoding = caps.get('positionEncoding', 'utf-16')
                require(encoding in ('utf-8', 'utf-16'), 'unsupported position encoding')
                provider = caps.get('diagnosticProvider')
                pull = client_pull and (isinstance(provider, dict) or provider is True)
            elif request['method'] == 'textDocument/diagnostic' and request.get('params', {}).get('textDocument', {}).get('uri') == uri and not m.get('error'):
                report = m.get('result')
                require(pull, 'unsolicited pull report')
                if isinstance(report, dict) and report.get('kind') == 'full':
                    publication(report.get('items'), context, index, 'pull')

    require(init_count == 1 and initialized and {uri, peer} <= opened, 'multi-document handshake incomplete')
    require(language != 'rust' or pull, 'Rust multi-file diagnostics require pull')
    require([(v, text) for _, v, text in peer_changes] == [(n['peer_bad_version'], case['peer_bad']), (n['peer_fixed_version'], case['peer_good'])], 'peer edit/restore trace mismatch')
    require(len(main_changes) == 3 and [x[2] for x in main_changes] == [case['partial'], after, case['partial']], 'main edits are not partial/completion/one undo')
    require(not any(index < main_changes[0][0] for index in main_saves), 'main save forced dependency refresh')
    defined = False
    for request, response, context, index in pairs:
        if request['method'] != 'textDocument/definition' or response.get('error'):
            continue
        p = request.get('params', {})
        require(p.get('textDocument', {}).get('uri') == uri and uri in context, 'definition used wrong document')
        if offset(context[uri][1], p.get('position'), encoding) != case['definition_offset']:
            continue
        result = response.get('result')
        target = result[0] if isinstance(result, list) and result else result
        if isinstance(target, dict):
            r = target.get('targetSelectionRange', target.get('range', {}))
            line = r.get('start', {}).get('line')
            defined |= target.get('targetUri', target.get('uri')) == peer and type(line) is int and line == case['definition_line']
    require(defined, 'cross-file definition not observed')
    raised = cleared = None
    for index, mv, pv, text, items, transport in publications:
        if index >= main_changes[0][0]:
            continue  # A later response for an old main snapshot is outside this phase.
        require(mv == n['main_initial_version'], 'main diagnostic version drift')
        if pv == n['peer_bad_version'] and text == case['peer_bad'] and index < peer_changes[1][0]:
            for d in items:
                if d.get('severity') != 1:
                    continue
                r = d.get('range', {})
                lo, hi = offset(case['good'], r.get('start'), encoding), offset(case['good'], r.get('end'), encoding)
                if lo <= case['definition_offset'] < hi and (language != 'rust' or d.get('code') == 'E0308'):
                    raised = index
        elif raised is not None and index > raised and pv == n['peer_fixed_version'] and text == case['peer_good']:
            cleared = index if not any(d.get('severity') == 1 for d in items) else None
    require(raised is not None and cleared is not None and main_changes[0][0] > cleared, 'dependent error/clear not observed before main edit')

    completed = False
    for request, response, context, index in pairs:
        if request['method'] != 'textDocument/completion' or response.get('error'):
            continue
        p = request.get('params', {})
        if p.get('textDocument', {}).get('uri') != uri or context.get(uri, (0, ''))[1] != case['partial']:
            continue
        if offset(case['partial'], p.get('position'), encoding) != case['completion_offset']:
            continue
        result = response.get('result')
        items = result.get('items', []) if isinstance(result, dict) else result
        if not isinstance(items, list):
            continue
        for item in items:
            if not isinstance(item, dict) or item.get('label') != n.get('selected_label') or item.get('kind', 0) != n['selected_kind'] or item.get('filterText', item.get('label')) != case['completion_name']:
                continue
            variants = [(item, index)]
            for resolve_request, resolve_response, _, resolve_index in pairs:
                if resolve_request['method'] != 'completionItem/resolve' or resolve_request.get('params') != item or resolve_response.get('error'):
                    continue
                resolved = resolve_response.get('result')
                if isinstance(resolved, dict):
                    merged = copy.deepcopy(item)
                    if resolved.get('additionalTextEdits'):
                        merged['additionalTextEdits'] = resolved['additionalTextEdits']
                    if 'insertText' in resolved:
                        merged['insertText'] = resolved['insertText']
                        if 'textEdit' in merged:
                            merged['textEdit']['newText'] = resolved['insertText']
                    if isinstance(resolved.get('textEdit'), dict):
                        merged['textEdit'] = dict(merged.get('textEdit', {}), newText=resolved['textEdit'].get('newText'))
                    variants.append((merged, resolve_index))
            for candidate, received_index in variants:
                additional = candidate.get('additionalTextEdits')
                if not isinstance(additional, list) or not additional or candidate.get('insertTextFormat', 1) != 1 or received_index >= main_changes[1][0]:
                    continue
                primary = candidate.get('textEdit') or dict(range=dict(start=_position(case['partial'], case['completion_start'], encoding), end=_position(case['partial'], case['completion_offset'], encoding)), newText=candidate.get('insertText', candidate['label']))
                completed |= apply_edits(case['partial'], [primary, *additional], encoding) == after
    require(completed, 'server completion plus additional import does not match native text')
    return dict(definition=True, dependent_diagnostics=True, autoimport=True, one_undo=True,
                diagnostic_transport='pull' if pull else 'push',
                diagnostic_correlation='peer snapshot at pull request' if pull else 'ordered peer edits plus native state')


def _position(text, at, encoding):
    prefix = text.encode()[:at].decode()
    tail = prefix.rsplit('\n', 1)[-1]
    return dict(line=prefix.count('\n'), character=len(tail.encode('utf-8')) if encoding == 'utf-8' else len(tail.encode('utf-16-le')) // 2)
