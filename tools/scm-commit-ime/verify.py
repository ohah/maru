"""Independent SCM message semantics and shared OS candidate/pixel binding."""
import hashlib
import json
from pathlib import Path
from prepare import load
common = load('scm_windows', Path(__file__).resolve().parents[1] / 'address-ime/verify.py')
anchors = load('scm_anchors', Path(__file__).resolve().parents[1] / 'project-search-ime/verify.py')
h, require = common.h, common.require
validate_anchors = anchors.validate_anchors


def semantics(report):
    require(report['schema'] == 'maru.scm-commit-ime.v1' and report['passed'] and not report['failures'], 'producer')
    require(report['candidate_count'] == 5, 'five windows')
    states = report['observations']
    expected = sum(([f'selected_fixture_{i}', f'han_{i}', f'opened_{i}', f'cancel_{i}'] for i in range(5)), []) + ['selected_fixture_5', 'han_5', 'opened_5', 'selected', 'terminal_restored']
    require([r['name'] for r in states] == expected, 'states')
    require([r['name'] for r in report['composition']] == ['ㅎ', '하', '한'] * 6, 'composition')
    base = states[0]['terminal_bytes']
    surface = states[0]['active_surface']
    for row in states + report['composition']:
        require(row['commit_attempts'] == 0 and row['active_surface'] == surface, 'commit attempt or surface transfer')
    def text(row, key, value):
        require(row[key+'_hash'] == h(value) and row[key+'_bytes'] == len(value.encode()), key)
    owners = set()
    for i in range(6):
        group = states[4*i:4*i+4]
        owner = int(group[0]['owner_generation'])
        require(1 << 56 < owner < 1 << 57 and owner not in owners, 'activation')
        owners.add(owner)
        for row in group + report['composition'][3*i:3*i+3]:
            require(int(row['owner_generation']) == owner and row['first_responder'] and row['open'] == row['palette_owner'] == 1 and row['terminal_bytes'] == base, 'owner or terminal leak')
        text(group[0], 'document', ''); text(group[0], 'query', '')
        for row, letter in zip(report['composition'][3*i:3*i+3], ('ㅎ','하','한')):
            text(row, 'document', letter)
            committed = row['query_hash'] == h(letter) and row['query_bytes'] == len(letter.encode()) and row['preedit_bytes'] == 0
            marked = row['query_hash'] == h('') and row['query_bytes'] == 0 and row['preedit_hash'] == h(letter) and row['preedit_bytes'] == len(letter.encode())
            require(committed or marked, 'composition publication')
        text(group[1], 'document', '한'); text(group[1], 'query', '한')
        text(group[2], 'document', '韓'); text(group[2], 'query', ''); text(group[2], 'preedit', '韓')
        require(group[2]['has_marked'], 'candidate preedit')
        word = '한' if i < 5 else '韓'
        text(group[3], 'document', word); text(group[3], 'query', word)
        require(not group[3]['has_marked'] and group[3]['preedit_bytes'] == 0 and group[3]['committed_callbacks'] == group[2]['committed_callbacks'] + 1, 'candidate settlement')
    end = states[-1]
    text(end, 'query', '韓')
    require(end['open'] == end['palette_owner'] == 0 and int(end['owner_generation']) == 0 and end['terminal_bytes'] == base+1 and not end['has_marked'] and end['first_responder'], 'terminal return')
    require(len(report['geometry']) == 12, 'geometry')
    advances = report['glyph_advances']
    require(advances['한'] > 0 and advances['韓'] == advances['한'], 'equal width grid glyphs')
    for empty, composed in zip(report['geometry'][::2], report['geometry'][1::2]):
        require(abs(composed['x'] - empty['x'] - advances['한']) <= .01, 'caret advance')
        for g in (empty, composed):
            require(g['w'] > 0 and g['h'] > 0 and g['x'] >= g['field_x']-1 and g['x']+g['w'] <= g['field_x']+g['field_w']+1 and g['y'] >= g['field_y']-1 and g['y']+g['h'] <= g['field_y']+g['field_h']+1, 'anchor bounds')
    return states, base


def git_unchanged(root):
    root = Path(root)
    baseline = json.loads((root/'git-baseline.json').read_text())
    require([row['path'] for row in baseline] == ['.git/HEAD', '.git/refs/heads/main', '.git/logs/HEAD', '.git/index', 'message.txt'], 'git witness inventory')
    for row in baseline:
        path = root/'scm-repo'/row['path']
        require(path.is_file() and not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256'], 'Git fixture mutated')


def validate(report, candidate, artifact_root=None):
    states, base = semantics(report)
    if artifact_root is None:
        roots = []
        for path in Path('/private/tmp').glob('maru-palette-live-*/run'):
            try:
                if json.loads((path/'result.json').read_text()) == report and json.loads((path/'candidate.json').read_text()) == candidate:
                    roots.append(path)
            except (OSError, ValueError):
                pass
        require(len(roots) == 1, 'unique run identity')
        artifact_root = roots[0]
    git_unchanged(artifact_root)
    validate_anchors(report, json.loads((Path(artifact_root)/'window-transcript.json').read_text()))
    return common.validate_window_evidence(report, candidate, states, base, artifact_root, scene='scm-commit')


def validate_diagnostic(report):
    require(report['mode'] == 'diagnostic' and report['window_inventory_validated'] is False, 'diagnostic separation')
    semantics(report)
