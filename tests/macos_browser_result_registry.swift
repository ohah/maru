import Foundation

@main
struct BrowserResultTransferRegistryTests {
    @MainActor
    static func main() throws {
        let registry = BrowserResultTransferRegistry(maxEntries: 2, maxEntryBytes: 8, maxTotalBytes: 10)
        let first = registry.insert(Data([0, 1, 2, 3, 4, 5]))!
        precondition(first != 0)
        precondition(registry.retainedBytes == 6)

        var dst = [UInt8](repeating: 0xEE, count: 8)
        let copied = dst.withUnsafeMutableBytes { raw in
            registry.copy(id: first, offset: 2, destination: raw.baseAddress, capacity: 3)
        }
        precondition(copied == 3)
        precondition(Array(dst[0..<3]) == [2, 3, 4])
        precondition(Array(dst[3...]) == [0xEE, 0xEE, 0xEE, 0xEE, 0xEE])
        precondition(registry.copy(id: first, offset: 6, destination: nil, capacity: 8) == 0)
        precondition(registry.copy(id: first, offset: 7, destination: nil, capacity: 0) == -1)
        precondition(registry.copy(id: first, offset: 0, destination: nil, capacity: 1) == -1)
        precondition(registry.copy(id: first, offset: 0, destination: nil, capacity: 0) == 0)
        precondition(registry.copy(id: first, offset: 0, destination: nil, capacity: BrowserResultTransferRegistry.maxCopyBytes + 1) == -1)
        precondition(registry.insert(Data(repeating: 0, count: 9)) == nil) // per-entry cap

        let second = registry.insert(Data([9, 8, 7, 6]))!
        precondition(second > first)
        precondition(registry.insert(Data([1])) == nil) // entry cap
        precondition(registry.release(first))
        precondition(!registry.release(first))
        precondition(registry.retainedBytes == 4)
        precondition(registry.insert(Data(repeating: 1, count: 7)) == nil) // aggregate cap
        registry.releaseAll()
        precondition(registry.count == 0 && registry.retainedBytes == 0)

        let exhausted = BrowserResultTransferRegistry(maxEntries: 2, maxEntryBytes: 8, maxTotalBytes: 16, nextId: UInt64.max)
        precondition(exhausted.insert(Data([1])) == UInt64.max)
        precondition(exhausted.insert(Data([2])) == nil)

        let object = try BrowserResultTransferRegistry.encodeScriptResult(["b": 2, "a": 1])
        precondition(String(decoding: object, as: UTF8.self) == "{\"a\":1,\"b\":2}")
        let fragment = try BrowserResultTransferRegistry.encodeScriptResult("hello")
        precondition(String(decoding: fragment, as: UTF8.self) == "\"hello\"")
        do {
            _ = try BrowserResultTransferRegistry.encodeScriptResult(Date())
            preconditionFailure("unsupported value must fail strict JSON encoding")
        } catch {}
        for rejected in [Double.nan, Double.infinity, -0.0] {
            do {
                _ = try BrowserResultTransferRegistry.encodeScriptResult(["value": rejected])
                preconditionFailure("non-finite and negative zero must fail strict JSON encoding")
            } catch {}
        }

        let bounded = try BrowserResultTransferRegistry.boundedPageScript("Promise.resolve({text: '\"한글\\n', value: args[0]})", maxBytes: 64)
        precondition(bounded.contains("return await __maruBoundedScriptV1"))
        precondition(bounded.contains("Promise.resolve({text:"))
        precondition(bounded.contains("64"))
        precondition(!bounded.contains("eval("))
        precondition(!BrowserResultTransferRegistry.boundedPageBootstrapScript.contains("JSON.stringify"))
        precondition(!BrowserResultTransferRegistry.boundedPageBootstrapScript.contains("TextEncoder"))
        precondition(!BrowserResultTransferRegistry.boundedPageBootstrapScript.contains("pageEval"))
        precondition(BrowserResultTransferRegistry.boundedPageBootstrapScript.contains("await thunk()"))
        precondition(BrowserResultTransferRegistry.boundedPageBootstrapScript.contains("writable:false"))
        _ = try BrowserResultTransferRegistry.boundedPageScript("function(){return 1}", maxBytes: 64)
        _ = try BrowserResultTransferRegistry.boundedPageScript("class {}", maxBytes: 64)
        for escaping in [
            "'x'.repeat(20000000)),25000000,(0",
            "'x'.repeat(100000000)), 999999999); (()=>{})((0",
            "1 /*",
        ] {
            do {
                _ = try BrowserResultTransferRegistry.boundedPageScript(escaping, maxBytes: 64)
                preconditionFailure("source must not escape the bounded wrapper")
            } catch {}
        }
        switch BrowserResultTransferRegistry.decodeBoundedPageResult("maru-json:{\"ok\":true}", maxBytes: 64) {
        case .json(let data): precondition(String(decoding: data, as: UTF8.self) == "{\"ok\":true}")
        default: preconditionFailure("bounded JSON prefix must decode")
        }
        switch BrowserResultTransferRegistry.decodeBoundedPageResult("maru-too-large:65", maxBytes: 64) {
        case .tooLarge(let observed): precondition(observed == 65)
        default: preconditionFailure("bounded overflow prefix must decode")
        }
        switch BrowserResultTransferRegistry.decodeBoundedPageResult("maru-json:\(String(repeating: "x", count: 65))", maxBytes: 64) {
        case .tooLarge(let observed): precondition(observed == 65)
        default: preconditionFailure("host must recheck page result cap")
        }
        switch BrowserResultTransferRegistry.decodeBoundedPageResult("maru-too-large:999", maxBytes: 64) {
        case .scriptError: break
        default: preconditionFailure("host must reject forged overflow markers")
        }
        switch BrowserResultTransferRegistry.decodeBoundedPageResult("maru-json:null", maxBytes: BrowserResultTransferRegistry.defaultMaxEntryBytes + 1) {
        case .scriptError: break
        default: preconditionFailure("host must enforce the independent 16 MiB hard cap")
        }
        let native = BrowserResultTransferRegistry.nativeScriptErrorPayload(
            NSError(domain: String(repeating: "\\", count: 1_000), code: 7, userInfo: [NSLocalizedDescriptionKey: String(repeating: "\u{0001}", count: 100_000)]))
        precondition(native.count <= BrowserResultTransferRegistry.maxScriptErrorPayloadBytes)
        let nativeObject = try JSONSerialization.jsonObject(with: native) as? [String: Any]
        precondition(nativeObject?["diagnostics_truncated"] as? Bool == true)
        let navigation = BrowserResultTransferRegistry.nativeScriptErrorPayload(NSError(domain: "Maru.Browser", code: 8), kind: "navigation")
        let navigationObject = try JSONSerialization.jsonObject(with: navigation) as? [String: Any]
        precondition(navigationObject?["kind"] as? String == "navigation")

        let chunkRegistry = BrowserResultTransferRegistry(
            maxEntries: 1,
            maxEntryBytes: BrowserResultTransferRegistry.maxCopyBytes,
            maxTotalBytes: BrowserResultTransferRegistry.maxCopyBytes
        )
        let exactChunk = Data(repeating: 0xA7, count: BrowserResultTransferRegistry.maxCopyBytes)
        let chunkId = chunkRegistry.insert(exactChunk)!
        var chunkDst = Data(repeating: 0, count: exactChunk.count)
        let exactCopied = chunkDst.withUnsafeMutableBytes { raw in
            chunkRegistry.copy(id: chunkId, offset: 0, destination: raw.baseAddress, capacity: raw.count)
        }
        precondition(exactCopied == exactChunk.count && chunkDst == exactChunk)
        precondition(chunkRegistry.release(chunkId))
        precondition(chunkRegistry.retainedBytes == 0)
    }
}
