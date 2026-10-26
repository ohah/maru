#!/usr/bin/env python3
"""독립 수명 모델의 코드 해시와 실제 테스트 출력을 보존한다."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
args = p.parse_args()
out = args.output.resolve()
if out.exists() or out == ROOT or ROOT in out.parents:
    p.error('new external output required')
out.mkdir(parents=True)
files = {}
for name in ('model.py', 'test_model.py', 'run.py'):
    source = Path(__file__).with_name(name)
    (out / name).write_bytes(source.read_bytes())
    files[name] = hashlib.sha256(source.read_bytes()).hexdigest()
command = [sys.executable, '-m', 'unittest', 'discover', '-s', str(out), '-p', 'test_*.py', '-v']
completed = subprocess.run(command, cwd=out, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(out / 'tests.log').write_text(completed.stdout)
if completed.returncode or 'Ran 9 tests' not in completed.stdout or '\nOK\n' not in completed.stdout:
    raise RuntimeError('model verification failed; preserved tests.log')
(out / 'manifest.json').write_text(json.dumps({
    'scope': 'independent single-document ownership model; no product worker or C parser',
    'base_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'python': platform.python_version(), 'command': command, 'sha256': files,
    'tests_log_sha256': hashlib.sha256((out / 'tests.log').read_bytes()).hexdigest(),
    'test_methods': 9, 'ordered_schedules': 72, 'semantic_faults_rejected': 5,
}, indent=2) + '\n')
print(completed.stdout)
