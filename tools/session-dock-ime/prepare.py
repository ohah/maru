"""Attach read-only witnesses and an opt-in NSView/HID driver to a private source copy."""
from pathlib import Path
import subprocess


def require_external_destination(repo, destination):
    if destination.resolve().is_relative_to(repo.resolve()):
        raise RuntimeError('source copies and evidence must be outside the repository')


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError('expected one injection point: ' + old)
    return text.replace(old, new, 1)


def prepare(repo, snapshot):
    require_external_destination(repo, snapshot)
    if snapshot.exists():
        raise RuntimeError('snapshot destination must be new')
    snapshot.mkdir(parents=True)
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out',
                    '--exclude=node_modules', '--exclude=references', '--exclude=.env*',
                    str(repo) + '/', str(snapshot) + '/'], check=True, timeout=120)
    for name in ('node_modules', 'web/node_modules'):
        if (repo / name).exists():
            (snapshot / name).symlink_to(repo / name, target_is_directory=True)
    instrument(repo, snapshot)


def instrument(repo, snapshot):
    fixtures = snapshot / 'src/platform/macos/app_session/debug_fixtures.zig'
    fixtures.write_text(fixtures.read_text() + '\n' + (repo / 'tools/session-dock-ime/probe.zig.inc').read_text())
    session = snapshot / 'src/platform/macos/app_session.zig'
    session.write_text(replace_once(session.read_text(), '        debug_fixtures.maybeDebugOpenNativeEditor(self);',
                       '        debug_fixtures.maybeDebugOpenNativeEditor(self);\n        debug_fixtures.observeSessionDockIME(self);'))
    host = snapshot / 'src/platform/macos/MaruAppHost.swift'
    text = replace_once(host.read_text(), '    private func maybeRunAgentSessionArchiveSmoke() {',
        '    private func maybeRunAgentSessionArchiveSmoke() {\n'
        '        if ProcessInfo.processInfo.environment["MARU_SESSION_DOCK_IME"] != nil {\n'
        '            tickSessionDockIME(); return\n        }')
    text = replace_once(text, '    func insertText(_ string: Any, replacementRange: NSRange) {\n        imeLog(',
        '    func insertText(_ string: Any, replacementRange: NSRange) {\n'
        '        if ProcessInfo.processInfo.environment["MARU_SESSION_DOCK_IME"] != nil { DockIMECallbackWitness.committed += 1 }\n        imeLog(')
    host.write_text(text + '\n' + (repo / 'tools/session-dock-ime/driver.swift.inc').read_text())
