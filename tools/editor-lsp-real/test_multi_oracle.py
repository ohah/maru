"""Multi-document evidence must prove the peer dependency and import transaction.

Goldens use literal server edits; damaged evidence must fail independently of
the native success flags. No language SDK is installed by these tests.
"""
import copy
from pathlib import Path
import unittest

from multi_fixture import make_case
from multi_oracle import verify
from oracle import InvalidEvidence


def golden(language='rust'):
    case = make_case(Path('/owned/multi'), language, 'f' * 32)
    uri, peer = Path(case['path']).as_uri(), Path(case['peer_path']).as_uri()
    wire = []

    def pos(source, at):
        prefix = source.encode()[:at].decode()
        return dict(line=prefix.count('\n'), character=len(prefix.rsplit('\n', 1)[-1].encode('utf-16-le')) // 2)

    def request(method, identity=None, params=None):
        message = dict(jsonrpc='2.0', method=method, params=params or {})
        if identity is not None:
            message['id'] = identity
        wire.append(dict(direction='client', message=message))

    def response(identity, result):
        wire.append(dict(direction='server', message=dict(jsonrpc='2.0', id=identity, result=result)))

    def change(path, version, source):
        request('textDocument/didChange', params=dict(textDocument=dict(uri=path, version=version), contentChanges=[dict(text=source)]))

    caps = dict(definitionProvider=True, completionProvider=dict(resolveProvider=True), positionEncoding='utf-16')
    client = {'textDocument': {}}
    if language == 'rust':
        caps['diagnosticProvider'] = {}
        client['textDocument']['diagnostic'] = {}
    request('initialize', 1, dict(rootUri=Path(case['root']).as_uri(), capabilities=client))
    response(1, dict(capabilities=caps))
    request('initialized')
    request('textDocument/didOpen', params=dict(textDocument=dict(uri=uri, version=1, text=case['good'])))
    request('textDocument/definition', 2, dict(textDocument=dict(uri=uri), position=pos(case['good'], case['definition_offset'])))
    response(2, [dict(uri=peer, range=dict(start=dict(line=case['definition_line'], character=7), end=dict(line=case['definition_line'], character=14)))])
    request('textDocument/didOpen', params=dict(textDocument=dict(uri=peer, version=1, text=case['peer_good'])))
    change(peer, 2, case['peer_bad'])
    request('textDocument/didSave', params=dict(textDocument=dict(uri=peer)))
    at = case['definition_offset']
    diag = dict(severity=1, code='E0308' if language == 'rust' else 'IncompatibleAssign',
                range=dict(start=pos(case['good'], at - 2), end=pos(case['good'], at + 5)))
    if language == 'rust':
        request('textDocument/diagnostic', 3, dict(textDocument=dict(uri=uri)))
        response(3, dict(kind='full', items=[diag]))
    else:
        wire.append(dict(direction='server', message=dict(jsonrpc='2.0', method='textDocument/publishDiagnostics', params=dict(uri=uri, version=1, diagnostics=[diag]))))
    change(peer, 3, case['peer_good'])
    request('textDocument/didSave', params=dict(textDocument=dict(uri=peer)))
    if language == 'rust':
        request('textDocument/diagnostic', 4, dict(textDocument=dict(uri=uri)))
        response(4, dict(kind='full', items=[]))
    else:
        wire.append(dict(direction='server', message=dict(jsonrpc='2.0', method='textDocument/publishDiagnostics', params=dict(uri=uri, version=1, diagnostics=[]))))
    change(uri, 2, case['partial'])
    request('textDocument/completion', 5, dict(textDocument=dict(uri=uri), position=pos(case['partial'], case['completion_offset'])))
    primary = dict(range=dict(start=pos(case['partial'], case['completion_start']), end=pos(case['partial'], case['completion_offset'])), newText=case['completion_name'])
    item = dict(label=case['completion_name'], kind=22 if language == 'rust' else 7, textEdit=primary, data={'owned': 1})
    if language == 'rust':
        additional = [dict(range=dict(start=dict(line=0, character=0), end=dict(line=0, character=0)), newText='use crate::types::ImportedToken;\n')]
        response(5, [copy.deepcopy(item)])
        request('completionItem/resolve', 6, copy.deepcopy(item))
        response(6, dict(**item, additionalTextEdits=additional))
        after = 'use crate::types::ImportedToken;\n' + case['partial'].replace('let _ = ImportedTok;', 'let _ = ImportedToken;')
    else:
        additional = [dict(range=dict(start=dict(line=1, character=0), end=dict(line=1, character=0)), newText='\nimport "time"\n')]
        item['additionalTextEdits'] = additional
        response(5, [item])
        after = case['partial'].replace('package main\n', 'package main\n\nimport "time"\n', 1).replace('time.Durat\n', 'time.Duration\n')
    change(uri, 3, after)
    change(uri, 4, case['partial'])
    result = dict(failure=None, stage='complete', definition_navigated=True, navigation_returned=True,
                  dependency_raised=True, dependency_cleared=True, completion_applied=True, completion_undone=True,
                  main_unchanged_during_dependency=True, peer_unchanged_by_completion=True,
                  target_path=case['peer_path'], target_line=case['definition_line'], main_initial_version=1,
                  main_dependency_version=1, peer_bad_version=2, peer_fixed_version=3,
                  after_dependency=case['good'], before_completion=case['partial'], after_completion=after,
                  after_undo=case['partial'], peer_after_completion=case['peer_good'],
                  selected_label=case['completion_name'], selected_kind=item['kind'], undo_before=1, undo_after=2, undo_after_undo=1)
    native = dict(schema='maru.lsp-real.product.v1', scenario='multi-file', language=language, stage='complete', failure=None, result=result)
    return case, native, wire


class MultiOracleTests(unittest.TestCase):
    def setUp(self):
        self.case, self.native, self.wire = golden()

    def check(self):
        return verify(self.case, self.native, self.wire)

    def response(self, identity):
        return next(x['message'] for x in self.wire if x['direction'] == 'server' and x['message'].get('id') == identity and 'method' not in x['message'])

    def test_control_rust(self):
        self.assertEqual(self.check()['diagnostic_transport'], 'pull')

    def test_control_go(self):
        self.case, self.native, self.wire = golden('go')
        self.assertEqual(self.check()['diagnostic_transport'], 'push')

    def test_server_request_id_does_not_consume_client_request(self):
        at = next(i for i, x in enumerate(self.wire) if x['direction'] == 'server' and x['message'].get('id') == 3)
        self.wire[at:at] = [
            dict(direction='server', message=dict(jsonrpc='2.0', id=3, method='workspace/diagnostic/refresh', params={})),
            dict(direction='client', message=dict(jsonrpc='2.0', id=3, result=None)),
        ]
        self.assertTrue(self.check()['dependent_diagnostics'])

    def test_error_after_clear_is_not_a_successful_clear(self):
        at = next(i for i, x in enumerate(self.wire) if x['message'].get('method') == 'textDocument/didChange' and x['message']['params']['textDocument']['uri'].endswith('main.rs'))
        request = dict(direction='client', message=dict(jsonrpc='2.0', id=77, method='textDocument/diagnostic', params=dict(textDocument=dict(uri=Path(self.case['path']).as_uri()))))
        response = dict(direction='server', message=dict(jsonrpc='2.0', id=77, result=copy.deepcopy(self.response(3)['result'])))
        self.wire[at:at] = [request, response]
        with self.assertRaises(InvalidEvidence):
            self.check()

    def test_saving_main_cannot_force_dependency_refresh(self):
        at = next(i for i, x in enumerate(self.wire) if x['message'].get('method') == 'textDocument/diagnostic')
        self.wire.insert(at, dict(direction='client', message=dict(jsonrpc='2.0', method='textDocument/didSave', params=dict(textDocument=dict(uri=Path(self.case['path']).as_uri())))))
        with self.assertRaises(InvalidEvidence):
            self.check()

    def test_damaged_evidence(self):
        def native(name, value):
            self.native['result'][name] = value

        attacks = [
            ('missing back', lambda: native('navigation_returned', False)),
            ('main edited to refresh', lambda: native('main_dependency_version', 2)),
            ('wrong target path', lambda: native('target_path', self.case['path'])),
            ('wrong target line', lambda: native('target_line', 0)),
            ('peer changed by completion', lambda: native('peer_after_completion', 'tampered')),
            ('wrong initial peer', lambda: next(m['message']['params']['textDocument'] for m in self.wire if m['message'].get('method') == 'textDocument/didOpen' and m['message']['params']['textDocument']['uri'].endswith('values.rs')).update(text='wrong')),
            ('wrong wire definition', lambda: self.response(2)['result'][0].update(uri=Path(self.case['path']).as_uri())),
            ('wrong wire definition line', lambda: self.response(2)['result'][0]['range']['start'].update(line=0)),
            ('missing bad report', lambda: self.response(3).update(result=dict(kind='full', items=[]))),
            ('missing clear', lambda: self.response(4).update(result=self.response(3)['result'])),
            ('missing bad edit', lambda: self.wire.__setitem__(slice(None), [x for x in self.wire if not (x['message'].get('method') == 'textDocument/didChange' and x['message']['params']['textDocument']['version'] == 2 and x['message']['params']['textDocument']['uri'].endswith('values.rs'))])),
            ('missing fixed edit', lambda: self.wire.__setitem__(slice(None), [x for x in self.wire if not (x['message'].get('method') == 'textDocument/didChange' and x['message']['params']['textDocument']['version'] == 3 and x['message']['params']['textDocument']['uri'].endswith('values.rs'))])),
            ('empty completion', lambda: self.response(5).update(result=[])),
            ('buffer word', lambda: native('selected_kind', 255)),
            ('no import edit', lambda: self.response(6)['result'].pop('additionalTextEdits')),
            ('different resolve data', lambda: next(x['message']['params'] for x in self.wire if x['message'].get('method') == 'completionItem/resolve').update(data={'owned': 99})),
            ('import in wrong place', lambda: self.response(6)['result']['additionalTextEdits'][0].update(newText='// use crate::types::ImportedToken;\n')),
            ('two undo operations', lambda: native('undo_after', 3)),
            ('wrong undo text', lambda: native('after_undo', self.case['good'])),
            ('wrong applied text', lambda: native('after_completion', self.case['partial'])),
            ('wrong scenario', lambda: self.native.update(scenario='single-file')),
            ('wrong language', lambda: self.native.update(language='go')),
            ('boolean target line', lambda: native('target_line', True)),
            ('boolean main version', lambda: native('main_dependency_version', True)),
            ('boolean undo count', lambda: native('undo_after_undo', True)),
            ('late bad report', lambda: self.wire.insert(next(i for i, x in enumerate(self.wire) if x['message'].get('method') == 'textDocument/diagnostic' and x['message'].get('id') == 4), self.wire.pop(next(i for i, x in enumerate(self.wire) if x['direction'] == 'server' and x['message'].get('id') == 3)))),
        ]
        for name, attack in attacks:
            with self.subTest(name=name):
                self.case, self.native, self.wire = golden()
                attack()
                with self.assertRaises(InvalidEvidence):
                    self.check()


if __name__ == '__main__':
    unittest.main()
