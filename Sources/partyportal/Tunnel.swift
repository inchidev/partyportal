// Public https link through a Cloudflare quick tunnel (no account, random *.trycloudflare.com name).
// Only the guest port is ever exposed; the host panel stays on 127.0.0.1.

import Foundation

final class Tunnel {
    /// The copy inside the app comes first (build-app.sh puts it beside our executable), so a host needs nothing
    /// but the app. A bare binary from `swift build` has none and falls back to Homebrew's.
    static let binary: String? = {
        let bundled = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("cloudflared").path
        return ([bundled].compactMap { $0 } + ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]).first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }()

    private var process: Process?
    private(set) var url: String?
    private(set) var error: String?
    var onChange: () -> Void = {}

    var running: Bool { process?.isRunning ?? false }

    func start(port: UInt16) {
        guard process == nil else { return }
        guard let bin = Self.binary else {
            error = "cloudflared is not installed"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        // An empty config of our own: quick tunnels refuse to start next to the host's ~/.cloudflared/config.yml,
        // and we must never pick up (or touch) their named tunnels.
        let config = (NSTemporaryDirectory() as NSString).appendingPathComponent("partyportal-cloudflared.yml")
        FileManager.default.createFile(atPath: config, contents: Data())
        p.arguments = ["tunnel", "--config", config, "--no-autoupdate", "--url", "http://127.0.0.1:\(port)"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let range = text.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) else { return }
            let found = String(text[range])
            DispatchQueue.main.async {
                self?.url = found
                self?.onChange()
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.process = nil
                self.url = nil
                self.onChange()
            }
        }
        do {
            try p.run()
            process = p
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        onChange()
    }

    func stop() {
        let p = process
        process = nil
        url = nil
        p?.terminate()
        onChange()
    }
}
