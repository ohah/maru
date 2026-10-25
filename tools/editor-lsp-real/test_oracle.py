import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

from oracle import InvalidEvidence, apply_edits, offset, verify

_spec = importlib.util.spec_from_file_location('gallery_lsp_proxy', Path(__file__).resolve().parents[1] / 'editor-theme-gallery/lsp_proxy.py')
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)
Observer = _module.Observer


def golden():
    text = 'fn probe_add(x: i32) -> i32 { x }\nfn main() { let probe_result = probe_add(41); let _ = probe_result; }\n'
    literal, comp = text.index('41'), text.rindex('probe_result')
    bad = text[:literal] + '"bad"' + text[literal + 2:]
    before = text[:comp] + 'probe_resul' + text[comp + len('probe_result'):]
    case = dict(root='/owned/case', path='/owned/case/main.rs', good=text, symbol='probe_add',
                completion_name='probe_result', hover_offset=text.rindex('probe_add') + 2,
                definition_line=0, literal_offset=literal, completion_offset=comp)
    native = dict(schema='maru.lsp-real.product.v1', stage='complete', failure=None, hover_displayed=True, definition_navigated=True,
                  navigation_returned=True, diagnostic_raised=True, diagnostic_cleared=True,
                  completion_applied=True, completion_undone=True, hover_text='fn probe_add(x: i32)',
                  selected_label='probe_result', selected_kind=6, before_completion=before,
                  after_completion=text, after_undo=before, undo_before=3, undo_after=4,
                  bad_version=2, fixed_version=3, received_diagnostics=3, received_completions=1)
    uri = Path(case['path']).as_uri()
    records = []

    def event(direction, method=None, identity=None, params=None, result=None):
        m = {'jsonrpc': '2.0'}
        if identity is not None:
            m['id'] = identity
        if method:
            m.update(method=method, params=params or {})
        else:
            m['result'] = result
        records.append(dict(direction=direction, message=m))

    def pos(source, at):  # Golden fixture is ASCII: these columns are literal character counts.
        return dict(line=source[:at].count('\n'), character=len(source[:at].rsplit('\n', 1)[-1]))

    event('client', 'initialize', 1, {'rootUri': Path(case['root']).as_uri()})
    event('server', identity=1, result={'capabilities': {'hoverProvider': True, 'definitionProvider': True, 'completionProvider': {}, 'positionEncoding': 'utf-16'}})
    event('client', 'initialized')
    event('client', 'textDocument/didOpen', params={'textDocument': {'uri': uri, 'version': 1, 'text': text}})
    event('client', 'textDocument/hover', 2, {'textDocument': {'uri': uri}, 'position': pos(text, case['hover_offset'])})
    event('server', identity=2, result={'contents': {'kind': 'markdown', 'value': 'fn probe_add(x: i32) -> i32'}})
    event('client', 'textDocument/definition', 3, {'textDocument': {'uri': uri}, 'position': pos(text, case['hover_offset'])})
    event('server', identity=3, result=[{'uri': uri, 'range': {'start': {'line': 0, 'character': 3}, 'end': {'line': 0, 'character': 12}}}])
    event('client', 'textDocument/didChange', params={'textDocument': {'uri': uri, 'version': 2}, 'contentChanges': [{'text': bad}]})
    event('server', 'textDocument/publishDiagnostics', params={'uri': uri, 'version': 2, 'diagnostics': [{'severity': 1, 'range': {'start': pos(bad, literal), 'end': pos(bad, literal + 5)}}]})
    event('client', 'textDocument/didChange', params={'textDocument': {'uri': uri, 'version': 3}, 'contentChanges': [{'text': text}]})
    event('server', 'textDocument/publishDiagnostics', params={'uri': uri, 'version': 3, 'diagnostics': []})
    event('client', 'textDocument/didChange', params={'textDocument': {'uri': uri, 'version': 4}, 'contentChanges': [{'text': before}]})
    event('client', 'textDocument/completion', 4, {'textDocument': {'uri': uri}, 'position': pos(before, comp + len('probe_resul'))})
    event('server', identity=4, result=[{'label': 'probe_result', 'kind': 6, 'textEdit': {'range': {'start': pos(before, comp), 'end': pos(before, comp + len('probe_resul'))}, 'newText': 'probe_result'}}])
    return case, native, records


