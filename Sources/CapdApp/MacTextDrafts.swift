import AppKit

@MainActor
protocol MacTextDraftPresentation: AnyObject {
    func show()
}

@MainActor
final class MacTextDrafts {
    private var active: [UUID: any MacTextDraftPresentation] = [:]
    private let make:
        (String, @escaping @MainActor (String?) -> Void) -> any MacTextDraftPresentation
    private let save: (String) -> Void

    init(
        make:
            @escaping (String, @escaping @MainActor (String?) -> Void) ->
            any MacTextDraftPresentation = {
                MacTextDraftWindow(text: $0, complete: $1)
            },
        save: @escaping (String) -> Void
    ) {
        self.make = make
        self.save = save
    }

    func stage(_ text: String) {
        let id = UUID()
        let presentation = make(text) { [weak self] value in
            guard let self, self.active.removeValue(forKey: id) != nil else { return }
            if let value { self.save(value) }
        }
        active[id] = presentation
        presentation.show()
    }
}

@MainActor
private final class MacTextDraftWindow: NSWindowController, NSWindowDelegate,
    MacTextDraftPresentation
{
    private let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 170))
    private var complete: (@MainActor (String?) -> Void)?

    init(text: String, complete: @escaping @MainActor (String?) -> Void) {
        self.complete = complete
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Save text to capd"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let content = NSView()
        panel.contentView = content
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        editor.isRichText = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.string = text
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(
            width: 380, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.autoresizingMask = [.width]
        editor.setAccessibilityLabel("Draft text")
        scroll.documentView = editor
        let save = NSButton(title: "Save", target: self, action: #selector(saveDraft))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelDraft))
        cancel.keyEquivalent = "\u{1b}"
        for view in [scroll, save, cancel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            scroll.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -16),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
        ])
        panel.minSize = NSSize(width: 320, height: 200)
        panel.initialFirstResponder = editor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func saveDraft() { finish(editor.string, close: true) }
    @objc private func cancelDraft() { finish(nil, close: true) }

    func windowWillClose(_ notification: Notification) { finish(nil, close: false) }

    private func finish(_ text: String?, close: Bool) {
        guard let complete else { return }
        self.complete = nil
        if close { window?.close() }
        complete(text)
    }
}
