#!/usr/bin/env python3
"""Real bundle carrier; isolated provider settings and no user hook execution.

The basic CI case exercises the installed command through real PTY environments.
Installed providers are opt-in and use one read-only, bounded synthetic turn each.
No credentials, model output or user configuration are emitted as test artifacts.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--test', required=True)
p.add_argument('--cli', required=True)
p.add_argument('--claude')
p.add_argument('--codex')
a = p.parse_args()
source_home = Path.home()
cli = Path(a.cli).resolve()
runner = Path(a.test).resolve()
rows = []
with tempfile.TemporaryDirectory(prefix='hook-native-default-') as temporary:
    root = Path(temporary).resolve()
    bundle = root / 'Maru.app' / 'Contents' / 'MacOS'
    bundle.mkdir(parents=True, mode=0o700)
    shutil.copy2(runner, bundle / 'MaruTest')
    for provider in ['basic', 'symlink'] + (['claude'] if a.claude else []) + (['codex'] if a.codex else []):
        binary = bundle / 'maru'
        if binary.exists() or binary.is_symlink():
            binary.unlink()
        if provider == 'symlink':
            binary.symlink_to(cli)
        else:
            shutil.copy2(cli, binary)
        home, project = root / provider / 'home', root / provider / 'project'
        home.mkdir(parents=True, mode=0o700)
        project.mkdir(mode=0o700)
        for directory in [home / '.claude', home / '.codex']:
            directory.mkdir(mode=0o700)
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        env = os.environ.copy()
        env.update(MARU_NATIVE_DEFAULT_CARRIER='1', MARU_NATIVE_DEFAULT_HOME=str(home),
                   MARU_NATIVE_DEFAULT_PROJECT=str(project),
                   MARU_TEST_KEEP_ONLY_PREFIX='app_session.test.native local reader default carrier')
        for key in ['MARU_NATIVE_DEFAULT_ARGV', 'MARU_NATIVE_DEFAULT_ENV', 'MARU_NATIVE_DEFAULT_PROVIDER']:
            env.pop(key, None)
        prompt = 'Execute exactly pwd once, do not read or modify files, then answer OK.'
        if provider == 'claude':
            command = [str(Path(a.claude).resolve()), '--print', '--setting-sources', '',
                       '--settings', str(home / '.claude' / 'settings.json'),
                       '--no-session-persistence', '--allowedTools', 'Bash(pwd)',
                       '--model', 'haiku', '--max-budget-usd', '0.20', prompt]
            # Authentication remains in the installed provider's normal location;
            # settings sources are disabled and only our isolated --settings is read.
            overrides = [f'HOME={source_home}']
        elif provider == 'codex':
            (home / '.codex' / 'config.toml').write_text('[features]\nhooks = true\n')
            auth = source_home / '.codex' / 'auth.json'
            if auth.is_file():
                shutil.copyfile(auth, home / '.codex' / 'auth.json')
                (home / '.codex' / 'auth.json').chmod(0o600)
            command = [str(Path(a.codex).resolve()), 'exec', '--skip-git-repo-check',
                       '--ephemeral', '--sandbox', 'read-only', '-c', 'model_reasoning_effort="low"', prompt]
            overrides = [f'CODEX_HOME={home / ".codex"}']
        if provider in ('claude', 'codex'):
            provider_output = project / 'provider-output'
            command = ['/bin/sh', '-c', shlex.join(command) + ' >' + shlex.quote(str(provider_output)) + ' 2>&1; status=$?; printf \"%s\" \"$status\" > provider-status; exec /bin/cat']
            env['MARU_NATIVE_DEFAULT_ARGV'] = json.dumps(command)
            env['MARU_NATIVE_DEFAULT_ENV'] = json.dumps(overrides)
            env['MARU_NATIVE_DEFAULT_PROVIDER'] = provider
        run = subprocess.run([str(bundle / 'MaruTest'), '--maru-expect-tests=7',
                              '--maru-expect-passed=1'], cwd=project, env=env,
                             capture_output=True, text=True, timeout=180)
        output = run.stdout + run.stderr
        case_ran = 'native local reader default carrier preserves' in output and '...OK' in output
        if run.returncode or not case_ran:
            # The runner contains synthetic paths only; never expose provider output
            # or credential content. Preserve the failure class and assertion sites.
            safe = '\n'.join(line for line in output.splitlines()
                             if 'FAIL (' in line or 'error:' in line or 'expected ' in line or 'app_session.zig:' in line or 'native event kind=' in line or 'native capture ' in line)
            if provider in ('claude', 'codex') and provider_output.exists():
                diagnostic = provider_output.read_text(errors='replace').lower()
                categories = [word for word in ['authentication', 'unauthorized', 'budget', 'rate limit', 'permission', 'not found', 'invalid', 'error'] if word in diagnostic]
                status = (project / 'provider-status').read_text() if (project / 'provider-status').exists() else 'running'
                safe += f'\nprovider status={status} error_categories={categories}'
            raise RuntimeError(f'{provider} carrier failed ({run.returncode}): {safe}')
        install_env = env.copy()
        install_env['HOME'] = str(home)
        install_env.pop('CLAUDE_CONFIG_DIR', None)
        install_env.pop('CODEX_HOME', None)
        for installed_provider in ('claude', 'codex'):
            hook_file = home / ('.claude/settings.json' if installed_provider == 'claude' else '.codex/hooks.json')
            before = json.loads(hook_file.read_text())['hooks']['UserPromptSubmit'][0]['hooks'][0]['command']
            installation = subprocess.run([str(binary), 'agent-hooks', 'install',
                                          '--provider=' + installed_provider, '--scope=remote',
                                          '--dir=' + str(home / '.cache/maru/remote-agent-events')],
                                         env=install_env, capture_output=True, text=True, timeout=5)
            if installation.returncode:
                raise RuntimeError('isolated CLI installation failed')
            after = json.loads(hook_file.read_text())['hooks']['UserPromptSubmit'][0]['hooks'][0]['command']
            if before != after:
                raise RuntimeError('GUI and CLI generated different installed commands')
        version = 'bundled CLI' if provider in ('basic', 'symlink') else subprocess.run(
            [str(Path(getattr(a, provider)).resolve()), '--version'], capture_output=True,
            text=True, check=True, timeout=5).stdout.strip()
        rows.append({'provider': provider, 'version': version, 'default_v2': True,
                     'live_v1_preserved': True, 'reader_generation_confirmed': True, 'gui_cli_command_equal': True,
                     'completed_turn_capture': provider in ('claude', 'codex')})
print(json.dumps(rows, ensure_ascii=False))
