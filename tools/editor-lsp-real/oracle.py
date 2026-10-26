"""Independent wire/native checks for the deliberately small owned fixtures.

This is an oracle for observed messages, not a second client. It never responds
or changes a product/server frame. Completion imports/snippets are outside this
local-variable case; unexpected extra edits fail rather than being discarded.
"""
import json
import hashlib
from pathlib import Path


PROFILES = {'Debug': 'debug', 'ReleaseFast': 'fast'}


class InvalidEvidence(ValueError):
    pass


def require(value, message):
    if not value:
        raise InvalidEvidence(message)


def offset(text, pos, encoding):
    require(isinstance(pos, dict), 'position missing')
    line, char = pos.get('line'), pos.get('character')
    require(type(line) is int and type(char) is int and line >= 0 and char >= 0, 'invalid position')
    lines = text.split('\n')
    require(line < len(lines), 'line outside document')
    body = lines[line].removesuffix('\r')
    codec, width = ('utf-8', 1) if encoding == 'utf-8' else ('utf-16-le', 2)
    raw = body.encode(codec)
    require(char * width <= len(raw), 'character outside line')
    try:
        prefix = raw[:char * width].decode(codec)
    except UnicodeDecodeError as exc:
        raise InvalidEvidence('position splits a code point') from exc
    return len(('\n'.join(lines[:line]) + ('\n' if line else '')).encode('utf-8')) + len(prefix.encode('utf-8'))


def apply_edits(text, edits, encoding):
    spans = []
    for edit in edits:
        require(isinstance(edit, dict) and isinstance(edit.get('newText'), str), 'invalid text edit')
        r = edit.get('range')
        require(isinstance(r, dict), 'text edit range missing')
        lo, hi = offset(text, r.get('start'), encoding), offset(text, r.get('end'), encoding)
        require(lo <= hi, 'reversed text edit')
        spans.append((lo, hi, edit['newText'].encode('utf-8')))
    spans.sort(key=lambda item: (item[0], item[1]))
    for a, b in zip(spans, spans[1:]):
        require(a[1] <= b[0] and a[0] != b[0], 'overlapping edits')
    raw = text.encode('utf-8')
    for lo, hi, replacement in reversed(spans):
        raw = raw[:lo] + replacement + raw[hi:]
    try:
        return raw.decode('utf-8')
    except UnicodeDecodeError as exc:
        raise InvalidEvidence('edit produced invalid UTF-8') from exc


def hover_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return '\n'.join(hover_text(item) for item in value)
    if isinstance(value, dict):
        return hover_text(value.get('value'))
    return ''


