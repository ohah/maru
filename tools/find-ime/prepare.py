"""Reuse the palette source-copy preparation, replacing only its private witnesses."""
import importlib.util
from pathlib import Path


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare(repo, snapshot):
    common = repo / 'tools/palette-ime'
    load('palette_prepare', common / 'prepare.py').prepare(repo, snapshot)
    # The ordinary product text/input code remains untouched by instrumentation.
    for relative, template, replacement in (
        ('src/platform/macos/app_session/debug_fixtures.zig', 'probe.zig.inc', 'probe.zig.inc'),
        ('src/platform/macos/MaruAppHost.swift', 'driver.swift.inc', 'driver.swift.inc'),
    ):
        path = snapshot / relative
        text = path.read_text()
        old = (common / template).read_text()
        if not text.endswith(old) or text.count(old) != 1:
            raise RuntimeError('unexpected private instrumentation: ' + relative)
        path.write_text(text[:-len(old)] + (repo / 'tools/find-ime' / replacement).read_text())

    # Read-only dispatch trace: distinguish an absent OS event from wrong routing.
    path = snapshot / 'src/platform/macos/app_session.zig'
    text = path.read_text()
    needle = '    pub fn handleKeyEvent(self: *AppSession, event: terminal.KeyEvent) !FrameSummary {'
    assert text.count(needle) == 1
    trace = '\n        if (event.key == .tab) std.debug.print("FIND_TAB before focus={s} role={s} replace={} target={s}\\n", .{@tagName(self.inputFocus()), @tagName(self.chrome_host.find.effectiveFocus()), self.chrome_host.find.replace_open, @tagName(self.chrome_host.find.target)});'
    path.write_text(text.replace(needle, needle + trace))
