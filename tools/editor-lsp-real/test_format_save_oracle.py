"""Synthetic protocol controls, independent of real SDK execution evidence."""
from pathlib import Path
import tempfile
import unittest

from format_save_fixture import make_case, fixture
from format_save_oracle import verify
from oracle import InvalidEvidence


def golden(language='rust', encoding='utf-16'):
    c = make_case(Path('/owned/format-save'), language, 'f' * 32)
    uri = Path(c['path']).as_uri()
    symbol = 'probe_add' if language == 'rust' else 'probeAdd'
    wire = []
    clock = [1_000_000_000]
    def message(direction, **m):
        wire.append(dict(time_ns=clock[0], direction=direction, message=dict(jsonrpc='2.0', **m)))
        clock[0] += 1_000_000
    def position(text, byte):
        prefix = text.encode()[:byte].decode()
        tail = prefix.rsplit('\n', 1)[-1]
        return dict(line=prefix.count('\n'), character=len(tail.encode()) if encoding == 'utf-8' else len(tail.encode('utf-16-le')) // 2)
    def notify(method, **params):
        message('client', method=method, params=params)
    def change(version, text):
        notify('textDocument/didChange', textDocument=dict(uri=uri, version=version), contentChanges=[dict(text=text)])
    def save(text):
        notify('textDocument/didSave', textDocument=dict(uri=uri), text=text)
    def ready(identity, text):
        message('client', id=identity, method='textDocument/definition', params=dict(textDocument=dict(uri=uri), position=position(text, c['definition_offset'])))
        at = text.encode().index(symbol.encode())
        message('server', id=identity, result=[dict(uri=uri, range=dict(start=position(text, at), end=position(text, at+len(symbol))))])
    def formatting(identity, before, after):
        message('client', id=identity, method='textDocument/formatting', params=dict(textDocument=dict(uri=uri), options=dict(tabSize=4, insertSpaces=True)))
        message('server', id=identity, result=[dict(range=dict(start=dict(line=0, character=0), end=position(before, len(before.encode()))), newText=after)])
    message('client', id=1, method='initialize', params=dict(rootUri=Path(c['root']).as_uri()))
    message('server', id=1, result=dict(capabilities=dict(documentFormattingProvider=True, definitionProvider=True, positionEncoding=encoding)))
    notify('initialized')
    notify('textDocument/didOpen', textDocument=dict(uri=uri, version=1, text=c['good']))
    change(2, c['before_save'])
    ready(200000001, c['before_save'])
    formatting(400000001, c['before_save'], c['formatted'])
    change(3, c['formatted']); save(c['formatted'])
    change(4, c['before_save'])
    ready(200000002, c['before_save'])
    formatting(400000002, c['before_save'], c['formatted'])
    change(5, c['local']); save(c['local'])
    change(6, c['timeout_source'])
    ready(200000003, c['timeout_source'])
    formatting(400000003, c['timeout_source'], c['formatted']+'// timeout probe\n')
    clock[0] += 900_000_000
    save(c['timeout_source'])
    change(7, c['disabled_source']); save(c['disabled_source'])
    states = [
        ('before', c['good'], c['good'], 1, 0, False),
        ('dirty', c['before_save'], c['good'], 2, 1, True),
        ('waiting_normal', c['before_save'], c['good'], 2, 1, True),
        ('saved_normal', c['formatted'], c['formatted'], 3, 2, False),
        ('undone', c['before_save'], c['formatted'], 4, 1, True),
        ('waiting_stale', c['before_save'], c['formatted'], 4, 1, True),
        ('saved_stale', c['local'], c['local'], 5, 2, False),
        ('waiting_timeout', c['timeout_source'], c['local'], 6, 3, True),
        ('saved_timeout', c['timeout_source'], c['timeout_source'], 6, 3, False),
        ('saved_disabled', c['disabled_source'], c['disabled_source'], 7, 4, False),
    ]
    samples = [dict(phase=p, buffer=b, disk=d, version=v, undo_len=u, dirty=dirty) for p,b,d,v,u,dirty in states]
    n = dict(schema='maru.lsp-real.product.v1', scenario='format-save', language=language, stage='complete', failure=None,
             result=dict(stage='complete', failure=None, request_ids=[400000001,400000002,400000003], samples=samples,
                         applied=1, stale=1, timeouts=1, format_requests=3, saves=4, duplicate_commands_suppressed=True,
                         stale_response_observed=True, timeout_response_observed=True, disabled_no_request=True,
                         timeout_ms=1000, timeout_deadline_ms=10000, timeout_response_seen_ms=9100, timeout_hold_end_ms=10001))
    return c,n,wire


class FormatSaveOracleTests(unittest.TestCase):
    def test_normal_profiles_and_encodings(self):
        for language in ('rust','go'):
            for encoding in ('utf-8','utf-16'):
                with self.subTest(language=language,encoding=encoding):
                    c,n,w=golden(language,encoding)
                    if language=='go':
                        next(x['message']['result']['capabilities'] for x in w if x['direction']=='server' and x['message'].get('id')==1)['documentFormattingProvider']={}
                    at=next(i for i,x in enumerate(w) if x['direction']=='server' and x['message'].get('id')==400000001)
                    stamp=w[at]['time_ns']
                    w[at:at]=[dict(time_ns=stamp,direction='server',message=dict(jsonrpc='2.0',id=400000001,method='workspace/configuration',params={})),dict(time_ns=stamp,direction='client',message=dict(jsonrpc='2.0',id=400000001,result=[]))]
                    self.assertTrue(verify(c,n,w)['format_save'])

    def test_fixture_ownership(self):
        for language in ('rust','go'):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)/'case'
                c = fixture(root,language)
                self.assertEqual(Path(c['path']).read_text(),c['good'])
                self.assertIn('한글😀',c['good'])
                self.assertNotEqual(c['before_save'],c['formatted'])
                self.assertEqual(Path(c['metadata']['path']).read_text(),c['metadata']['good'])
                with self.assertRaises(FileExistsError):fixture(root,language)

    def test_damaged_evidence(self):
        def response(w,identity):
            return next(x['message'] for x in w if x['direction']=='server' and x['message'].get('id')==identity and 'method' not in x['message'])
        attacks = [
            ('forged short timeout wire interval', lambda c,n,w:next(x for x in w if x['message'].get('method')=='textDocument/didSave' and x['message']['params'].get('text')==c['timeout_source']).update(time_ns=next(x['time_ns'] for x in w if x['direction']=='server' and x['message'].get('id')==400000003)+1_000_000)),
            ('boolean wire timestamp', lambda c,n,w:w[0].update(time_ns=True)),
            ('readiness missing', lambda c,n,w:w.__setitem__(slice(None),[x for x in w if not(x['direction']=='server' and x['message'].get('id')==200000003)])),
            ('empty timeout edit', lambda c,n,w:response(w,400000003).update(result=[])),
            ('wrong formatting option', lambda c,n,w:next(x['message']['params']['options'] for x in w if x['message'].get('method')=='textDocument/formatting').update(tabSize=True)),
            ('wrong scenario', lambda c,n,w:n.update(scenario='rename')),
            ('wrong language', lambda c,n,w:n.update(language='go')),
            ('incomplete', lambda c,n,w:n.update(stage='normal_save')),
            ('nested incomplete', lambda c,n,w:n['result'].update(stage='normal_save')),
            ('failed process report', lambda c,n,w:n.update(failure='failed')),
            ('format not applied', lambda c,n,w:n['result'].update(applied=0)),
            ('stale applied', lambda c,n,w:n['result'].update(stale=0)),
            ('timeout not reached', lambda c,n,w:n['result'].update(timeouts=0)),
            ('extra format request', lambda c,n,w:n['result'].update(format_requests=4)),
            ('save omitted', lambda c,n,w:n['result'].update(saves=3)),
            ('boolean counter', lambda c,n,w:n['result'].update(applied=True)),
            ('pending save stolen', lambda c,n,w:n['result'].update(duplicate_commands_suppressed=False)),
            ('stale response unobserved', lambda c,n,w:n['result'].update(stale_response_observed=False)),
            ('timeout response unobserved', lambda c,n,w:n['result'].update(timeout_response_observed=False)),
            ('disabled still requests', lambda c,n,w:n['result'].update(disabled_no_request=False)),
            ('boolean clock', lambda c,n,w:n['result'].update(timeout_ms=True)),
            ('changed product deadline', lambda c,n,w:n['result'].update(timeout_ms=5000)),
            ('reply already late', lambda c,n,w:n['result'].update(timeout_response_seen_ms=10001)),
            ('hold ended early', lambda c,n,w:n['result'].update(timeout_hold_end_ms=9999)),
            ('duplicate IDs', lambda c,n,w:n['result'].update(request_ids=[400000001]*3)),
            ('missing sample', lambda c,n,w:n['result']['samples'].pop()),
            ('early disk write', lambda c,n,w:n['result']['samples'][2].update(disk=c['before_save'])),
            ('incorrect format', lambda c,n,w:n['result']['samples'][3].update(buffer=c['before_save'])),
            ('two undo entries', lambda c,n,w:n['result']['samples'][3].update(undo_len=3)),
            ('undo lost text', lambda c,n,w:n['result']['samples'][4].update(buffer=c['good'])),
            ('undo wrote disk', lambda c,n,w:n['result']['samples'][4].update(disk=c['before_save'])),
            ('stale overwrote edit', lambda c,n,w:n['result']['samples'][6].update(buffer=c['formatted'])),
            ('timeout applied late edit', lambda c,n,w:n['result']['samples'][8].update(buffer=c['formatted'])),
            ('disabled formatted', lambda c,n,w:n['result']['samples'][9].update(buffer=c['formatted'])),
            ('saved still dirty', lambda c,n,w:n['result']['samples'][3].update(dirty=True)),
            ('boolean version', lambda c,n,w:n['result']['samples'][0].update(version=True)),
            ('no capability', lambda c,n,w:response(w,1)['result']['capabilities'].update(documentFormattingProvider=False)),
            ('empty format result', lambda c,n,w:response(w,400000001).update(result=[])),
            ('stale error not edit', lambda c,n,w:response(w,400000002).update(error=dict(code=-1,message='failed'))),
            ('timeout response missing', lambda c,n,w:w.__setitem__(slice(None),[x for x in w if not(x['direction']=='server' and x['message'].get('id')==400000003)])),
            ('wrong returned bytes', lambda c,n,w:response(w,400000001)['result'][0].update(newText='wrong')),
            ('overlapping edits', lambda c,n,w:response(w,400000001)['result'].__imul__(2)),
            ('save missing from wire', lambda c,n,w:w.__setitem__(slice(None),[x for x in w if x['message'].get('method')!='textDocument/didSave'])),
            ('wrong saved text', lambda c,n,w:next(x['message']['params'] for x in w if x['message'].get('method')=='textDocument/didSave').update(text=c['good'])),
            ('main changed outside flow', lambda c,n,w:w.__setitem__(slice(None),[x for x in w if not(x['message'].get('method')=='textDocument/didChange' and x['message']['params']['textDocument']['version']==3)])),
        ]
        for name,attack in attacks:
            with self.subTest(name=name):
                c,n,w = golden()
                attack(c,n,w)
                with self.assertRaises(InvalidEvidence):verify(c,n,w)


if __name__=='__main__':unittest.main()
