#!/usr/bin/env python3
"""Compile real search regressions and rejected defects in a private source copy."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
args.output.mkdir(parents=True, exist_ok=False)
zig = subprocess.check_output(['mise', 'which', 'zig'], cwd=repo, text=True).strip()
assert subprocess.check_output([zig, 'version'], text=True).strip() == '0.17.0'
results = []
with tempfile.TemporaryDirectory(prefix='maru-search-fd-mutants-') as temporary:
    private = Path(temporary)
    shutil.copytree(repo / 'src', private / 'src')
    helper = private / 'src/pty/macos_spawn.zig'
    runner = private / 'src/platform/macos/app_session/editor/search/process.zig'
    judges = private / 'src/platform/macos/project_search_fd_judges.zig'
    pristine = {p: p.read_text() for p in (helper, runner, judges)}
    hashes = {str(p.relative_to(private)): hashlib.sha256(p.read_bytes()).hexdigest() for p in pristine}
    hashes["tests/boundary/spawn_cloexec_axis.zig"] = hashlib.sha256((repo / "tests/boundary/spawn_cloexec_axis.zig").read_bytes()).hexdigest()

    def restore():
        for path, source in pristine.items():
            path.write_text(source)

    def execute(name, command, expected, markers):
        result = subprocess.run(command, cwd=private, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        (args.output / f'{name}.log').write_text(result.stdout)
        verified = (result.returncode == 0) == expected and all(m in result.stdout for m in markers)
        results.append(dict(name=name, expected_pass=expected, verified=verified, exit=result.returncode))
        (args.output / 'manifest.json').write_text(json.dumps(dict(sources=hashes, results=results), indent=2))
        if not verified:
            raise SystemExit(f'{name}: invalid control or unexpected result\n{result.stdout[-2500:]}')

    def behavior(name, mode, healthy):
        command = [zig, 'test', '-lc', '-O', mode, '--test-filter', 'EDPSFD', '--dep', 'maru', f'-Mroot={judges}', '--dep', 'maru_terminfo', f'-Mmaru={private / "src/maru.zig"}', f'-Mmaru_terminfo={repo / "terminfo/maru.terminfo"}']
        markers = ['All 20 tests passed.'] + [f'EDPSFD case={n} passed=true ' for n in range(1, 21)] if healthy else ['16 passed; 0 skipped; 4 failed.', 'FAIL (TestExpectedEqual)', 'inherited']
        execute(name, command, healthy, markers)

    for mode in ('Debug', 'ReleaseFast'):
        restore()
        behavior(f'{mode}-normal', mode, True)
        helper.write_text(pristine[helper] + '\n// Equivalent source control.\n')
        behavior(f'{mode}-equivalent', mode, True)
        assert '.CLOEXEC_DEFAULT = true' in pristine[helper]
        helper.write_text(pristine[helper].replace('.CLOEXEC_DEFAULT = true', '.CLOEXEC_DEFAULT = false', 1))
        behavior(f'{mode}-cloexec-defect', mode, False)
        restore()
        behavior(f'{mode}-restored', mode, True)

    gate = [zig, 'test', str(repo / 'tests/boundary/spawn_cloexec_axis.zig'), '--test-runner', str(repo / 'tools/simple_test_runner.zig')]
    execute('gate-normal', gate, True, ['All 6 tests passed.'])
    # These valid Zig declarations model common aliases; the gate must fail on
    # the product source inventory, not on a compiler error in the injected code.
    for name, alias in [('namespace', 'const hidden = std.process;'), ('function', 'const hidden = std.process.spawn;'), ('by-name', 'const hidden = @field(std.process, "spawn");')]:
        restore()
        judges.write_text(pristine[judges] + '\n' + alias + '\n')
        execute(f'gate-{name}-defect', gate, False, ['FAIL (TestUnexpectedResult)', '[spawn cloexec 축]'])
    restore()
    execute('gate-restored', gate, True, ['All 6 tests passed.'])
print(f'PASS {len(results)} normal/equivalent/defect/restored controls: {args.output}')
