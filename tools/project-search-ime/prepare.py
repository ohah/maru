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
        path.write_text(text[:-len(old)] + (repo / 'tools/project-search-ime' / replacement).read_text())

    # Observe real tagged HID delivery in the source copy only. Neither monitor
    # nor defer changes event dispatch or product input decisions.
    text = (snapshot / 'src/platform/macos/MaruAppHost.swift').read_text()
    for signature, start, end in (
        ('    override func keyDown(with event: NSEvent) {', 'view_received', 'view_handled'),
        ('    override func keyUp(with event: NSEvent) {', 'view_release_received', 'view_release_handled'),
    ):
        if text.count(signature) != 1:
            raise RuntimeError('unexpected private event observation point')
        text = text.replace(signature, signature + f'\n        projectTabRecord(event, phase: "{start}")\n        defer {{ projectTabRecord(event, phase: "{end}") }}', 1)
    (snapshot / 'src/platform/macos/MaruAppHost.swift').write_text(text + '\n' + (repo / 'tools/project-search-ime/tab_trace.swift.inc').read_text())
