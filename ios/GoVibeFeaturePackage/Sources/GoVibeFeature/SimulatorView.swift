#if canImport(UIKit)
import AVFoundation
import SwiftUI
import UIKit

// MARK: - UIScrollView-based representable

enum DragPhase {
    case began
    case changed(dx: Double, dy: Double)
    case ended
}

enum SimulatorInteractionMode {
    case viewport
    case mouse
}

final class DoubleTapDragGestureRecognizer: UIGestureRecognizer {
    private let movementThreshold: CGFloat = 6
    private var trackingSecondTap = false
    private(set) var initialLocation: CGPoint = .zero
    private(set) var didDrag = false

    override func reset() {
        super.reset()
        trackingSecondTap = false
        initialLocation = .zero
        didDrag = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touches.count == 1 else {
            state = .failed
            return
        }
        
        // If it's tapCount 1, we stay in .possible (but don't fail).
        // If it's tapCount 2, we stay in .possible (waiting for drag or release).
        if touch.tapCount > 2 {
            state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return }
        let location = touch.location(in: view)
        
        // We only care about drags that start on the second tap.
        guard touch.tapCount == 2 else { return }
        
        if state == .possible {
            if !trackingSecondTap {
                trackingSecondTap = true
                initialLocation = location
                return
            }
            
            let dx = location.x - initialLocation.x
            let dy = location.y - initialLocation.y
            if hypot(dx, dy) >= movementThreshold {
                didDrag = true
                state = .began
            }
            return
        }
        
        didDrag = true
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else {
            state = .failed
            return
        }
        
        if touch.tapCount == 2 {
            if state == .possible || state == .began || state == .changed {
                state = .ended
            } else {
                state = .failed
            }
        } else if touch.tapCount == 1 {
            // After the first tap ends, we'll wait a very short duration. 
            // If another tap hasn't started by then, we'll fail to let singleTap fire.
            // Standard double-tap timeout is usually 0.3s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if self.state == .possible && !self.trackingSecondTap {
                    self.state = .failed
                }
            }
        } else {
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }
}

// UIScrollView subclass that fires a callback on every layoutSubviews pass.
// This lets the coordinator size the zoom/player views immediately once UIKit
// has given the scroll view real bounds — without waiting for the next SwiftUI
// state change (which would otherwise be the heartbeat, up to 3 s away).
private final class SimScrollView: UIScrollView {
    var onLayoutSubviews: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}

