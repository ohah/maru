import copy
import unittest

from oracle import InvalidEvidence, verify
from test_oracle import golden


def pull_golden():
    case, native, wire = golden()
    wire[0]['message']['params']['capabilities'] = {'textDocument': {'diagnostic': {}}}
    wire[1]['message']['result']['capabilities']['diagnosticProvider'] = {'interFileDependencies': True}
    out = []
    identity = 2000000000
    for event in wire:
        m = event['message']
        if m.get('method') != 'textDocument/publishDiagnostics':
            out.append(event)
            continue
        identity += 1
        p = m['params']
        out += [
            dict(direction='client', message=dict(jsonrpc='2.0', id=identity, method='textDocument/diagnostic', params={'textDocument': {'uri': p['uri']}})),
            dict(direction='server', message=dict(jsonrpc='2.0', id=identity, result={'kind': 'full', 'items': p['diagnostics']})),
        ]
    return case, native, out


class PullEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.case, self.native, self.wire = pull_golden()

    def check(self):
        return verify(self.case, self.native, self.wire)

    def test_pull_without_any_push_normal_control(self):
        self.assertEqual('pull', self.check()['diagnostic_transport'])

    def test_object_provider_can_be_empty(self):
        self.wire[1]['message']['result']['capabilities']['diagnosticProvider'] = {}
        self.assertEqual('pull', self.check()['diagnostic_transport'])

    def test_wrong_pull_document_is_rejected(self):
        next(e['message'] for e in self.wire if e['message'].get('method') == 'textDocument/diagnostic')['params']['textDocument']['uri'] += '.other'
        with self.assertRaises(InvalidEvidence):
            self.check()

    def test_pull_not_advertised_by_client_is_rejected(self):
        self.wire[0]['message']['params']['capabilities'] = {}
        with self.assertRaises(InvalidEvidence):
            self.check()

    def test_missing_bad_pull_cannot_be_replaced_by_push(self):
        for e in self.wire:
            m = e['message']
            if m.get('id') == 2000000001 and 'result' in m:
                m['result']['items'] = []
        # An unsolicited push cannot substitute for the negotiated pull result.
        self.wire.insert(10, dict(direction='server', message=dict(jsonrpc='2.0', method='textDocument/publishDiagnostics', params={'uri': 'file:///owned/case/main.rs', 'version': 2, 'diagnostics': [{'severity': 1}]})))
        with self.assertRaises(InvalidEvidence):
            self.check()

    def test_cancellation_is_not_an_error_diagnostic(self):
        m = next(e['message'] for e in self.wire if e['direction'] == 'server' and e['message'].get('id') == 2000000001)
        m.pop('result')
        m['error'] = {'code': -32802, 'data': {'retriggerRequest': True}}
        with self.assertRaises(InvalidEvidence):
            self.check()

    def test_unchanged_without_a_prior_result_cannot_clear(self):
        m = next(e['message'] for e in self.wire if e['direction'] == 'server' and e['message'].get('id') == 2000000002)
        m['result'] = {'kind': 'unchanged', 'resultId': 'unused'}
        with self.assertRaises(InvalidEvidence):
            self.check()

    def test_retry_response_uses_the_same_document_version(self):
        at = next(i for i, e in enumerate(self.wire) if e['direction'] == 'server' and e['message'].get('id') == 2000000001)
        good = copy.deepcopy(self.wire[at])
        self.wire[at]['message'].pop('result')
        self.wire[at]['message']['error'] = {'code': -32802, 'data': {'retriggerRequest': True}}
        request = copy.deepcopy(self.wire[at - 1])
        request['message']['id'] = 2000000003
        good['message']['id'] = 2000000003
        self.wire[at + 1:at + 1] = [request, good]
        self.assertEqual('pull', self.check()['diagnostic_transport'])
