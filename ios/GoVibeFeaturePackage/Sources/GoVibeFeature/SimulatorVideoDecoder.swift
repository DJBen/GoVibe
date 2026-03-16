#if canImport(UIKit)
import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import UIKit
import VideoToolbox

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

    // MARK: - Thumbnail capture
    // VTDecompressionSession decodes frames to CVPixelBuffer so we can produce a real
    // UIImage snapshot — AVSampleBufferDisplayLayer renders via Metal and produces black
    // images from any layer.render / drawHierarchy call.
    private var thumbSession: VTDecompressionSession?
    // Written from the VT callback (background thread); only read on main actor after
    // VTDecompressionSessionWaitForAsynchronousFrames ensures the write has completed.
    nonisolated(unsafe) private var _lastThumbBuffer: CVPixelBuffer?

    init(onKeyframeRequest: @escaping @MainActor () -> Void) {
        self.onKeyframeRequest = onKeyframeRequest
    }

    func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
        // Discard any format description cached before the display layer was
        // connected.  Non-IDR frames that arrive while waiting for the
        // keyframe response would otherwise pass the `guard let formatDescription`
        // check in handleSlice and get enqueued without a prior IDR, pushing the
        // layer into a .failed state and causing every subsequent IDR to be
        // dropped (flush → request → non-IDR frames → fail → drop IDR → loop).
        formatDescription = nil
        setupTimebase(for: layer)
        // Ask Mac for an IDR frame immediately so the first frame appears
        // without waiting for the next natural keyframe interval.
        print("[SimVideoDecoder] setDisplayLayer called — requesting keyframe")
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

        guard status == noErr, let newFormatDesc else {
            print("[SimVideoDecoder] handleParameterSet: CMVideoFormatDescriptionCreateFromH264ParameterSets FAILED status=\(status)")
            return
        }

        if let existing = formatDescription,
           CMFormatDescriptionEqual(existing, otherFormatDescription: newFormatDesc) {
            return
        }
        print("[SimVideoDecoder] handleParameterSet: new format set, flushing layer (layer=\(displayLayer != nil ? "non-nil" : "nil"))")
        formatDescription = newFormatDesc
        rebuildThumbSession()
        displayLayer?.flush()
    }

    // MARK: - Video Slice

    private func handleSlice(_ data: Data) {
        guard let formatDescription, let displayLayer else {
            print("[SimVideoDecoder] handleSlice: SKIPPED — formatDescription=\(formatDescription != nil ? "set" : "nil"), displayLayer=\(displayLayer != nil ? "non-nil" : "nil")")
            return
        }

        let layerStatus = displayLayer.status

        if layerStatus == .failed {
            print("[SimVideoDecoder] handleSlice: layer .failed — flushing and requesting keyframe")
            displayLayer.flush()
            // Don't return — attempt to enqueue the current frame (which may be
            // the IDR we were waiting for).  If it's a non-IDR the layer will
            // discard it; if it's the IDR it will display.  A fresh keyframe
            // request is sent so we recover even if this frame can't decode.
            onKeyframeRequest()
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
        guard sbStatus == noErr, let sampleBuffer else {
            print("[SimVideoDecoder] handleSlice: CMSampleBufferCreateReady FAILED status=\(sbStatus)")
            return
        }

        displayLayer.enqueue(sampleBuffer)

        // Feed every frame to thumbSession so _lastThumbBuffer always holds a recent
        // decoded pixel buffer. No IDR filtering — that would risk missing all frames
        // if the IDR detection were wrong.
        if let thumbSession {
            let decodeStatus = VTDecompressionSessionDecodeFrame(
                thumbSession, sampleBuffer: sampleBuffer, flags: [],
                frameRefcon: nil, infoFlagsOut: nil)
            if decodeStatus != noErr {
                print("[SimVideoDecoder] handleSlice: VTDecompressionSessionDecodeFrame status=\(decodeStatus)")
            }
        } else {
            print("[SimVideoDecoder] handleSlice: thumbSession nil — no thumbnail decode")
        }
    }

    // MARK: - Thumbnail

    func captureLastFrame() -> UIImage? {
        // Flush any pending async frames before reading the buffer.
        if let s = thumbSession {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
        } else {
            print("[SimVideoDecoder] captureLastFrame: thumbSession is nil")
        }
        guard let pb = _lastThumbBuffer else {
            print("[SimVideoDecoder] captureLastFrame: _lastThumbBuffer is nil — no frames decoded yet")
            return nil
        }
        // Use CIImage → CIContext → CGImage to handle IOSurface-backed buffers and
        // any pixel format VT decides to deliver (ignoring our BGRA request is rare but possible).
        let ci = CIImage(cvPixelBuffer: pb)
        print("[SimVideoDecoder] captureLastFrame: CIImage extent \(Int(ci.extent.width))×\(Int(ci.extent.height))")
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else {
            print("[SimVideoDecoder] captureLastFrame: CIContext.createCGImage failed")
            return nil
        }
        print("[SimVideoDecoder] captureLastFrame: success \(cg.width)×\(cg.height)")
        return UIImage(cgImage: cg)
    }

    private func rebuildThumbSession() {
        if let s = thumbSession { VTDecompressionSessionInvalidate(s) }
        thumbSession = nil
        _lastThumbBuffer = nil
        guard let fmt = formatDescription else { return }
        // Do not force a pixel format — let VT deliver its native format (typically
        // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange on iOS hardware decoders).
        // Forcing BGRA can cause a silent color-conversion failure that produces black frames.
        // CIImage(cvPixelBuffer:) handles YUV natively.
        let cb: VTDecompressionOutputCallback = { refCon, _, status, _, imageBuffer, _, _ in
            guard status == noErr, let pb = imageBuffer, let ptr = refCon else {
                if status != noErr { print("[SimVideoDecoder] thumbSession callback error status=\(status)") }
                return
            }
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let decoder = Unmanaged<SimulatorVideoDecoder>.fromOpaque(ptr).takeUnretainedValue()
            let isFirst = decoder._lastThumbBuffer == nil
            decoder._lastThumbBuffer = pb
            if isFirst { print("[SimVideoDecoder] thumbSession: first frame decoded OK fmt=\(fmt) \(w)×\(h)") }
        }
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: cb,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var session: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: nil, formatDescription: fmt,
            decoderSpecification: nil, imageBufferAttributes: nil,
            outputCallback: &record, decompressionSessionOut: &session)
        print("[SimVideoDecoder] rebuildThumbSession: \(session != nil ? "OK" : "FAILED")")
        thumbSession = session
    }

    // MARK: - Reset

    func reset() {
        formatDescription = nil
        if let s = thumbSession { VTDecompressionSessionInvalidate(s) }
        thumbSession = nil
        _lastThumbBuffer = nil
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
