import CoreGraphics
import Foundation

/// The dynamic Duo's three postures. Fixed-inner startup is a separate mode
/// and never overwrites this record, so returning to the outer entry resumes
/// the last dynamic session rather than the fixed-inner test pose.
public enum VPhoneDuoPosture: String, Codable, CaseIterable, Sendable {
    case closed, book, open

    public var angle: Double {
        switch self {
        case .closed: 0
        case .book: 100
        case .open: 180
        }
    }

    /// Final logical panel dimensions, before interface rotation.
    public var panelSize: CGSize {
        self == .closed ? CGSize(width: 466, height: 678) : CGSize(width: 669, height: 951)
    }

    private struct Record: Codable {
        let position: VPhoneDuoPosture
    }

    public static func load(in machineDirectory: URL) -> Self? {
        let url = machineDirectory.appendingPathComponent("display-posture.plist")
        guard let data = try? Data(contentsOf: url),
              let record = try? PropertyListDecoder().decode(Record.self, from: data)
        else { return nil }
        return record.position
    }

    public func save(in machineDirectory: URL) throws {
        let url = machineDirectory.appendingPathComponent("display-posture.plist")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(Record(position: self)).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
    }
}
