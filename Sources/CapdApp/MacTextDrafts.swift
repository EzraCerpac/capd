import AppKit

@MainActor
protocol MacTextDraftPresentation: AnyObject {
    func show()
    func setSaving(_ saving: Bool)
    func saved()
}

@MainActor
final class MacTextDrafts {
    private var active: [UUID: any MacTextDraftPresentation] = [:]
    private var saving: [UUID: UUID] = [:]
    private let make:
        (String, @escaping @MainActor (String?) -> Void) -> any MacTextDraftPresentation
    private let save: (String, @escaping @MainActor (Bool) -> Void) -> Void

    init(
        make:
            @escaping (String, @escaping @MainActor (String?) -> Void) ->
            any MacTextDraftPresentation = {
                MacTextDraftWindow(text: $0, complete: $1)
            },
        save: @escaping (String, @escaping @MainActor (Bool) -> Void) -> Void
    ) {
        self.make = make
        self.save = save
    }

    func stage(_ text: String) {
        let id = UUID()
        let presentation = make(text) { [weak self] value in
            guard let self, let presentation = self.active[id] else { return }
            guard let value else {
                self.active[id] = nil
                self.saving[id] = nil
                return
            }
            guard self.saving[id] == nil else { return }
            let attempt = UUID()
            self.saving[id] = attempt
            presentation.setSaving(true)
            self.save(value) { [weak self] succeeded in
                guard let self, self.saving[id] == attempt,
                    let presentation = self.active[id]
                else { return }
                self.saving[id] = nil
                if succeeded {
                    self.active[id] = nil
                    presentation.saved()
                } else {
                    presentation.setSaving(false)
                }
            }
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
    private var isSaving = false
    private var saveButton: NSButton?
    private var cancelButton: NSButton?

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
        saveButton = save
        cancelButton = cancel
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

    func setSaving(_ saving: Bool) {
        isSaving = saving
        editor.isEditable = !saving
        saveButton?.isEnabled = !saving
        cancelButton?.isEnabled = !saving
        window?.standardWindowButton(.closeButton)?.isEnabled = !saving
    }

    func saved() {
        complete = nil
        window?.close()
    }

    @objc private func saveDraft() {
        guard !isSaving else { return }
        complete?(editor.string)
    }

    @objc private func cancelDraft() {
        guard !isSaving else { return }
        finish(close: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !isSaving }

    func windowWillClose(_ notification: Notification) { finish(close: false) }

    private func finish(close: Bool) {
        guard let complete else { return }
        self.complete = nil
        if close { window?.close() }
        complete(nil)
    }
}
