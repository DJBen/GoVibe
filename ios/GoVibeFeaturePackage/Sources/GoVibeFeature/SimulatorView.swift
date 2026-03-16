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

final class DoubleTapDragGestureRecognizer: UIGestureRecognizer {
    private let movementThreshold: CGFloat = 6
    private var trackingSecondTap = false
    private(set) var initialLocation: CGPoint = .zero

    override func reset() {
        super.reset()
        trackingSecondTap = false
        initialLocation = .zero
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let touch = touches.first, touches.count == 1 else {
            state = .failed
            return
        }
        guard touch.tapCount == 2, let view else { return }
        trackingSecondTap = true
        initialLocation = touch.location(in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackingSecondTap, let touch = touches.first, let view else { return }
        let location = touch.location(in: view)
        if state == .possible {
            let dx = location.x - initialLocation.x
            let dy = location.y - initialLocation.y
            if hypot(dx, dy) >= movementThreshold {
                state = .began
            }
            return
        }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackingSecondTap else {
            state = .failed
            return
        }
        if state == .began || state == .changed {
            state = .ended
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
    var onDisplayLayer: (AVSampleBufferDisplayLayer) -> Void
    var onCursorMove: (CGPoint) -> Void   // dx/dy relative delta, normalized by view size
    var onTap: (Int) -> Void              // clickCount only; no position (trackpad model)
    var onDrag: (DragPhase) -> Void
    var onSnapshotCapture: ((@escaping () -> UIImage?) -> Void)?

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
            guard let playerView, !playerView.bounds.isEmpty else { return nil }
            let renderer = UIGraphicsImageRenderer(size: playerView.bounds.size)
            return renderer.image { ctx in
                playerView.layer.render(in: ctx.cgContext)
            }
        })

        // Add tap/pan recognizers to the scrollView itself (not zoomView) so that
        // UIScrollView's touch-interception machinery doesn't swallow them.

        // Double-tap → double-click
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // Single-tap → single-click (requires double-tap to fail first)
        let singleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        // 1-finger pan → cursor move (suppressed when zoomed so UIScrollView pans instead)
        let pan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        scrollView.addGestureRecognizer(pan)
        context.coordinator.panGesture = pan

        // Double-tap-and-drag → click-and-drag (mouseDown + mouseDragged + mouseUp)
        let doubleTapDrag = DoubleTapDragGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTapDrag(_:)))
        doubleTapDrag.delegate = context.coordinator
        doubleTap.require(toFail: doubleTapDrag)
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
        weak var doubleTapDragGesture: DoubleTapDragGestureRecognizer?
        private var lastDragLocation: CGPoint?

        init(_ parent: SimulatorScrollView) { self.parent = parent }

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
            let isZoomed = scrollView.zoomScale > 1.0
            // At 1×: our custom pan handles cursor moves; UIScrollView's pan is off.
            // Zoomed: UIScrollView's pan scrolls the content; our custom pan is off.
            scrollView.isScrollEnabled = isZoomed
            scrollView.panGestureRecognizer.isEnabled = isZoomed
            panGesture?.isEnabled = !isZoomed
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
            parent.onTap(1)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            parent.onTap(2)
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

        @objc func handleDoubleTapDrag(_ recognizer: DoubleTapDragGestureRecognizer) {
            guard let sv = scrollView else { return }
            let location = recognizer.location(in: sv)
            switch recognizer.state {
            case .began:
                lastDragLocation = recognizer.initialLocation
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
            case .ended, .cancelled, .failed:
                lastDragLocation = nil
                parent.onDrag(.ended)
            default:
                break
            }
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Suppress cursor-pan when zoomed — UIScrollView's pan takes over
            if gestureRecognizer === panGesture {
                return (scrollView?.zoomScale ?? 1.0) <= 1.0
            }
            if gestureRecognizer === doubleTapDragGesture {
                return (scrollView?.zoomScale ?? 1.0) <= 1.0
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === doubleTapDragGesture || otherGestureRecognizer === doubleTapDragGesture {
                return false
            }
            return false
        }
    }
}

// MARK: - SimulatorView

struct SimulatorView: View {
    @Bindable var viewModel: SessionViewModel

    var body: some View {
        if let simInfo = viewModel.simInfo {
            SimulatorScrollView(
                simInfo: simInfo,
                onDisplayLayer: { viewModel.connectDisplayLayer($0) },
                onCursorMove:   { viewModel.sendSimCursorMoveAsync(dx: $0.x, dy: $0.y) },
                onTap:          { viewModel.sendSimClickAsync(clickCount: $0) },
                onDrag: { phase in
                    switch phase {
                    case .began:                       viewModel.sendSimDragBeginAsync()
                    case .changed(let dx, let dy):     viewModel.sendSimDragMoveAsync(dx: dx, dy: dy)
                    case .ended:                       viewModel.sendSimDragEndAsync()
                    }
                },
                onSnapshotCapture: { capturer in viewModel.captureSnapshot = capturer }
            )
            .ignoresSafeArea()
            .accessibilityIdentifier("simulator_view")
        } else {
            Color.black
                .ignoresSafeArea()
                .accessibilityIdentifier("simulator_view")
        }
    }
}

#endif
