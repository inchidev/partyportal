import Foundation

/// A host-drawn rectangle in window-relative coordinates (0…1, origin top-left).
/// `hide` paints it over before encoding; `block` swallows the guest's clicks inside it.
struct MaskRect: Codable, Equatable {
    var id: String
    var name: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var hide: Bool
    var block: Bool

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct Locks: Codable, Equatable {
    var viewOnly = false
    var keyboard = true
    var titleButtons = true
    var edges = true
    var frameGuard = true
    var autoFocus = true
    /// "list" blocks `blockedShortcuts`, "all" blocks every ⌘ combination, "none" only the system ones.
    var cmdMode = "list"
    var blockedShortcuts = Locks.defaultShortcuts

    static let defaultShortcuts = [
        "Meta+KeyQ", "Meta+KeyW", "Meta+KeyH", "Meta+KeyM", "Meta+KeyN", "Meta+KeyT", "Meta+KeyO",
        "Meta+KeyS", "Meta+KeyP", "Meta+KeyV", "Meta+Comma", "Control+Meta+KeyF",
    ]
}

struct VideoSettings: Codable, Equatable {
    var maxDim = 1920
    var fps = 60
    var kbps = 8000
    var audio = true
    /// Try a direct UDP connection (WebRTC) before falling back to the WebSocket through the tunnel.
    var direct = true
}

/// Background mode: the guest works in the window while the host keeps using the Mac.
struct BackgroundSettings: Codable, Equatable {
    /// Address input to the app that owns the window instead of going through the host's pointer and focus.
    var enabled = false
    /// While shared, keep the window on a software-only monitor so nothing covers it and it keeps drawing.
    var park = true
}

struct Settings: Codable {
    var locks = Locks()
    var video = VideoSettings()
    var background = BackgroundSettings()
    var masksByApp: [String: [MaskRect]] = [:]
}

// Tolerant decoding: a config written by an older build (or a panel that sends fewer fields) keeps
// what it has and takes defaults for the rest, instead of failing as a whole and losing the masks.
extension Locks {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        viewOnly = try c.decodeIfPresent(Bool.self, forKey: .viewOnly) ?? viewOnly
        keyboard = try c.decodeIfPresent(Bool.self, forKey: .keyboard) ?? keyboard
        titleButtons = try c.decodeIfPresent(Bool.self, forKey: .titleButtons) ?? titleButtons
        edges = try c.decodeIfPresent(Bool.self, forKey: .edges) ?? edges
        frameGuard = try c.decodeIfPresent(Bool.self, forKey: .frameGuard) ?? frameGuard
        autoFocus = try c.decodeIfPresent(Bool.self, forKey: .autoFocus) ?? autoFocus
        cmdMode = try c.decodeIfPresent(String.self, forKey: .cmdMode) ?? cmdMode
        blockedShortcuts = try c.decodeIfPresent([String].self, forKey: .blockedShortcuts) ?? blockedShortcuts
    }
}

extension VideoSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxDim = try c.decodeIfPresent(Int.self, forKey: .maxDim) ?? maxDim
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? fps
        kbps = try c.decodeIfPresent(Int.self, forKey: .kbps) ?? kbps
        audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? audio
        direct = try c.decodeIfPresent(Bool.self, forKey: .direct) ?? direct
    }
}

extension BackgroundSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        park = try c.decodeIfPresent(Bool.self, forKey: .park) ?? park
    }
}

extension Settings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decodeIfPresent(BackgroundSettings.self, forKey: .background) ?? background
        locks = try c.decodeIfPresent(Locks.self, forKey: .locks) ?? locks
        video = try c.decodeIfPresent(VideoSettings.self, forKey: .video) ?? video
        masksByApp = try c.decodeIfPresent([String: [MaskRect]].self, forKey: .masksByApp) ?? masksByApp
    }
}

final class ConfigStore {
    let url: URL

    init(path: String?) {
        if let path {
            url = URL(fileURLWithPath: path)
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PartyPortal")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("config.json")
        }
    }

    func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    func save(_ s: Settings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

struct PortalError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Encodable → JSON object, for sending settings to the panel.
func jsonObject<T: Encodable>(_ value: T) -> Any {
    guard let data = try? JSONEncoder().encode(value), let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] as [String: Any] }
    return obj
}

/// JSON object → Decodable, for settings posted by the panel.
func decode<T: Decodable>(_ type: T.Type, from obj: Any?) -> T? {
    guard let obj, JSONSerialization.isValidJSONObject(obj), let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
