#if canImport(UIKit)
import AVFoundation
import CoreMedia
import Foundation
import UIKit

/// Decodes H.264 binary frames received from the Mac relay and renders via AVSampleBufferDisplayLayer.
///
/// Binary frame format (5-byte header):
///   [1 byte: type] [4 bytes: payload length, big-endian] [N bytes: payload]
///
/// Type 0x01 — Parameter sets:  [4 bytes: SPS len] [SPS bytes] [4 bytes: PPS len] [PPS bytes]
/// Type 0x02 — Video slice:     AVCC-format NAL units (4-byte length-prefixed)
@MainActor
final class SimulatorVideoDecoder {
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var formatDescription: CMVideoFormatDescription?
    private var timebase: CMTimebase?
    private let onKeyframeRequest: @MainActor () -> Void

    init(onKeyframeRequest: @escaping @MainActor () -> Void) {
        self.onKeyframeRequest = onKeyframeRequest
    }

    func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
        setupTimebase(for: layer)
        // Ask Mac for an IDR frame immediately so the first frame appears
        // without waiting for the next natural keyframe interval.
        onKeyframeRequest()
    }

    private func setupTimebase(for layer: AVSampleBufferDisplayLayer) {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: nil,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        guard let tb else { return }
        CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
        CMTimebaseSetRate(tb, rate: 1.0)
        layer.controlTimebase = tb
        timebase = tb
    }

    // MARK: - Frame Dispatch

    func receiveBinaryFrame(_ data: Data) {
        guard data.count >= 5 else { return }

        let frameType = data[0]
        let payloadLen = Int(data[1]) << 24 | Int(data[2]) << 16 | Int(data[3]) << 8 | Int(data[4])
        guard data.count >= 5 + payloadLen, payloadLen > 0 else { return }

        let payload = data.subdata(in: 5..<(5 + payloadLen))
        switch frameType {
        case 0x01: handleParameterSet(payload)
        case 0x02: handleSlice(payload)
        default:   break
        }
    }

    // MARK: - Parameter Sets (SPS + PPS)

    private func handleParameterSet(_ data: Data) {
        var offset = 0

        guard offset + 4 <= data.count else { return }
        let spsLen = readUInt32BE(data, at: offset)
        offset += 4

        guard offset + spsLen <= data.count else { return }
        let spsData = data.subdata(in: offset..<(offset + spsLen))
        offset += spsLen

        guard offset + 4 <= data.count else { return }
        let ppsLen = readUInt32BE(data, at: offset)
        offset += 4

        guard offset + ppsLen <= data.count else { return }
        let ppsData = data.subdata(in: offset..<(offset + ppsLen))

        var newFormatDesc: CMVideoFormatDescription?
        let status = spsData.withUnsafeBytes { spsBuf in
            ppsData.withUnsafeBytes { ppsBuf in
                var ptrs: [UnsafePointer<UInt8>] = [
                    spsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                var sizes: [Int] = [spsLen, ppsLen]
                return ptrs.withUnsafeMutableBufferPointer { ptrsBuf in
                    sizes.withUnsafeMutableBufferPointer { sizesBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: nil,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrsBuf.baseAddress!,
                            parameterSetSizes: sizesBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newFormatDesc
                        )
                    }
                }
            }
        }

        guard status == noErr, let newFormatDesc else { return }

        if let existing = formatDescription,
           CMFormatDescriptionEqual(existing, otherFormatDescription: newFormatDesc) {
            return
        }
        formatDescription = newFormatDesc
        displayLayer?.flush()
    }

    // MARK: - Video Slice

    private func handleSlice(_ data: Data) {
        guard let formatDescription, let displayLayer else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
            onKeyframeRequest()
            return
        }

        // Create a CMBlockBuffer that owns its memory.
        var blockBuffer: CMBlockBuffer?
        let dataLen = data.count
        var createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: dataLen,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLen,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return }

        createStatus = data.withUnsafeBytes { rawBuf in
            CMBlockBufferReplaceDataBytes(
                with: rawBuf.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataLen
            )
        }
        guard createStatus == kCMBlockBufferNoErr else { return }

        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var size = dataLen
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else { return }

        displayLayer.enqueue(sampleBuffer)
    }

    // MARK: - Reset

    func reset() {
        formatDescription = nil
        displayLayer?.flush()
        onKeyframeRequest()
    }

    // MARK: - Helpers

    private func readUInt32BE(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 |
        Int(data[offset + 2]) << 8 | Int(data[offset + 3])
    }
}
#endif
