#!/usr/bin/env python3
"""Execute five hostile parser/queue mutations in disposable source copies.

Normal/ReleaseFast controls and equivalent rewrites prevent a judge that merely
rejects every variant. This proves pure policy coverage, not AppKit URL delivery.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--zig')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = (args.output or Path(tempfile.mkdtemp(prefix='maru-url-adversarial-'))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error('a new empty output directory is required')
    zig = args.zig or subprocess.check_output(['mise', 'which', 'zig'], text=True).strip()
    source = (root/'src/session/editor_app_url.zig').read_text()
    tests = (root/'src/session/editor_app_url_test.zig').read_text()
    mutations = [
        ('duplicate-path', 'if (path != null) return error.InvalidURL;', ''),
        ('invalid-utf8', 'if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidURL;', ''),
        ('zero-coordinate', 'if (n == 0) return error.InvalidURL;', ''),
        ('early-drain', 'if (self.state != .ready or self.count == 0) return null;', 'if (self.count == 0) return null;'),
        ('unbounded-slots', 'if (self.count == max_pending or raw.len > max_pending_bytes - self.raw_bytes)', 'if (raw.len > max_pending_bytes - self.raw_bytes)'),
    ]
    equivalents = [
        ('equivalent-length', 'raw.len < prefix.len', 'prefix.len > raw.len'),
        ('equivalent-ring', '(self.head + self.count) % max_pending', '(self.head + self.count) & (max_pending - 1)'),
    ]
    results = []

    def run(name, variant, mode, expected):
        case = output/name
        case.mkdir()
        (case/'editor_app_url.zig').write_text(variant)
        (case/'editor_app_url_test.zig').write_text(tests)
        # Absolute roots and per-case manifests prevent a compiler cache keyed by
        # relative arguments from running a preceding control's artifact.
        command = [zig, 'test', str((case/'editor_app_url_test.zig').resolve()), '-O', mode,
                   '--cache-dir', str(case/'cache'), '--global-cache-dir', str(output/'global')]
        result = subprocess.run(command, cwd=case, text=True, capture_output=True, timeout=90)
        log = result.stdout+result.stderr
        (case/'test.log').write_text(log.replace(str(output), '<output>'))
        passed = result.returncode == 0
        # A rejected mutation must reach a test assertion, not fail compilation.
        if passed != expected or (not expected and 'FAIL' not in log and 'TestExpectedError' not in log):
            raise RuntimeError(f'{name}: unexpected test result {result.returncode}')
        results.append(dict(name=name, mode=mode, exit_code=result.returncode, expected_pass=expected))
        print(name, 'verified', flush=True)

    for number, (name, old, new) in enumerate(mutations, 1):
        if source.count(old) != 1:
            raise RuntimeError(f'non-unique mutation anchor: {name}')
        mode = 'Debug' if number % 2 else 'ReleaseFast'
        run(f'round-{number}-control', source, mode, True)
        run(f'round-{number}-{name}', source.replace(old, new), mode, False)
    for name, old, new in equivalents:
        if source.count(old) != 1:
            raise RuntimeError(f'non-unique equivalent anchor: {name}')
        run(name, source.replace(old, new), 'ReleaseFast', True)
    (output/'results.json').write_text(json.dumps(dict(
        scope='pure parser and queue; not OS delivery',
        source_sha256=hashlib.sha256(source.encode()).hexdigest(),
        test_sha256=hashlib.sha256(tests.encode()).hexdigest(), results=results), indent=2)+'\n')
    print(output/'results.json')


if __name__ == '__main__':
    main()
