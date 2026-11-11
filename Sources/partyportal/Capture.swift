// Frame sources: one real window through ScreenCaptureKit, and a synthetic picture
// (`--fake`) that needs no permissions and has known colours for pixel tests.

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct WindowInfo {
    var id: UInt32
    var title: String
    var app: String
    var bundleId: String
    var pid: Int32
    var frame: CGRect  // points, global, origin top-left

    var appKey: String { bundleId.isEmpty ? app : bundleId }

    var json: [String: Any] {
        ["id": id, "title": title, "app": app, "pid": pid, "w": Int(frame.width), "h": Int(frame.height)]
    }
}

protocol FrameSource: AnyObject {
    /// Called on the video queue with a 4:2:0 bi-planar buffer. The buffer must not be modified.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)? { get set }
    var onStop: ((String) -> Void)? { get set }
    /// The app's sound, 48 kHz, left and right. Called on the source's own audio queue.
    var onAudio: (([Float], [Float]) -> Void)? { get set }
    func stop()
    func resize(points: CGSize)
    func apply(video: VideoSettings)
}

func hostTimeNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

final class WindowCapture: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStop: ((String) -> Void)?
    var onAudio: (([Float], [Float]) -> Void)?

    private let queue: DispatchQueue
    private let audioQueue = DispatchQueue(label: "partyportal.audio", qos: .userInteractive)
    private var stream: SCStream?
    private var video: VideoSettings
    private var points = CGSize.zero
    private var scale: CGFloat = 2
    private var stopped = false

    init(queue: DispatchQueue, video: VideoSettings) {
        self.queue = queue
        self.video = video
    }

    private static func shareable() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    private static func info(_ w: SCWindow) -> WindowInfo {
        WindowInfo(
            id: w.windowID, title: w.title ?? "", app: w.owningApplication?.applicationName ?? "",
            bundleId: w.owningApplication?.bundleIdentifier ?? "", pid: w.owningApplication?.processID ?? 0, frame: w.frame)
    }

    /// Ordinary app windows the host could share (no menu bar items, overlays or our own windows).
    static func list() async throws -> [WindowInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        return try await shareable().windows.filter { w in
            guard w.windowLayer == 0, w.isOnScreen, w.frame.width >= 120, w.frame.height >= 90 else { return false }
            guard let app = w.owningApplication, app.processID != me else { return false }
            return NSRunningApplication(processIdentifier: app.processID)?.activationPolicy == .regular
        }.map(info)
    }

    static func thumbnail(windowID: UInt32, maxWidth: CGFloat = 480) async -> Data? {
        guard let w = try? await shareable().windows.first(where: { $0.windowID == windowID }) else { return nil }
        let cfg = SCStreamConfiguration()
        let k = min(1, maxWidth / max(1, w.frame.width))
        cfg.width = max(2, Int(w.frame.width * k))
        cfg.height = max(2, Int(w.frame.height * k))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: w)
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    func start(windowID: UInt32) async throws -> WindowInfo {
        // Look on every Space: a window in full screen lives on a Space of its own and is "off screen" from here.
        let everywhere = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let w = everywhere.windows.first(where: { $0.windowID == windowID }) else {
            throw PortalError("Window not found: it may have been closed or minimized")
        }
        // Only this window: nothing above, below or beside it ever reaches the encoder.
        let filter = SCContentFilter(desktopIndependentWindow: w)
        points = w.frame.size
        scale = CGFloat(filter.pointPixelScale)
        let s = SCStream(filter: filter, configuration: makeConfig(), delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try? s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)  // no sound is not a reason to fail
        try await s.startCapture()
        stream = s
        return Self.info(w)
    }

    private func makeConfig() -> SCStreamConfiguration {
        var w = points.width * scale
        var h = points.height * scale
        let longest = max(w, h)
        if longest > CGFloat(video.maxDim) {
            let k = CGFloat(video.maxDim) / longest
            w *= k
            h *= k
        }
        let cfg = SCStreamConfiguration()
        cfg.width = max(16, Int(w.rounded()) & ~1)
        cfg.height = max(16, Int(h.rounded()) & ~1)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(5, video.fps)))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 5
        cfg.scalesToFit = true
        cfg.ignoreShadowsSingleWindow = true
        // The sound of the app that owns the window (all of it, not just this window), never our own.
        cfg.capturesAudio = true
        cfg.sampleRate = Int(OpusEncoder.sampleRate)
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        return cfg
    }

    func resize(points new: CGSize) {
        guard new != points, new.width > 1, new.height > 1 else { return }
        points = new
        reconfigure()
    }

    func apply(video new: VideoSettings) {
        guard new != video else { return }
        video = new
        reconfigure()
    }

    private func reconfigure() {
        guard let stream else { return }
        let cfg = makeConfig()
        Task { try? await stream.updateConfiguration(cfg) }
    }

    func stop() {
        stopped = true
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sb.isValid, let onAudio, let (l, r) = AudioSamples.planar(sb) { onAudio(l, r) }
            return
        }
        guard type == .screen, sb.isValid, let pb = sb.imageBuffer else { return }
        if let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
            let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        onFrame?(pb, sb.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if !stopped { onStop?(error.localizedDescription) }
    }
}

