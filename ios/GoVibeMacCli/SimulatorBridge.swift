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
    private var currentCursorPoint: CGPoint?
    private var screenWidth: Int = 390
    private var screenHeight: Int = 844
    private var simUDID: String = ""
    private var simName: String = ""
    private var needsWindowDisambiguation = true

    var onSimInfo: ((SimInfoPayload) -> Void)?
    var onBinaryFrame: ((Data) -> Void)?

    init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - Simulator Discovery

    func findBootedSimulator(preferredUDID: String? = nil) -> (udid: String, name: String)? {
        guard let output = runProcess("/usr/bin/xcrun", args: ["simctl", "list", "devices", "--json"]),
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: Any] else { return nil }

        var firstBooted: (udid: String, name: String)?
        for (_, deviceList) in devices {
            guard let list = deviceList as? [[String: Any]] else { continue }
            for device in list {
                if let state = device["state"] as? String, state == "Booted",
                   let udid = device["udid"] as? String,
                   let name = device["name"] as? String {
                    if let preferred = preferredUDID, udid == preferred {
                        return (udid: udid, name: name)
                    }
                    if firstBooted == nil {
                        firstBooted = (udid: udid, name: name)
                    }
                }
            }
        }
        return firstBooted
    }

    // MARK: - Capture

    /// Finds the booted simulator, starts ScreenCaptureKit capture, and calls onSimInfo.
    /// Must be called from an async context. NSApplication must already be initialized
    /// on the main thread before calling this (done in main.swift).
    func startCapture(preferredUDID: String? = nil) async {
        guard !isCapturing else {
            logger.info("startCapture() skipped — already capturing")
            return
        }
        logger.info("startCapture() — checking screen recording permission")

        if !AXIsProcessTrusted() {
            logger.error("Accessibility not granted — click injection will fail. Grant in System Settings → Privacy & Security → Accessibility, then relaunch.")
        }

        guard CGPreflightScreenCaptureAccess() else {
            logger.error("Screen recording permission denied. Grant access in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch.")
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

        let selectedWindow = selectSimulatorWindow(
            from: content.windows,
            simulatorPID: simPID,
            preferredUDID: simUDID,
            simulatorName: simName
        )
        guard let selectedWindow else {
            let bundleIds = content.windows.compactMap { $0.owningApplication?.bundleIdentifier }
            logger.error("Simulator window not found. Visible app bundle IDs: \(bundleIds.joined(separator: ", "))")
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

    // MARK: - Cursor / Click / Button Injection

    /// Moves the cursor by a relative delta (trackpad model).
    /// dx/dy are normalized by the iOS view size; scaled to window pixel dimensions on Mac.
    func injectCursorMove(dx: Double, dy: Double) {
        guard simPID > 0, !windowBounds.isEmpty else { return }
        let current = currentCursorPoint ?? CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        let newX = max(windowBounds.minX, min(windowBounds.maxX,
                       current.x + dx * windowBounds.width))
        let newY = max(windowBounds.minY, min(windowBounds.maxY,
                       current.y + dy * windowBounds.height))
        let newPoint = CGPoint(x: newX, y: newY)
        currentCursorPoint = newPoint
        CGWarpMouseCursorPosition(newPoint)
    }

    /// Clicks at the current tracked cursor position (trackpad model — no repositioning).
    func injectClick(clickCount: Int) {
        guard simPID > 0, !windowBounds.isEmpty else { return }
        let point = currentCursorPoint ?? CGPoint(x: windowBounds.midX, y: windowBounds.midY)

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != simPID,
           let app = NSRunningApplication(processIdentifier: simPID) {
            app.activate()
        }

        func sendClick() {
            if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                  mouseCursorPosition: point, mouseButton: .left) {
                down.post(tap: .cghidEventTap)
            }
            if let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                  mouseCursorPosition: point, mouseButton: .left) {
                drag.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                mouseCursorPosition: point, mouseButton: .left) {
                up.post(tap: .cghidEventTap)
            }
        }

        sendClick()
        if clickCount == 2 { sendClick() }
    }

    func injectButton(action: String) {
        guard simPID > 0, !windowBounds.isEmpty else {
            logger.error("injectButton(\(action)) skipped — simulator target not ready (capture not started?)")
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
        if needsWindowDisambiguation {
            focusCapturedSimulatorWindow()
        }
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Helpers

    private func focusCapturedSimulatorWindow() {
        // Keyboard shortcuts in Simulator target the key window, not a UDID, so
        // explicitly focus the captured window before posting key events.
        if let app = NSRunningApplication(processIdentifier: simPID) {
            app.activate()
        }

        let focusPoint = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                              mouseCursorPosition: focusPoint, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                            mouseCursorPosition: focusPoint, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }

        usleep(50_000)
    }

    private func selectSimulatorWindow(
        from windows: [SCWindow],
        simulatorPID: pid_t,
        preferredUDID: String?,
        simulatorName: String
    ) -> (window: SCWindow, candidateCount: Int)? {
        let bundleMatches = windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator"
        }
        guard !bundleMatches.isEmpty else { return nil }

        let pidMatches = bundleMatches.filter {
            $0.owningApplication?.processID == simulatorPID
        }
        let pidFiltered = pidMatches.isEmpty ? bundleMatches : pidMatches

        logger.info("Simulator window candidates: bundle=\(bundleMatches.count), pid=\(pidMatches.count)")
        for window in pidFiltered {
            logger.info("  candidate id=\(window.windowID) pid=\(window.owningApplication?.processID ?? 0) title=\(window.title ?? "<untitled>") frame=\(window.frame)")
        }

        var candidates = pidFiltered
        let normalizedName = simulatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedName.isEmpty {
            let nameMatches = candidates.filter { window in
                (window.title ?? "").localizedCaseInsensitiveContains(normalizedName)
            }
            if !nameMatches.isEmpty {
                logger.info("Filtered candidates by device name '\(normalizedName)': \(nameMatches.count)")
                candidates = nameMatches
            }
        }

        let candidateCount = candidates.count

        if let preferredUDID, let bestByGeometry = selectWindowByPreferredGeometry(candidates, udid: preferredUDID) {
            return (bestByGeometry, candidateCount)
        }

        guard let first = candidates.first else { return nil }
        return (first, candidateCount)
    }

    private func selectWindowByPreferredGeometry(_ windows: [SCWindow], udid: String) -> SCWindow? {
        let preferredCenters = preferredWindowCenters(for: udid)
        guard !preferredCenters.isEmpty else {
            logger.info("No preferred window geometry found for UDID \(udid)")
            return nil
        }

        logger.info("Loaded \(preferredCenters.count) preferred window center(s) for UDID \(udid)")

        let ranked = windows.map { window -> (window: SCWindow, distance: CGFloat) in
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let bestDistance = preferredCenters
                .map { hypot(center.x - $0.x, center.y - $0.y) }
                .min() ?? .greatestFiniteMagnitude
            return (window, bestDistance)
        }
        .sorted { $0.distance < $1.distance }

        if let top = ranked.first {
            logger.info("Geometry-selected simulator window id=\(top.window.windowID) distance=\(String(format: "%.2f", top.distance))")
            return top.window
        }
        return nil
    }

    private func preferredWindowCenters(for udid: String) -> [CGPoint] {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.iphonesimulator.plist")
        guard
            let root = NSDictionary(contentsOf: plistURL) as? [String: Any],
            let devicePreferences = root["DevicePreferences"] as? [String: Any],
            let deviceConfig = devicePreferences[udid] as? [String: Any]
        else {
            return []
        }

        var centers: [CGPoint] = []
        centers += parseWindowCenters(in: deviceConfig["SimulatorWindowGeometry"])
        centers += parseWindowCenters(in: deviceConfig["ExternalWindowGeometry"])
        return centers
    }

    private func parseWindowCenters(in value: Any?) -> [CGPoint] {
        guard let geometries = value as? [String: Any] else { return [] }
        return geometries.values.compactMap { geometry in
            guard let dict = geometry as? [String: Any] else { return nil }
            if let centerString = dict["WindowCenter"] as? String {
                return NSPointFromString(centerString)
            }
            if let centerArray = dict["WindowCenter"] as? [CGFloat], centerArray.count == 2 {
                return CGPoint(x: centerArray[0], y: centerArray[1])
            }
            if let centerArray = dict["WindowCenter"] as? [Double], centerArray.count == 2 {
                return CGPoint(x: centerArray[0], y: centerArray[1])
            }
            return nil
        }
    }

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
