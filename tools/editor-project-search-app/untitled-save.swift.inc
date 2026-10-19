// 첫 저장 호출·다음 main 블록·완료 관측을 나눠 잰다. 검사와 캡처는 시각 기록 뒤에 한다.
@_silgen_name("maru_untitled_benchmark_setup") private func untitledBenchmarkSetup() -> Int32
@_silgen_name("maru_untitled_benchmark_save") private func untitledBenchmarkSave() -> Int32
@_silgen_name("maru_untitled_benchmark_probe") private func untitledBenchmarkProbe() -> Int32
@MainActor private enum UntitledBenchmark {
    static var started = false
    static var done = false
    static var start: UInt64 = 0
    static var returned: UInt64 = 0
    static var next: UInt64 = 0
    static var result: Int32 = -1
}
extension MaruAppHostController {
    private func maybeRunUntitledBenchmark() {
        guard !UntitledBenchmark.started else { return }
        UntitledBenchmark.started = true
        guard untitledBenchmarkSetup() == 1 else { exitCode = 1; bypassQuitConfirm = true; NSApp.terminate(nil); return }
        DispatchQueue.main.async {
            UntitledBenchmark.start = DispatchTime.now().uptimeNanoseconds
            UntitledBenchmark.result = untitledBenchmarkSave()
            UntitledBenchmark.returned = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                UntitledBenchmark.next = DispatchTime.now().uptimeNanoseconds
                self.pollUntitledBenchmark()
            }
        }
    }
    private func pollUntitledBenchmark() {
        guard !UntitledBenchmark.done else { return }
        let observed = DispatchTime.now().uptimeNanoseconds
        let ready = untitledBenchmarkProbe()
        if ready == 0 && observed - UntitledBenchmark.start < 10_000_000_000 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { self.pollUntitledBenchmark() }
            return
        }
        UntitledBenchmark.done = true
        let passed = UntitledBenchmark.result == 1 && ready == 1 && editorProjectSearchCapture("untitled-saved")
        FileHandle.standardError.write(Data("UNTITLED_SAVE_METRIC call_ns=\(UntitledBenchmark.returned - UntitledBenchmark.start) next_event_ns=\(UntitledBenchmark.next - UntitledBenchmark.start) passed=\(passed)\n".utf8))
        FileHandle.standardError.write(Data("UNTITLED_SETTLED ns=\(observed - UntitledBenchmark.start)\n".utf8))
        FileHandle.standardError.write(Data("EDITOR_PROJECT_SEARCH_FINISH passed=\(passed) transport=AppKit-local untitled=true\n".utf8))
        if !passed { exitCode = 1 }
        EditorProjectSearchRun.stage = 99
        bypassQuitConfirm = true
        NSApp.terminate(nil)
    }
}