struct SimulatorScrollView: UIViewRepresentable {
    let simInfo: SimInfo
    var interactionMode: SimulatorInteractionMode
    var onDisplayLayer: (AVSampleBufferDisplayLayer) -> Void
    var onCursorMove: (CGPoint) -> Void   // dx/dy relative delta, normalized by view size
    var onTap: (String, Int) -> Void      // button, clickCount; no position (trackpad model)
    var onDrag: (DragPhase) -> Void
    var onScroll: (CGPoint) -> Void
    var onZoomStateChange: (Bool) -> Void
    var onSnapshotCapture: ((@escaping () -> UIImage?) -> Void)?
    var onPendingSnapshot: ((UIImage?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = SimScrollView()
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.isScrollEnabled = false   // enabled only when zoomed
        scrollView.delaysContentTouches = false
        // Disable UIScrollView's built-in pan at 1× so it doesn't compete with our
        // custom pan gesture. scrollViewDidZoom re-enables it when zoomed in.
        scrollView.panGestureRecognizer.isEnabled = false

        // Wire the layoutSubviews callback so the player frame is updated as soon as
        // UIKit sizes the scroll view — not only when SwiftUI state next changes.
        let coordinator = context.coordinator
        (scrollView as? SimScrollView)?.onLayoutSubviews = { [weak coordinator, weak scrollView] in
            guard let coordinator, let scrollView, scrollView.zoomScale == 1.0 else { return }
            coordinator.zoomView?.frame = scrollView.bounds
            scrollView.contentSize = scrollView.bounds.size
            coordinator.layoutPlayerView()
        }

        let zoomView = UIView()
        zoomView.backgroundColor = .black
        scrollView.addSubview(zoomView)
        context.coordinator.zoomView = zoomView
        context.coordinator.scrollView = scrollView

        let playerView = PlayerView()
        zoomView.addSubview(playerView)
        context.coordinator.playerView = playerView
        onDisplayLayer(playerView.displayLayer)
        onSnapshotCapture?({ [weak playerView] in
            // drawHierarchy captures AVSampleBufferDisplayLayer GPU-composited content;
            // layer.render(in:) always produces black for video layers.
            guard let playerView, !playerView.bounds.isEmpty else { return nil }
            let renderer = UIGraphicsImageRenderer(size: playerView.bounds.size)
            return renderer.image { _ in
                playerView.drawHierarchy(in: playerView.bounds, afterScreenUpdates: false)
            }
        })

        // Add tap/pan recognizers to the scrollView itself (not zoomView) so that
        // UIScrollView's touch-interception machinery doesn't swallow them.

        // Single-tap → single-click (requires the double-tap/drag recognizer to fail first)
        let singleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = context.coordinator
        scrollView.addGestureRecognizer(singleTap)

        // 1-finger pan → cursor move (suppressed when zoomed so UIScrollView pans instead)
        let pan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        scrollView.addGestureRecognizer(pan)
        context.coordinator.panGesture = pan

        let rightTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleRightTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        rightTap.delegate = context.coordinator
        scrollView.addGestureRecognizer(rightTap)

        let middleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleMiddleTap(_:)))
        middleTap.numberOfTouchesRequired = 3
        middleTap.delegate = context.coordinator
        scrollView.addGestureRecognizer(middleTap)

        let scrollPan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleScrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        scrollPan.delegate = context.coordinator
        scrollView.addGestureRecognizer(scrollPan)
        context.coordinator.scrollPanGesture = scrollPan

