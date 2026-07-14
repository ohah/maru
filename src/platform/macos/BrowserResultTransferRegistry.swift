import Foundation
import CoreFoundation

enum BrowserPageScriptResult {
    case json(Data)
    case tooLarge(observedAtLeast: Int)
    case scriptError(Data)
}

/// executeScript JSON bytes의 Swift-side 안정 소유자. 모든 호출은 main actor에서 일어나며 raw pointer는 copy 호출의
/// `withUnsafeBytes` 범위 밖으로 절대 나가지 않는다. ID는 process lifetime 동안 재사용하지 않는다.
@MainActor
final class BrowserResultTransferRegistry {
    static let shared = BrowserResultTransferRegistry()
    nonisolated static let defaultMaxEntries = 8
    nonisolated static let defaultMaxEntryBytes = 16 * 1024 * 1024
    nonisolated static let defaultMaxTotalBytes = 256 * 1024 * 1024
    nonisolated static let maxCopyBytes = 512 * 1024
    nonisolated static let maxSerializationDepth = 128
    nonisolated static let maxSerializationNodes = 1_000_000
    nonisolated static let maxScriptErrorPayloadBytes = 24 * 1024

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

    nonisolated static let pageRunnerName = "__maruBoundedScriptV1"

    /// browser WKWebView가 문서 script보다 먼저 page world에 설치한다. serializer가 쓰는 intrinsic을 이 시점의 closure에
    /// 고정하고 non-writable/non-configurable runner만 노출해, 한 executeScript가 prototype을 오염해도 다음 요청의 byte
    /// accounting과 fidelity가 변하지 않게 한다.
    nonisolated static let boundedPageBootstrapScript: String = {
        """
        (() => {
          'use strict';
          const root = globalThis, runnerName = '\(pageRunnerName)';
          if (typeof root[runnerName] === 'function') return;
          const objectDefineProperty = Object.defineProperty, depthLimit = \(maxSerializationDepth), nodeLimit = \(maxSerializationNodes);
          const pageEval = eval, arrayIsArray = Array.isArray, objectKeys = Object.keys, numberIsFinite = Number.isFinite, objectIs = Object.is, stringFrom = String, typeError = TypeError, weakSetCtor = WeakSet;
          const call = Function.prototype.call, bind = Function.prototype.bind;
          const numberToString = call.bind(Number.prototype.toString), charCodeAt = call.bind(String.prototype.charCodeAt);
          const stringSlice = call.bind(String.prototype.slice), arrayJoin = call.bind(Array.prototype.join), bindTo = call.bind(bind);
          const weakSetHas = WeakSet.prototype.has, weakSetAdd = WeakSet.prototype.add, weakSetDelete = WeakSet.prototype.delete;
          const arrayPush = Array.prototype.push, arrayJoinMethod = Array.prototype.join;
          const run = (source, limit) => {
          const seen = new weakSetCtor(), out = [];
          const seenHas = bindTo(weakSetHas, seen), seenAdd = bindTo(weakSetAdd, seen), seenDelete = bindTo(weakSetDelete, seen);
          const outPush = bindTo(arrayPush, out), outJoin = bindTo(arrayJoinMethod, out);
          let bytes = 0, nodes = 0, pending = '';
          const TOO_LARGE = {}, SERIALIZATION = {};
          const flush = () => { if (pending.length) { outPush(pending); pending = ''; } };
          const put = (text, count) => {
            if (bytes + count > limit) throw TOO_LARGE;
            pending += text; bytes += count;
            if (pending.length >= 8192) flush();
          };
          const hex = (n, width) => { let s = numberToString(n, 16); while (s.length < width) s = '0' + s; return s; };
          const quoted = (text) => {
            put('"', 1);
            for (let i = 0; i < text.length; i++) {
              const c = charCodeAt(text, i);
              if (c === 34) { put('\\\\"', 2); continue; }
              if (c === 92) { put('\\\\\\\\', 2); continue; }
              if (c === 8) { put('\\\\b', 2); continue; }
              if (c === 9) { put('\\\\t', 2); continue; }
              if (c === 10) { put('\\\\n', 2); continue; }
              if (c === 12) { put('\\\\f', 2); continue; }
              if (c === 13) { put('\\\\r', 2); continue; }
              if (c < 32) { put('\\\\u00' + hex(c, 2), 6); continue; }
              if (c >= 0xD800 && c <= 0xDBFF) {
                const d = i + 1 < text.length ? charCodeAt(text, i + 1) : 0;
                if (d >= 0xDC00 && d <= 0xDFFF) { put(stringSlice(text, i, i + 2), 4); i++; continue; }
                put('\\\\u' + hex(c, 4), 6); continue;
              }
              if (c >= 0xDC00 && c <= 0xDFFF) { put('\\\\u' + hex(c, 4), 6); continue; }
              put(text[i], c < 0x80 ? 1 : (c < 0x800 ? 2 : 3));
            }
            put('"', 1);
          };
          const escapedDiagnostic = (value, cap) => {
            let text;
            try { text = stringFrom(value); } catch (_) { return {json:'"<unavailable>"', bytes:15, truncated:true}; }
            const parts = ['"']; let used = 2, truncated = false;
            const append = (fragment, count) => {
              if (used + count > cap) { truncated = true; return false; }
              parts[parts.length] = fragment; used += count; return true;
            };
            for (let i = 0; i < text.length; i++) {
              const c = charCodeAt(text, i); let fragment, count;
              if (c === 34) { fragment = '\\\\"'; count = 2; }
              else if (c === 92) { fragment = '\\\\\\\\'; count = 2; }
              else if (c === 8) { fragment = '\\\\b'; count = 2; }
              else if (c === 9) { fragment = '\\\\t'; count = 2; }
              else if (c === 10) { fragment = '\\\\n'; count = 2; }
              else if (c === 12) { fragment = '\\\\f'; count = 2; }
              else if (c === 13) { fragment = '\\\\r'; count = 2; }
              else if (c < 32) { fragment = '\\\\u00' + hex(c, 2); count = 6; }
              else if (c >= 0xD800 && c <= 0xDBFF) {
                const d = i + 1 < text.length ? charCodeAt(text, i + 1) : 0;
                if (d >= 0xDC00 && d <= 0xDFFF) { fragment = stringSlice(text, i, i + 2); count = 4; i++; }
                else { fragment = '\\\\u' + hex(c, 4); count = 6; }
              } else if (c >= 0xDC00 && c <= 0xDFFF) { fragment = '\\\\u' + hex(c, 4); count = 6; }
              else { fragment = text[i]; count = c < 0x80 ? 1 : (c < 0x800 ? 2 : 3); }
              if (!append(fragment, count)) break;
            }
            parts[parts.length] = '"';
            return {json: arrayJoin(parts, ''), bytes: used, truncated};
          };
          const diagnostic = (error, kind) => {
            let name = '<unavailable>', message = '<unavailable>', stack = '';
            try { name = error && error.name !== undefined ? error.name : 'Error'; } catch (_) {}
            try { message = error && error.message !== undefined ? error.message : error; } catch (_) {}
            try { stack = error && error.stack !== undefined ? error.stack : ''; } catch (_) {}
            const n = escapedDiagnostic(name, 258), m = escapedDiagnostic(message, 16386);
            const p0 = '{"kind":"' + kind + '","name":', p1 = ',"message":', p2 = ',"stack":';
            const fixed = p0 + n.json + p1 + m.json + p2;
            const fixedBytes = p0.length + n.bytes + p1.length + m.bytes + p2.length;
            const available = \(maxScriptErrorPayloadBytes) - fixedBytes - 40, remaining = available > 2 ? available : 2;
            const s = escapedDiagnostic(stack, remaining), truncated = n.truncated || m.truncated || s.truncated;
            return fixed + s.json + ',"diagnostics_truncated":' + (truncated ? 'true' : 'false') + '}';
          };
          const write = (value, depth) => {
            if (++nodes > nodeLimit || depth > depthLimit) throw SERIALIZATION;
            if (value === null || value === undefined) { put('null', 4); return; }
            const kind = typeof value;
            if (kind === 'boolean') { put(value ? 'true' : 'false', value ? 4 : 5); return; }
            if (kind === 'string') { quoted(value); return; }
            if (kind === 'number') {
              if (!numberIsFinite(value) || objectIs(value, -0)) throw SERIALIZATION;
              const text = '' + value; put(text, text.length); return;
            }
            if (kind !== 'object' || seenHas(value)) throw SERIALIZATION;
            seenAdd(value);
            try {
              if (arrayIsArray(value)) {
                put('[', 1);
                for (let i = 0; i < value.length; i++) { if (i) put(',', 1); write(value[i], depth + 1); }
                put(']', 1);
              } else {
                const keys = objectKeys(value); put('{', 1);
                for (let i = 0; i < keys.length; i++) { if (i) put(',', 1); quoted(keys[i]); put(':', 1); write(value[keys[i]], depth + 1); }
                put('}', 1);
              }
            } finally { seenDelete(value); }
          };
          let value;
          try { value = pageEval(source); } catch (error) { return 'maru-script-error:' + diagnostic(error, 'execution'); }
          try { write(value, 0); flush(); return 'maru-json:' + outJoin(''); }
          catch (error) {
            if (error === TOO_LARGE) return 'maru-too-large:' + (limit + 1);
            return 'maru-script-error:' + diagnostic(error === SERIALIZATION ? new typeError('result is not strict JSON') : error, 'serialization');
          }
          };
          objectDefineProperty(root, runnerName, {value:run, writable:false, configurable:false, enumerable:false});
        })()
        """
    }()

