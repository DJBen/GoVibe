import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

public struct AppWindowInfoPayload: Codable, Sendable {
    public let windowTitle: String
    public let appName: String
    public let screenWidth: Int
    public let screenHeight: Int
    public let scale: Double
    public let fps: Int

    public init(windowTitle: String, appName: String, screenWidth: Int, screenHeight: Int, scale: Double, fps: Int) {
        self.windowTitle = windowTitle
        self.appName = appName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.scale = scale
        self.fps = fps
    }
}

public final class AppWindowBridge: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let logger: HostLogger
    private let captureQueue = DispatchQueue(label: "dev.govibe.appwindow.capture", qos: .userInteractive)

    private var stream: SCStream?
    private var compressionSession: VTCompressionSession?
    private var isCapturing = false
    private var isEncoding = false
    private var forceNextKeyframe = false

    private var windowBounds: CGRect = .zero
    private var currentCursorPoint: CGPoint?
    private var isDragging = false
    private var screenWidth: Int = 1280
    private var screenHeight: Int = 800
    private var targetAppPID: pid_t = 0

    private let windowTitle: String
    private let bundleIdentifier: String?

    public var onAppWindowInfo: ((AppWindowInfoPayload) -> Void)?
    public var onBinaryFrame: ((Data) -> Void)?

    public init(windowTitle: String, bundleIdentifier: String?, logger: HostLogger) {
        self.windowTitle = windowTitle
        self.bundleIdentifier = bundleIdentifier
        self.logger = logger
    }

    // MARK: - Window Discovery

    public static func listWindows() async throws -> [AvailableWindow] {
        let content = try await SCShareableContent.current
        let skippedAppNames: Set<String> = [
            "Dock", "Desktop", "Window Server", "Wallpaper", "Control Centre",
            "Control Center", "Notification Center", "SystemUIServer"
        ]
        var results: [AvailableWindow] = []
        for window in content.windows {
            guard let title = window.title, !title.isEmpty else { continue }
            guard let app = window.owningApplication else { continue }
            let appName = app.applicationName
            guard !skippedAppNames.contains(appName) else { continue }
            guard window.frame.width > 50, window.frame.height > 50 else { continue }
            results.append(AvailableWindow(
                id: window.windowID,
                title: title,
                appName: appName,
                bundleIdentifier: app.bundleIdentifier
            ))
        }
        return results.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    // MARK: - Capture

    public func startCapture(relayTransport: RelayTransport) async {
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

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            logger.error("SCShareableContent failed: \(error.localizedDescription)")
            return
        }

        guard let targetWindow = findWindow(in: content.windows) else {
            logger.error("Target window '\(windowTitle)' not found.")
            return
        }

        if let app = targetWindow.owningApplication {
            targetAppPID = pid_t(app.processID)
            logger.info("Target app PID: \(targetAppPID), app: \(app.applicationName)")
        }

        windowBounds = targetWindow.frame
        screenWidth = max(Int(targetWindow.frame.width), 1)
        screenHeight = max(Int(targetWindow.frame.height), 1)
        logger.info("Found window: id=\(targetWindow.windowID) title=\(targetWindow.title ?? "<untitled>") frame=\(targetWindow.frame)")

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

        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
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
        logger.info("App window capture started: \(screenWidth)x\(screenHeight)")

        let appName = targetWindow.owningApplication?.applicationName ?? "Unknown"
        let payload = AppWindowInfoPayload(
            windowTitle: windowTitle,
            appName: appName,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            scale: 1.0,
            fps: 30
        )
        onAppWindowInfo?(payload)
        relayTransport.sendAppWindowInfo(payload)

        self.onBinaryFrame = { data in
            relayTransport.sendBinaryFrame(data)
        }
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

    private func findWindow(in windows: [SCWindow]) -> SCWindow? {
        // Try exact match on title + bundleId
        if let bundleIdentifier {
            if let match = windows.first(where: {
                ($0.title ?? "") == windowTitle &&
                $0.owningApplication?.bundleIdentifier == bundleIdentifier
            }) {
                return match
            }
        }
        // Title exact match
        if let match = windows.first(where: { ($0.title ?? "") == windowTitle }) {
            return match
        }
        // Title contains match
        if let match = windows.first(where: {
            let t = $0.title ?? ""
            return !t.isEmpty && t.localizedCaseInsensitiveContains(windowTitle)
        }) {
            return match
        }
        // BundleId match with any window
        if let bundleIdentifier, let match = windows.first(where: {
            $0.owningApplication?.bundleIdentifier == bundleIdentifier
        }) {
            return match
        }
        return nil
    }

    // MARK: - H.264 Encoder

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
                Unmanaged<AppWindowBridge>.fromOpaque(outputRef).takeUnretainedValue()
                    .handleEncodedFrame(sampleBuffer: sampleBuffer)
            },
            refcon: refcon,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw NSError(domain: "AppWindowBridge", code: Int(status),
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

    // MARK: - Keyframe

    public func forceKeyframe() {
        forceNextKeyframe = true
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
            if let parameterFrame = buildParameterSetFrame(from: formatDesc) {
                onBinaryFrame?(parameterFrame)
            }
        }

        let totalLen = CMBlockBufferGetDataLength(dataBuffer)
        var sliceData = Data(count: totalLen)
        let copyStatus = sliceData.withUnsafeMutableBytes { rawBuf -> OSStatus in
            CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: totalLen,
                destination: rawBuf.baseAddress!
            )
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
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr,
            parameterSetSizeOut: &spsLen,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        ) == noErr,
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPtr,
            parameterSetSizeOut: &ppsLen,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
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

    // MARK: - Input Injection

    public func injectCursorMove(dx: Double, dy: Double) {
        captureQueue.async {
            guard !self.windowBounds.isEmpty else { return }
            let newPoint = self.nextCursorPoint(dx: dx, dy: dy)
            self.currentCursorPoint = newPoint
            CGWarpMouseCursorPosition(newPoint)
        }
    }

    public func injectClick(button: String = "left", clickCount: Int) {
        captureQueue.async { self._injectClick(button: button, clickCount: clickCount) }
    }

    private func _injectClick(button: String, clickCount: Int) {
        guard !windowBounds.isEmpty, targetAppPID > 0 else { return }
        let point = currentCursorPoint ?? CGPoint(x: windowBounds.midX, y: windowBounds.midY)

        CGWarpMouseCursorPosition(point)

        guard let eventSpec = mouseEventSpec(for: button) else { return }

        if let down = CGEvent(mouseEventSource: nil, mouseType: eventSpec.downType,
                              mouseCursorPosition: point, mouseButton: eventSpec.button) {
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            down.postToPid(targetAppPID)
        }
        if let up = CGEvent(mouseEventSource: nil, mouseType: eventSpec.upType,
                            mouseCursorPosition: point, mouseButton: eventSpec.button) {
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            up.postToPid(targetAppPID)
        }
    }

    public func injectScroll(dx: Double, dy: Double) {
        captureQueue.async {
            guard !self.windowBounds.isEmpty, self.targetAppPID > 0 else { return }
            let point = self.currentCursorPoint ?? CGPoint(x: self.windowBounds.midX, y: self.windowBounds.midY)
            self.currentCursorPoint = point
            CGWarpMouseCursorPosition(point)

            let horizontalPixels = self.scrollPixels(for: dx, dimension: self.windowBounds.width)
            let verticalPixels = self.scrollPixels(for: -dy, dimension: self.windowBounds.height)
            guard horizontalPixels != 0 || verticalPixels != 0 else { return }

            if let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(verticalPixels),
                wheel2: Int32(horizontalPixels),
                wheel3: 0
            ) {
                event.postToPid(self.targetAppPID)
            }
        }
    }

    public func injectDragBegin() {
        captureQueue.async {
            guard !self.windowBounds.isEmpty, self.targetAppPID > 0 else { return }
            let point = self.currentCursorPoint ?? CGPoint(x: self.windowBounds.midX, y: self.windowBounds.midY)
            self.isDragging = true
            self.currentCursorPoint = point
            CGWarpMouseCursorPosition(point)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                    mouseCursorPosition: point, mouseButton: .left)?.postToPid(self.targetAppPID)
        }
    }

    public func injectDragMove(dx: Double, dy: Double) {
        captureQueue.async {
            guard self.isDragging, !self.windowBounds.isEmpty, self.targetAppPID > 0 else { return }
            let newPoint = self.nextCursorPoint(dx: dx, dy: dy)
            self.currentCursorPoint = newPoint
            CGWarpMouseCursorPosition(newPoint)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                    mouseCursorPosition: newPoint, mouseButton: .left)?.postToPid(self.targetAppPID)
        }
    }

    public func injectDragEnd() {
        captureQueue.async {
            guard self.isDragging, !self.windowBounds.isEmpty, self.targetAppPID > 0 else { return }
            let point = self.currentCursorPoint ?? CGPoint(x: self.windowBounds.midX, y: self.windowBounds.midY)
            self.isDragging = false
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                    mouseCursorPosition: point, mouseButton: .left)?.postToPid(self.targetAppPID)
        }
    }

    // MARK: - Helpers

    private func nextCursorPoint(dx: Double, dy: Double) -> CGPoint {
        let current = currentCursorPoint ?? CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        let speed = 1.5
        let newX = max(windowBounds.minX, min(windowBounds.maxX, current.x + dx * windowBounds.width * speed))
        let newY = max(windowBounds.minY, min(windowBounds.maxY, current.y + dy * windowBounds.height * speed))
        return CGPoint(x: newX, y: newY)
    }

    private func scrollPixels(for delta: Double, dimension: CGFloat) -> Int {
        let pixels = Int((delta * dimension * 0.75).rounded())
        if pixels == 0, delta != 0 {
            return delta > 0 ? 1 : -1
        }
        return pixels
    }

    private func mouseEventSpec(for button: String) -> (downType: CGEventType, dragType: CGEventType, upType: CGEventType, button: CGMouseButton)? {
        switch button.lowercased() {
        case "left":
            return (.leftMouseDown, .leftMouseDragged, .leftMouseUp, .left)
        case "right":
            return (.rightMouseDown, .rightMouseDragged, .rightMouseUp, .right)
        case "middle":
            return (.otherMouseDown, .otherMouseDragged, .otherMouseUp, .center)
        default:
            return nil
        }
    }
}
