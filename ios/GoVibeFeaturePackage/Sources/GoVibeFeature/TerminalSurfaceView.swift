import Foundation
import SwiftUI
import SwiftTerm
#if canImport(UIKit)
import UIKit
#endif

enum TerminalScrollPageDirection {
    case up
    case down
}

struct TerminalScrollGestureMapper {
    func pageLines(
        for direction: TerminalScrollPageDirection,
        visibleRows: Int,
        previousDirection: TerminalScrollPageDirection?
    ) -> Int {
        let rows = max(1, visibleRows)
        let adjustedRows: Int
        if let previousDirection, previousDirection != direction {
            adjustedRows = max(1, rows - 2)
        } else {
            adjustedRows = rows
        }
        switch direction {
        case .up:
            return -adjustedRows
        case .down:
            return adjustedRows
        }
    }
}

#if canImport(UIKit)
struct TerminalSurfaceView: UIViewRepresentable {
    @Bindable var viewModel: SessionViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.backgroundColor = .black
        terminal.caretViewTracksFocus = false
        terminal.caretColor = .white
        terminal.caretTextColor = .black
        terminal.isScrollEnabled = false
        terminal.showsVerticalScrollIndicator = false
        terminal.showsHorizontalScrollIndicator = false
        terminal.getTerminal().changeHistorySize(0)

        let scrollSwipeUp = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRemoteScrollSwipe(_:)))
        scrollSwipeUp.direction = .up
        scrollSwipeUp.numberOfTouchesRequired = 1
        terminal.addGestureRecognizer(scrollSwipeUp)
        context.coordinator.scrollSwipeUp = scrollSwipeUp

        let scrollSwipeDown = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRemoteScrollSwipe(_:)))
        scrollSwipeDown.direction = .down
        scrollSwipeDown.numberOfTouchesRequired = 1
        terminal.addGestureRecognizer(scrollSwipeDown)
        context.coordinator.scrollSwipeDown = scrollSwipeDown

        DispatchQueue.main.async {
            _ = terminal.becomeFirstResponder()
        }

        viewModel.setTerminalOutputSink { [weak terminal] payload in
            guard let terminal else { return }
            let bytes = [UInt8](payload)
            terminal.feed(byteArray: bytes[...])
        }

        viewModel.setTerminalResetSink { [weak terminal] in
            guard let terminal else { return }
            // ESC c = RIS (Reset to Initial State): clears screen and resets all attributes
            // without changing font/size settings managed by SwiftTerm itself.
            terminal.feed(byteArray: [0x1B, 0x63][...])
        }

        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.handleUpdate(source: uiView, relayConnectTrigger: viewModel.relayConnectTrigger)
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.viewModel?.clearTerminalOutputSink()
        coordinator.viewModel?.clearTerminalResetSink()
    }

    @MainActor final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        weak var viewModel: SessionViewModel?
        weak var terminal: TerminalView?
        var scrollSwipeUp: UISwipeGestureRecognizer?
        var scrollSwipeDown: UISwipeGestureRecognizer?
        private var lastScrollPosition: Double?
        private var lastRelayConnectTrigger: Int = 0
        private var lastSwipeDirection: TerminalScrollPageDirection?
        private var scrollMapper = TerminalScrollGestureMapper()

        init(viewModel: SessionViewModel) {
            self.viewModel = viewModel
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            publishSize(cols: newCols, rows: newRows)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Drop XTWINOPS responses (ESC [ <digits/semicolons> t) that SwiftTerm
            // generates in reply to terminal-size queries embedded in the stream.
            // Forwarding them back through the relay injects them as PTY stdin,
            // causing tmux to echo them as literal text.
            let bytes = Array(data)
            if isXtwinopsResponse(bytes) { return }
            let vm = viewModel
            let payload = Data(data)
            Task { @MainActor in
                vm?.sendInputDataAsync(payload)
            }
        }

        private func isXtwinopsResponse(_ bytes: [UInt8]) -> Bool {
            // ESC [ <one-or-more digits/semicolons> t
            guard bytes.count >= 5,
                  bytes[0] == 0x1B,
                  bytes[1] == 0x5B,
                  bytes.last == 0x74
            else { return false }
            return bytes.dropFirst(2).dropLast().allSatisfy {
                $0 == 0x3B || ($0 >= 0x30 && $0 <= 0x39)  // ';' or '0'–'9'
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {
            lastScrollPosition = position
            anchorViewportToBottom(source)
        }
        func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func handleUpdate(source: TerminalView, relayConnectTrigger: Int) {
            let isNewConnection = relayConnectTrigger != lastRelayConnectTrigger
            lastRelayConnectTrigger = relayConnectTrigger
            publishCurrentSizeIfNeeded(source: source, force: isNewConnection)
        }

        func publishCurrentSizeIfNeeded(source: TerminalView, force: Bool) {
            terminal = source
            let vm = viewModel
            Task { @MainActor in
                let t = source.getTerminal()
                let cols = t.cols
                let rows = t.rows
                if cols > 0, rows > 0 {
                    vm?.sendResizeAsync(cols: cols, rows: rows)
                } else if force, let size = vm?.lastKnownTerminalSize {
                    vm?.sendResizeAsync(cols: size.cols, rows: size.rows)
                }
            }
        }

        private func publishSize(cols: Int, rows: Int) {
            let vm = viewModel
            Task { @MainActor in
                vm?.sendResizeAsync(cols: cols, rows: rows)
            }
        }

        private func anchorViewportToBottom(_ source: TerminalView) {
            let bottom = max(0, source.contentSize.height - source.bounds.height)
            source.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }

        private func sendScroll(_ lines: Int) {
            guard lines != 0 else { return }
            let vm = viewModel
            Task { @MainActor in
                vm?.sendScrollAsync(lines: lines)
            }
        }

        @objc func handleRemoteScrollSwipe(_ gesture: UISwipeGestureRecognizer) {
            guard let terminal else { return }
            let rows = terminal.getTerminal().rows
            let direction: TerminalScrollPageDirection = gesture.direction == .up ? .up : .down
            let lines = scrollMapper.pageLines(
                for: direction,
                visibleRows: rows,
                previousDirection: lastSwipeDirection
            )
            lastSwipeDirection = direction
            sendScroll(lines)
            _ = terminal.becomeFirstResponder()
        }
    }
}
#endif
