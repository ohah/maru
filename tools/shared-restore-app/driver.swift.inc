// 이 파일은 검증용 사본의 MaruAppHost.swift에만 붙인다. 실제 창/렌더/종료 경로를 사용한다.
@_silgen_name("maru_shared_restore_fixture_step")
private func sharedRestoreFixtureStep(_ command: UInt32) -> Int32

@MainActor
private enum SharedRestoreRun {
    static var stage = 0
    static var next = 0.0
}

extension MaruAppHostController {
    private func captureSharedRestore(_ label: String) -> Bool {
        guard let surface = primary, let renderer = surface.metalRenderer,
              let root = ProcessInfo.processInfo.environment["MARU_SHARED_RESTORE_OUTPUT"] else { return false }
        let path = URL(fileURLWithPath: root).appendingPathComponent(label + ".ppm")
        guard !FileManager.default.fileExists(atPath: path.path),
              maru_metal_renderer_request_test_capture(renderer, path.path) else { return false }
        withSurface(surface) {
            metalNeedsRedraw = true
            _ = renderTick()
        }
        return FileManager.default.fileExists(atPath: path.path)
    }

    private func finishSharedRestore(_ success: Bool) {
        if !success { exitCode = 1 }
        SharedRestoreRun.stage = 99
        FileHandle.standardError.write(Data("SHARED_RESTORE_FINISH success=\(success)\n".utf8))
        bypassQuitConfirm = true
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private func maybeRunSharedRestore() {
        guard let phase = ProcessInfo.processInfo.environment["MARU_SHARED_RESTORE_PHASE"],
              phase != "ime", SharedRestoreRun.stage < 99,
              let window = primary?.window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if phase == "seed" {
            if SharedRestoreRun.stage == 0 {
                let ready = sharedRestoreFixtureStep(1)
                if ready < 0 { finishSharedRestore(false); return }
                if ready == 0 { return }
                SharedRestoreRun.stage = 1
                SharedRestoreRun.next = now + 0.5
                return
            }
            guard now >= SharedRestoreRun.next else { return }
            let ok = sharedRestoreFixtureStep(10) == 1 && captureSharedRestore("seed")
            finishSharedRestore(ok)
            return
        }
        if SharedRestoreRun.stage == 0 {
            let ready = sharedRestoreFixtureStep(20)
            if ready == 0 { return }
            guard ready == 1, captureSharedRestore("restored") else { finishSharedRestore(false); return }
            SharedRestoreRun.stage = 1
            SharedRestoreRun.next = now + 0.8
            return
        }
        guard now >= SharedRestoreRun.next else { return }
        switch SharedRestoreRun.stage {
        case 1:
            guard sharedRestoreFixtureStep(2) == 1 else { return }
            guard sharedRestoreFixtureStep(21) == 1, captureSharedRestore("settled") else { finishSharedRestore(false); return }
            window.setContentSize(NSSize(width: 640, height: 480))
            SharedRestoreRun.stage = 2
        case 2:
            guard sharedRestoreFixtureStep(22) == 1, captureSharedRestore("narrow") else { finishSharedRestore(false); return }
            window.setContentSize(NSSize(width: 1200, height: 800))
            SharedRestoreRun.stage = 3
        default:
            let ok = sharedRestoreFixtureStep(23) == 1 && captureSharedRestore("wide")
            finishSharedRestore(ok)
        }
        SharedRestoreRun.next = now + 0.6
    }
}
