import SwiftUI
import AppKit

/// Native macOS frosted-glass material used behind the dark workspace shell.
struct WindowChrome: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = FrostedWindowView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        DispatchQueue.main.async { [weak view] in
            (view as? FrostedWindowView)?.configureWindow()
        }
    }
}

private final class FrostedWindowView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
        DispatchQueue.main.async { [weak self] in
            self?.configureWindow()
        }
    }

    func configureWindow() {
        guard let window else { return }
        if window.isOpaque { window.isOpaque = false }
        if window.backgroundColor != .clear { window.backgroundColor = .clear }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if window.appearance?.name != .darkAqua {
            window.appearance = NSAppearance(named: .darkAqua)
        }
        if window.toolbar != nil {
            window.toolbar = nil
        }
    }
}

/// Non-vibrant AppKit text field ensuring crisp white input text and placeholder over dark HUD glass.
struct DarkPlainTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var fontSize: CGFloat = 12
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NonVibrantTextField(frame: .zero)
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.appearance = NSAppearance(named: .darkAqua)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyStyling(to: field)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        applyStyling(to: field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = .white
            editor.textColor = NSColor.white.withAlphaComponent(0.92)
            if !editor.hasMarkedText(), field.stringValue != text {
                field.stringValue = text
            }
        } else if field.stringValue != text {
            field.stringValue = text
        }
    }

    private func applyStyling(to field: NSTextField) {
        let font = NSFont.systemFont(ofSize: fontSize)
        field.font = font
        field.textColor = NSColor.white.withAlphaComponent(0.92)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                .font: font
            ]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DarkPlainTextField

        init(_ parent: DarkPlainTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView {
                editor.insertionPointColor = .white
                editor.textColor = NSColor.white.withAlphaComponent(0.92)
                editor.drawsBackground = false
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView {
                editor.insertionPointColor = .white
                editor.textColor = NSColor.white.withAlphaComponent(0.92)
            }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)), let onSubmit = parent.onSubmit {
                parent.text = control.stringValue
                onSubmit()
                return true
            }
            return false
        }
    }
}

private final class NonVibrantTextField: NSTextField {
    override var allowsVibrancy: Bool { false }
}

struct DarkRailView: View {
    @Environment(AppState.self) private var app
    @Binding var showingFolders: Bool
    @Binding var sidebarCollapsed: Bool

    private var isAllNotesActive: Bool {
        !sidebarCollapsed
            && !showingFolders
            && AppState.isSameDirectory(app.currentFolderURL ?? app.vaultStore.vaultURL, app.vaultStore.vaultURL)
    }

    private var isInboxActive: Bool {
        app.editor.currentNote?.lastPathComponent == "00 Inbox.md"
    }

    var body: some View {
        VStack(spacing: 9) {
            railButton("tray.full", title: "所有笔记", isActive: isAllNotesActive) {
                app.currentFolderURL = app.vaultStore.vaultURL
                showingFolders = false
                if sidebarCollapsed {
                    withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed = false }
                }
            }
            railButton("folder", title: "目录", isActive: !sidebarCollapsed && showingFolders) {
                if sidebarCollapsed {
                    showingFolders = true
                    withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed = false }
                } else {
                    showingFolders.toggle()
                }
            }
            railButton("magnifyingglass", title: "全局搜索", isActive: app.activeOverlay == .search) {
                app.presentOverlay(.search)
            }
            railButton("tray.and.arrow.down", title: "Inbox", isActive: isInboxActive) {
                openInbox()
            }
            Spacer()
            railButton("gearshape", title: "设置", isActive: false) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        // 顶部 36pt 已由 MainView 的控制带占据，图标轨从安全区下方开始排列。
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(width: 52)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1)
                .padding(.top, 8)
        }
    }

    private func railButton(_ symbol: String, title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(isActive ? 0.96 : 0.72))
                .frame(width: 34, height: 34)
                .background(.white.opacity(isActive ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func openInbox() {
        if let note = app.vaultStore.allNotes().first(where: { $0.name == "00 Inbox.md" }) {
            app.currentFolderURL = app.vaultStore.vaultURL
            app.selectNote(note.url, preserveFolder: true)
            showingFolders = false
        } else {
            app.quickAppendToInbox("", createIfMissing: true)
            if let note = app.vaultStore.allNotes().first(where: { $0.name == "00 Inbox.md" }) {
                app.selectNote(note.url, preserveFolder: true)
            }
        }
    }
}
