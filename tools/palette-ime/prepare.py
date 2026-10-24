"""Instrument an external source copy without changing distributed input authority."""
from pathlib import Path
import subprocess


def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError('expected one instrumentation point: ' + old)
    return text.replace(old, new, 1)


def prepare(repo, snapshot):
    if snapshot.exists() or snapshot.resolve().is_relative_to(repo.resolve()):
        raise RuntimeError('a new external snapshot is required')
    snapshot.mkdir(parents=True)
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out',
                    '--exclude=node_modules', '--exclude=references', '--exclude=.env*',
                    str(repo) + '/', str(snapshot) + '/'], check=True, timeout=120)
    for name in ('node_modules', 'web/node_modules'):
        if (repo / name).exists():
            (snapshot / name).symlink_to(repo / name, target_is_directory=True)
    fixtures = snapshot / 'src/platform/macos/app_session/debug_fixtures.zig'
    fixtures.write_text(fixtures.read_text() + '\n' + (repo / 'tools/palette-ime/probe.zig.inc').read_text())
    session = snapshot / 'src/platform/macos/app_session.zig'
    session.write_text(once(session.read_text(), '        debug_fixtures.maybeDebugOpenNativeEditor(self);',
                           '        debug_fixtures.maybeDebugOpenNativeEditor(self);\n        debug_fixtures.observePaletteIME(self);'))
    host = snapshot / 'src/platform/macos/MaruAppHost.swift'
    text = once(host.read_text(), '    private func maybeRunAgentSessionArchiveSmoke() {',
                '    private func maybeRunAgentSessionArchiveSmoke() {\n'
                '        if ProcessInfo.processInfo.environment["MARU_PALETTE_IME"] != nil { tickPaletteIME(); return }')
    text = once(text, '    func insertText(_ string: Any, replacementRange: NSRange) {\n        imeLog(',
                '    func insertText(_ string: Any, replacementRange: NSRange) {\n'
                '        if ProcessInfo.processInfo.environment["MARU_PALETTE_IME"] != nil { PaletteIMEWitness.committed += 1 }\n        imeLog(')
    host.write_text(text + '\n' + (repo / 'tools/palette-ime/driver.swift.inc').read_text())
