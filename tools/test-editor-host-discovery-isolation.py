#!/usr/bin/env python3
"""언어 서버가 설치된 호스트의 입력·탐색 격리를 정상/결함 주입/원복으로 검증한다."""
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import subprocess
import tempfile


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Expected one mutation anchor')
    return text.replace(old, new, 1)


def mutate_test(text, prefix, old, new):
    start = text.index('test "' + prefix)
    end = text.find('\ntest ', start + 6)
    if end < 0:
        end = len(text)
    return text[:start] + replace_once(text[start:end], old, new) + text[end:]


def target_failed(output, prefix):
    headers = list(re.finditer(r'^\d+/15 (.+?)\.\.\.', output, re.MULTILINE))
    for i, match in enumerate(headers):
        if '.test.' + prefix not in match.group(1):
            continue
        end = headers[i + 1].start() if i + 1 < len(headers) else len(output)
        return re.search(r'FAIL \((TestUnexpectedResult|TestExpectedEqual)\)', output[match.start():end]) is not None
    return False


def main():
    if platform.system() != 'Darwin':
        raise SystemExit('macOS is required')
    repo = Path(__file__).resolve().parents[1]
    root = Path(tempfile.mkdtemp(prefix='maru-discovery-isolation-'))
    source = root / 'source'
    print(root, flush=True)
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', str(repo) + '/', str(source) + '/'], check=True, timeout=120)
    # .git 없는 사본은 저장소 밖 문서가 되어 신뢰 시트 자체가 생기지 않는다.
    # 사용자 저장소 대신 이 사본만의 빈 저장소를 만들어 같은 신뢰 경계를 통과한다.
    subprocess.run(['git', 'init', '--quiet', str(source)], check=True, timeout=30)
    relative = 'src/platform/macos/app_session/editor/mod.zig'
    path = source / relative
    original = path.read_text()
    locator = source / "src/platform/macos/lsp_process.zig"
    original_locator = locator.read_text()
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    before = digest(repo / relative)
    # 발견만으로 신뢰 확인창이 생긴다. 허용 전에는 이 실행 파일을 실행하면 안 된다.
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    fake = bin_dir / 'zls'
    fake.write_text('#!/bin/sh\nprintf executed > "' + str(root / 'unexpected-server') + '"\nexit 86\n')
    fake.chmod(0o700)
    env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ.get('PATH', ''))
    env.pop('MARU_LSP_SERVER_OVERRIDE', None)
    cases = [(name, name, '    fx.session.loaded_config.config.lsp.enabled = false;', '    fx.session.loaded_config.config.lsp.enabled = true;') for name in [
        'COL7 ', 'AC3 ', 'BR6 ', 'shared editor view find adversarial R1 ',
        'shared editor view find adversarial R6 replacement ',
        'shared editor view find adversarial R7 ', 'LATE3 ',
    ]]
    cases += [
        ('ambient-server', 'LSPE2 ', 'EnvGuard.set("MARU_LSP_SERVER_OVERRIDE", "")', 'EnvGuard.set("MARU_LSP_SERVER_OVERRIDE", null)'),
        ('ignore-path-only', 'host discovery fixture ', 'it.fallback_pos = git_locate.fallback_dirs.len;', 'it.fallback_pos = 0;'),
        ('lost-restore', 'LSPE19 ', '    defer _ = lsp_process.setFallbackSearchForTest(fallback);', '    _ = fallback;'),
    ]
    rows = []
    try:
        for name, prefix, old, new in [('control', None, None, None)] + cases + [('restored-control', None, None, None)]:
            path.write_text(original)
            locator.write_text(original_locator)
            if name == 'ignore-path-only':
                locator.write_text(replace_once(original_locator, old, new))
            elif prefix is not None:
                path.write_text(mutate_test(original, prefix, old, new))
            run = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-host-discovery-isolation', '-j2'], cwd=source, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)
            label = re.sub(r'[^a-zA-Z0-9_-]+', '-', name).strip('-')
            (root / (label + '.log')).write_text(run.stdout)
            expected = 'host discovery fixture ' if name == 'lost-restore' else prefix
            verified = (run.returncode == 0 and 'All 15 tests passed.' in run.stdout) if prefix is None else (run.returncode == 1 and target_failed(run.stdout, expected))
            if (root / 'unexpected-server').exists():
                raise RuntimeError('A host server executed before trust')
            rows.append(dict(case=name, target=expected, mutation=prefix is not None, exit=run.returncode, verified=verified))
            (root / 'results.json').write_text(json.dumps(rows, indent=2))
            print(label + ': ' + str(verified), flush=True)
            if not verified:
                raise RuntimeError(run.stdout[-3000:])
    finally:
        path.write_text(original)
        locator.write_text(original_locator)
        if locator.read_text() != original_locator:
            raise RuntimeError("Locator restoration failed")
        if digest(repo / relative) != before or digest(path) != before:
            raise RuntimeError('Source restoration or original source integrity failed')
    (root / 'provenance.json').write_text(json.dumps(dict(head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(), editor_sha256=before, mutations=len(cases), controls=2, fixture_server_executed=False), indent=2))
    print(root / 'results.json', flush=True)


if __name__ == '__main__':
    main()