def verify(case, native, records, process_code=0):
    require(process_code == 0, 'product process failed')
    require(native.get('schema') == 'maru.lsp-real.product.v1', 'unsupported native evidence schema')
    require(native.get('stage') == 'complete' and native.get('failure') is None, 'native judge incomplete')
    for flag in ('hover_displayed', 'definition_navigated', 'navigation_returned',
                 'diagnostic_raised', 'diagnostic_cleared', 'completion_applied', 'completion_undone'):
        require(native.get(flag) is True, 'native assertion missing: ' + flag)
    require(type(native.get('received_diagnostics')) is int and native['received_diagnostics'] >= 2, 'native diagnostics were not received')
    require(type(native.get('received_completions')) is int and native['received_completions'] > 0, 'native server completion was not received')
    require(case['symbol'] in native.get('hover_text', ''), 'displayed hover missing symbol')
    require(native.get('after_completion') == case['good'], 'native completion changed unexpected text')
    require(native.get('after_undo') == native.get('before_completion'), 'native undo text mismatch')
    require(type(native.get('undo_before')) is int and native.get('undo_after') == native['undo_before'] + 1, 'completion is not one undo')
    bad, fixed = native.get('bad_version'), native.get('fixed_version')
    require(type(bad) is int and type(fixed) is int and fixed > bad > 1, 'invalid diagnostic versions')
    uri = Path(case['path']).as_uri()
    pending = {}
    pairs = []
    publications = []
    initialized, opened = False, False
    encoding = 'utf-16'
    text, version = None, None
    history = {}
    initialize_count = 0
    server_info = None
    client_pull = False
    pull_authoritative = False
    pull_versions = set()
    for record in records:
        require(record.get('direction') in ('client', 'server'), 'unknown wire direction')
        m = record.get('message')
        require(isinstance(m, dict), 'wire message is not an object')
        require(m.get('jsonrpc') == '2.0', 'wrong JSON-RPC version')
        direction, method, identity = record['direction'], m.get('method'), m.get('id')
        require(identity is None or type(identity) in (str, int), 'invalid wire id')
        key = (type(identity).__name__, identity)
        if direction == 'client' and method:
            p = m.get('params') or {}
            if method == 'initialize':
                initialize_count += 1
                client_pull = isinstance(p.get('capabilities', {}).get('textDocument', {}).get('diagnostic'), dict)
                require(p.get('rootUri') == Path(case['root']).as_uri(), 'wrong workspace root')
            elif method == 'initialized':
                initialized = True
            elif method == 'textDocument/didOpen':
                d = p.get('textDocument', {})
                require(d.get('uri') == uri and d.get('text') == case['good'], 'wrong opened document')
                text, version, opened = d['text'], d['version'], True
                history[version] = text
            elif method == 'textDocument/didChange':
                d = p.get('textDocument', {})
                require(opened and d.get('uri') == uri, 'change to unowned document')
                next_version = d.get('version')
                require(type(next_version) is int and next_version > version, 'document version did not advance')
                for change in p.get('contentChanges', []):
                    require(isinstance(change.get('text'), str), 'change text missing')
                    text = apply_edits(text, [{'range': change['range'], 'newText': change['text']}], encoding) if 'range' in change else change['text']
                version = next_version
                history[version] = text
            if identity is not None:
                require(key not in pending, 'request id reused while pending')
                pending[key] = (m, text, version)
        elif direction == 'server' and method == 'textDocument/publishDiagnostics':
            p = m.get('params', {})
            if p.get('uri') == uri and not pull_authoritative:
                v = p.get('version', version)
                publications.append((v, p.get('diagnostics', []), 'version' in p))
        elif direction == 'server' and method is None and identity is not None:
            require(key in pending, 'unmatched server response')
            request, source, request_version = pending.pop(key)
            pairs.append((request, m, source, request_version))
            if request.get('method') == 'textDocument/diagnostic' and not m.get('error'):
                result = m.get('result')
                if isinstance(result, dict) and result.get('kind') == 'full':
                    require(pull_authoritative, 'pull was not negotiated')
                    require(request.get('params', {}).get('textDocument', {}).get('uri') == uri, 'pull used wrong document')
                    publications.append((request_version, result.get('items'), True))
                    pull_versions.add(request_version)
            if request.get('method') == 'initialize':
                require(not m.get('error') and isinstance(m.get('result'), dict), 'initialize failed')
                server_info = m['result'].get('serverInfo')
                caps = m['result'].get('capabilities', {})
                provider = caps.get('diagnosticProvider')
                pull_authoritative = client_pull and (isinstance(provider, dict) or provider is True)
                encoding = caps.get('positionEncoding', 'utf-16')
                require(encoding in ('utf-8', 'utf-16'), 'unsupported position encoding')
                for capability in ('hoverProvider', 'definitionProvider', 'completionProvider'):
                    require(caps.get(capability) is not None and caps.get(capability) is not False, 'required capability absent')
    require(initialize_count == 1 and initialized and opened, 'initialization/document handshake incomplete')
    require('"bad"' in history.get(bad, '') and history.get(fixed) == case['good'], 'diagnostic edits not observed')
    hovered, defined, completed = False, False, False
    for request, response, source, _ in pairs:
        method = request.get('method')
        if method not in ('textDocument/hover', 'textDocument/definition', 'textDocument/completion'):
            continue
        if response.get('error'):
            continue
        p = request.get('params', {})
        require(p.get('textDocument', {}).get('uri') == uri and source is not None, 'request used wrong document')
        at = offset(source, p.get('position'), encoding)
        result = response.get('result')
        if method == 'textDocument/hover' and at == case['hover_offset']:
            hovered |= isinstance(result, dict) and case['symbol'] in hover_text(result.get('contents'))
        elif method == 'textDocument/definition' and at == case['hover_offset']:
            target = result[0] if isinstance(result, list) and result else result
            if isinstance(target, dict):
                target_uri = target.get('targetUri', target.get('uri'))
                r = target.get('targetSelectionRange', target.get('range', {}))
                defined |= target_uri == uri and r.get('start', {}).get('line') == case['definition_line']
        elif method == 'textDocument/completion' and source == native['before_completion']:
            if at != case['completion_offset'] + len(case['completion_name'].encode()) - 1:
                continue
            items = result.get('items', []) if isinstance(result, dict) else result
            if not isinstance(items, list):
                continue
            for item in items:
                if not isinstance(item, dict) or item.get('label') != native.get('selected_label') or item.get('kind', 0) != native.get('selected_kind'):
                    continue
                if item.get('insertTextFormat', 1) != 1 or item.get('additionalTextEdits'):
                    continue  # This case deliberately tests a local variable, not snippets/imports.
                edit = item.get('textEdit')
                if edit is not None:
                    expected = apply_edits(source, [edit], encoding)
                else:
                    insert = item.get('insertText', item['label'])
                    raw = source.encode()
                    start = case['completion_offset']
                    expected = (raw[:start] + insert.encode() + raw[at:]).decode()
                completed |= expected == native['after_completion']
    require(hovered, 'server hover not observed at expected position')
    require(defined, 'server definition target mismatch')
    require(completed, 'server completion edit does not match product text')
    raised, cleared = False, False
    versioned = True
    for v, diags, has_version in publications:
        require(isinstance(diags, list), 'diagnostics not an array')
        if v not in (bad, fixed):
            continue
        versioned &= has_version
        if v == bad:
            for d in diags:
                if d.get('severity') == 1:
                    r = d.get('range', {})
                    lo, hi = offset(history[bad], r.get('start'), encoding), offset(history[bad], r.get('end'), encoding)
                    raised |= lo <= case['literal_offset'] + 4 and hi > case['literal_offset']
        elif raised and v == fixed and not any(d.get('severity') == 1 for d in diags):
            cleared = True
    require(raised and cleared, 'fresh type-error publication and clear not observed')
    require(not pull_authoritative or {bad, fixed} <= pull_versions, 'bad/fixed pull reports missing')
    return dict(server_info=server_info, encoding=encoding, diagnostic_transport='pull' if pull_authoritative else 'push', hover=True, definition=True, completion=True, diagnostic_roundtrip=True,
                diagnostic_correlation='versioned' if versioned else 'ordered unversioned plus native state')


