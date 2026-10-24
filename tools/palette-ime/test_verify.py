"""Reject false live success without launching GUI or pretending these are pixel tests."""
import copy
import unittest

from verify import text_hash, validate, validate_diagnostic


def fixture(committed=False):
    states, transitions, rows, geometry, composition = [], [], [], [], []
    for index in range(6):
        owner = (1 << 63) + 2 + 2 * index
        callbacks = index * (5 if committed else 2) + (3 if committed else 0)
        state = dict(name=f'han_{index}', first_responder=True, open=1, palette_owner=1,
                     owner_generation=str(owner), query_bytes=3 if committed else 0, query_hash=text_hash('한' if committed else ''),
                     preedit_bytes=0 if committed else 3, preedit_hash=text_hash('' if committed else '한'), results=0,
                     terminal_bytes=7, has_marked=not committed, committed_callbacks=callbacks)
        for phase, letter in enumerate(('ㅎ', '하', '한')):
            composition.append(dict(state, name=f'{letter}_{index}', query_hash=text_hash(letter if committed else ''),
                                    preedit_hash=text_hash('' if committed else letter),
                                    committed_callbacks=callbacks - (2 - phase) if committed else callbacks))
        states.append(state)
        geometry += [dict(x=10, y=10, w=8, h=18, field_x=0, field_y=0, field_w=200, field_h=40),
                     dict(x=26, y=10, w=8, h=18, field_x=0, field_y=0, field_w=200, field_h=40)]
        if index == 5:
            states.append(dict(state, name='selected', query_bytes=3, query_hash=text_hash('韓'),
                               preedit_bytes=0, preedit_hash=text_hash(''), has_marked=False))
            break
        cancelled = dict(state, name=f'cancel_{index}', query_bytes=3, query_hash=text_hash('한'),
                         preedit_bytes=0, preedit_hash=text_hash(''), has_marked=False, committed_callbacks=callbacks + 2)
        states.append(cancelled)
        before = dict(owner_generation=owner, first_responder=True, search_owner=True,
                      query_bytes=state['query_bytes'], query_hash=int(state['query_hash']), preedit_bytes=state['preedit_bytes'], preedit_hash=int(state['preedit_hash']))
        opened = dict(before, query_bytes=3, query_hash=int(text_hash('한')), preedit_bytes=3, preedit_hash=int(text_hash('韓')))
        closed = dict(opened, preedit_bytes=0, preedit_hash=int(text_hash('')))
        counter = dict(pty_input_bytes=7, committed_text_callbacks=callbacks, base_screen_generation=8)
        transitions.append(dict(before=before, opened=opened, closed=closed, before_counters=counter,
                                opened_counters=dict(counter, committed_text_callbacks=callbacks + 1),
                                closed_counters=dict(counter, committed_text_callbacks=callbacks + 2)))
        rows.append(dict(window_id=100 + index, counters=counter))
    states.append(dict(states[-1], name='terminal_restored', open=0, palette_owner=0,
                       owner_generation='0', query_hash=text_hash('한'), terminal_bytes=8))
    report = dict(schema='maru.palette-ime.v1', mode='live', passed=True, failures=[], candidate_count=5,
                  observations=states, geometry=geometry, composition=composition)
    candidate = dict(schema='maru.session-dock-ime-candidate-observation.v1',
                     source_id='com.apple.inputmethod.Korean.2SetKorean', rows=rows, search_transitions=transitions)
    return report, candidate


class VerifyTests(unittest.TestCase):
    def test_diagnostic_cannot_be_pixel_success(self):
        report, candidate = fixture()
        report['mode'] = 'diagnostic'
        validate_diagnostic(report)
        with self.assertRaises(ValueError):
            validate(report, candidate)
    def test_native_committed_replacement_delivery(self):
        report, candidate = fixture(committed=True)
        validate(report, candidate)
        for mutate in [lambda r: r['composition'][1].update(query_hash=text_hash('gk')),
                       lambda r: r['composition'][1].update(committed_callbacks=99),
                       lambda r: r['composition'][1].update(has_marked=True)]:
            bad = copy.deepcopy(report)
            mutate(bad)
            with self.assertRaises(ValueError):
                validate(bad, candidate)

    def reject(self, mutations):
        report, candidate = fixture()
        validate(report, candidate)
        for name, mutate in mutations:
            with self.subTest(name=name):
                bad_report, bad_candidate = copy.deepcopy((report, candidate))
                mutate(bad_report, bad_candidate)
                with self.assertRaises(ValueError):
                    validate(bad_report, bad_candidate)
                validate(report, candidate)

    def test_owner_and_source(self):
        self.reject([
            ('wrong source', lambda r, c: c.update(source_id='ABC')),
            ('old activation', lambda r, c: r['observations'][2].update(owner_generation=r['observations'][0]['owner_generation'])),
            ('lost first responder', lambda r, c: r['observations'][1].update(first_responder=False)),
            ('wrong selection owner', lambda r, c: r['observations'][-2].update(owner_generation='1')),
        ])

    def test_canonical_preview_and_selection(self):
        self.reject([
            ('Latin input', lambda r, c: r['observations'][0].update(preedit_hash=text_hash('g'))),
            ('duplicated commit', lambda r, c: r['observations'][1].update(query_bytes=6)),
            ('wrong Hanja', lambda r, c: r['observations'][-2].update(query_hash=text_hash('한'))),
            ('cancel mismatch', lambda r, c: c['search_transitions'][0]['closed'].update(query_hash=int(text_hash('韓')))),
        ])

    def test_terminal_and_callback_counters(self):
        self.reject([
            ('terminal leak', lambda r, c: r['observations'][2].update(terminal_bytes=8)),
            ('terminal never resumed', lambda r, c: r['observations'][-1].update(terminal_bytes=7)),
            ('extra callback', lambda r, c: c['search_transitions'][0]['opened_counters'].update(committed_text_callbacks=3)),
            ('terminal screen changed', lambda r, c: c['search_transitions'][0]['closed_counters'].update(base_screen_generation=9)),
        ])

    def test_candidate_lifecycle_binding(self):
        self.reject([
            ('window replay', lambda r, c: c['rows'][1].update(window_id=c['rows'][0]['window_id'])),
            ('missing triplet', lambda r, c: c['search_transitions'].pop()),
            ('unbound owner', lambda r, c: c['search_transitions'][0]['before'].update(owner_generation=2)),
            ('producer failure', lambda r, c: r.update(passed=False)),
        ])

    def test_caret_geometry(self):
        self.reject([
            ('no advance', lambda r, c: r['geometry'][1].update(x=10)),
            ('off field', lambda r, c: r['geometry'][1].update(x=999)),
            ('empty anchor', lambda r, c: r['geometry'][1].update(h=0)),
            ('missing samples', lambda r, c: r['geometry'].pop()),
        ])


if __name__ == '__main__':
    unittest.main()