/// Synthetic 1280×720 picture: four coloured quadrants, a white "secret" box and a moving bar.
final class FakeSource: FrameSource {
    static let size = CGSize(width: 1280, height: 720)
    /// Known colours (sRGB) for pixel tests: top-left, top-right, bottom-left, bottom-right.
    static let quadrants: [(UInt8, UInt8, UInt8)] = [(200, 40, 40), (40, 160, 60), (40, 80, 200), (220, 180, 40)]
    /// The white box a mask is expected to cover, in window-relative coordinates.
    static let secret = CGRect(x: 0.55, y: 0.10, width: 0.35, height: 0.12)

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStop: ((String) -> Void)?
    var onAudio: (([Float], [Float]) -> Void)?
    /// The test tone: 440 Hz at this amplitude. It goes to the guest only, nothing plays on this Mac.
    static let toneHz = 440.0
    static let toneAmplitude: Float = 0.25

    private var phase = 0.0
    private let noisy = ProcessInfo.processInfo.environment["PP_FAKE_NOISE"] != nil
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var counter = 0
    private var fps: Int

    init(queue: DispatchQueue, video: VideoSettings) {
        self.queue = queue
        fps = ProcessInfo.processInfo.environment["PP_FAKE_FULL_FPS"] != nil ? video.fps : min(30, video.fps)  // full rate only for transport tests
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(Self.size.width), kCVPixelBufferHeightKey: Int(Self.size.height),
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    static var windowInfo: WindowInfo {
        WindowInfo(id: 0, title: "Test picture", app: "PartyPortal (no window)", bundleId: "partyportal.fake", pid: 0, frame: CGRect(origin: .zero, size: size))
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func resize(points: CGSize) {}
    func apply(video: VideoSettings) {}

    private static func ycbcr(_ c: (UInt8, UInt8, UInt8)) -> (UInt8, UInt8, UInt8) {
        let r = Double(c.0) / 255, g = Double(c.1) / 255, b = Double(c.2) / 255
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let cb = (b - y) / 1.8556, cr = (r - y) / 1.5748
        return (UInt8((16 + 219 * y).rounded()), UInt8((128 + 224 * cb).rounded()), UInt8((128 + 224 * cr).rounded()))
    }

    private func tone() {
        guard let onAudio else { return }
        let n = Int(OpusEncoder.sampleRate) / fps
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = Float(sin(phase)) * Self.toneAmplitude
            phase += 2 * .pi * Self.toneHz / OpusEncoder.sampleRate
        }
        phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
        onAudio(samples, samples)
    }

    private func tick() {
        tone()
        guard let pool else { return }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let w = Int(Self.size.width), h = Int(Self.size.height)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else {
            CVPixelBufferUnlockBaseAddress(pb, [])
            return
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let y = yBase.assumingMemoryBound(to: UInt8.self), uv = uvBase.assumingMemoryBound(to: UInt8.self)

        func fill(_ rect: CGRect, _ color: (UInt8, UInt8, UInt8)) {
            let c = Self.ycbcr(color)
            let x0 = max(0, Int(rect.minX)) & ~1, x1 = min(w, Int(rect.maxX)) & ~1
            let y0 = max(0, Int(rect.minY)) & ~1, y1 = min(h, Int(rect.maxY)) & ~1
            guard x1 > x0, y1 > y0 else { return }
            for row in y0..<y1 { memset(y + row * yStride + x0, Int32(c.0), x1 - x0) }
            for row in (y0 / 2)..<(y1 / 2) {
                var p = uv + row * uvStride + x0
                for _ in 0..<((x1 - x0) / 2) {
                    p[0] = c.1
                    p[1] = c.2
                    p += 2
                }
            }
        }

        let hw = CGFloat(w / 2), hh = CGFloat(h / 2)
        fill(CGRect(x: 0, y: 0, width: hw, height: hh), Self.quadrants[0])
        fill(CGRect(x: hw, y: 0, width: hw, height: hh), Self.quadrants[1])
        fill(CGRect(x: 0, y: hh, width: hw, height: hh), Self.quadrants[2])
        fill(CGRect(x: hw, y: hh, width: hw, height: hh), Self.quadrants[3])
        let s = Self.secret
        fill(CGRect(x: s.minX * CGFloat(w), y: s.minY * CGFloat(h), width: s.width * CGFloat(w), height: s.height * CGFloat(h)), (255, 255, 255))
        // Stress mode (PP_FAKE_NOISE=1): a patch of fresh noise every frame, which no encoder can compress,
        // so the stream runs at its full bitrate and the transport can be measured under load.
        if noisy {
            let x0 = w / 20, x1 = w * 9 / 20, y0 = h * 11 / 20, y1 = h * 9 / 10
            for row in y0..<y1 { arc4random_buf(y + row * yStride + x0, x1 - x0) }
        }
        // Liveness: a bar crossing the bottom strip every 4 seconds.
        let barX = CGFloat(counter % (fps * 4)) / CGFloat(fps * 4) * CGFloat(w - 16)
        fill(CGRect(x: barX, y: CGFloat(h) * 0.94, width: 16, height: CGFloat(h) * 0.06), (255, 255, 255))
        counter += 1
        CVPixelBufferUnlockBaseAddress(pb, [])

        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        onFrame?(pb, hostTimeNow())
    }
}
