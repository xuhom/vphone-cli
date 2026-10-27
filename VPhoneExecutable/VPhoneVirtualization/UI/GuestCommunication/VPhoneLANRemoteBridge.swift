import Foundation

/// Runs the LAN bridge as a child of the selected VM process. The bridge only
/// receives a loopback API token and this VM's directory; it never boots or
/// stops another machine.
@MainActor
final class VPhoneLANRemoteBridge {
    private var process: Process?
    private var logHandle: FileHandle?
    private let stateDirectory: URL

    init(machineDirectory: URL) throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        stateDirectory = support.appendingPathComponent("VPhone Remote", isDirectory: true)
            .appendingPathComponent(machineDirectory.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
    }

    var isRunning: Bool { process?.isRunning == true }

    func start(machine: String, directory: URL, upstream: URL, token: String) async throws {
        guard !isRunning else { return }
        let bundle = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = bundle.appendingPathComponent("Contents/MacOS/vphone-remote-bridge")
        let helper = bundle.appendingPathComponent("Contents/Helpers/VPhoneRemoteAudio.app/Contents/MacOS/vphone-remote-audio")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(domain: "VPhoneLANRemoteBridge", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bundled LAN bridge is missing: \(executable.path)",
            ])
        }
        let profile = stateDirectory.appendingPathComponent("pairing.json")
        try? FileManager.default.removeItem(at: profile)
        let log = stateDirectory.appendingPathComponent("bridge.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        try output.truncate(atOffset: 0)
        logHandle = output
        let child = Process()
        child.executableURL = executable
        child.arguments = [
            "--machine", machine,
            "--upstream", upstream.absoluteString,
            "--state", stateDirectory.path,
            "--guest-directory", directory.path,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--audio-helper", helper.path,
            "--port", "58888",
        ]
        child.environment = ProcessInfo.processInfo.environment.merging([
            "VPHONE_UPSTREAM_TOKEN": token,
        ]) { _, new in new }
        child.standardOutput = output
        child.standardError = output
        child.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.process === finished else { return }
                self.process = nil
                self.logHandle?.closeFile()
                self.logHandle = nil
                try? FileManager.default.removeItem(at: profile)
                self.onStop?()
            }
        }
        try child.run()
        process = child
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: profile.path) { return }
            if !child.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        stop()
        let diagnostic = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        throw NSError(domain: "VPhoneLANRemoteBridge", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "LAN bridge did not start. \(diagnostic.suffix(1200))",
        ])
    }

    var onStop: (() -> Void)?

    func pairingJSON() throws -> String {
        guard isRunning else {
            throw NSError(domain: "VPhoneLANRemoteBridge", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "LAN Remote is stopped.",
            ])
        }
        return try String(contentsOf: stateDirectory.appendingPathComponent("pairing.json"), encoding: .utf8)
    }

    func stop() {
        let child = process
        process = nil
        if child?.isRunning == true { child?.terminate() }
        logHandle?.closeFile()
        logHandle = nil
        try? FileManager.default.removeItem(at: stateDirectory.appendingPathComponent("pairing.json"))
    }
}
