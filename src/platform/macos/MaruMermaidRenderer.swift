import AppKit
import Foundation
import WebKit
import Darwin

/// FP10c2 helper. bridge/message handler 없는 별도 WKWebView에서 strict Mermaid를 실행하고
/// sanitized SVG만 bounded protocol result로 반환한다.
@main
@MainActor
struct MaruMermaidRenderer {
    private static var retainedPage: MermaidRendererPage?
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
                    // HelloAck는 WebKit cold-start와 무관한 process/protocol liveness다. 실제 renderer는
                    // 첫 정상 Request에서 lazy 생성하고 그 job의 end-to-end deadline에 비용을 귀속한다.
                case UInt32(MARU_MERMAID_TAG_REQUEST):
                    guard helperInstance == frame.helper_instance else { Darwin.exit(6) }
                    let source = frame.body_ptr.map {
                        String(decoding: UnsafeBufferPointer(start: $0, count: frame.body_len), as: UTF8.self)
                    } ?? ""
                    if source == "__MARU_TEST_HANG__" { return }
                    if source == "__MARU_TEST_MAX_SVG__" {
                        writeMaxSvg(frame.capability)
                        return
                    }
                    if source == "__MARU_TEST_EXTERNAL_APIS__" {
                        guard let page = rendererPage() else { Darwin.exit(12) }
                        let capability = frame.capability
                        page.probeExternalRequests { attempts in
                            guard attempts?.isExactAPIProbe == true,
                                  page.externalNavigationAttempts == 0 else { Darwin.exit(13) }
                            writeRenderError(capability)
                        }
                        return
                    }
                    if source == "__MARU_TEST_EXTERNAL_SUBRESOURCE__" {
                        guard let page = rendererPage() else { Darwin.exit(12) }
                        let capability = frame.capability
                        page.probeExternalSubresource { attempts in
                            guard let attempts,
                                  attempts.fetch == 0,
                                  attempts.xhr == 0,
                                  attempts.webSocket == 0,
                                  attempts.eventSource == 0,
                                  attempts.cspViolation > 0,
                                  page.externalNavigationAttempts == 0 else { Darwin.exit(13) }
                            writeRenderError(capability)
                        }
                        return
                    }
                    if source == "__MARU_TEST_EXTERNAL_NAVIGATION__" {
                        guard let page = rendererPage() else { Darwin.exit(12) }
                        let capability = frame.capability
                        page.probeExternalNavigation { blocked in
                            guard blocked else { Darwin.exit(13) }
                            writeRenderError(capability)
                        }
                        return
                    }
                    if source.hasPrefix("__MARU_TEST_") {
                        writeRenderError(frame.capability, duplicate: source == "__MARU_TEST_DUPLICATE__", flood: source == "__MARU_TEST_FLOOD__")
                        return
                    }
                    guard let page = rendererPage() else { Darwin.exit(12) }
                    let capability = frame.capability
                    page.render(source: source) { outcome in
                        switch outcome {
                        case let .success(rendered):
                            guard rendered.externalRequests.total == 0,
                                  page.externalNavigationAttempts == 0 else {
                                writeRenderError(capability)
                                return
                            }
                            let body = Data(rendered.svg.utf8)
                            guard body.count <= Int(MARU_MERMAID_PROTOCOL_MAX_SVG_BYTES) else {
                                writeRenderError(capability)
                                return
                            }
                            var mutable = capability
                            guard let result = MermaidProtocolBridge.result(
                                capability: &mutable,
                                status: UInt32(MARU_MERMAID_RESULT_OK),
                                body: body
                            ) else { Darwin.exit(7) }
                            write(result)
                        case let .failure(error):
                            FileHandle.standardError.write(Data("render_error: \(error)\n".utf8))
                            writeRenderError(capability)
                        }
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

    private static func writeRenderError(
        _ capability: MaruMermaidJobCapability,
        duplicate: Bool = false,
        flood: Bool = false
    ) {
        var mutable = capability
        guard let result = MermaidProtocolBridge.result(
            capability: &mutable,
            status: UInt32(MARU_MERMAID_RESULT_RENDER_ERROR),
            body: Data()
        ) else { Darwin.exit(7) }
        write(result)
        if duplicate { write(result) }
        if flood { for _ in 0..<15 { write(result) } }
    }

    private static func writeMaxSvg(_ capability: MaruMermaidJobCapability) {
        let prefix = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><!--".utf8)
        let suffix = Data("--></svg>".utf8)
        let total = Int(MARU_MERMAID_PROTOCOL_MAX_SVG_BYTES)
        guard prefix.count + suffix.count <= total else { Darwin.exit(7) }
        var body = Data(capacity: total)
        body.append(prefix)
        body.append(Data(repeating: 0x78, count: total - prefix.count - suffix.count))
        body.append(suffix)
        var mutable = capability
        guard let result = MermaidProtocolBridge.result(
            capability: &mutable,
            status: UInt32(MARU_MERMAID_RESULT_OK),
            body: body
        ) else { Darwin.exit(7) }
        write(result)
    }

    private static func loadRendererScript() -> String? {
        guard let resource = Bundle.main.resourceURL else { return nil }
        let url = resource
            .appendingPathComponent("web", isDirectory: true)
            .appendingPathComponent("mermaid-helper.js", isDirectory: false)
        return MermaidScriptLoader.load(
            url: url,
            maxBytes: MermaidRendererPage.maxScriptBytes,
            expectedSHA256: MermaidHelperDigest.sha256
        )
    }

    private static func rendererPage() -> MermaidRendererPage? {
        if let retainedPage { return retainedPage }
        guard let script = loadRendererScript(), let page = MermaidRendererPage(script: script) else {
            return nil
        }
        retainedPage = page
        return page
    }
}
