import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

public struct SimInfoPayload: Sendable {
    public let deviceName: String
    public let udid: String
    public let screenWidth: Int
    public let screenHeight: Int
    public let scale: Double
    public let fps: Int

    public init(deviceName: String, udid: String, screenWidth: Int, screenHeight: Int, scale: Double, fps: Int) {
        self.deviceName = deviceName
        self.udid = udid
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.scale = scale
        self.fps = fps
    }
}

public final class SimulatorBridge: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let logger: HostLogger
    private let captureQueue = DispatchQueue(label: "dev.govibe.sim.capture", qos: .userInteractive)

    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    private var isCapturing = false
    private var isEncoding = false
    private var forceNextKeyframe = false

    private var simPID: pid_t = 0
    private var windowBounds: CGRect = .zero
    private var currentCursorPoint: CGPoint?
    private var screenWidth: Int = 390
    private var screenHeight: Int = 844
    private var simUDID: String = ""
    private var simName: String = ""
    private var needsWindowDisambiguation = true

    public var onSimInfo: ((SimInfoPayload) -> Void)?
    public var onBinaryFrame: ((Data) -> Void)?

    public init(logger: HostLogger) {
        self.logger = logger
    }

    public static func bootedSimulators() -> [BootedSimulatorDevice] {
        guard let output = runProcess("/usr/bin/xcrun", args: ["simctl", "list", "devices", "--json"]),
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: Any] else { return [] }

        var results: [BootedSimulatorDevice] = []
        for (_, deviceList) in devices {
            guard let list = deviceList as? [[String: Any]] else { continue }
            for device in list {
                if let state = device["state"] as? String, state == "Booted",
                   let udid = device["udid"] as? String,
                   let name = device["name"] as? String {
                    results.append(BootedSimulatorDevice(udid: udid, name: name))
                }
            }
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func findBootedSimulator(preferredUDID: String? = nil) -> (udid: String, name: String)? {
        let booted = Self.bootedSimulators()
        if let preferredUDID, let preferred = booted.first(where: { $0.udid == preferredUDID }) {
            return (preferred.udid, preferred.name)
        }
        guard let first = booted.first else { return nil }
        return (first.udid, first.name)
    }

    public func startCapture(preferredUDID: String? = nil) async {
        guard !isCapturing else {
            logger.info("startCapture() skipped — already capturing")
            return
        }
        logger.info("startCapture() — checking screen recording permission")

        if !AXIsProcessTrusted() {
            logger.error("Accessibility not granted — click injection will fail.")
        }

        guard CGPreflightScreenCaptureAccess() else {
            logger.error("Screen recording permission denied.")
            CGRequestScreenCaptureAccess()
            return
        }

        logger.info("startCapture() — finding booted simulator")
        guard let simDevice = findBootedSimulator(preferredUDID: preferredUDID) else {
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

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            logger.error("SCShareableContent failed: \(error.localizedDescription)")
            return
        }

        let selectedWindow = selectSimulatorWindow(
            from: content.windows,
            simulatorPID: simPID,
            preferredUDID: simUDID,
            simulatorName: simName
        )
        guard let selectedWindow else {
            logger.error("Simulator window not found.")
            return
        }
        let simWindow = selectedWindow.window
        needsWindowDisambiguation = selectedWindow.candidateCount > 1
        logger.info("Simulator window disambiguation needed: \(needsWindowDisambiguation) (candidates=\(selectedWindow.candidateCount))")
        logger.info("Found simulator window: id=\(simWindow.windowID) title=\(simWindow.title ?? "<untitled>") frame=\(simWindow.frame)")

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

    public func stopCapture() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        isCapturing = false
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    public func activateSimulator() {
        guard simPID > 0, let app = NSRunningApplication(processIdentifier: simPID) else { return }
        if #available(macOS 14.0, *) {
            _ = app.activate()
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }

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

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let compressionSession, let imageBuffer = sampleBuffer.imageBuffer else { return }
        guard !isEncoding else { return }
        isEncoding = true

        var frameProperties: CFDictionary?
        if forceNextKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            forceNextKeyframe = false
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Screen capture stopped: \(error.localizedDescription)")
        stopCapture()
    }

    public func injectCursorMove(dx: Double, dy: Double) {
        guard windowBounds.width > 0, windowBounds.height > 0 else { return }
        if currentCursorPoint == nil {
            currentCursorPoint = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        }
        currentCursorPoint!.x = min(max(windowBounds.minX, currentCursorPoint!.x + dx * windowBounds.width), windowBounds.maxX)
        currentCursorPoint!.y = min(max(windowBounds.minY, currentCursorPoint!.y - dy * windowBounds.height), windowBounds.maxY)
        moveMouse(to: currentCursorPoint!)
    }

    public func injectClick(clickCount: Int) {
        guard let point = currentCursorPoint else { return }
        activateSimulator()
        sendMouseClick(at: point, clickCount: clickCount)
    }

    public func injectButton(action: String) {
        guard let keyCode = buttonActionToKeyCode(action) else { return }
        activateSimulator()
        sendKeyPress(keyCode: keyCode)
    }

    public func forceKeyframe() {
        forceNextKeyframe = true
    }

    private func handleEncodedFrame(sampleBuffer: CMSampleBuffer) {
        defer { isEncoding = false }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let dataPointer, length > 0 else { return }

        var encoded = Data(bytes: dataPointer, count: length)
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let attachment = attachments.first {
            let isKeyframe = !(attachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
            if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                encoded = avccWithParameterSets(formatDescription: format) + encoded
            }
        }
        onBinaryFrame?(encoded)
    }

    private func avccWithParameterSets(formatDescription: CMFormatDescription) -> Data {
        var data = Data()
        var parameterSetCount: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0,
                                                           parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil,
                                                           parameterSetCountOut: &parameterSetCount,
                                                           nalUnitHeaderLengthOut: nil)

        for index in 0..<parameterSetCount {
            var parameterSetPointer: UnsafePointer<UInt8>?
            var parameterSetSize: Int = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription,
                                                               parameterSetIndex: index,
                                                               parameterSetPointerOut: &parameterSetPointer,
                                                               parameterSetSizeOut: &parameterSetSize,
                                                               parameterSetCountOut: nil,
                                                               nalUnitHeaderLengthOut: nil)
            if let parameterSetPointer, parameterSetSize > 0 {
                var header = UInt32(parameterSetSize).bigEndian
                data.append(Data(bytes: &header, count: MemoryLayout<UInt32>.size))
                data.append(parameterSetPointer, count: parameterSetSize)
            }
        }
        return data
    }
}

