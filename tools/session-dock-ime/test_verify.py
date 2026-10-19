"""Attack the semantic oracle with independently constructed known text/geometry witnesses."""
import copy
import hashlib
import unittest
import tempfile
from pathlib import Path
from verify import validate_report, validate_candidate_transitions
from prepare import replace_once, require_external_destination


def hash64(text):
    return str(int.from_bytes(hashlib.sha256(text.encode('utf-8')).digest()[0:8], byteorder='little'))


def control(mode='callbacks'):
    def row(name, query='', marked='', active=1, owner=1, cards=3, pty=1):
        return dict(name=name, first_responder=True, owner_generation=9 if owner else 0, search_active=active, dock_focus=owner,
                    search_owner=owner, query_bytes=len(query.encode()), query_hash=hash64(query),
                    preedit_bytes=len(marked.encode()), preedit_hash=hash64(marked), has_marked=bool(marked), cards=cards, terminal_bytes=pty)
    rows = [row('view_switch', active=0, owner=0, pty=0), row('search_focus')]
    if mode == 'callbacks':
        rows.append(row('marked', marked='한'))
        rows.extend([row('committed', query='한', cards=0), row('terminal_restored', query='한', active=0, owner=0, cards=0, pty=2)])
    else:
        rows += [row('live_han_' + str(i), marked='한') for i in range(5)]
        rows.extend([row('live_committed', query='한', cards=0), row('live_candidate_selected', query='韓', cards=0), row('live_terminal_restored', query='한', active=0, owner=0, cards=0, pty=2)])
    rect = dict(x=100, y=40, w=12, h=20, field_x=80, field_y=30, field_w=300, field_h=40)
    return dict(schema='maru.session-dock-ime.v1', mode=mode, passed=True, failures=[],
                observations=rows, candidate_count=0 if mode=='callbacks' else 5,
                geometry=[rect, dict(rect, x=124)])


