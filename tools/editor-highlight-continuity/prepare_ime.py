#!/usr/bin/env python3
"""검증된 stream 사본에서 IME/Undo/Redo와 앱 Metal 키프레임 전용 사본을 만든다."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('ambiguous instrumentation anchor: ' + old[:80])
    return text.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    output = args.output.resolve()
    repo = Path(__file__).resolve().parents[2]
    if output.exists() or output == repo or repo in output.parents:
        parser.error('new external output required')
    receipt = json.loads((build / 'source.json').read_text())
    assert sha(build / 'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app') == receipt['app_sha256']
    assert all(sha(build / 'source' / name) == value for name, value in receipt['instrumented'].items())
    output.mkdir(parents=True)
    source = output / 'source'
    source.mkdir()
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=zig-pkg', '--exclude=references', str(build / 'source') + '/', str(source) + '/'], check=True)
    (source / 'zig-pkg').symlink_to((build / 'source/zig-pkg').resolve(), target_is_directory=True)
    (source / 'web/node_modules').symlink_to((build / 'source/web/node_modules').resolve(), target_is_directory=True)
    original = {str(p.relative_to(source)): sha(p) for p in (source / 'src').rglob('*') if p.is_file()}
    agent = source / 'src/platform/macos/app_session/agent.zig'
    text = agent.read_text()
    guard = '    if (std.c.getenv("MARU_LATENCY_OUTPUT") != null) return;'
    assert text.count(guard) == 4
    # IME 실험도 stream 실험과 동일하게 사용자 provider 설정에 쓰지 않는다.
    text = text.replace(guard, '    if (std.c.getenv("MARU_LATENCY_OUTPUT") != null or std.c.getenv("MARU_EDITOR_IME_SMOKE_OUT") != null) return;')
    text = once(text, '    if (std.c.getenv("MARU_LATENCY_OUTPUT") != null) return .v1;', '    if (std.c.getenv("MARU_LATENCY_OUTPUT") != null or std.c.getenv("MARU_EDITOR_IME_SMOKE_OUT") != null) return .v1;')
    agent.write_text(text)
    driver = source / 'src/platform/macos/EditorIMESmokeDriver.swift'
    text = once(driver.read_text(), '    private var step = 0', '    var highlightEvidencePhase: String { "s\\(step)-l\\(liveStep)-k\\(liveKeyIndex)" }\n    private var step = 0')
    text = once(text, 'window: NSWindow) {\n        guard let event = NSEvent.keyEvent(', 'window: NSWindow, modifiers: NSEvent.ModifierFlags = [.command]) {\n        guard let event = NSEvent.keyEvent(')
    text = once(text, 'with: .keyDown, location: .zero, modifierFlags: [.command],', 'with: .keyDown, location: .zero, modifierFlags: modifiers,')
    text = once(text, '''        case 4:
            guard disk("cat cat", "multicursor_single_undo") else { return }
            finish()''', '''        case 4:
            guard disk("cat cat", "multicursor_single_undo") else { return }
            key(6, "z", view: view, window: window, modifiers: [.command, .shift])
            expect(virtualText(view) == "한 한", "multicursor_redo_document")
            key(1, "s", view: view, window: window)
        case 5:
            guard disk("한 한", "multicursor_redo_saved") else { return }
            key(6, "z", view: view, window: window)
            expect(virtualText(view) == "cat cat", "multicursor_second_undo_document")
            key(1, "s", view: view, window: window)
        case 6:
            guard disk("cat cat", "multicursor_second_undo_saved") else { return }
            finish()''')
    driver.write_text(text)
    host = source / 'src/platform/macos/MaruAppHost.swift'
    text = once(host.read_text(), '    private var editorIMESmokeDriver: EditorIMESmokeDriver?', '    private var highlightCaptureRequested = Set<String>()\n    private var highlightLastCapture: URL?\n    private var editorIMESmokeDriver: EditorIMESmokeDriver?')
    # 완료 직후 마지막 키프레임을 기다리는 다음 tick에서도 종료 처리가 실행돼야 한다.
    text = once(text, 'guard let driver = editorIMESmokeDriver, !driver.finished,', 'guard let driver = editorIMESmokeDriver,')
    text = once(text, '            driver.tick(editorPresent: ok && probe.editor_present != 0, view: view, window: window)', '''            driver.tick(editorPresent: ok && probe.editor_present != 0, view: view, window: window)
            if let root = ProcessInfo.processInfo.environment["MARU_HIGHLIGHT_APP_CAPTURE_ROOT"],
               let renderer = surface.metalRenderer {
                let label = driver.highlightEvidencePhase
                if !highlightCaptureRequested.contains(label) {
                    let path = URL(fileURLWithPath: root).appendingPathComponent(label + ".ppm")
                    if maru_metal_renderer_request_test_capture(renderer, path.path) {
                        highlightCaptureRequested.insert(label)
                        highlightLastCapture = path
                        metalNeedsRedraw = true
                    }
                }
            }''')
    text = once(text, '        if driver.finished {\n            if !driver.failures.isEmpty { exitCode = 1 }', '''        if driver.finished {
            if let path = highlightLastCapture, !FileManager.default.fileExists(atPath: path.path) {
                metalNeedsRedraw = true
                return
            }
            if !driver.failures.isEmpty { exitCode = 1 }''')
    host.write_text(text)
    renderer = source / 'src/platform/macos/maru_metal_renderer.m'
    renderer.write_text(once(renderer.read_text(), '    static const char *const gates[] = {', '    static const char *const gates[] = {\n        "MARU_HIGHLIGHT_APP_CAPTURE",'))
    instrumented = {str(p.relative_to(source)): sha(p) for p in (source / 'src').rglob('*') if p.is_file()}
    write = dict(base_receipt=receipt, original=original, instrumented=instrumented, prepare_sha256=sha(Path(__file__)))
    (output / 'source.json').write_text(json.dumps(write, indent=2) + '\n')
    with (output / 'build.log').open('xb') as log:
        subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'macos-app-bundle', '-Doptimize=ReleaseFast', '--cache-dir', str(args.cache.resolve()), '-j2'], cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True)
    assert all(sha(source / name) == value for name, value in instrumented.items())
    write['app_sha256'] = sha(source / 'zig-out/Maru.app/Contents/MacOS/maru-macos-app')
    (output / 'source.json').write_text(json.dumps(write, indent=2) + '\n')
    print(source / 'zig-out/Maru.app/Contents/MacOS/maru-macos-app')


if __name__ == '__main__':
    main()
