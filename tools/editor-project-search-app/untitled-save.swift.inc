// 첫 저장을 main queue에서 실행하고 다음 이벤트 지연을 따로 잰다.
@_silgen_name("maru_untitled_benchmark_setup") private func untitledBenchmarkSetup() -> Int32
@_silgen_name("maru_untitled_benchmark_save") private func untitledBenchmarkSave() -> Int32
@MainActor private enum UntitledBenchmark { static var started = false }
extension MaruAppHostController {
    private func maybeRunUntitledBenchmark() {
        guard !UntitledBenchmark.started else { return }
        UntitledBenchmark.started = true
        guard untitledBenchmarkSetup() == 1 else { exitCode = 1; bypassQuitConfirm = true; NSApp.terminate(nil); return }
        // 준비 비용과 저장 호출 비용을 섞지 않고 다음 main 이벤트에서 시작한다.
        DispatchQueue.main.async {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = untitledBenchmarkSave()
            let returned = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let next = DispatchTime.now().uptimeNanoseconds
                let captured = self.editorProjectSearchCapture("untitled-saved")
                FileHandle.standardError.write(Data("UNTITLED_SAVE_METRIC call_ns=\(returned - start) next_event_ns=\(next - start) passed=\(result == 1 && captured)\n".utf8))
                FileHandle.standardError.write(Data("EDITOR_PROJECT_SEARCH_FINISH passed=\(result == 1 && captured) transport=AppKit-local untitled=true\n".utf8))
                if result != 1 || !captured { self.exitCode = 1 }
                EditorProjectSearchRun.stage = 99
                self.bypassQuitConfirm = true
                NSApp.terminate(nil)
            }
        }
    }
}
