import AppKit

/// Menu bar icon: shows Linux drives, ejects them, pauses auto-mount, and
/// relays the service's notifications. Runs as the logged-in user.
final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var status = Status()
    private var lastNotice = 0
    private var watcher: DispatchSourceFileSystemObject?
    private var paused: Bool { FileManager.default.fileExists(atPath: Paths.pauseFlag) }

    static func main() {
        // One menu bar icon per user. A second launch (double-click in
        // Applications) just opens the Full Disk Access settings.
        let lock = open(NSTemporaryDirectory() + "ext4-automount-menu.lock", O_CREAT | O_RDWR, 0o600)
        if lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0 {
            NSWorkspace.shared.open(URL(string: Paths.fdaSettings)!)
            return
        }
        let app = NSApplication.shared
        let delegate = MenuApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if let old = try? JSONDecoder().decode(Status.self, from: Data(contentsOf: URL(fileURLWithPath: Paths.status))) {
            lastNotice = old.notice?.id ?? 0   // don't replay an old notification at login
        }
        refresh()
        watch()
    }

    /// Reload when the service rewrites its status file.
    private func watch() {
        let fd = open(Paths.runDir, O_EVTONLY)
        guard fd >= 0 else {   // service not started yet
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.watch() }
            return
        }
        let w = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        w.setEventHandler { [weak self] in self?.refresh() }
        w.setCancelHandler { close(fd) }
        w.resume()
        watcher = w
        refresh()
    }

    private func refresh() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.status)),
           let s = try? JSONDecoder().decode(Status.self, from: data) {
            status = s
        }
        let warn = !status.fullDiskAccess
        let symbol = warn ? "exclamationmark.triangle" : "externaldrive"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Ext4 Automount")
        item.button?.toolTip = warn ? "Ext4 Automount needs Full Disk Access" : "Ext4 Automount"

        if let n = status.notice, n.id > lastNotice {
            lastNotice = n.id
            func quoted(_ s: String) -> String {
                "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            let script = "display notification \(quoted(n.text)) with title \"Ext4 Automount\" subtitle \(quoted(n.title))"
            DispatchQueue.global().async { runTool("/usr/bin/osascript", ["-e", script]) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector? = nil, _ object: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = object
            menu.addItem(i)
            return i
        }
        if !status.fullDiskAccess {
            _ = add("Turn On Full Disk Access…", #selector(openSettings))
            menu.addItem(.separator())
        }
        if status.drives.isEmpty { _ = add("No Linux drives connected") }
        for d in status.drives {
            switch d.state {
            case "mounted": _ = add("Eject \(d.label)", #selector(eject(_:)), d.mountPoint)
            case "mounting": _ = add("\(d.label): mounting…")
            case "waiting": _ = add("\(d.label): waiting for the other drive")
            case "ejected": _ = add("Mount \(d.label)", #selector(mount(_:)), d.device)
            default: _ = add("Retry Mounting \(d.label)", #selector(mount(_:)), d.device)
            }
        }
        menu.addItem(.separator())
        add("Pause Auto-Mount", #selector(togglePause)).state = paused ? .on : .off
        _ = add("Open Log", #selector(openLog))
        menu.addItem(.separator())
        _ = add("Quit", #selector(quit))
    }

    @objc private func openSettings() { NSWorkspace.shared.open(URL(string: Paths.fdaSettings)!) }
    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.log)) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func togglePause() {
        if paused {
            try? FileManager.default.removeItem(atPath: Paths.pauseFlag)
        } else {
            FileManager.default.createFile(atPath: Paths.pauseFlag, contents: nil)
        }
    }

    /// Ask the service to mount an ejected (or failed) drive. Takes a few seconds.
    @objc private func mount(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? String else { return }
        try? device.write(toFile: Paths.mountRequest, atomically: true, encoding: .utf8)
    }

    /// Unmount the volume; the service then ejects the physical disk.
    @objc private func eject(_ sender: NSMenuItem) {
        guard let point = sender.representedObject as? String else { return }
        DispatchQueue.global().async {
            if runTool("/usr/sbin/diskutil", ["unmount", point]).status != 0 {
                runTool("/sbin/umount", [point])
            }
        }
    }
}