class OracleTests(unittest.TestCase):
    def setUp(self):
        self.case, self.native, self.wire = golden()

    def check(self):
        return verify(self.case, self.native, self.wire)

    def response(self, identity):
        return next(e['message'] for e in self.wire if e['direction'] == 'server' and e['message'].get('id') == identity and 'method' not in e['message'])

    def notification(self, method, number=0):
        return [e['message'] for e in self.wire if e['message'].get('method') == method][number]

    def rejected(self):
        with self.assertRaises(InvalidEvidence):
            self.check()

    def test_normal_control(self):
        self.assertTrue(self.check()['diagnostic_roundtrip'])

    def test_01_wrong_root(self):
        self.notification('initialize')['params']['rootUri'] = 'file:///unowned'
        self.rejected()

    def test_02_missing_initialized(self):
        self.wire = [e for e in self.wire if e['message'].get('method') != 'initialized']
        self.rejected()

    def test_03_wrong_open_document(self):
        self.notification('textDocument/didOpen')['params']['textDocument']['uri'] = 'file:///elsewhere'
        self.rejected()

    def test_04_null_hover(self):
        self.response(2)['result'] = None
        self.rejected()

    def test_05_wrong_hover_position(self):
        self.notification('textDocument/hover')['params']['position']['character'] -= 1
        self.rejected()

    def test_06_wrong_definition_document(self):
        self.response(3)['result'][0]['uri'] = 'file:///elsewhere'
        self.rejected()

    def test_07_wrong_definition_line(self):
        self.response(3)['result'][0]['range']['start']['line'] = 1
        self.rejected()

    def test_08_no_error_diagnostic(self):
        self.notification('textDocument/publishDiagnostics')['params']['diagnostics'] = []
        self.rejected()

    def test_09_stale_error_diagnostic(self):
        self.notification('textDocument/publishDiagnostics')['params']['version'] = 1
        self.rejected()

    def test_10_missing_bad_edit(self):
        self.notification('textDocument/didChange')['params']['contentChanges'][0]['text'] = self.case['good']
        self.rejected()

    def test_11_missing_clear(self):
        self.wire = [e for e in self.wire if e['message'] is not self.notification('textDocument/publishDiagnostics', 1)]
        self.rejected()

    def test_12_stale_clear(self):
        self.notification('textDocument/publishDiagnostics', 1)['params']['version'] = 2
        self.rejected()

    def test_13_clear_still_has_error(self):
        self.notification('textDocument/publishDiagnostics', 1)['params']['diagnostics'] = copy.deepcopy(self.notification('textDocument/publishDiagnostics')['params']['diagnostics'])
        self.rejected()

    def test_14_empty_completion(self):
        self.response(4)['result'] = []
        self.rejected()

    def test_15_buffer_word_is_not_server_completion(self):
        self.native['selected_kind'] = 255
        self.rejected()

    def test_16_wrong_selected_label(self):
        self.native['selected_label'] = 'other'
        self.rejected()

    def test_17_edit_outside_document(self):
        self.response(4)['result'][0]['textEdit']['range']['end']['line'] = 999
        self.rejected()

    def test_18_native_text_mismatch(self):
        self.native['after_completion'] += 'unexpected'
        self.rejected()

    def test_19_undo_text_mismatch(self):
        self.native['after_undo'] = 'wrong'
        self.rejected()

    def test_20_multiple_undo_entries(self):
        self.native['undo_after'] += 1
        self.rejected()

    def test_process_failure_cannot_pass(self):
        with self.assertRaises(InvalidEvidence):
            verify(self.case, self.native, self.wire, process_code=1)

    def test_typed_ids_are_distinct(self):
        self.response(2)['id'] = '2'
        self.rejected()

    def test_unversioned_diagnostics_are_labelled(self):
        for i in (0, 1):
            self.notification('textDocument/publishDiagnostics', i)['params'].pop('version')
        self.assertEqual('ordered unversioned plus native state', self.check()['diagnostic_correlation'])

    def test_boolean_flags_are_not_truthy_strings(self):
        self.native['hover_displayed'] = 'true'
        self.rejected()

    def test_same_id_server_request_does_not_steal_initialize(self):
        self.wire.insert(1, {'direction': 'server', 'message': {'jsonrpc': '2.0', 'id': 1, 'method': 'window/showMessageRequest', 'params': {}}})
        self.wire.insert(2, {'direction': 'client', 'message': {'jsonrpc': '2.0', 'id': 1, 'result': None}})
        self.check()

    def test_unicode_offsets_and_crlf(self):
        self.assertEqual(5, offset('a😀b\r\nx', {'line': 0, 'character': 3}, 'utf-16'))
        self.assertEqual(8, offset('a😀b\r\nx', {'line': 1, 'character': 0}, 'utf-16'))
        self.assertEqual(5, offset('a😀b', {'line': 0, 'character': 5}, 'utf-8'))
        for encoding, char in [('utf-16', 2), ('utf-8', 3)]:
            with self.assertRaises(InvalidEvidence):
                offset('a😀b', {'line': 0, 'character': char}, encoding)

    def test_overlapping_edits(self):
        edits = [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 2}}, 'newText': 'x'},
                 {'range': {'start': {'line': 0, 'character': 1}, 'end': {'line': 0, 'character': 3}}, 'newText': 'y'}]
        with self.assertRaises(InvalidEvidence):
            apply_edits('abc', edits, 'utf-16')


class ObserverTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.obs = Observer(self.root)
        self.addCleanup(self.obs.close)

    def test_cross_direction_request_ids(self):
        self.obs.observe('client', {'id': 1, 'method': 'initialize'})
        self.obs.observe('server', {'id': 1, 'method': 'window/showMessageRequest'})
        self.obs.observe('client', {'id': 1, 'result': None})
        self.obs.observe('server', {'id': 1, 'result': {'capabilities': {}}})
        events = [json.loads(s) for s in (self.root / 'protocol.ndjson').read_text().splitlines()]
        self.assertEqual(1, sum(e['event'] == 'initialize_response' for e in events))
        self.assertFalse(self.obs.pending)

    def test_string_and_number_request_ids(self):
        self.obs.observe('client', {'id': 1, 'method': 'initialize'})
        self.obs.observe('client', {'id': '1', 'method': 'textDocument/semanticTokens/full'})
        self.obs.observe('server', {'id': '1', 'result': {'data': [0, 0, 1, 0, 0]}})
        self.assertIn(('int', 1), self.obs.pending)
        self.obs.observe('server', {'id': 1, 'result': {'capabilities': {}}})
        self.assertFalse(self.obs.pending)

    def test_wire_is_opt_in(self):
        self.obs.observe('client', {'method': 'initialized'})
        self.assertFalse((self.root / 'wire.ndjson').exists())

    def test_wire_budget_is_a_failure(self):
        other = Observer(self.root, wire=True, wire_limit=10)
        self.addCleanup(other.close)
        with self.assertRaises(ValueError):
            other.observe('client', {'method': 'initialized'})
        self.assertEqual(0, (self.root / 'wire.ndjson').stat().st_size)
        self.assertIn('wire byte limit exceeded', (self.root / 'protocol.ndjson').read_text())

    def test_non_object_message_is_rejected(self):
        with self.assertRaises(ValueError):
            self.obs.observe('server', [])


if __name__ == '__main__':
    unittest.main()