        // Double-tap-and-drag → click-and-drag (mouseDown + mouseDragged + mouseUp)
        let doubleTapDrag = DoubleTapDragGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTapDrag(_:)))
        doubleTapDrag.delegate = context.coordinator
        singleTap.require(toFail: doubleTapDrag)
        scrollView.addGestureRecognizer(doubleTapDrag)
        context.coordinator.doubleTapDragGesture = doubleTapDrag

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if scrollView.zoomScale == 1.0 {
            context.coordinator.zoomView?.frame = scrollView.bounds
            scrollView.contentSize = scrollView.bounds.size
        }
        context.coordinator.layoutPlayerView()
        context.coordinator.applyInteractionMode()
    }

    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        // Eagerly capture before the view is torn down so onDisappear can still use it
        // even if dismantleUIView fires first (mirrors TerminalSurfaceView behavior).
        // Use drawHierarchy — layer.render(in:) always returns black for AVSampleBufferDisplayLayer.
        if let pv = coordinator.playerView, !pv.bounds.isEmpty {
            let renderer = UIGraphicsImageRenderer(size: pv.bounds.size)
            let image = renderer.image { _ in pv.drawHierarchy(in: pv.bounds, afterScreenUpdates: false) }
            coordinator.parent.onPendingSnapshot?(image)
        }
    }

    // MARK: - AVSampleBufferDisplayLayer host

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

        var displayLayer: AVSampleBufferDisplayLayer {
            layer as! AVSampleBufferDisplayLayer  // swiftlint:disable:this force_cast
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            displayLayer.videoGravity = .resizeAspect
            backgroundColor = .black
        }

        required init?(coder: NSCoder) { fatalError() }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: SimulatorScrollView
        weak var zoomView: UIView?
        weak var playerView: PlayerView?
        weak var scrollView: UIScrollView?
        weak var panGesture: UIPanGestureRecognizer?
        weak var scrollPanGesture: UIPanGestureRecognizer?
        weak var doubleTapDragGesture: DoubleTapDragGestureRecognizer?
        private var lastDragLocation: CGPoint?

        init(_ parent: SimulatorScrollView) { self.parent = parent }

        private var isZoomed: Bool { (scrollView?.zoomScale ?? 1.0) > 1.0 }
        private var isMouseInteractionEnabled: Bool { !isZoomed || parent.interactionMode == .mouse }
        private var isViewportPanningEnabled: Bool { isZoomed && parent.interactionMode == .viewport }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Center zoomView in the viewport when content is smaller than viewport
            let offsetX = max((scrollView.bounds.width  - scrollView.contentSize.width)  / 2, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
            zoomView?.center = CGPoint(
                x: scrollView.contentSize.width  / 2 + offsetX,
                y: scrollView.contentSize.height / 2 + offsetY
            )
            applyInteractionMode()
            parent.onZoomStateChange(isZoomed)
        }

        func layoutPlayerView() {
            guard let zv = zoomView, let pv = playerView,
                  zv.bounds.width > 0, zv.bounds.height > 0 else { return }
            let videoSize = CGSize(width: parent.simInfo.screenWidth,
                                   height: parent.simInfo.screenHeight)
            pv.frame = aspectFitRect(videoSize: videoSize, in: zv.bounds.size)
        }

        private func aspectFitRect(videoSize: CGSize, in containerSize: CGSize) -> CGRect {
            guard videoSize.width > 0, videoSize.height > 0,
                  containerSize.width > 0, containerSize.height > 0 else {
                return CGRect(origin: .zero, size: containerSize)
            }
            let scale = min(containerSize.width  / videoSize.width,
                            containerSize.height / videoSize.height)
            let w = videoSize.width  * scale
            let h = videoSize.height * scale
            return CGRect(x: (containerSize.width  - w) / 2,
                          y: (containerSize.height - h) / 2,
                          width: w, height: h)
        }

        // MARK: Gesture handlers

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            parent.onTap("left", 1)
        }

        @objc func handleRightTap(_ recognizer: UITapGestureRecognizer) {
            parent.onTap("right", 1)
        }

        @objc func handleMiddleTap(_ recognizer: UITapGestureRecognizer) {
            parent.onTap("middle", 1)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            // Only fire on .changed — taps have no .changed events so they won't
            // accidentally move the cursor before the tap recognizer fires.
            guard recognizer.state == .changed else { return }
            guard let sv = scrollView else { return }
            let translation = recognizer.translation(in: sv)
            recognizer.setTranslation(.zero, in: sv)
            guard let delta = SimulatorGestureMath.normalizedTranslation(translation, in: sv.bounds) else { return }
            // Send relative delta normalized by view size (trackpad model)
            parent.onCursorMove(delta)
        }

        @objc func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .changed else { return }
            guard let sv = scrollView else { return }
            let translation = recognizer.translation(in: sv)
            recognizer.setTranslation(.zero, in: sv)
            guard let delta = SimulatorGestureMath.normalizedTranslation(translation, in: sv.bounds) else { return }
            parent.onScroll(delta)
        }

        @objc func handleDoubleTapDrag(_ recognizer: DoubleTapDragGestureRecognizer) {
            guard let sv = scrollView else { return }
            let location = recognizer.location(in: sv)
            switch recognizer.state {
            case .began:
                lastDragLocation = recognizer.initialLocation
                // ONLY send .began if we have actually moved enough to be a drag.
                // The recognizer already does the movementThreshold check before moving to .began.
                parent.onDrag(.began)
                if let delta = SimulatorGestureMath.normalizedDelta(
                    from: recognizer.initialLocation,
                    to: location,
                    in: sv.bounds
                ), delta != .zero {
                    parent.onDrag(.changed(dx: delta.x, dy: delta.y))
                    lastDragLocation = location
                }
            case .changed:
                guard let lastDragLocation else {
                    self.lastDragLocation = location
                    return
                }
                guard let delta = SimulatorGestureMath.normalizedDelta(from: lastDragLocation, to: location, in: sv.bounds) else { return }
                parent.onDrag(.changed(dx: delta.x, dy: delta.y))
                self.lastDragLocation = location
            case .ended:
                if !recognizer.didDrag {
                    // This was just a second tap without drag — it's a double-click.
                    parent.onTap("left", 2)
                    lastDragLocation = nil
                    return
                }
                // Drag ended
                lastDragLocation = nil
                parent.onDrag(.ended)
            case .cancelled, .failed:
                lastDragLocation = nil
                if recognizer.didDrag {
                    parent.onDrag(.ended)
                }
            default:
                break
            }
        }

        func applyInteractionMode() {
            guard let scrollView else { return }
            scrollView.isScrollEnabled = isViewportPanningEnabled
            scrollView.panGestureRecognizer.isEnabled = isViewportPanningEnabled
            panGesture?.isEnabled = isMouseInteractionEnabled
            scrollPanGesture?.isEnabled = isMouseInteractionEnabled
            parent.onZoomStateChange(isZoomed)
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === panGesture || gestureRecognizer === scrollPanGesture ||
                gestureRecognizer === doubleTapDragGesture {
                return isMouseInteractionEnabled
            }
            if gestureRecognizer is UITapGestureRecognizer {
                return isMouseInteractionEnabled
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === doubleTapDragGesture && otherGestureRecognizer === panGesture {
                return true
            }
            if gestureRecognizer === panGesture && otherGestureRecognizer === doubleTapDragGesture {
                return true
            }
            return false
        }
    }
}

