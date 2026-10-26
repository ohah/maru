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
        replacement_text = (repo / 'tools/inspector-ime' / replacement).read_text()
        if replacement == 'probe.zig.inc':
            shared = (repo / 'tools/project-search-ime/probe.zig.inc').read_text()
            marker = 'const AddressEvidence ='
            if shared.count(marker) != 1:
                raise RuntimeError('unexpected shared candidate collector')
            replacement_text += marker + shared.split(marker, 1)[1]
        path.write_text(text[:-len(old)] + replacement_text)
