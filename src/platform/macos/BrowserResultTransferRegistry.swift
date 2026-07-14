import Foundation
import CoreFoundation

/// executeScript JSON bytes의 Swift-side 안정 소유자. 모든 호출은 main actor에서 일어나며 raw pointer는 copy 호출의
/// `withUnsafeBytes` 범위 밖으로 절대 나가지 않는다. ID는 process lifetime 동안 재사용하지 않는다.
@MainActor
final class BrowserResultTransferRegistry {
    static let shared = BrowserResultTransferRegistry()
    nonisolated static let defaultMaxEntries = 8
    nonisolated static let defaultMaxEntryBytes = 16 * 1024 * 1024
    nonisolated static let defaultMaxTotalBytes = 256 * 1024 * 1024
    nonisolated static let maxCopyBytes = 512 * 1024

    private var entries: [UInt64: Data] = [:]
    private var nextId: UInt64
    private let maxEntries: Int
    private let maxEntryBytes: Int
    private let maxTotalBytes: Int
    private(set) var retainedBytes = 0

    init(
        maxEntries: Int = defaultMaxEntries,
        maxEntryBytes: Int = defaultMaxEntryBytes,
        maxTotalBytes: Int = defaultMaxTotalBytes,
        nextId: UInt64 = 1
    ) {
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalBytes = maxTotalBytes
        self.nextId = nextId
    }

    var count: Int { entries.count }

    /// Data의 COW backing을 registry가 보존한다. caller가 이후 값을 변경해도 Swift COW가 새 backing을 만들므로
    /// registry bytes는 불변이며, 삽입 때 full-size byte copy를 한 벌 더 만들지 않는다.
    func insert(_ source: Data) -> UInt64? {
        guard nextId != 0,
              entries.count < maxEntries,
              source.count <= maxEntryBytes,
              source.count <= maxTotalBytes - retainedBytes else { return nil }
        let id = nextId
        nextId = id == UInt64.max ? 0 : id + 1
        entries[id] = source
        retainedBytes += source.count
        return id
    }

    /// 성공 시 복사한 byte 수, unknown/invalid면 -1. EOF와 capacity=0은 0이다.
    func copy(id: UInt64, offset: UInt64, destination: UnsafeMutableRawPointer?, capacity: Int) -> Int {
        guard capacity >= 0, capacity <= Self.maxCopyBytes, let data = entries[id] else { return -1 }
        guard offset <= UInt64(data.count) else { return -1 }
        if capacity == 0 || offset == UInt64(data.count) { return 0 }
        guard let destination else { return -1 }
        let start = Int(offset) // offset <= data.count <= Int.max
        let copied = min(capacity, data.count - start)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            destination.copyMemory(from: base.advanced(by: start), byteCount: copied)
        }
        return copied
    }

    /// first release=true, unknown/duplicate=false. 둘 다 호출 뒤 해당 id의 Data는 존재하지 않는다.
    @discardableResult
    func release(_ id: UInt64) -> Bool {
        guard let data = entries.removeValue(forKey: id) else { return false }
        retainedBytes -= data.count
        return true
    }

    func releaseAll() {
        entries.removeAll(keepingCapacity: false)
        retainedBytes = 0
    }

    /// executeScript 성공 값만 strict JSON bytes로 만든다. fallback `String(describing:)`은 허용하지 않는다.
    static func encodeScriptResult(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject([value]), !containsRejectedNumber(value) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: [], debugDescription: "executeScript result is not JSON-serializable")
            )
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    private static func containsRejectedNumber(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return false }
            let d = number.doubleValue
            return !d.isFinite || (d == 0 && d.sign == .minus)
        }
        if let values = value as? [Any] { return values.contains(where: containsRejectedNumber) }
        if let object = value as? [String: Any] { return object.values.contains(where: containsRejectedNumber) }
        return false
    }
}
