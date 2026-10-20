#!/usr/bin/env python3
"""Independent artifact gate for native tree E2E, including Paused preservation."""
import argparse
import json
from pathlib import Path
import re


def verify(output):
    manifest = json.loads((output / 'manifest.json').read_text())
    assert manifest['passed'] and len(manifest['rounds']) == 20, 'need all twenty completed rounds'
    changed = 0
    samples = 0
    images = 0
    for result in manifest['rounds']:
        directory = output / f'round-{result["round"]:02d}'
        report = (directory / 'report.txt').read_text()
        assert 'click-missing' not in report and 'hover-missing' not in report, 'native target missing'
        assert 'label=row actual=hand' in report, 'wrong native row cursor'
        for phase in ('ready', 'selected', 'collapsed', 'searched', 'cleared', 'expanded', 'picked'):
            match = re.search(r'inspector label=' + phase + r' placement=(\d+).*?flags=(\d+)', report)
            assert match, f'missing native phase {phase}'
            placement, flags = map(int, match.groups())
            assert placement == result['placement'] + 1, 'wrong native placement'
            expected_pause = result['paused'] and phase in ('collapsed', 'searched', 'cleared', 'expanded')
            assert bool(flags & 4) == expected_pause, f'Paused changed at {phase}'
        pixels = json.loads((directory / 'pixels.json').read_text())
        assert pixels['outline_edge_changed_pixels'] > 0, 'missing owner outline'
        changed += pixels['outline_edge_changed_pixels']
        for name in ('baseline', 'selected', 'collapsed', 'searched', 'picked') + (('detached',) if result['placement'] == 4 else ()):
            assert (directory / f'{name}.png').read_bytes()[:8] == b'\x89PNG\r\n\x1a\n', 'missing real PNG'
            images += 1
        observations = json.loads((directory / 'observations.json').read_text())
        assert len(observations) == result['cli_samples'], 'CLI sample count mismatch'
        samples += len(observations)
    return dict(rounds=20, cli_samples=samples, pngs=images, outline_changed_pixels=changed)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.output), indent=2))
