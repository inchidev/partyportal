// Masks are painted on the host before the encoder ever sees the frame,
// so hidden pixels never leave this machine.

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

final class Masker {
    private var pool: CVPixelBufferPool?
    private var poolKey = ""

    /// Returns a copy of `src` with every rect (window-relative, 0…1) painted over.
    /// Returns nil when the copy cannot be made: the caller must then drop the frame, never send the original.
    func masked(_ src: CVPixelBuffer, rects: [CGRect]) -> CVPixelBuffer? {
        guard CVPixelBufferGetPlaneCount(src) == 2 else { return nil }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let format = CVPixelBufferGetPixelFormatType(src)
        let key = "\(w)x\(h)/\(format)"
        if key != poolKey || pool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h, kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolKey = key
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let dst = out else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        for plane in 0..<2 {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, plane), let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { return nil }
            let sStride = CVPixelBufferGetBytesPerRowOfPlane(src, plane), dStride = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
            let rows = CVPixelBufferGetHeightOfPlane(src, plane)
            if sStride == dStride {
                memcpy(d, s, sStride * rows)
            } else {
                let n = min(sStride, dStride)
                for r in 0..<rows { memcpy(d + r * dStride, s + r * sStride, n) }
            }
        }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(dst, 0), let uvBase = CVPixelBufferGetBaseAddressOfPlane(dst, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(dst, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
        for r in rects {
            // Grow by two pixels and snap to even coordinates so chroma covers the same area as luma.
            let x0 = max(0, Int((r.minX * CGFloat(w)).rounded(.down)) - 2) & ~1
            let x1 = min(w, (Int((r.maxX * CGFloat(w)).rounded(.up)) + 3) & ~1)
            let y0 = max(0, Int((r.minY * CGFloat(h)).rounded(.down)) - 2) & ~1
            let y1 = min(h, (Int((r.maxY * CGFloat(h)).rounded(.up)) + 3) & ~1)
            guard x1 > x0, y1 > y0 else { continue }
            for row in y0..<y1 { memset(yBase + row * yStride + x0, 22, x1 - x0) }
            for row in (y0 / 2)..<(y1 / 2) { memset(uvBase + row * uvStride + x0, 128, x1 - x0) }
        }
        CVBufferPropagateAttachments(src, dst)
        return dst
    }
}

enum Preview {
    /// Its own queue: a slow or stuck picture must never hold the video queue.
    /// (Core Image once deadlocked in here and froze the stream for the guest.)
    private static let queue = DispatchQueue(label: "partyportal.preview", qos: .utility)
    private static let lock = NSLock()
    private static var busy = false

    /// Unmasked JPEG for the host's own panel. Calls back on the preview queue;
    /// nil when there is no picture or the previous request is still running.
    static func jpeg(_ pb: CVPixelBuffer, maxWidth: Int = 1280, _ done: @escaping (Data?) -> Void) {
        lock.lock()
        if busy { lock.unlock(); return done(nil) }
        busy = true
        lock.unlock()
        queue.async {
            let data = render(pb, maxWidth: maxWidth)
            lock.lock(); busy = false; lock.unlock()
            done(data)
        }
    }

    private static func render(_ pb: CVPixelBuffer, maxWidth: Int) -> Data? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0 else { return nil }
        let k = min(1, Double(maxWidth) / Double(w))
        let ow = max(2, Int(Double(w) * k) & ~1), oh = max(2, Int(Double(h) * k) & ~1)
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, ow, oh, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess, let bgra = out else { return nil }
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else { return nil }
        defer { VTPixelTransferSessionInvalidate(session) }
        guard VTPixelTransferSessionTransferImage(session, from: pb, to: bgra) == noErr else { return nil }

        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(bgra), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(bgra), space: space, bitmapInfo: info),
              let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