class OracleTests(unittest.TestCase):
    def test_positive_and_unrelated_metadata(self):
        for mode in ('callbacks', 'live'):
            report = control(mode)
            validate_report(report, mode)
            report['observations'][1]['unused_note'] = 'equivalent control'
            validate_report(report, mode)

    def test_focus_and_callback_routing_mutations(self):
        for index, field, value in [(1,'first_responder',False), (1,'search_owner',0),
                                     (0,'dock_focus',1), (1,'terminal_bytes',0)]:
            report = control(); report['observations'][index][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_report(report, 'callbacks')

    def test_marked_must_not_commit_filter_or_leak(self):
        for field, value in [('query_hash',hash64('한')), ('query_bytes',3), ('preedit_hash',hash64('하')),
                              ('cards',0), ('terminal_bytes',2)]:
            report = control(); report['observations'][2][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_report(report, 'callbacks')

    def test_commit_and_blur_keep_original_target(self):
        for index, field, value in [(3,'cards',3), (3,'terminal_bytes',2), (4,'search_active',1),
                                     (4,'query_hash',hash64('')), (4,'terminal_bytes',1)]:
            report = control(); report['observations'][index][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_report(report, 'callbacks')

    def test_empty_fallback_clipped_and_stationary_caret(self):
        for field, value in [('x',0), ('y',0), ('w',0), ('h',100), ('x',100)]:
            report = control(); report['geometry'][1][field] = value
            with self.subTest(field=field,value=value), self.assertRaises(ValueError):
                validate_report(report, 'callbacks')

    def test_owner_and_appkit_state_stay_consistent(self):
        for mode in ('callbacks', 'live'):
            for index, field, value in [(2, 'first_responder', False), (2, 'search_owner', 0),
                                         (2, 'dock_focus', 0), (2, 'has_marked', False),
                                         (-2, 'has_marked', True), (-1, 'has_marked', True),
                                         (-1, 'preedit_hash', hash64('한')), (-1, 'cards', 3),
                                         (1, 'cards', 0)]:
                report = control(mode); report['observations'][index][field] = value
                with self.subTest(mode=mode, field=field), self.assertRaises(ValueError):
                    validate_report(report, mode)

    def test_missing_duplicate_and_forged_mode(self):
        for kind in ('missing', 'duplicate', 'candidate', 'failed', 'mode'):
            report = control('live')
            if kind == 'missing': report['observations'].pop(3)
            if kind == 'duplicate': report['observations'][3] = copy.deepcopy(report['observations'][2])
            if kind == 'candidate': report['candidate_count'] = 0
            if kind == 'failed': report['passed'] = False
            if kind == 'mode': report['mode'] = 'callbacks'
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                validate_report(report, 'live')

    def test_injection_requires_exact_source_identity(self):
        self.assertEqual(replace_once('before MARK after', 'MARK', 'NEW'), 'before NEW after')
        for text in ('missing', 'MARK MARK'):
            with self.assertRaises(RuntimeError): replace_once(text, 'MARK', 'NEW')

    def test_source_copy_cannot_recurse_into_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / 'repo'; repo.mkdir()
            alias = root / 'alias'; alias.symlink_to(repo, target_is_directory=True)
            require_external_destination(repo, root / 'evidence')
            for destination in (repo, repo / 'snapshot', alias / 'snapshot'):
                with self.subTest(destination=destination), self.assertRaises(RuntimeError):
                    require_external_destination(repo, destination)


def candidate_control(report, commit=True):
    transitions, rows = [], []
    for index in range(5):
        witness = report['observations'][index + 2]
        before = dict(owner_generation=witness['owner_generation'], first_responder=True, search_owner=True,
                      query_bytes=0, query_hash=int(hash64('')), preedit_bytes=3, preedit_hash=int(hash64('한')))
        opened = dict(before, query_bytes=3, query_hash=int(hash64('한')), preedit_bytes=0, preedit_hash=int(hash64(''))) if commit else dict(before)
        a = dict(pty_input_bytes=witness['terminal_bytes'], committed_text_callbacks=index * 2, base_screen_generation=7)
        b = dict(a, committed_text_callbacks=a['committed_text_callbacks'] + int(commit))
        transitions.append(dict(before=before, opened=opened, closed=dict(opened),
                                before_counters=a, opened_counters=b, closed_counters=dict(b)))
        rows.append(dict(window_id=index + 1, counters=dict(a)))
    return dict(schema='maru.session-dock-ime-candidate-observation.v1',
                source_id='com.apple.inputmethod.Korean.2SetKorean', rows=rows, search_transitions=transitions)


class CandidateQueryOracleTests(unittest.TestCase):
    def test_no_commit_and_exact_request_commit_controls(self):
        report = control('live')
        for commit in (False, True):
            validate_candidate_transitions(candidate_control(report, commit), report)

    def test_preview_then_cancel_matches_actual_korean_candidate(self):
        report = control('live')
        artifact = candidate_control(report)
        for row in artifact['search_transitions']:
            row['opened'] = dict(row['closed'], preedit_bytes=3, preedit_hash=int(hash64('韓')))
            row['closed_counters']['committed_text_callbacks'] += 1
        validate_candidate_transitions(artifact, report)
        stuck = copy.deepcopy(artifact)
        stuck['search_transitions'][0]['closed'] = dict(stuck['search_transitions'][0]['opened'])
        stuck['search_transitions'][0]['closed_counters'] = dict(stuck['search_transitions'][0]['opened_counters'])
        with self.assertRaises(ValueError):
            validate_candidate_transitions(stuck, report)
        for state, field, value in [('opened', 'preedit_hash', int(hash64('漢'))),
                                    ('opened', 'query_hash', int(hash64('韓'))),
                                    ('opened', 'query_bytes', 0),
                                    ('closed', 'preedit_hash', int(hash64('韓')))]:
            bad = copy.deepcopy(artifact)
            bad['search_transitions'][0][state][field] = value
            with self.subTest(state=state,field=field), self.assertRaises(ValueError):
                validate_candidate_transitions(bad, report)

    def test_rejects_query_owner_counter_and_manifest_rebinding(self):
        for mutation in ('query', 'owner', 'responder', 'pty', 'screen', 'callbacks', 'report', 'id_replay', 'schema', 'absent_owner'):
            report = control('live')
            artifact = candidate_control(report)
            row = artifact['search_transitions'][0]
            if mutation == 'query': row['opened']['query_hash'] = int(hash64('한韓'))
            if mutation == 'owner': row['closed']['owner_generation'] += 1
            if mutation == 'responder': row['opened']['first_responder'] = False
            if mutation == 'pty': row['closed_counters']['pty_input_bytes'] += 1
            if mutation == 'screen': row['closed_counters']['base_screen_generation'] += 1
            if mutation == 'callbacks': row['opened_counters']['committed_text_callbacks'] += 1
            if mutation == 'report': row['before_counters']['pty_input_bytes'] += 1
            if mutation == 'id_replay': artifact['rows'][1]['window_id'] = artifact['rows'][0]['window_id']
            if mutation == 'schema': artifact['schema'] = 'maru.session-host-cr6d-ime-candidate-observation.v2'
            if mutation == 'absent_owner':
                for name in ('before', 'opened', 'closed'): row[name]['owner_generation'] = 0
                report['observations'][2]['owner_generation'] = 0
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                validate_candidate_transitions(artifact, report)


if __name__ == '__main__': unittest.main()
