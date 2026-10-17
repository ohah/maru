"""Canonical order oracle and opt-in changes confined to the external GUI source copy."""
import re


def adoption_order(manifest):
    if manifest.get('schema') != 'maru.partial-gui-source-copy.v2':
        raise RuntimeError('prepare a v2 source copy with explicit adoption order')
    order = manifest.get('adoption_order')
    if order not in ('target-first', 'healthy-first'):
        raise RuntimeError('unknown or missing adoption order')
    return order


def validate_order_evidence(text, identities, order):
    adoption_order(dict(schema='maru.partial-gui-source-copy.v2', adoption_order=order))
    for key in ('host_id', 'healthy', 'target'):
        value = identities.get(key)
        if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{32}', value) or int(value, 16) == 0:
            raise RuntimeError('invalid canonical fixture identity')
    patterns = {
        'PARTIAL_GUI_ROW ': r'PARTIAL_GUI_ROW host=([0-9a-f]{32}) job=([1-9][0-9]*) index=([01]) handle=([1-9][0-9]*) runtime=([0-9a-f]{32})',
        'PARTIAL_GUI_GONE ': r'PARTIAL_GUI_GONE host=([0-9a-f]{32}) job=([1-9][0-9]*) index=([01]) runtime=([0-9a-f]{32}) prior=([a-z_]+)',
    }
    records = []
    for line in text.splitlines():
        for prefix, pattern in patterns.items():
            if not line.startswith(prefix): continue
            match = re.fullmatch(pattern, line)
            if not match: raise RuntimeError('malformed canonical order observation')
            records.append((prefix, match.groups()))
    if [tag for tag, _ in records] != ['PARTIAL_GUI_ROW ', 'PARTIAL_GUI_ROW ', 'PARTIAL_GUI_GONE ']:
        raise RuntimeError('missing duplicated or unordered canonical observations')
    first, second, gone = [fields for _, fields in records]
    expected = [identities['target'], identities['healthy']]
    if order == 'healthy-first': expected.reverse()
    if expected[0] == expected[1] or any(row[0] != identities['host_id'] for row in [first, second, gone]):
        raise RuntimeError('foreign or ambiguous runtime identity')
    if not first[1] == second[1] == gone[1]: raise RuntimeError('foreign job generation')
    if (first[2], second[2]) != ('0', '1') or int(first[3]) >= int(second[3]):
        raise RuntimeError('canonical runtime handle order changed')
    if [first[4], second[4]] != expected: raise RuntimeError('canonical order differs from requested adoption')
    index = expected.index(identities['target'])
    if gone[2:] != (str(index), identities['target'], 'published_new' if index else 'none'):
        raise RuntimeError('gone transition did not preserve preceding healthy publication')


def configure_adoption_order(edit, order):
    adoption_order(dict(schema='maru.partial-gui-source-copy.v2', adoption_order=order))
    if order == 'target-first': return
    harness = 'src/platform/macos/session_host/cr6c_appkit_smoke.zig'
    swift = 'src/platform/macos/MaruAppHost.swift'
    edit(harness,
         'setenv("MARU_SESSION_HOST_CR6C_RUNTIME_ID", @ptrCast(&sibling_runtime_id_z), 1)',
         'setenv("MARU_SESSION_HOST_CR6C_RUNTIME_ID", @ptrCast(&runtime_id_z), 1)')
    edit(swift, '    private var sessionHostAutoReconnectPrimaryTargetSelected = false',
         '    private var partialHealthyFocusReturned = false\n    private var sessionHostAutoReconnectPrimaryTargetSelected = false')
    edit(swift, '''                    guard probe.recovered_count == 0,
                          probe.c3c_sibling_live != 0,
                          probe.c3c_sibling_controller != 0 else { return }''',
         '''                    guard probe.recovered_count == 0, probe.c3c_historical_count == 1,
                          probe.c3c_sibling_live == 0,
                          probe.c3c_sibling_controller == 0 else { return }''')
    edit(swift, '"MARU_SESSION_HOST_CR6E_C3C_PRIMARY_RUNTIME_ID"',
         '"MARU_SESSION_HOST_CR6E_C3C_SIBLING_RUNTIME_ID"')
    edit(swift, '''                    sessionHostAutoReconnectSiblingLiveBefore = true
                    sessionHostAutoReconnectSiblingControllerBefore = true
''', '')
    edit(swift, '''                guard probe.recovered_count == 0,
                      probe.c3c_sibling_live != 0,
                      probe.c3c_sibling_controller != 0 else { return }
                sessionHostRecoverySmokeRemotePublished = true''',
         '''                if !partialHealthyFocusReturned {
                    guard probe.recovered_count == 0,
                          probe.c3c_sibling_live != 0, probe.c3c_sibling_controller != 0,
                          let healthy = ProcessInfo.processInfo.environment["MARU_SESSION_HOST_CR6E_C3C_PRIMARY_RUNTIME_ID"],
                          setenv("MARU_SESSION_HOST_CR6C_RUNTIME_ID", healthy, 1) == 0,
                          dispatchSessionHostInputKey(keyCode: 33, characters: "[", modifiers: [.command, .shift],
                              view: view, window: window) else { return }
                    partialHealthyFocusReturned = true
                    return
                }
                guard probe.recovered_count == 0, probe.c3c_historical_count == 1,
                      probe.c3c_sibling_live != 0,
                      probe.c3c_sibling_controller != 0 else { return }
                sessionHostAutoReconnectSiblingLiveBefore = true
                sessionHostAutoReconnectSiblingControllerBefore = true
                sessionHostRecoverySmokeRemotePublished = true''')
