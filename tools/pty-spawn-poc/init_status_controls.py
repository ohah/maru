#!/usr/bin/env python3
"""Compiled behavioral mutations of the independent initialization experiment."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
from init_status import cases, execute, require


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if platform.system() != 'Darwin': p.error('Darwin only')
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()): p.error('Output must be new or empty')
    out.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).with_name('init_status.c')
    original = source.read_text()
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    # Each negative changes a different causal guarantee. Compilation alone is
    # insufficient: only the independent behavioral verifier's rejection counts.
    mutations = [
        ('eof-is-ready', '        if(eof && ready)outcome=',
         '        if(eof && !wire_used){outcome="target-ready";break;}\n        if(eof && ready)outcome=', 'early-zero'),
        ('leak-status-fd', 'fcntl(4,F_SETFD,FD_CLOEXEC)', 'fcntl(4,F_SETFD,0)', 'baseline'),
        ('leak-request-fd', '    close(3);', '    /* retain request FD across target exec */', 'baseline'),
        ('accept-unknown-version', 'wire[4]!=1 ||', '0 ||', 'wire-version'),
        ('erase-native-errno', 'frame(b,stage,error);', 'frame(b,stage,error?EINVAL:0);', 'exec-missing'),
        ('restart-deadline', 'if(now_ms()>=deadline){outcome="timeout";goto done;}',
         'deadline=now_ms()+budget;', 'prep-deadline'),
    ]
    variants = [('original', original, None)]
    for name, old, new, case in mutations:
        require(original.count(old) == 1, 'mutation anchor drift: ' + name)
        variants.append((name, original.replace(old, new), case))
    old = '    if(write_all(request[1],req,n)<0){native_error=errno;outcome="request-write-error";goto done;}'
    require(original.count(old) == 1, 'fragment control anchor drift')
    equivalent = '    for(size_t part=0;part<n;part++){if(write_all(request[1],req+part,1)<0){native_error=errno;outcome="request-write-error";goto done;}pause_ms(1);}'
    variants.append(('fragmented-request', original.replace(old, equivalent), None))
    summary = []
    for name, text, focus in variants:
        root = out / name; root.mkdir()
        src = root / 'init_status.c'; src.write_text(text)
        exe = root / 'probe'
        build = subprocess.run(['cc', '-O0', '-Wall', '-Wextra', '-Werror', str(src), '-o', str(exe)], capture_output=True, text=True)
        (root / 'build.log').write_text(build.stdout + build.stderr)
        require(build.returncode == 0, name + ': compilation failure does not count as rejection')
        selected = [s for s in cases() if focus is None or s[0] == focus]
        observed_error = None
        try:
            execute(exe, root, selected)
        except ValueError as exc:
            observed_error = str(exc)
        require((observed_error is not None) == (focus is not None), name + ': unexpected acceptance/rejection')
        require((root / 'progress.json').exists(), name + ': behavioral record absent')
        summary.append({'control': name, 'expected_pass': focus is None, 'passed': observed_error is None,
                        'behavioral_rejection': observed_error, 'case_count': len(selected)})
        (out / 'progress.json').write_text(json.dumps(summary, indent=2) + '\n')
    require(hashlib.sha256(source.read_bytes()).hexdigest() == before, 'original source changed')
    (out / 'results.json').write_text(json.dumps({'source_sha256': before, 'controls': summary}, indent=2) + '\n')
    print('6 compiled behavioral mutations rejected; original and fragmented-request controls passed')


if __name__ == '__main__':
    main()
