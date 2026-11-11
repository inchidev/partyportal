// The shared app's sound: 48 kHz stereo float in, Opus packets of 20 ms out.
// WebCodecs' AudioDecoder takes raw Opus packets as they are.

import AVFoundation
import Foundation

final class OpusEncoder {
    static let sampleRate = 48000.0
    static let frame = 960  // 20 ms

    /// Opus packet and its timestamp in microseconds.
    var onPacket: ((Data, Int64) -> Void)?

    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private var left: [Float] = []
    private var right: [Float] = []
    private var packets: Int64 = 0
    private var silentRun = 0

    init?(kbps: Int = 96) {
        var desc = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.frame),
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 2, interleaved: false),
            let opus = AVAudioFormat(streamDescription: &desc), let conv = AVAudioConverter(from: pcm, to: opus)
        else { return nil }
        conv.bitRate = kbps * 1000
        input = pcm
        output = opus
        converter = conv
    }

    /// Call from one queue only.
    func append(_ l: [Float], _ r: [Float]) {
        // Most apps are silent most of the time: after half a second of pure silence stop sending anything.
        let quiet = !l.contains { abs($0) > 1e-5 } && !r.contains { abs($0) > 1e-5 }
        silentRun = quiet ? silentRun + l.count : 0
        if silentRun > 24000 {
            left.removeAll(keepingCapacity: true)
            right.removeAll(keepingCapacity: true)
            return
        }
        left.append(contentsOf: l)
        right.append(contentsOf: r)
        // Never sit on more than a quarter of a second: late sound is worse than a gap.
        if left.count > 12000 {
            left.removeFirst(left.count - Self.frame)
            right.removeFirst(right.count - Self.frame)
        }
        while left.count >= Self.frame, right.count >= Self.frame { encodeFrame() }
    }

    private func encodeFrame() {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(Self.frame)), let channels = pcm.floatChannelData else { return }
        pcm.frameLength = AVAudioFrameCount(Self.frame)
        left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: Self.frame) }
        right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: Self.frame) }
        left.removeFirst(Self.frame)
        right.removeFirst(Self.frame)

        let out = AVAudioCompressedBuffer(format: output, packetCapacity: 4, maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if fed {
                state.pointee = .noDataNow
                return nil
            }
            fed = true
            state.pointee = .haveData
            return pcm
        }
        guard status != .error, out.packetCount > 0 else { return }
        if let descriptions = out.packetDescriptions {
            for i in 0..<Int(out.packetCount) {
                let d = descriptions[i]
                emit(Data(bytes: out.data + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
            }
        } else {
            emit(Data(bytes: out.data, count: Int(out.byteLength)))
        }
    }

    private func emit(_ packet: Data) {
        guard !packet.isEmpty else { return }
        onPacket?(packet, packets * 20_000)
        packets += 1
    }
}

enum AudioSamples {
    /// Left and right channels of a captured audio buffer; nil for anything but 48 kHz float.
    static func planar(_ sb: CMSampleBuffer) -> ([Float], [Float])? {
        guard let desc = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
            let format = AVAudioFormat(streamDescription: asbd), format.commonFormat == .pcmFormatFloat32, format.sampleRate == OpusEncoder.sampleRate
        else { return nil }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr,
            let data = pcm.floatChannelData
        else { return nil }
        let channels = Int(format.channelCount)
        if format.isInterleaved {
            var l = [Float](repeating: 0, count: frames), r = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                l[i] = data[0][i * channels]
                r[i] = data[0][i * channels + (channels > 1 ? 1 : 0)]
            }
            return (l, r)
        }
        let l = Array(UnsafeBufferPointer(start: data[0], count: frames))
        let r = channels > 1 ? Array(UnsafeBufferPointer(start: data[1], count: frames)) : l
        return (l, r)
    }
}
