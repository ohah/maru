import Foundation

/// CR6d AppKit child가 SIGKILL/timeout으로 정산되지 못한 경우 부모 하네스가 실행하는 최소 복원 도구다.
/// record가 이미 정상 소비됐으면 no-op이고, 제3 source로 바뀌었으면 사용자 선택을 덮지 않고 실패한다.
@main
enum SessionHostInputSourceRestoreMain {
    static func main() {
        guard CommandLine.arguments.count == 2 else { Foundation.exit(64) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        switch SessionHostInputSourcePolicy.restore(recordURL: url) {
        case .restored, .noRecord:
            Foundation.exit(0)
        case .superseded:
            Foundation.exit(65)
        case .invalidRecord:
            Foundation.exit(66)
        case .restoreFailed:
            Foundation.exit(67)
        }
    }
}