// MARK: - SimulatorView

struct SimulatorView: View {
    @Bindable var viewModel: SessionViewModel
    @State private var interactionMode: SimulatorInteractionMode = .viewport
    @State private var isZoomed = false
    @State private var showInteractionModeHint = !GoVibeBootstrap.hasSeenSimulatorInteractionModeHint

    var body: some View {
        if let simInfo = viewModel.simInfo {
            SimulatorScrollView(
                simInfo: simInfo,
                interactionMode: interactionMode,
                onDisplayLayer: { viewModel.connectDisplayLayer($0) },
                onCursorMove:   { viewModel.sendSimCursorMoveAsync(dx: $0.x, dy: $0.y) },
                onTap:          { viewModel.sendSimClickAsync(button: $0, clickCount: $1) },
                onDrag: { phase in
                    switch phase {
                    case .began:                       viewModel.sendSimDragBeginAsync()
                    case .changed(let dx, let dy):     viewModel.sendSimDragMoveAsync(dx: dx, dy: dy)
                    case .ended:                       viewModel.sendSimDragEndAsync()
                    }
                },
                onScroll:       { viewModel.sendSimScrollAsync(dx: $0.x, dy: $0.y) },
                onZoomStateChange: { zoomed in
                    let wasZoomed = isZoomed
                    isZoomed = zoomed
                    if zoomed && !wasZoomed {
                        interactionMode = .viewport
                    } else if !zoomed {
                        interactionMode = .viewport
                    }
                },
                onSnapshotCapture: { capturer in viewModel.captureSnapshot = capturer },
                onPendingSnapshot: { image in viewModel.pendingSnapshotImage = image }
            )
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if isZoomed {
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            interactionMode = interactionMode == .viewport ? .mouse : .viewport
                        } label: {
                            Image(systemName: interactionMode == .viewport
                                  ? "arrow.up.and.down.and.arrow.left.and.right"
                                  : "cursorarrow")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .accessibilityIdentifier("simulator_interaction_mode_toggle")

                        if showInteractionModeHint {
                            HStack(alignment: .center, spacing: 12) {
                                Text("Toggle between viewport control and mouse control.")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Button("OK") {
                                    GoVibeBootstrap.hasSeenSimulatorInteractionModeHint = true
                                    showInteractionModeHint = false
                                }
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08))
                            }
                            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                            .accessibilityIdentifier("simulator_interaction_mode_hint")
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 48) // Avoid overlap with top-right floating controls
                    .padding(.top, 20)
                }
            }
            .accessibilityIdentifier("simulator_view")
        } else {
            Color.black
                .ignoresSafeArea()
                .accessibilityIdentifier("simulator_view")
        }
    }
}

#endif