private func runProcess(_ executable: String, args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}

private func selectSimulatorWindow(
    from windows: [SCWindow],
    simulatorPID: pid_t,
    preferredUDID: String,
    simulatorName: String
) -> (window: SCWindow, candidateCount: Int)? {
    let candidates = windows.filter { window in
        guard window.owningApplication?.processID == simulatorPID else { return false }
        let title = window.title?.lowercased() ?? ""
        return title.contains(preferredUDID.lowercased()) || title.contains(simulatorName.lowercased()) || title.contains("simulator")
    }

    if let exact = candidates.first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(preferredUDID) }) {
        return (exact, candidates.count)
    }
    if let named = candidates.first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(simulatorName) }) {
        return (named, candidates.count)
    }
    if let first = candidates.first {
        return (first, candidates.count)
    }
    return nil
}

private func moveMouse(to point: CGPoint) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
    event.post(tap: .cghidEventTap)
}

private func sendMouseClick(at point: CGPoint, clickCount: Int) {
    let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    mouseDown?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
    mouseDown?.post(tap: .cghidEventTap)

    let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    mouseUp?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
    mouseUp?.post(tap: .cghidEventTap)
}

private func buttonActionToKeyCode(_ action: String) -> CGKeyCode? {
    switch action {
    case "home":
        return 115
    case "lock":
        return 145
    case "siri":
        return 160
    default:
        return nil
    }
}

private func sendKeyPress(keyCode: CGKeyCode) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}
