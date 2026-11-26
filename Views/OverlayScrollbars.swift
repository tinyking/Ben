import SwiftUI
import AppKit

extension View {
    /// 按需在窗口挂载和文档切换时为所有 NSScrollView 启用悬浮自动隐藏滚动条，无需后台轮询定时器。
    func benOverlayScrollbars<T: Equatable>(trigger: T) -> some View {
        background(OverlayScrollbarProbe(trigger: trigger))
    }
}

struct OverlayScrollbarProbe<T: Equatable>: NSViewRepresentable {
    let trigger: T

    func makeNSView(context: Context) -> ScrollbarStyleProbe {
        let probe = ScrollbarStyleProbe(frame: .zero)
        DispatchQueue.main.async { probe.applyToWindow() }
        return probe
    }

    func updateNSView(_ probe: ScrollbarStyleProbe, context: Context) {
        DispatchQueue.main.async { probe.applyToWindow() }
    }
}

final class ScrollbarStyleProbe: NSView {
    private var windowObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        guard let window else { return }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in self?.applyToWindow() }
        DispatchQueue.main.async { [weak self] in self?.applyToWindow() }
    }

    func applyToWindow() {
        guard let root = window?.contentView else { return }
        Self.applyStyle(in: root)
    }

    private static func applyStyle(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            configureOverlayScrollbars(scrollView)
        }
        view.subviews.forEach(applyStyle(in:))
    }

    static func configureOverlayScrollbars(_ scrollView: NSScrollView) {
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        if !scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = true
        }
    }

    deinit {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }
}
