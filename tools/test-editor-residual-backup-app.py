"""Actual AppKit save/exit/relaunch with denied backup deletion; isolated user data."""
from pathlib import Path
import hashlib, json, os, signal, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix='maru-residual-app-', dir='/tmp')).resolve()
home = work / 'home'
home.mkdir()
backups = work / 'backups'
backups.mkdir(mode=0o700)
config = work / 'config'
config.write_text('session.keep-alive-after-quit = false\n')
document = work / 'document.txt'
document.write_bytes(b'original-from-open\n')
base = {k: v for k, v in os.environ.items() if not k.startswith('MARU_')}
base.update(HOME=str(home), CFFIXED_USER_HOME=str(home),
    MARU_CONFIG=str(config), XDG_CONFIG_HOME=str(home / '.config'),
    XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
    MARU_SESSION_HOST_ROOT=str(work / 'host'), MARU_EDITOR_BACKUP_ROOT=str(backups),
    MARU_NATIVE_EDITOR=str(document), MARU_EDITOR_SAVE_CONFLICT_DOCUMENT=str(document),
    MARU_EDITOR_RECOVERY_CHECKPOINT_TEST='maru-test-only-v1', MARU_MACOS_APP_SMOKE_MS='15000', MARU_EDITOR_SAVE_CONFLICT_SMOKE='1')
results = []

def run(scenario):
    summary = work / (scenario + '.summary')
    env = dict(base, MARU_EDITOR_SAVE_CONFLICT_SMOKE_SCENARIO=scenario,
        MARU_APP_SUMMARY_PATH=str(summary))
    if scenario != 'quit-backup':
        env.pop('MARU_NATIVE_EDITOR', None)
    with (work / (scenario + '.log')).open('wb') as log:
        child = subprocess.Popen([str(root / 'zig-out/Maru.app/Contents/MacOS/maru-macos-app')],
            env=env, cwd=root, stdout=log, stderr=log, start_new_session=True)
        try:
            code = child.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            raise
    text = summary.read_text()
    assert code == 0, (scenario, code, str(work))
    assert 'editor_save_conflict_smoke_stage=done\n' in text, (scenario, text)
    assert 'editor_save_conflict_smoke_failure=\n' in text, (scenario, text)
    results.append(dict(scenario=scenario, pid=child.pid, exit_code=code, stage='done'))

try:
    original = document.read_bytes()
    run('quit-backup')
    records = list(backups.glob('*.bak'))
    assert len(records) == 1, records
    record = records[0]
    older_record = record.read_bytes()
    older_body = older_record.split(b'\n\n', 1)[1]
    assert older_body != original and document.read_bytes() == original
    backups.chmod(0o500)
    run('residual-save')
    latest_disk = document.read_bytes()
    assert latest_disk != original and latest_disk != older_body
    assert record.read_bytes() == older_record, 'deletion failure did not retain older record'
    backups.chmod(0o700)
    run('restore-backup')
    assert document.read_bytes() == latest_disk, 'relaunch changed latest saved file'
    assert record.read_bytes().split(b'\n\n', 1)[1] == older_body
    report = dict(artifact_root=str(work), processes=results,
        app_sha256=hashlib.sha256((root / 'zig-out/Maru.app/Contents/MacOS/maru-macos-app').read_bytes()).hexdigest(),
        latest_disk_sha256=hashlib.sha256(latest_disk).hexdigest(),
        older_body_sha256=hashlib.sha256(older_body).hexdigest(),
        save_newer_succeeded=True, older_backup_retained=True,
        relaunch_dirty_without_typing=True, latest_disk_preserved=True,
        scope='actual AppKit processes; native editor open hook, smoke keys, normal quit; workspace v2 restore selects the persisted recovery ID')
    (work / 'result.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
finally:
    backups.chmod(0o700)
