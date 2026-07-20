import AppKit
import Foundation
import WebKit
import Darwin

/// FP10c1 helper foundation. Process는 bridge/message handler 없는 별도 WKWebView를 소유하지만,
/// Mermaid 실행과 sanitized SVG success는 FP10c2 전까지 비활성이다. 정상 Request는 render_error로
/// 돌려 editor source를 보존하고, smoke hang token만 의도적으로 응답하지 않는다.
@main
@MainActor
struct MaruMermaidRenderer {
    private static var retainedWebView: WKWebView?
    private static var decoder: MermaidProtocolDecoder?
    private static var helperInstance: UInt64?

    static func main() {
        _ = NSApplication.shared
        guard let protocolDecoder = MermaidProtocolDecoder() else { Darwin.exit(2) }
        decoder = protocolDecoder

        let stdin = FileHandle.standardInput
        stdin.readabilityHandler = { handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                if data.isEmpty {
                    guard decoder?.finish() == true else { Darwin.exit(3) }
                    Darwin.exit(0)
                }
                consume(data)
            }
        }
        RunLoop.current.run()
    }

    private static func consume(_ data: Data) {
        guard let decoder, decoder.feed(data) else { Darwin.exit(4) }
        while true {
            let status = decoder.next { frame in
                switch frame.tag {
                case UInt32(MARU_MERMAID_TAG_HELLO):
                    guard helperInstance == nil,
                          let ack = MermaidProtocolBridge.hello(
                            helperInstance: frame.helper_instance,
                            nonce: frame.nonce,
                            ack: true
                          ) else { Darwin.exit(5) }
                    helperInstance = frame.helper_instance
                    write(ack)
                    if ProcessInfo.processInfo.environment["MARU_MERMAID_SMOKE_NO_STDIN"] == "1" {
                        FileHandle.standardInput.readabilityHandler = nil
                        return
                    }
                    if ProcessInfo.processInfo.environment["MARU_MERMAID_SMOKE_CLOSE_PIPES"] == "1" {
                        FileHandle.standardInput.readabilityHandler = nil
                        _ = Darwin.close(STDOUT_FILENO)
                        _ = Darwin.close(STDERR_FILENO)
                        return
                    }
                    // HelloAck는 WebKit cold-start와 무관한 process/protocol liveness다. ACK 뒤에만
                    // ephemeral bridge-free renderer를 만들고, 그동안 들어온 Request는 main queue에서 대기한다.
                    retainedWebView = MermaidRendererPage.makeWebView()
                case UInt32(MARU_MERMAID_TAG_REQUEST):
                    guard helperInstance == frame.helper_instance else { Darwin.exit(6) }
                    let source = frame.body_ptr.map {
                        String(decoding: UnsafeBufferPointer(start: $0, count: frame.body_len), as: UTF8.self)
                    } ?? ""
                    if source == "__MARU_TEST_HANG__" { return }
                    var capability = frame.capability
                    guard let result = MermaidProtocolBridge.result(
                        capability: &capability,
                        status: UInt32(MARU_MERMAID_RESULT_RENDER_ERROR),
                        body: Data()
                    ) else { Darwin.exit(7) }
                    write(result)
                    if source == "__MARU_TEST_DUPLICATE__" { write(result) }
                    if source == "__MARU_TEST_FLOOD__" {
                        for _ in 0..<15 { write(result) }
                    }
                default:
                    Darwin.exit(8)
                }
            }
            guard status == true else {
                if status == false { Darwin.exit(9) }
                break
            }
        }
    }

    private static func write(_ data: Data) {
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            Darwin.exit(10)
        }
    }
}
