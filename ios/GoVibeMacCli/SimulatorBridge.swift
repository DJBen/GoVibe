import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

struct SimInfoPayload: Sendable {
    let deviceName: String
    let udid: String
    let screenWidth: Int
    let screenHeight: Int
    let scale: Double
    let fps: Int
}

/// Captures the iOS Simulator screen via ScreenCaptureKit, encodes frames as H.264,
/// and injects touch/button events via CGEvent.
final class SimulatorBridge: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let logger: Logger
    private let captureQueue = DispatchQueue(label: "dev.govibe.sim.capture", qos: .userInteractive)

    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    private var isCapturing = false
    private var isEncoding = false
    private var forceNextKeyframe = false

    private var simPID: pid_t = 0
    private var windowBounds: CGRect = .zero
    private var screenWidth: Int = 390
    private var screenHeight: Int = 844
    private var simUDID: String = ""
    private var simName: String = ""

    var onSimInfo: ((SimInfoPayload) -> Void)?
    var onBinaryFrame: ((Data) -> Void)?

    init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - Simulator Discovery

    func findBootedSimulator() -> (udid: String, name: String)? {
        guard let output = runProcess("/usr/bin/xcrun", args: ["simctl", "list", "devices", "--json"]),
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: Any] else { return nil }

        for (_, deviceList) in devices {
            guard let list = deviceList as? [[String: Any]] else { continue }
            for device in list {
                if let state = device["state"] as? String, state == "Booted",
                   let udid = device["udid"] as? String,
                   let name = device["name"] as? String {
                    return (udid: udid, name: name)
                }
            }
        }
        return nil
    }

    // MARK: - Capture

    /// Finds the booted simulator, starts ScreenCaptureKit capture, and calls onSimInfo.
    /// Must be called from an async context. NSApplication must already be initialized
    /// on the main thread before calling this (done in main.swift).
    func startCapture() async {
        guard !isCapturing else {
            logger.info("startCapture() skipped — already capturing")
            return
        }
        logger.info("startCapture() — checking screen recording permission")

        guard CGPreflightScreenCaptureAccess() else {
            logger.error("Screen recording permission denied. Grant access in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch.")
            CGRequestScreenCaptureAccess()
            return
        }

        logger.info("startCapture() — finding booted simulator")
        guard let simDevice = findBootedSimulator() else {
            logger.error("No booted simulator found. Boot a simulator in Xcode first.")
            return
        }
        simUDID = simDevice.udid
        simName = simDevice.name
        logger.info("Found simulator: \(simDevice.name) (\(simDevice.udid))")

        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.iphonesimulator"
        ).first {
            simPID = app.processIdentifier
            logger.info("Simulator PID: \(simPID)")
        } else {
            logger.error("Simulator.app process not found — is the Simulator running?")
            return
        }

        logger.info("startCapture() — enumerating shareable content")
        let content: SCShareableContent
        do {
            // onScreenWindowsOnly:false also picks up minimized / off-screen windows
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            logger.error("SCShareableContent failed: \(error.localizedDescription)")
            return
        }
        logger.info("SCShareableContent returned \(content.windows.count) windows")

        let simWindow = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator"
        })
        guard let simWindow else {
            let bundleIds = content.windows.compactMap { $0.owningApplication?.bundleIdentifier }
            logger.error("Simulator window not found. Visible app bundle IDs: \(bundleIds.joined(separator: ", "))")
            return
        }
        logger.info("Found simulator window: \(simWindow.frame)")

        windowBounds = simWindow.frame
        screenWidth = max(Int(simWindow.frame.width), 1)
        screenHeight = max(Int(simWindow.frame.height), 1)

        do {
            try setupEncoder(width: screenWidth, height: screenHeight)
        } catch {
            logger.error("Encoder setup failed: \(error)")
            return
        }

        let config = SCStreamConfiguration()
        config.width = screenWidth
        config.height = screenHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let filter = SCContentFilter(desktopIndependentWindow: simWindow)
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)

        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            logger.error("addStreamOutput failed: \(error)")
            return
        }

        do {
            try await newStream.startCapture()
        } catch {
            logger.error("startCapture failed: \(error)")
            return
        }

        stream = newStream
        isCapturing = true
        logger.info("Simulator capture started: \(screenWidth)x\(screenHeight)")

        onSimInfo?(SimInfoPayload(
            deviceName: simName,
            udid: simUDID,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            scale: 1.0,
            fps: 30
        ))
    }

    func stopCapture() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        isCapturing = false
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    // MARK: - Encoder Setup

    private func setupEncoder(width: Int, height: Int) throws {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { outputRef, _, status, _, sampleBuffer in
                guard let outputRef, status == noErr, let sampleBuffer else { return }
                Unmanaged<SimulatorBridge>.fromOpaque(outputRef).takeUnretainedValue()
                    .handleEncodedFrame(sampleBuffer: sampleBuffer)
            },
            refcon: refcon,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw NSError(domain: "SimulatorBridge", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed: \(status)"])
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: 1_500_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)

        compressionSession = session
        logger.info("H.264 encoder ready (\(width)x\(height))")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard !isEncoding else { return }
        guard let compressionSession else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        isEncoding = true

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        var frameProperties: CFDictionary?
        if forceNextKeyframe {
            forceNextKeyframe = false
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("SCStream stopped: \(error.localizedDescription)")
        isCapturing = false
    }

    // MARK: - Encoded Frame Handler

    private func handleEncodedFrame(sampleBuffer: CMSampleBuffer) {
        defer { captureQueue.async { self.isEncoding = false } }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let isNotSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isIDR = !isNotSync

        if isIDR, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if let paramFrame = buildParameterSetFrame(from: formatDesc) {
                onBinaryFrame?(paramFrame)
            }
        }

        let totalLen = CMBlockBufferGetDataLength(dataBuffer)
        var sliceData = Data(count: totalLen)
        let copyStatus = sliceData.withUnsafeMutableBytes { rawBuf -> OSStatus in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalLen,
                                       destination: rawBuf.baseAddress!)
            return noErr
        }
        if copyStatus == noErr, !sliceData.isEmpty {
            onBinaryFrame?(buildFrame(type: 0x02, payload: sliceData))
        }
    }

    private func buildParameterSetFrame(from formatDesc: CMVideoFormatDescription) -> Data? {
        var spsPtr: UnsafePointer<UInt8>?
        var spsLen = 0
        var ppsPtr: UnsafePointer<UInt8>?
        var ppsLen = 0

        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsLen,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        ) == noErr,
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsLen,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        ) == noErr,
        let spsPtr, spsLen > 0, let ppsPtr, ppsLen > 0 else { return nil }

        var payload = Data()
        var spsLenBE = UInt32(spsLen).bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &spsLenBE) { Array($0) })
        payload.append(spsPtr, count: spsLen)
        var ppsLenBE = UInt32(ppsLen).bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &ppsLenBE) { Array($0) })
        payload.append(ppsPtr, count: ppsLen)
        return buildFrame(type: 0x01, payload: payload)
    }

    private func buildFrame(type: UInt8, payload: Data) -> Data {
        var frame = Data(count: 5 + payload.count)
        frame[0] = type
        var lenBE = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lenBE) { frame.replaceSubrange(1..<5, with: $0) }
        frame.replaceSubrange(5..., with: payload)
        return frame
    }

    // MARK: - Force Keyframe

    func forceKeyframe() {
        forceNextKeyframe = true
    }

    // MARK: - Touch / Button Injection

    func injectTouch(phase: String, x: Double, y: Double) {
        guard simPID > 0, !windowBounds.isEmpty else { return }
        let absX = windowBounds.origin.x + x * windowBounds.width
        let absY = windowBounds.origin.y + y * windowBounds.height
        let point = CGPoint(x: absX, y: absY)

        let eventType: CGEventType
        switch phase {
        case "began":   eventType = .leftMouseDown
        case "moved":   eventType = .leftMouseDragged
        default:        eventType = .leftMouseUp
        }

        if let event = CGEvent(mouseEventSource: nil, mouseType: eventType,
                               mouseCursorPosition: point, mouseButton: .left) {
            event.postToPid(simPID)
        }
    }

    func injectPinch(phase: String, centerX: Double, centerY: Double, scale: Double) {
        guard simPID > 0, !windowBounds.isEmpty else { return }
        let cx = windowBounds.origin.x + centerX * windowBounds.width
        let cy = windowBounds.origin.y + centerY * windowBounds.height
        let offset = max(40.0 * scale, 10.0)

        let point1 = CGPoint(x: cx - offset, y: cy)
        let point2 = CGPoint(x: cx + offset, y: cy)

        let eventType: CGEventType
        switch phase {
        case "began":   eventType = .leftMouseDown
        case "changed": eventType = .leftMouseDragged
        default:        eventType = .leftMouseUp
        }

        let flags = CGEventFlags.maskAlternate
        if let e1 = CGEvent(mouseEventSource: nil, mouseType: eventType,
                            mouseCursorPosition: point1, mouseButton: .left) {
            e1.flags = flags
            e1.postToPid(simPID)
        }
        if let e2 = CGEvent(mouseEventSource: nil, mouseType: eventType,
                            mouseCursorPosition: point2, mouseButton: .left) {
            e2.flags = flags
            e2.postToPid(simPID)
        }
    }

    func injectButton(action: String) {
        guard simPID > 0 else {
            logger.error("injectButton(\(action)) skipped — simPID not set (capture not started?)")
            return
        }
        logger.info("injectButton: \(action) → simPID \(simPID)")

        let keyEvents: (keyCode: CGKeyCode, flags: CGEventFlags)?
        switch action {
        case "home":        keyEvents = (4,   [.maskCommand, .maskShift])
        case "shake":       keyEvents = (6,   [.maskCommand, .maskControl])
        case "lock":        keyEvents = (37,  .maskCommand)
        case "rotateLeft":  keyEvents = (123, .maskCommand)
        case "rotateRight": keyEvents = (124, .maskCommand)
        default:            keyEvents = nil
        }

        guard let (keyCode, flags) = keyEvents else { return }
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.postToPid(simPID)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.postToPid(simPID)
        }
    }

    // MARK: - Helpers

    private func runProcess(_ executable: String, args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
