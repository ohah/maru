import Foundation

/// A live IME fixture may restore only the sources it still owns. These cases exercise the
/// preflight without changing the machine's input source or requiring an unlocked desktop.
@main
enum EditorIMEInputSourcePolicyTest {
    static func main() {
        let selected = SessionHostInputSourcePolicy.korean2SetSourceID
        let originalGlobal = "global-original"
        let originalView = "view-original"
        let cases: [(String?, String?, String?, Bool)] = [
            (selected, selected, originalView, true),
            (originalGlobal, originalView, originalView, true),
            ("user-third", selected, originalView, false),
            (selected, "user-third", originalView, false),
            (nil, selected, originalView, false),
            (selected, nil, originalView, false),
            (selected, nil, nil, true),
        ]
        for (index, sample) in cases.enumerated() {
            let allowed = SessionHostInputSourcePolicy.permitsViewRestoration(
                currentGlobal: sample.0, originalGlobal: originalGlobal,
                currentView: sample.1, originalView: sample.2
            )
            guard allowed == sample.3 else {
                fputs("input-source restore authority case \(index) failed\n", stderr)
                exit(1)
            }
        }
        print("editor IME input-source restoration policy: \(cases.count) cases passed")
    }
}
