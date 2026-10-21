#!/usr/bin/env python3
"""Recheck five sidebar rounds from CLI snapshots and actual Metal pixels."""
import json
import pathlib
import sys


def verify(output):
    manifest = json.loads((output / 'manifest.json').read_text())
    assert len(manifest['rounds']) == 5
    changed = 0
    samples = 0
    for number, result in enumerate(manifest['rounds'], 1):
        assert result['round'] == number and result['mode'] == 'sidebar'
        assert result['passed'] and not result['errors']
        expected = result['expected']
        assert expected['source'] == 'sidebar'
        assert expected['role'] == {1: 'tab', 2: 'tree_item', 3: 'tree_item', 4: 'button', 5: 'button'}[number]
        assert result['hover']['picking'] and not result['selected']['picking']
        assert result['hover']['hovered'] == expected
        assert result['selected']['selected'] == expected
        after = [v for v in result['selected']['nodes'] if v['source'] == 'sidebar']
        assert result['sidebar_before'] == after, 'product action changed sidebar'
        if number <= 3:
            assert result['control'] is not None, 'missing normal product action control'
            assert after != [v for v in result['control']['nodes'] if v['source'] == 'sidebar']
        folder = output / f'round-{number:02d}'
        report = (folder / 'report.txt').read_text()
        assert 'phase=hover cursor=crosshair' in report
        assert f'placement={number}' in report
        before = (folder / 'baseline.ppm').read_bytes().split(b'\n', 3)
        hover = (folder / 'hover.ppm').read_bytes().split(b'\n', 3)
        assert before[:3] == hover[:3]
        width, height = map(int, before[1].split())
        assert len(before[3]) == len(hover[3]) == width * height * 3
        if number == 5:
            assert width >= 1800, 'missing injected 2x owner backing pixels'
            assert (folder / 'detached.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        r = expected['visible_rect']
        x, y, w, h = (int(r[v]) for v in ('x', 'y', 'width', 'height'))
        assert 0 <= x < x+w <= width and 0 <= y < y+h <= height
        edge = [(xx, yy) for yy in range(y, y+h) for xx in range(x, x+w)
                if xx-x < 2 or x+w-xx <= 2 or yy-y < 2 or y+h-yy <= 2]
        pixels = sum(before[3][(yy*width+xx)*3:(yy*width+xx)*3+3] != hover[3][(yy*width+xx)*3:(yy*width+xx)*3+3] for xx, yy in edge)
        assert pixels > 0, 'no painted boundary at CLI geometry'
        changed += pixels
        samples += len(json.loads((folder / 'observations.json').read_text()))
    return dict(passed=True, rounds=5, cli_samples=samples, changed_edge_pixels=changed)


if __name__ == '__main__':
    root = pathlib.Path(sys.argv[1])
    result = verify(root)
    (root / 'verified.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