    /// `evaluateJavaScript`가 raw object graph를 host로 materialize하기 전에 document-start runner를 호출한다.
    /// 결과 prefix는 host가 작은 terminal과 성공 JSON을 구분하기 위한 private backend 계약이다.
    nonisolated static func boundedPageScript(_ script: String, maxBytes: Int) throws -> String {
        let literalData = try JSONSerialization.data(withJSONObject: script, options: [.fragmentsAllowed])
        let literal = String(decoding: literalData, as: UTF8.self)
        return "\(pageRunnerName)(\(literal),\(maxBytes))"
    }

    nonisolated static func decodeBoundedPageResult(_ text: String, maxBytes: Int) -> BrowserPageScriptResult {
        guard maxBytes > 0, maxBytes <= defaultMaxEntryBytes else {
            return .scriptError(nativeScriptErrorPayload(NSError(domain: "Maru.Browser", code: 3)))
        }
        if text.hasPrefix("maru-json:") {
            let payload = text.dropFirst("maru-json:".count)
            guard payload.utf8.count <= maxBytes else { return .tooLarge(observedAtLeast: maxBytes + 1) }
            return .json(Data(payload.utf8))
        }
        if text.hasPrefix("maru-too-large:"), let n = Int(text.dropFirst("maru-too-large:".count)), n == maxBytes + 1 {
            return .tooLarge(observedAtLeast: n)
        }
        if text.hasPrefix("maru-script-error:") {
            let payload = text.dropFirst("maru-script-error:".count)
            if payload.utf8.count <= maxScriptErrorPayloadBytes { return .scriptError(Data(payload.utf8)) }
        }
        return .scriptError(nativeScriptErrorPayload(NSError(domain: "Maru.Browser", code: 2)))
    }

    nonisolated static func nativeScriptErrorPayload(_ error: Error) -> Data {
        let ns = error as NSError
        let name = "\(ns.domain)(\(ns.code))"
        let message = ns.localizedDescription
        func clipped(_ value: String, maxBytes: Int) -> (String, Bool) {
            var bytes = 0
            var result = ""
            for scalar in value.unicodeScalars {
                let count: Int
                switch scalar.value {
                case 0 ..< 0x20: count = 6
                case 0x22, 0x5C: count = 2
                default: count = String(scalar).utf8.count
                }
                if bytes + count > maxBytes { return (result, true) }
                bytes += count
                result.unicodeScalars.append(scalar)
            }
            return (result, false)
        }
        let n = clipped(name, maxBytes: 256)
        let m = clipped(message, maxBytes: 16 * 1024)
        let object: [String: Any] = [
            "kind": "execution", "name": n.0, "message": m.0, "stack": "",
            "diagnostics_truncated": n.1 || m.1,
        ]
        let fallback = Data("{\"kind\":\"execution\",\"name\":\"Error\",\"message\":\"WebKit error\",\"stack\":\"\",\"diagnostics_truncated\":true}".utf8)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count <= maxScriptErrorPayloadBytes else { return fallback }
        return data
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
