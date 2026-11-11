// Masks are painted on the host before the encoder ever sees the frame,
// so hidden pixels never leave this machine.

import CoreImage
import CoreVideo
import Foundation

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
    private static let context = CIContext()

    /// Unmasked JPEG for the host's own panel.
    static func jpeg(_ pb: CVPixelBuffer, maxWidth: CGFloat = 1280) -> Data? {
        var img = CIImage(cvPixelBuffer: pb)
        let k = min(1, maxWidth / max(1, img.extent.width))
        if k < 1 { img = img.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(of: img, colorSpace: space, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.72])
    }
}
