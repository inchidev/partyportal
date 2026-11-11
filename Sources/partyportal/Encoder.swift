// Hardware H.264 through VideoToolbox, tuned for low latency: no B-frames, real-time rate control.
// Output is AVCC (length-prefixed NAL units) plus an avcC record, which is what WebCodecs takes as `description`.

import CoreMedia
import Foundation
import VideoToolbox

final class H264Encoder {
    /// codec string, avcC, width, height. Called before the first frame that uses it.
    var onConfig: ((String, Data, Int, Int) -> Void)?
    /// AVCC access unit, keyframe flag, timestamp in microseconds.
    var onFrame: ((Data, Bool, Int64) -> Void)?

    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var kbps: Int
    private var fps: Int
    private var lastConfig = Data()
    private let configLock = NSLock()

    init(kbps: Int, fps: Int) {
        self.kbps = kbps
        self.fps = fps
    }

    deinit { invalidate() }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    /// Send the codec config again with the next keyframe (a new viewer has joined).
    func announceConfig() {
        configLock.lock()
        lastConfig = Data()
        configLock.unlock()
    }

    func update(kbps: Int, fps: Int) {
        self.kbps = kbps
        self.fps = fps
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: kbps * 1000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
    }

    private func create(_ w: Int, _ h: Int) -> Bool {
        invalidate()
        var s: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!] as CFDictionary
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatency,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        if status != noErr || s == nil {
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        guard status == noErr, let s else { return false }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: kbps * 1000))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 10))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 10))
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        width = w
        height = h
        announceConfig()
        return true
    }

    /// Call from one queue only.
    func encode(_ pb: CVPixelBuffer, pts: CMTime, forceKey: Bool) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var force = forceKey
        if session == nil || w != width || h != height {
            guard create(w, h) else { return }
            force = true
        }
        guard let session else { return }
        let props = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, _, sample in
            guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else { return }
            self?.emit(sample, w, h)
        }
    }

    private func emit(_ sample: CMSampleBuffer, _ w: Int, _ h: Int) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if isKey, let format = CMSampleBufferGetFormatDescription(sample), let (codec, avcC) = Self.avcConfig(format) {
            configLock.lock()
            let changed = avcC != lastConfig
            lastConfig = avcC
            configLock.unlock()
            if changed { onConfig?(codec, avcC, w, h) }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == kCMBlockBufferNoErr else { return }
        let micros = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1_000_000)
        onFrame?(data, isKey, micros)
    }

    private static func avcConfig(_ format: CMFormatDescription) -> (String, Data)? {
        func parameterSet(_ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer, size > 3 || index == 1 else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = parameterSet(0), let pps = parameterSet(1), sps.count >= 4 else { return nil }
        var avcC = Data([1, sps[1], sps[2], sps[3], 0xFF, 0xE1, UInt8(sps.count >> 8), UInt8(sps.count & 0xff)])
        avcC.append(sps)
        avcC.append(contentsOf: [1, UInt8(pps.count >> 8), UInt8(pps.count & 0xff)])
        avcC.append(pps)
        let codec = String(format: "avc1.%02x%02x%02x", sps[1], sps[2], sps[3])
        return (codec, avcC)
    }
}
