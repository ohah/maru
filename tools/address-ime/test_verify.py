"""Negative controls for URL suffix, owner, callback budget and raw capture binding."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from verify import h, validate, validate_diagnostic

PREFIX = 'https://a.invalid/'


def fixture(prefix=PREFIX):
    states, composition, raw, artifacts = [], [], [], []
    count = 0
    for index in range(6):
        owner = (1 << 62) + 2 + index

        def state(name, query, preedit, word, callbacks):
            return dict(name=name, owner_generation=str(owner), first_responder=True,
                        open=1, palette_owner=1, terminal_bytes=0, navigate_pending=0,
                        query_bytes=len(query.encode()), query_hash=h(query),
                        preedit_bytes=len(preedit.encode()), preedit_hash=h(preedit),
                        document_bytes=len((prefix + word + '/z').encode()), document_hash=h(prefix + word + '/z'),
                        committed_callbacks=callbacks, has_marked=bool(preedit))

        states.append(state(f'selected_fixture_{index}', prefix + '😀/z', '', '😀', count))
        for letter in ('ㅎ', '하', '한'):
            count += 1
            composition.append(state(letter, prefix + letter + '/z', '', letter, count))
        before = state(f'han_{index}', prefix + '한/z', '', '한', count)
        count += 1
        opened = state(f'opened_{index}', prefix + '/z', '韓', '韓', count)
        count += 1
        closed = state(f'cancel_{index}' if index < 5 else 'selected', prefix + ('한' if index < 5 else '韓') + '/z', '', '한' if index < 5 else '韓', count)
        states.extend([before, opened, closed])
        if index == 5:
            break
        identity = dict(pid=77, bundle_id='dev.maru.apphost', signing_id='dev.maru.apphost', apple_signed=False)
        window = dict(id=100 + index, owner=identity, layer=20, on_screen=True, bounds=dict(x=20, y=40, w=89, h=266))
        capture = dict(window_id=window['id'], capture_basename=f'candidate-{index}-{window["id"]}.png', sha256='a' * 64, width=89, height=266, hanja_rows=6)
        snapshots = {}
        for name, value in zip(('before', 'opened', 'closed'), (before, opened, closed)):
            snapshots[name] = dict(search={key: (int(value[key]) if key in ('owner_generation', 'query_hash', 'preedit_hash') else value[key]) for key in ('owner_generation', 'query_bytes', 'query_hash', 'preedit_bytes', 'preedit_hash')},
                                   counters=dict(pty_input_bytes=0, committed_text_callbacks=value['committed_callbacks'], base_screen_generation=5),
                                   windows=[window] if name == 'opened' else [], app_captures=[capture] if name == 'opened' else [])
            snapshots[name]['search'].update(first_responder=True, search_owner=True)
        raw.append(snapshots)
        artifacts.append(dict(window_id=window['id'], owner_pid=77, bundle_id=identity['bundle_id'], signing_id=identity['signing_id'], apple_signed=False, layer=20, app_capture=capture))
    terminal = copy.deepcopy(states[-1])
    terminal.update(name='terminal_restored', owner_generation='0', open=0, palette_owner=0, terminal_bytes=1)
    states.append(terminal)
    geometry = [dict(x=x, y=1, w=8, h=18, field_x=0, field_y=0, field_w=300, field_h=30) for _ in range(6) for x in (10, 20)]
    report = dict(schema='maru.address-ime.v1', passed=True, failures=[], mode='live', candidate_count=5,
                  window_inventory_validated=True, observations=states, composition=composition, geometry=geometry)
    candidate = dict(schema='maru.address-ime-candidate.v1', source_id='com.apple.inputmethod.Korean.2SetKorean', rows=artifacts)
    return report, candidate, raw


class AddressVerifierTests(unittest.TestCase):
    def check(self, report, candidate, raw):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'window-transcript.json').write_text(json.dumps(raw))
            validate(report, candidate, root)

    def test_positive(self):
        self.check(*fixture())

    def test_diagnostic_cannot_claim_pixels(self):
        r, c, raw = fixture()
        r.update(mode='diagnostic', window_inventory_validated=False)
        validate_diagnostic(r)
        with self.assertRaises(ValueError):
            self.check(r, c, raw)

    def test_suffix_and_selected_word(self):
        for row in (1, 2, 3, -2):
            r, c, raw = fixture()
            r['observations'][row]['document_hash'] = h('韓')
            with self.subTest(row=row), self.assertRaises(ValueError):
                self.check(r, c, raw)

    def test_replayed_owner_and_lost_responder(self):
        for key, value in (('owner_generation', str((1 << 62) + 2)), ('first_responder', False)):
            r, c, raw = fixture()
            r['observations'][4][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check(r, c, raw)

    def test_extra_commit_terminal_leak_and_navigate(self):
        for row, key in ((-2, 'committed_callbacks'), (2, 'terminal_bytes'), (1, 'navigate_pending')):
            r, c, raw = fixture()
            r['observations'][row][key] += 1
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check(r, c, raw)

    def test_raw_binding_window_replay_and_capture_swap(self):
        for attack in ('hash', 'callbacks', 'closed_window', 'capture', 'replay'):
            r, c, raw = fixture()
            if attack == 'hash':
                raw[0]['opened']['search']['query_hash'] = 0
            elif attack == 'callbacks':
                raw[0]['opened']['counters']['committed_text_callbacks'] += 1
            elif attack == 'closed_window':
                raw[0]['closed']['windows'] = raw[0]['opened']['windows']
            elif attack == 'capture':
                c['rows'][0]['app_capture'] = c['rows'][1]['app_capture']
            else:
                c['rows'][1]['window_id'] = c['rows'][0]['window_id']
            with self.subTest(attack=attack), self.assertRaises(ValueError):
                self.check(r, c, raw)

    def test_missing_composition_and_caret(self):
        r, c, raw = fixture()
        r['composition'].pop()
        with self.assertRaises(ValueError):
            self.check(r, c, raw)
        r, c, raw = fixture()
        r['geometry'][1]['x'] = r['geometry'][0]['x']
        with self.assertRaises(ValueError):
            self.check(r, c, raw)


if __name__ == '__main__':
    unittest.main()
