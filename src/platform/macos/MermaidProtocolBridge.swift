import Foundation

/// Swift 양쪽은 frame layout을 모르고 이 Zig codec wrapper만 사용한다. `DecodedFrame.body_ptr`는
/// decoder의 다음 feed/next 전까지만 유효하므로 callback 안에서만 소비해야 한다.
final class MermaidProtocolDecoder {
    private var handle: OpaquePointer?

    init?() {
        guard let created = maru_mermaid_protocol_decoder_create() else { return nil }
        handle = created
    }

    deinit {
        if let handle { maru_mermaid_protocol_decoder_destroy(handle) }
    }

    func feed(_ data: Data) -> Bool {
        guard let handle else { return false }
        return data.withUnsafeBytes { raw in
            maru_mermaid_protocol_decoder_feed(
                handle,
                raw.bindMemory(to: UInt8.self).baseAddress,
                raw.count
            ) == 0
        }
    }

    /// frame이 있으면 callback을 동기 실행한다. nil은 partial input, false는 malformed다.
    func next(_ consume: (inout MaruMermaidDecodedFrame) -> Void) -> Bool? {
        guard let handle else { return false }
        var frame = MaruMermaidDecodedFrame()
        let status = maru_mermaid_protocol_decoder_next(handle, &frame)
        if status == 0 { return nil }
        guard status == 1 else { return false }
        consume(&frame)
        return true
    }

    func finish() -> Bool {
        guard let handle else { return false }
        return maru_mermaid_protocol_decoder_finish(handle) == 0
    }
}

enum MermaidProtocolBridge {
    private static func encode(capacity: Int, _ body: (UnsafeMutablePointer<UInt8>, Int) -> Int64) -> Data? {
        var data = Data(count: capacity)
        let written = data.withUnsafeMutableBytes { raw -> Int64 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return body(base, raw.count)
        }
        guard written > 0, written <= capacity else { return nil }
        data.count = Int(written)
        return data
    }

    static func hello(helperInstance: UInt64, nonce: UInt64, ack: Bool) -> Data? {
        encode(capacity: 64) { out, cap in
            maru_mermaid_protocol_encode_hello(ack ? 1 : 0, helperInstance, nonce, out, cap)
        }
    }

    /// Zig coordinator가 이미 encode한 leased frame을 executor-owned storage로 한 번 복사한다.
    /// Swift는 wire layout을 다시 만들거나 해석하지 않는다.
    static func copyRequestFrame(action: inout MaruMermaidCoordinatorAction) -> Data? {
        guard let frame = action.request_frame_ptr,
              action.request_frame_len > 0,
              action.request_frame_len <= Int(MARU_MERMAID_PROTOCOL_MAX_REQUEST_FRAME_BYTES) else { return nil }
        return Data(bytes: frame, count: action.request_frame_len)
    }

    static func result(
        capability: inout MaruMermaidJobCapability,
        status: UInt32,
        body: Data
    ) -> Data? {
        encode(capacity: Int(MARU_MERMAID_PROTOCOL_MAX_RESULT_FRAME_BYTES)) { out, cap in
            body.withUnsafeBytes { raw in
                withUnsafePointer(to: &capability) { capabilityPtr in
                    maru_mermaid_protocol_encode_result(
                        capabilityPtr,
                        status,
                        raw.bindMemory(to: UInt8.self).baseAddress,
                        raw.count,
                        out,
                        cap
                    )
                }
            }
        }
    }
}
