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