def verify_directory(root, process_code):
    case = json.loads((root / 'case.json').read_text())
    native = json.loads((root / 'product.json').read_text())
    records = [json.loads(line) for line in (root / 'wire.ndjson').read_text().splitlines()]
    events = [json.loads(line) for line in (root / 'protocol.ndjson').read_text().splitlines()]
    require(not any(e.get('event') == 'observer_error' for e in events), 'protocol observer failed')
    scenario = case.get('scenario', 'single-file')
    require(scenario in ('single-file', 'multi-file', 'rename') and native.get('scenario', 'single-file') == scenario, 'scenario mismatch')
    expected_sources = {'real_lsp_judge.zig', 'mod.zig', 'lsp.zig', 'completion.zig', 'hover.zig', 'definition.zig', 'semantic.zig'}
    if scenario == 'multi-file':
        expected_sources.add('real_lsp_multi_judge.zig')
    if scenario == 'rename':
        expected_sources |= {'rename_judge.zig', 'rename.zig', 'workspace_edit.zig'}
    fingerprints = native.get('source_fingerprints', [])
    require(len(fingerprints) == len(expected_sources) and {e.get('name') for e in fingerprints} == expected_sources, 'compiled controller fingerprint set is incomplete')
    for entry in fingerprints:
        snapshot = root.parent / 'sources' / entry['name']
        require(hashlib.sha256(snapshot.read_bytes()).hexdigest() == entry['sha256'], 'judge binary and controller snapshot differ: ' + entry['name'])
    if scenario == 'rename':
        from rename_oracle import verify as verify_rename
        result = verify_rename(case, native, records, process_code)
    elif scenario == 'multi-file':
        from multi_oracle import verify as verify_multi
        result = verify_multi(case, native, records, process_code)
    else:
        result = verify(case, native, records, process_code)
    result['compiled_controller_sources'] = len(fingerprints)
    return result
