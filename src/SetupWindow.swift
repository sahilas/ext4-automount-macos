import AppKit

/// Welcome window: a live checklist of the three things needed before a
/// drive mounts. Each line turns green as it is done.
final class SetupWindow: NSObject {
    private var window: NSWindow?
    private let steps = (0..<3).map { _ in (icon: NSImageView(), title: NSTextField(labelWithString: ""),
                                            detail: NSTextField(wrappingLabelWithString: "")) }
    private let settingsButton = NSButton(title: "Open Full Disk Access Settings…", target: nil, action: nil)

    func show(_ status: Status) {
        if window == nil { build() }
        update(status)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func update(_ status: Status) {
        guard window != nil else { return }
        let installed = Paths.anylinuxfs != nil
        set(0, done: installed, "anylinuxfs is installed",
            installed ? "" : "In Terminal, run:  brew install nohajc/anylinuxfs/anylinuxfs")

        set(1, done: status.fullDiskAccess, "Full Disk Access is on",
            status.fullDiskAccess ? "" : "Turn on the switch next to Ext4 Automount. macOS only lets you do this yourself. If it isn't listed, click + and choose it from Applications.")
        settingsButton.isHidden = status.fullDiskAccess

        let drive = status.drives.first
        let mounted = status.drives.contains { $0.state == "mounted" }
        let detail: String
        switch drive?.state {
        case nil: detail = "Plug in a Linux (ext4) drive. It shows up in Finder within about 10 seconds."
        case "mounted": detail = "\(drive!.label) is in Finder. You're all set."
        case "mounting": detail = "Mounting \(drive!.label)… The first time can take a minute."
        default: detail = "\(drive!.label) is connected. Use the drive icon in the menu bar to mount it."
        }
        set(2, done: mounted, mounted ? "Your drive is mounted" : "Plug in your drive", detail)
    }

    private func set(_ i: Int, done: Bool, _ title: String, _ detail: String) {
        let symbol = done ? "checkmark.circle.fill" : "circle"
        steps[i].icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: done ? "Done" : "To do")
        steps[i].icon.contentTintColor = done ? .systemGreen : .secondaryLabelColor
        steps[i].title.stringValue = title
        steps[i].detail.stringValue = detail
        steps[i].detail.isHidden = detail.isEmpty
    }

    private func build() {
        let heading = NSTextField(labelWithString: "Set up Ext4 Automount")
        heading.font = .boldSystemFont(ofSize: 17)
        let logo = NSImageView(image: NSApp.applicationIconImage)
        logo.widthAnchor.constraint(equalToConstant: 56).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let header = NSStackView(views: [logo, heading])
        header.spacing = 12
        let column = NSStackView(views: [header])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)

        for (i, step) in steps.enumerated() {
            step.icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
            step.icon.setContentHuggingPriority(.required, for: .horizontal)
            step.title.font = .systemFont(ofSize: 13, weight: .medium)
            step.detail.font = .systemFont(ofSize: 12)
            step.detail.textColor = .secondaryLabelColor
            step.detail.preferredMaxLayoutWidth = 360
            let text = NSStackView(views: [step.title, step.detail] + (i == 1 ? [settingsButton] : []))
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 4
            let row = NSStackView(views: [step.icon, text])
            row.alignment = .top
            row.spacing = 10
            column.addArrangedSubview(row)
        }
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)

        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        column.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Ext4 Automount"
        w.isReleasedWhenClosed = false
        w.contentView = column
        column.widthAnchor.constraint(equalToConstant: 440).isActive = true
        window = w
    }

    @objc private func openSettings() { NSWorkspace.shared.open(URL(string: Paths.fdaSettings)!) }
    @objc private func close() { window?.close() }
}
