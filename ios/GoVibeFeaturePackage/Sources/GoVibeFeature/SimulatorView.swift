#if canImport(UIKit)
import AVFoundation
import SwiftUI
import UIKit

// MARK: - UIScrollView-based representable

struct SimulatorScrollView: UIViewRepresentable {
    let simInfo: SimInfo
    var onDisplayLayer: (AVSampleBufferDisplayLayer) -> Void
    var onCursorMove: (CGPoint) -> Void   // dx/dy relative delta, normalized by view size
    var onTap: (Int) -> Void              // clickCount only; no position (trackpad model)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
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

        let zoomView = UIView()
        zoomView.backgroundColor = .black
        scrollView.addSubview(zoomView)
        context.coordinator.zoomView = zoomView
        context.coordinator.scrollView = scrollView

        let playerView = PlayerView()
        zoomView.addSubview(playerView)
        context.coordinator.playerView = playerView
        onDisplayLayer(playerView.displayLayer)

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
            let w = sv.bounds.width
            let h = sv.bounds.height
            guard w > 0, h > 0 else { return }
            // Send relative delta normalized by view size (trackpad model)
            parent.onCursorMove(CGPoint(x: translation.x / w, y: translation.y / h))
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Suppress cursor-pan when zoomed — UIScrollView's pan takes over
            if gestureRecognizer === panGesture {
                return (scrollView?.zoomScale ?? 1.0) <= 1.0
            }
            return true
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
                onTap:          { viewModel.sendSimClickAsync(clickCount: $0) }
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
