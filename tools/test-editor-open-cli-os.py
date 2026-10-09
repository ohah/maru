#!/usr/bin/env python3
"""Route real CLI argv through OS URL events to an isolated exact app bundle.

The test-only exec interposer adds -a/private HOME to keep existing user apps and
OS default associations intact. Default-handler selection is a separate URL gate.
App/backend receipts, not CLI exit status, establish document/caret identity.
"""
import argparse
import ctypes
import signal
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import time
import uuid
from pathlib import Path
from urllib.parse import quote

INTERPOSER = r'''

    #include <spawn.h>
    #include <sys/wait.h>
    #include <errno.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>

    static int route(const char *path, char *const argv[], char *const envp[]) {
     if(strcmp(path,"/usr/bin/open") || !argv[1] || argv[2]) _exit(95);
     FILE *f=fopen(getenv("CAPTURE"),"wb");if(!f)_exit(96);
     for(size_t i=0;argv[i];i++)fwrite(argv[i],1,strlen(argv[i])+1,f);fclose(f);
     char *next[80];size_t n=0;next[n++]="/usr/bin/open";next[n++]="-a";next[n++]=getenv("APP");
     if(getenv("COLD")) {
     next[n++]="-n";next[n++]="-W";next[n++]="--stdout";next[n++]=getenv("APP_OUT");next[n++]="--stderr";next[n++]=getenv("APP_ERR");
     const char *keys[]={"HOME","CFFIXED_USER_HOME","MARU_CONFIG","XDG_CONFIG_HOME","XDG_CACHE_HOME","XDG_STATE_HOME","MARU_SESSION_HOST_ROOT","MARU_EDITOR_BACKUP_ROOT","MARU_MACOS_APP_SMOKE_MS","MARU_EDITOR_RECOVERY_CHECKPOINT_TEST","MARU_NO_WORKSPACE_RESTORE","MARU_EDITOR_APP_URL_RECEIPTS",NULL};
     static char vals[16][4096];for(int i=0;keys[i];i++){snprintf(vals[i],4096,"%s=%s",keys[i],getenv(keys[i]));next[n++]="--env";next[n++]=vals[i];}
     }
     next[n++]=argv[1];next[n++]=NULL;
     pid_t pid; if(posix_spawn(&pid,path,NULL,NULL,next,envp)) _exit(96);
     int status;while(waitpid(pid,&status,0)<0){if(errno!=EINTR)_exit(97);}
     _exit(WIFEXITED(status)?WEXITSTATUS(status):98);
    }
    __attribute__((used)) static struct {const void *replacement;const void *original;} interpose __attribute__((section("__DATA,__interpose")))={route,execve};

'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    if any(root.iterdir()):
        parser.error('output must be empty; prefer a folder under ~/.cache for GUI access')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app.resolve())], check=True, capture_output=True, timeout=15)
    def default_handler():
        source = 'import AppKit; print(NSWorkspace.shared.urlForApplication(toOpen: URL(string: "maru://open?path=%2Ftmp%2Fx")!)?.path ?? "none")'
        return subprocess.check_output(['swift', '-e', source], text=True, timeout=15).strip()

    original_handler = default_handler()
    app = root / 'Maru.app'
    shutil.copytree(args.app.resolve(), app, symlinks=True)
    info = app / 'Contents/Info.plist'
    fields = plistlib.loads(info.read_bytes())
    fields['CFBundleIdentifier'] = 'dev.maru.cli-open-fixture.' + uuid.uuid4().hex
    info.write_bytes(plistlib.dumps(fields))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, capture_output=True, timeout=15)
    # Stage byte-identical CLI outside Documents for GUI launchd access.
    cli = root / 'maru'
    shutil.copy2(args.cli.resolve(), cli)
    assert cli.read_bytes() == args.cli.resolve().read_bytes()
    for n in ['home', 'cache', 'state', 'backups', 'host']:
        (root / n).mkdir(mode=448, exist_ok=True)
    (root / 'config').write_text('session.keep-alive-after-quit = false\nworkspace.restore = false\n')
    file = root / '한 +%2F& file.txt'
    file.write_bytes('A😀B\r\n한\n'.encode())
    source = INTERPOSER
    (root / 'route.c').write_text(source)
    subprocess.run(['/usr/bin/clang', '-dynamiclib', str(root / 'route.c'), '-o', str(root / 'route.dylib')], check=True)
    base = dict(HOME=str(root / 'home'), CFFIXED_USER_HOME=str(root / 'home'), MARU_CONFIG=str(root / 'config'), XDG_CONFIG_HOME=str(root / 'home/.config'), XDG_CACHE_HOME=str(root / 'cache'), XDG_STATE_HOME=str(root / 'state'), MARU_SESSION_HOST_ROOT=str(root / 'host'), MARU_EDITOR_BACKUP_ROOT=str(root / 'backups'), MARU_MACOS_APP_SMOKE_MS='15000', MARU_EDITOR_RECOVERY_CHECKPOINT_TEST='maru-test-only-v1', MARU_NO_WORKSPACE_RESTORE='1', MARU_EDITOR_APP_URL_RECEIPTS='1', DYLD_INSERT_LIBRARIES=str(root / 'route.dylib'), APP=str(app), APP_OUT=str(root / 'app.stdout'), APP_ERR=str(root / 'app.stderr'))
    pattern = re.compile('\\[EDITOR_URL\\] id=(\\d+) surface=(\\d+) byte=(\\d+) path_sha256=([0-9a-f]{64})')

    def rows():
        return pattern.findall((root / 'app.stderr').read_text(errors='replace')) if (root / 'app.stderr').exists() else []

    def waitrows(n):
        end = time.monotonic() + 15
        while time.monotonic() < end:
            r = rows()
            if len(r) >= n:
                return r
            time.sleep(0.05)
        raise RuntimeError(('missing receipt', n))

    def stop_fixture():
        # Stop only a fresh PID whose executable is this unique private fixture.
        # The test does not verify the product quit-confirmation interaction.
        log = root / 'app.stderr'
        if not log.exists():
            return
        match = re.search('maru build:.*pid=(\\d+)', log.read_text(errors='replace'))
        if not match:
            return
        pid = int(match.group(1))
        lib = ctypes.CDLL('/usr/lib/libproc.dylib')
        lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        buffer = ctypes.create_string_buffer(4096)
        if lib.proc_pidpath(pid, buffer, len(buffer)) > 0 and os.fsdecode(buffer.value) == str(app / 'Contents/MacOS/maru-macos-app'):
            os.kill(pid, signal.SIGKILL)
    jobs = []

    def start(name, args, cold=False):
        label = 'dev.maru.test.cli.' + uuid.uuid4().hex
        domain = f'gui/{os.getuid()}/{label}'
        env = dict(base, CAPTURE=str(root / (name + '.argv')))
        if cold:
            env['COLD'] = '1'
        p = root / (name + '.plist')
        p.write_bytes(plistlib.dumps(dict(Label=label, ProgramArguments=[str(cli), 'editor', 'open', *args], EnvironmentVariables=env, RunAtLoad=True, KeepAlive=False, ProcessType='Interactive', WorkingDirectory=str(root), StandardOutPath=str(root / (name + '.stdout')), StandardErrorPath=str(root / (name + '.stderr')))))
        subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(p)], check=True, capture_output=True, timeout=15)
        jobs.append(domain)
        return domain
    try:
        cold = start('cold', ['-l', '2', '-c', '2', '--', file.name], True)
        waitrows(1)
        start('warm', [str(file), '--line', '1', '--column', '3'])
        waitrows(2)
        start('file-only', [str(file)])
        r = waitrows(3)
        assert [int(x[2]) for x in r] == [11, 5, 5], r
        assert len({x[1] for x in r}) == 1
        assert all((x[3] == hashlib.sha256(str(file).encode()).hexdigest() for x in r))
        expected = 'maru://open?path=' + quote(str(file), safe='~')
        for (name, suffix) in [('cold', '&line=2&column=2'), ('warm', '&line=1&column=3'), ('file-only', '')]:
            assert (root / (name + '.argv')).read_bytes().split(b'\x00')[:-1] == [b'/usr/bin/open', (expected + suffix).encode()]
        stop_fixture()
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            status = subprocess.run(['launchctl', 'print', cold], capture_output=True, text=True, timeout=10).stdout
            if 'last exit code = 0' in status:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('owned OS delivery waiter did not finish')
        assert default_handler() == original_handler
        result = dict(passed=True, scope='real CLI argv routed by test-only interposer to isolated exact-bundle OS event; default handler choice separate', byte_offsets=[11, 5, 5], same_surface=True, cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(), app_sha256=hashlib.sha256((app / 'Contents/MacOS/maru-macos-app').read_bytes()).hexdigest())
        (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(root / 'result.json', flush=True)
    finally:
        stop_fixture()
        for job in jobs:
            subprocess.run(['launchctl', 'bootout', job], capture_output=True, timeout=15)
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(app)], capture_output=True, timeout=15)
if __name__ == '__main__':
    main()
