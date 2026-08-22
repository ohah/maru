import Carbon.HIToolbox
import Foundation

/// CR6d opt-in smoke만 사용하는 system-global input-source transaction이다.
/// 일반 앱 입력 경로는 이 타입을 호출하지 않는다. 전환 전에 복원 record를 atomic write하고,
/// 복원 시 current가 우리가 선택한 source일 때만 original을 되돌려 사용자 중간 선택을 덮지 않는다.
enum SessionHostInputSourcePolicy {
    static let korean2SetSourceID = "com.apple.inputmethod.Korean.2SetKorean"

    enum PrepareError: Error {
        case currentUnavailable
        case invalidSourceID
        case recordExists
        case recordWriteFailed
        case sourceUnavailable
        case selectionFailed
    }

    enum RestoreOutcome: Equatable {
        case restored
        case noRecord
        case superseded
        case invalidRecord
        case restoreFailed
    }

    private struct RestoreRecord: Codable {
        let version: UInt32
        let original: String
        let selected: String
    }

    static func currentSourceID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    static func prepareKoreanSelection(recordURL: URL) throws -> String {
        guard let original = currentSourceID() else { throw PrepareError.currentUnavailable }
        guard validSourceID(original), validSourceID(korean2SetSourceID) else {
            throw PrepareError.invalidSourceID
        }
        guard !FileManager.default.fileExists(atPath: recordURL.path) else {
            throw PrepareError.recordExists
        }
        let record = RestoreRecord(version: 1, original: original, selected: korean2SetSourceID)
        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: recordURL, options: .atomic)
        } catch {
            throw PrepareError.recordWriteFailed
        }
        guard selectSource(id: korean2SetSourceID), currentSourceID() == korean2SetSourceID else {
            _ = restore(recordURL: recordURL)
            throw PrepareError.selectionFailed
        }
        return original
    }

    static func restore(recordURL: URL) -> RestoreOutcome {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return .noRecord }
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(RestoreRecord.self, from: data),
              record.version == 1,
              validSourceID(record.original), validSourceID(record.selected),
              record.selected == korean2SetSourceID,
              let current = currentSourceID()
        else { return .invalidRecord }

        if current != record.original {
            guard current == record.selected else { return .superseded }
            guard selectSource(id: record.original), currentSourceID() == record.original else {
                return .restoreFailed
            }
        }
        do {
            try FileManager.default.removeItem(at: recordURL)
        } catch {
            return .restoreFailed
        }
        return .restored
    }

    private static func validSourceID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && !id.contains("\n") && !id.contains("\r")
    }

    private static func selectSource(id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as? [TISInputSource],
              sources.count == 1, let source = sources.first else { return false }
        return TISSelectInputSource(source) == noErr
    }
}
