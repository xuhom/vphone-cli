import Foundation
import Testing
@testable import VPhoneCoreKit

struct DuoPostureTests {
    @Test(arguments: VPhoneDuoPosture.allCases)
    func `a dynamic posture survives a new session`(posture: VPhoneDuoPosture) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(VPhoneDuoPosture.load(in: directory) == nil)
        try posture.save(in: directory)
        #expect(VPhoneDuoPosture.load(in: directory) == posture)
        try VPhoneDuoPosture.closed.save(in: directory)
        #expect(VPhoneDuoPosture.load(in: directory) == .closed)
    }

    @Test func `legacy records load and invalid records cannot select an unsafe pose`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("display-posture.plist")
        for (value, expected) in [("open", VPhoneDuoPosture.open), ("book", .book)] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["position": value], format: .xml, options: 0)
            try data.write(to: file)
            #expect(VPhoneDuoPosture.load(in: directory) == expected)
        }
        try Data("damaged".utf8).write(to: file)
        #expect(VPhoneDuoPosture.load(in: directory) == nil)
        let invalid = try PropertyListSerialization.data(fromPropertyList: ["position": "inner"], format: .binary, options: 0)
        try invalid.write(to: file)
        #expect(VPhoneDuoPosture.load(in: directory) == nil)
    }
}
