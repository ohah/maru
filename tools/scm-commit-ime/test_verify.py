"""Synthetic controls for the independent judge; no GUI or pixel claim."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from prepare import load
from verify import validate, h, git_unchanged
source = load('scm_fixture_source', Path(__file__).resolve().parents[1]/'address-ime/test_verify.py')


def fixture():
    r, c, raw = source.fixture(prefix='', suffix='', initial_word='', owner_shift=56)
    r['schema'] = 'maru.scm-commit-ime.v1'
    c['schema'] = 'maru.scm-commit-ime-candidate.v1'
    r['glyph_advances'] = {'한': 10., '韓': 10.}
    for row in r['observations'] + r['composition']:
        row.update(commit_attempts=0, active_surface=77)
    for triplet in raw:
        for snapshot in triplet.values():
            snapshot['anchor_appkit'] = dict(x=20,y=1,w=8,h=18)
    return r,c,raw


class SCMJudgeTests(unittest.TestCase):
    def check(self, r,c,raw, mutate_git=None):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'window-transcript.json').write_text(json.dumps(raw))
            rows=[]
            for name in ('.git/HEAD','.git/refs/heads/main','.git/logs/HEAD','.git/index','message.txt'):
                p=root/'scm-repo'/name
                p.parent.mkdir(parents=True,exist_ok=True)
                p.write_text(name)
                rows.append(dict(path=name,sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
            (root/'git-baseline.json').write_text(json.dumps(rows))
            if mutate_git:
                (root/'scm-repo'/mutate_git).write_text('changed')
            validate(r,c,root)

    def test_normal_control(self):
        self.check(*fixture())

    def test_corrupt_evidence(self):
        attacks = {
            'candidate_commit_attempt':lambda r,c,w:r['observations'][2].update(commit_attempts=1),
            'candidate_newline':lambda r,c,w:r['observations'][23].update(query_hash=h('韓\n'),query_bytes=4),
            'lost_draft_after_blur':lambda r,c,w:r['observations'][-1].update(query_hash=h(''),query_bytes=0),
            'wrong_owner_namespace':lambda r,c,w:r['observations'][0].update(owner_generation=str(1<<57)),
            'replayed_owner':lambda r,c,w:r['observations'][4].update(owner_generation=r['observations'][0]['owner_generation']),
            'composition_terminal_leak':lambda r,c,w:r['composition'][0].update(terminal_bytes=1),
            'preview_published':lambda r,c,w:r['observations'][2].update(query_hash=h('韓'),query_bytes=3),
            'stale_cancel':lambda r,c,w:r['observations'][3].update(has_marked=True),
            'unequal_grid_width':lambda r,c,w:r['glyph_advances'].update(韓=11.),
            'preview_anchor_moves':lambda r,c,w:w[0]['opened']['anchor_appkit'].update(x=21),
            'wrong_focus':lambda r,c,w:r['observations'][1].update(first_responder=False),
            'terminal_return_missing':lambda r,c,w:r['observations'][-1].update(terminal_bytes=0),
            'surface_changes':lambda r,c,w:r['observations'][2].update(active_surface=78),
            'bounds_invalid':lambda r,c,w:r['geometry'][0].update(field_w=1),
        }
        for name,attack in attacks.items():
            with self.subTest(name=name):
                r,c,w=fixture();attack(r,c,w)
                with self.assertRaises(ValueError):
                    self.check(r,c,w)

    def test_git_changes_rejected(self):
        for name in ('.git/HEAD','.git/refs/heads/main','.git/logs/HEAD','.git/index','message.txt'):
            with self.subTest(name=name),self.assertRaises(ValueError):
                self.check(*fixture(),mutate_git=name)
