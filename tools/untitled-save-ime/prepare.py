"""Reuse rename instrumentation and replace only private fixture/driver witnesses."""
import importlib.util
from pathlib import Path


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError('instrumentation anchor drift: ' + old[:100])
    return text.replace(old, new, 1)


def prepare(repo, snapshot):
    base = repo / 'tools/rename-ime'
    load('rename_prepare', base / 'prepare.py').prepare(repo, snapshot)
    instrument(repo, snapshot)


def instrument(repo, snapshot):
    base = repo / 'tools/rename-ime'
    fixture = snapshot / 'src/platform/macos/app_session/debug_fixtures.zig'
    old = (base / 'probe.zig.inc').read_text()
    footer = old[old.index('const AddressEvidence ='):]
    fixture.write_text(once(fixture.read_text(), old,
                           (repo / 'tools/untitled-save-ime/probe.zig.inc').read_text() + '\n' + footer))
    driver = (base / 'driver.swift.inc').read_text()
    driver = driver.replace('maru.rename-ime.v1', 'maru.untitled-first-save-ime.v1')
    driver = driver.replace('"a//z"', '""')
    for old_word, word in [('a/ㅎ/z', 'ㅎ'), ('a/하/z', '하'), ('a/한/z', '한'), ('a/韓/z', '韓')]:
        driver = driver.replace('"' + old_word + '"', '"' + word + '"')
    driver = once(driver, 'try paletteIMERequire(maru_address_fixture_start(0) != 0, "address_fixture")',
                  'guard maru_address_fixture_start(0) != 0 else { return }')
    driver = once(driver, '"terminal_bytes": paletteIMEWitness(9),',
                  '"terminal_bytes": paletteIMEWitness(9), "untitled":paletteIMEWitness(30), "body_hash":String(paletteIMEWitness(31)), "dirty":paletteIMEWitness(32), "confirm":paletteIMEWitness(33), "surface_id":paletteIMEWitness(34),')
    driver = once(driver, '"mode": paletteIMEDiagnostic ? "diagnostic" : "live",',
                  '"mode": "diagnostic", "scenario":firstSaveCase, "pid":getpid(), "root":paletteIMERoot.path, "main_window_id":view?.window?.windowNumber ?? 0, "candidate_window_id":PaletteIMERun.selectedID ?? 0, "source_restored":PaletteIMERun.originalGlobal != nil && !failures.contains("source_restore") && !failures.contains("source_superseded"),')
    driver = once(driver, 'try addressDocument("한")\n                    paletteIMEState("han_',
                  'try addressDocument("한")\n                    if firstSaveCase == "korean" { try paletteIMEHID(36, view:view, window:window); PaletteIMERun.step=30; return }\n                    paletteIMEState("han_')
    driver = driver.replace('PaletteIMERun.candidateCount < 5', 'PaletteIMERun.candidateCount < 1')
    driver = once(driver, 'paletteIMEState("opened_\\(PaletteIMERun.candidateCount)", view: view, window: window)',
                  'paletteIMEState("opened_\\(PaletteIMERun.candidateCount)", view: view, window: window)\n                    if PaletteIMERun.candidateCount == 1 { let added=opened.windows.filter { !old.contains($0.id) }; try paletteIMERequire(added.count==1,"candidate_identity"); PaletteIMERun.selectedID=added[0].id; try firstSaveNativeCapture(Int(added[0].id), "candidate") }')
    start = driver.index('                case 30:')
    end = driver.index('                default:', start)
    driver = driver[:start] + (repo / 'tools/untitled-save-ime/finish.swift.inc').read_text() + driver[end:]
    driver = once(driver, '    private func addressDocument(_ text: String) throws {',
                  (repo / 'tools/untitled-save-ime/capture.swift.inc').read_text() + '    private func addressDocument(_ text: String) throws {')
    driver = once(driver, '"rename_document_or_target")',
                  '"rename_document_or_target")\n        try paletteIMERequire(paletteIMEWitness(30)==1 && paletteIMEWitness(31)==paletteIMEHash("first save body\\n") && paletteIMEWitness(32)==1 && paletteIMEWitness(33)==0,"early_save")')
    driver += '\n@_silgen_name("maru_untitled_model") private func maru_untitled_model() -> UInt64\n'
    host = snapshot / 'src/platform/macos/MaruAppHost.swift'
    host.write_text(once(host.read_text(), (base / 'driver.swift.inc').read_text(), driver))
