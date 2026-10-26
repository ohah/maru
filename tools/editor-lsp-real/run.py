#!/usr/bin/env python3
"""Opt-in real SDK regression through Maru's AppSession, never a mock client."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import time
import uuid

from oracle import InvalidEvidence, PROFILES, verify_directory

REPO = Path(__file__).resolve().parents[2]
PROXY = REPO / 'tools/editor-theme-gallery/lsp_proxy.py'

SAMPLES = {
    'rust': ('main.rs', 'probe_add', 'probe_result', '''fn probe_add(value: i32) -> i32 { value + 1 }
fn main() {
    /* 한글😀 */ let probe_result = probe_add(41);
    /* 한글😀 */ let _ = probe_result;
}
'''),
    'go': ('main.go', 'probeAdd', 'probeResult', '''package main
func probeAdd(value int) int { return value + 1 }
func main() {
    /* 한글😀 */ probeResult := probeAdd(41)
    /* 한글😀 */ _ = probeResult
}
'''),
    'kotlin': ('main.kt', 'probeAdd', 'probeResult', '''fun probeAdd(value: Int): Int = value + 1
fun main() {
    /* 한글😀 */ val probeResult = probeAdd(41)
    /* 한글😀 */ val copy = probeResult
}
'''),
    'dart': ('main.dart', 'probeAdd', 'probeResult', '''int probeAdd(int value) => value + 1;
void main() {
    /* 한글😀 */ final probeResult = probeAdd(41);
    /* 한글😀 */ final copy = probeResult;
}
'''),
    'scala': ('main.scala', 'probeAdd', 'probeResult', '''object Probe {
  def probeAdd(value: Int): Int = value + 1
  def main(args: Array[String]): Unit = {
    /* 한글😀 */ val probeResult = probeAdd(41)
    /* 한글😀 */ val copy = probeResult
  }
}
'''),
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fixture(root, language):
    filename, symbol, name, text = SAMPLES[language]
    root.mkdir(mode=0o700)
    nonce = uuid.uuid4().hex
    (root / '.maru-real-lsp-case').write_text(nonce)
    (root / filename).write_text(text)
    subprocess.run(['/usr/bin/git', 'init', '-q', str(root)], check=True, timeout=15,
                   env={k: v for k, v in os.environ.items() if not k.startswith('GIT_')})
    metadata = {
        'rust': ('Cargo.toml', '[package]\nname="maru_lsp_probe"\nversion="0.1.0"\nedition="2021"\n[[bin]]\nname="probe"\npath="main.rs"\n'),
        'go': ('go.mod', 'module example.invalid/maru-lsp-probe\n\ngo 1.24\n'),
        'dart': ('pubspec.yaml', 'name: maru_lsp_probe\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n'),
    }.get(language)
    if metadata:
        (root / metadata[0]).write_text(metadata[1])
    raw = text.encode('utf-8')
    first = raw.index(symbol.encode())
    cfg = dict(nonce=nonce, root=str(root), path=str(root / filename),
               report_path=str(root / 'product.json'), good=text, symbol=symbol,
               completion_name=name, hover_offset=raw.rindex(symbol.encode()) + 2,
               definition_line=raw[:first].count(b'\n'), literal_offset=raw.index(b'41'),
               completion_offset=raw.rindex(name.encode()))
    (root / 'case.json').write_text(json.dumps(cfg, ensure_ascii=False, indent=2))
    return cfg


def stop_owned_proxy_groups(root):
    """Never signal a group unless its live leader still names this exact case."""
    path = root / 'protocol.ndjson'
    if not path.exists():
        return []
    groups = set()
    for line in path.read_text().splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        group = event.get('pgid')
        if event.get('event') == 'spawn' and type(group) is int and group > 1 and group == event.get('proxy_pid'):
            groups.add(group)
    actions = []
    for group in groups:
        if group == os.getpgrp():
            raise RuntimeError('refusing to signal the runner process group')
        try:
            if os.getpgid(group) != group:
                continue
        except ProcessLookupError:
            continue
        command = subprocess.run(['/bin/ps', '-p', str(group), '-o', 'command='], capture_output=True, text=True, timeout=3)
        if command.returncode or str(PROXY) not in command.stdout or str(root / 'proxy.json') not in command.stdout:
            raise RuntimeError('proxy process ownership no longer matches this fixture')
        os.killpg(group, signal.SIGTERM)
        actions.append(group)
    return actions


def run_case(args, language, spec):
    root = args.output / ('case-' + language)
    if getattr(args, 'scenario', 'single-file') == 'format-save':
        from format_save_fixture import fixture as format_save_fixture
        cfg = format_save_fixture(root, language)
    elif getattr(args, 'scenario', 'single-file') == 'rename':
        from rename_fixture import fixture as rename_fixture
        cfg = rename_fixture(root, language)
    elif getattr(args, 'scenario', 'single-file') == 'multi-file':
        from multi_fixture import fixture as multi_fixture
        cfg = multi_fixture(root, language)
    else:
        cfg = fixture(root, language)
    cfg['timeout_ms'] = args.phase_timeout * 1000
    (root / 'case.json').write_text(json.dumps(cfg, ensure_ascii=False, indent=2))
    server_env = {k: v for k, v in os.environ.items()
                  if k in ('HOME', 'PATH', 'LANG', 'TMPDIR', 'CARGO_HOME', 'RUSTUP_HOME', 'GOPATH', 'GOROOT', 'JAVA_HOME')}
    server_env.update(spec.get('environment', {}))
    if language == 'scala' and spec.get('scala_cli'):
        setup = [spec['java'], '-jar', spec['scala_cli'], 'setup-ide', 'main.scala',
                 '--scala', spec.get('scala_version', '3.3.7'), '--jvm', 'system']
        with (root / 'setup.log').open('wb') as log:
            subprocess.run(setup, cwd=root, env=server_env, stdout=log, stderr=log,
                           check=True, timeout=args.phase_timeout)
    proxy_cfg = dict(root=str(root), argv=spec['argv'], server_environment=server_env,
                     wire=True, wire_limit_bytes=16 * 1024 * 1024, inherit_process_group=True)
    (root / 'proxy.json').write_text(json.dumps(proxy_cfg, indent=2))
    wrapper = root / 'server-proxy'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.join([sys.executable, str(PROXY), str(root / 'proxy.json')]) + '\n')
    wrapper.chmod(0o700)
    (root / 'config').write_text('lsp.enabled = true\nlsp.shell-environment = false\nlsp.repository-environment = false\nsidebar.agent-hooks = false\nworkspace.restore = false\nsession.keep-alive-after-quit = false\n')
    # HOME is deliberately absent from Maru. The explicitly configured SDK child
    # receives its own selected environment, never the caller's arbitrary tokens.
    env = {k: os.environ[k] for k in ('PATH', 'TMPDIR', 'LANG') if k in os.environ}
    env.update(MARU_REAL_LSP_CASE=str(root / 'case.json'), MARU_CONFIG=str(root / 'config'),
               MARU_LSP_SERVER_OVERRIDE=str(wrapper), MARU_SESSION_HOST_ROOT=str(root / 'host'),
               MARU_EDITOR_BACKUP_ROOT=str(root / 'backups'),
               XDG_CONFIG_HOME=str(root / 'profile/config'), XDG_CACHE_HOME=str(root / 'profile/cache'),
               XDG_STATE_HOME=str(root / 'profile/state'), CFFIXED_USER_HOME=str(root / 'profile'))
    started = time.monotonic()
    with (root / 'judge.log').open('wb') as log:
        child = subprocess.Popen([str(args.judge), '--maru-expect-tests=5', '--maru-expect-passed=5'],
                                 cwd=REPO, env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            try:
                # Multi-file adds peer registration and two explicit sync
                # barriers. Its valid phase budgets must fit inside the owner.
                phases = {'single-file': 7, 'multi-file': 10, 'rename': 16, 'format-save': 16}[getattr(args, 'scenario', 'single-file')]
                code = child.wait(timeout=args.phase_timeout * phases + 30)
            except subprocess.TimeoutExpired:
                code = -1
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
            cleanup = stop_owned_proxy_groups(root)
    entrypoint = Path(shutil.which(spec['argv'][0], path=server_env.get('PATH')) or spec['argv'][0]).resolve()
    result = dict(entrypoint=str(entrypoint), entrypoint_sha256=sha(entrypoint), language=language, exit_code=code, seconds=round(time.monotonic() - started, 3),
                  fixture_sha256=sha(root / 'case.json'), argv=spec['argv'], terminated_owned_proxy_groups=cleanup)
    if (root / 'product.json').exists():
        result['product'] = json.loads((root / 'product.json').read_text())
    else:
        result['failure'] = 'product report missing'
    if code == 0 and 'product' in result:
        try:
            if result['product'].get('build_mode') != PROFILES[args.optimize]:
                raise InvalidEvidence('judge optimization mode does not match requested profile')
            result['validation'] = verify_directory(root, code)
            if language == 'rust' and getattr(args, 'scenario', 'single-file') not in ('rename', 'format-save') and result['validation'].get('diagnostic_transport') != 'pull':
                raise InvalidEvidence('Rust diagnostics were not obtained through pull')
        except (InvalidEvidence, OSError, ValueError, KeyError, TypeError) as exc:
            result['failure'] = 'wire/native oracle: ' + str(exc)
    result['artifacts'] = {p.name: sha(p) for p in root.iterdir() if p.is_file() and p.name in ('case.json', 'product.json', 'wire.ndjson', 'protocol.ndjson', 'judge.log', 'server.stderr')}
    (root / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--servers-json', type=Path, required=True)
    parser.add_argument('--languages', nargs='+', choices=SAMPLES)
    parser.add_argument('--scenario', choices=['single-file', 'multi-file', 'rename', 'format-save'], default='single-file')
    parser.add_argument('--judge', type=Path)
    parser.add_argument('--phase-timeout', type=int, default=90)
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--optimize', choices=['Debug', 'ReleaseFast'], default='Debug')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('the product judge requires macOS; pure oracle tests are portable')
    if args.scenario in ('multi-file', 'rename', 'format-save') and args.languages and not set(args.languages) <= {'rust', 'go'}:
        parser.error(args.scenario + ' supports Rust and Go only')
    args.languages = args.languages or (['rust', 'go'] if args.scenario != 'single-file' else list(SAMPLES))
    judge_names = {'single-file': 'maru-real-lsp-test', 'multi-file': 'maru-real-lsp-multi-test', 'rename': 'maru-real-lsp-rename-test', 'format-save': 'maru-real-lsp-format-save-test'}
    args.judge = args.judge or REPO / 'zig-out/bin' / judge_names[args.scenario]
    args.output = args.output.resolve()
    args.judge = args.judge.resolve()
    if args.output == REPO or REPO in args.output.parents or args.output.exists():
        parser.error('output must be a new directory outside the checkout; use durable artifact storage')
    if not 1 <= args.phase_timeout <= 180:
        parser.error('phase timeout must be between 1 and 180 seconds')
    specs = json.loads(args.servers_json.read_text())
    if args.build:
        subprocess.run(['mise', 'exec', '--', 'zig', 'build', {'single-file': 'editor-real-lsp-judge', 'multi-file': 'editor-real-lsp-multi-judge', 'rename': 'editor-real-lsp-rename-judge', 'format-save': 'editor-real-lsp-format-save-judge'}[args.scenario], '-Doptimize=' + args.optimize, '-j2'], cwd=REPO, check=True)
    args.output.mkdir(parents=True, mode=0o700)
    frozen_judge = args.output / 'judge'
    shutil.copyfile(args.judge, frozen_judge)
    frozen_judge.chmod(0o700)
    args.judge = frozen_judge
    sources = args.output / 'sources'
    sources.mkdir()
    controller_names = ('real_lsp_judge.zig', 'mod.zig', 'lsp.zig', 'completion.zig', 'hover.zig', 'definition.zig', 'semantic.zig')
    if args.scenario == 'multi-file':
        controller_names += ('real_lsp_multi_judge.zig',)
    if args.scenario == 'rename':
        controller_names += ('rename.zig', 'workspace_edit.zig')
        (sources / 'rename_judge.zig').write_bytes((REPO / 'src/platform/macos/app_session/editor/real_lsp/rename.zig').read_bytes())
    if args.scenario == 'format-save':
        controller_names += ('format.zig', 'local_save.zig')
        for name, source in [('format_save_judge.zig', 'real_lsp/format_save.zig'), ('save_dispatch.zig', 'save/dispatch.zig')]:
            (sources / name).write_bytes((REPO / 'src/platform/macos/app_session/editor' / source).read_bytes())
    for name in controller_names:
        (sources / name).write_bytes((REPO / 'src/platform/macos/app_session/editor' / name).read_bytes())
    tool_sources = args.output / 'tool-sources'
    tool_sources.mkdir()
    tool_names = ('run.py', 'oracle.py', 'verify.py')
    if args.scenario == 'multi-file':
        tool_names += ('multi_fixture.py', 'multi_oracle.py')
    if args.scenario == 'rename':
        tool_names += ('rename_fixture.py', 'rename_oracle.py')
    if args.scenario == 'format-save':
        tool_names += ('format_save_fixture.py', 'format_save_oracle.py')
    for name in tool_names:
        (tool_sources / name).write_bytes((Path(__file__).parent / name).read_bytes())
    (tool_sources / 'lsp_proxy.py').write_bytes(PROXY.read_bytes())
    report = dict(schema='maru.lsp-real.run.v1', scenario=args.scenario, optimize=args.optimize, source_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
                  judge_sha256=sha(args.judge), dirty_tree=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=REPO)), tool_sources={p.name: sha(p) for p in tool_sources.iterdir()}, controller_sources={p.name: sha(p) for p in sources.iterdir()}, scope='headless product AppSession; real SDKs; no physical GUI/IME claim', languages=[])
    for language in args.languages:
        try:
            result = run_case(args, language, specs[language])
        except Exception as exc:
            result = dict(language=language, exit_code=-2, failure=type(exc).__name__ + ': ' + str(exc))
        report['languages'].append(result)
        (args.output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(language, result['exit_code'], result.get('failure') or result.get('product', {}).get('failure') or result.get('product', {}).get('stage'), flush=True)
    return int(any(r['exit_code'] != 0 or r.get('failure') or r.get('product', {}).get('failure') for r in report['languages']))


if __name__ == '__main__':
    raise SystemExit(main())
