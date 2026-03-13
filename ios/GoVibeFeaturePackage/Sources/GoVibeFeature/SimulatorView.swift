#if canImport(UIKit)
import AVFoundation
import SwiftUI
import UIKit

// MARK: - AVSampleBufferDisplayLayer host view

final class SimulatorPlayerUIView: UIView {
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

// MARK: - UIViewRepresentable

struct SimulatorPlayerView: UIViewRepresentable {
    let viewModel: SessionViewModel

    func makeUIView(context: Context) -> SimulatorPlayerUIView {
        let view = SimulatorPlayerUIView()
        viewModel.connectDisplayLayer(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: SimulatorPlayerUIView, context: Context) {}
}

// MARK: - Main SimulatorView

struct SimulatorView: View {
    @Bindable var viewModel: SessionViewModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                SimulatorPlayerView(viewModel: viewModel)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .gesture(touchGesture(in: geo.size))
                    .gesture(pinchGesture(in: geo.size))
            }
        }
        .overlay(alignment: .topTrailing) {
            SimulatorQuickActionsMenu { action in
                viewModel.sendSimButtonAsync(action: action)
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .accessibilityIdentifier("simulator_view")
    }

    // MARK: - Gestures

    private func touchGesture(in containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let phase: String
                if value.startLocation == value.location {
                    phase = "began"
                } else {
                    phase = "moved"
                }
                let norm = normalizedPoint(value.location, in: containerSize)
                viewModel.sendSimTouchAsync(phase: phase, x: norm.x, y: norm.y)
            }
            .onEnded { value in
                let norm = normalizedPoint(value.location, in: containerSize)
                viewModel.sendSimTouchAsync(phase: "ended", x: norm.x, y: norm.y)
            }
    }

    private func pinchGesture(in containerSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let norm = normalizedPoint(value.startAnchor.cgPoint(in: containerSize),
                                           in: containerSize)
                viewModel.sendSimPinchAsync(
                    phase: "changed",
                    centerX: norm.x,
                    centerY: norm.y,
                    scale: value.magnification
                )
            }
            .onEnded { value in
                let norm = normalizedPoint(value.startAnchor.cgPoint(in: containerSize),
                                           in: containerSize)
                viewModel.sendSimPinchAsync(
                    phase: "ended",
                    centerX: norm.x,
                    centerY: norm.y,
                    scale: value.magnification
                )
            }
    }

    // MARK: - Coordinate Helpers

    private func normalizedPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard let simInfo = viewModel.simInfo, size.width > 0, size.height > 0 else {
            return point
        }
        let imageRect = aspectFitRect(
            contentSize: CGSize(width: simInfo.screenWidth, height: simInfo.screenHeight),
            in: size
        )
        let nx = ((point.x - imageRect.minX) / imageRect.width).clamped(to: 0...1)
        let ny = ((point.y - imageRect.minY) / imageRect.height).clamped(to: 0...1)
        return CGPoint(x: nx, y: ny)
    }

    private func aspectFitRect(contentSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / contentSize.width,
                        containerSize.height / contentSize.height)
        let w = contentSize.width * scale
        let h = contentSize.height * scale
        return CGRect(x: (containerSize.width - w) / 2,
                      y: (containerSize.height - h) / 2,
                      width: w, height: h)
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension UnitPoint {
    func cgPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}
#endif
