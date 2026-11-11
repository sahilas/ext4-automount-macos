import AppKit
import UserNotifications

/// Menu bar icon: shows Linux drives, mounts and ejects them, changes
/// options, and relays the service's notifications. Runs as the logged-in user.
final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var status = Status()
    private var lastNotice = 0
    private var watcher: DispatchSourceFileSystemObject?
    private var canNotify = false
    private var newerVersion: String?
    private lazy var setup = SetupWindow()
    private var paused: Bool { FileManager.default.fileExists(atPath: Paths.pauseFlag) }
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// The app logo (drive with a plug-in arrow) as a menu bar template image.
    private static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let body = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 1.75, width: 14.5, height: 7.5), xRadius: 2, yRadius: 2)
            body.lineWidth = 1.5
            body.stroke()
            NSBezierPath(ovalIn: NSRect(x: 12, y: 4.5, width: 2, height: 2)).fill()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 9, y: 10.5))
            for (x, y) in [(5.5, 14.0), (7.8, 14.0), (7.8, 17.0), (10.2, 17.0), (10.2, 14.0), (12.5, 14.0)] {
                arrow.line(to: NSPoint(x: x, y: y))
            }
            arrow.close()
            arrow.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ext4 Automount"
        return image
    }()

    static func main() {
        // One menu bar icon per user. A second launch (double-click in
        // Applications) asks the running one to show its setup window.
        let lock = open(NSTemporaryDirectory() + "ext4-automount-menu.lock", O_CREAT | O_RDWR, 0o600)
        if lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0 {
            DistributedNotificationCenter.default().postNotificationName(
                .init("local.ext4-automount.showSetup"), object: nil, deliverImmediately: true)
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
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async { self.canNotify = ok }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showSetup), name: .init("local.ext4-automount.showSetup"), object: nil)
        refresh()
        watch()
        // Give the service a moment to report, then offer setup if it isn't done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if !self.status.fullDiskAccess || Paths.anylinuxfs == nil { self.showSetup() }
        }
        let lastCheck = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - lastCheck > 86_400 { checkForUpdates(quiet: true) }
    }

    // MARK: Status from the service

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
        item.button?.image = MenuApp.glyph
        item.button?.imagePosition = .imageLeading
        item.button?.title = warn ? "!" : ""
        item.button?.toolTip = warn ? "Ext4 Automount needs Full Disk Access" : "Ext4 Automount"
        setup.update(status)

        if let n = status.notice, n.id > lastNotice {
            lastNotice = n.id
            post(n)
        }
    }

    // MARK: Notifications

    private func post(_ n: Notice) {
        guard canNotify else {   // not allowed: fall back to a plain script notification
            func quoted(_ s: String) -> String {
                "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            let script = "display notification \(quoted(n.text)) with title \"Ext4 Automount\" subtitle \(quoted(n.title))"
            DispatchQueue.global().async { runTool("/usr/bin/osascript", ["-e", script]) }
            return
        }
        let c = UNMutableNotificationContent()
        c.title = n.title
        c.body = n.text
        if let path = n.path { c.userInfo = ["path": path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: String(n.id), content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }

    /// Clicking a notification opens the drive, or setup if there is none.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if !status.fullDiskAccess {
            showSetup()
        }
        done()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        @discardableResult
        func add(_ title: String, _ action: Selector? = nil, _ object: Any? = nil, to m: NSMenu = menu) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = object
            m.addItem(i)
            return i
        }
        if !status.fullDiskAccess || Paths.anylinuxfs == nil {
            add("Finish Setup…", #selector(showSetup))
            menu.addItem(.separator())
        }

        if status.drives.isEmpty { add("No Linux drives connected") }
        for d in status.drives {
            switch d.state {
            case "mounted":
                add("Open \(d.label)", #selector(openDrive(_:)), d.mountPoint)
                add("Eject \(d.label)", #selector(eject(_:)), d.mountPoint)
            case "mounting": add("\(d.label): mounting… (the first time can take a minute)")
            case "waiting": add("\(d.label): waiting for the other drive")
            case "ejected": add("Mount \(d.label)", #selector(mount(_:)), d.device)
            case "ignored": add("\(d.label): set to never mount")
            default: add("Retry Mounting \(d.label)", #selector(mount(_:)), d.device)
            }
        }
        menu.addItem(.separator())

        add("Pause Auto-Mount", #selector(togglePause)).state = paused ? .on : .off
        let config = Config.load()
        let options = NSMenu()
        add("Mount Read-Only", #selector(toggleOption(_:)), ["READ_ONLY", !config.readOnly], to: options)
            .state = config.readOnly ? .on : .off
        add("Make All Files Writable for Me", #selector(toggleOption(_:)), ["IGNORE_PERMISSIONS", !config.ignorePermissions], to: options)
            .state = config.ignorePermissions ? .on : .off
        if !status.drives.isEmpty {
            options.addItem(.separator())
            add("Never Mount:", to: options)
            for d in status.drives {
                let ignored = d.state == "ignored"
                add(d.label, #selector(toggleIgnore(_:)), [ignored ? "unignore" : "ignore", d.device], to: options)
                    .state = ignored ? .on : .off
            }
        }
        options.addItem(.separator())
        add("Changes apply the next time a drive mounts", to: options)
        add("Options").submenu = options
        menu.addItem(.separator())

        if let v = newerVersion {
            add("Update Available (\(v))…", #selector(openReleases))
        } else {
            add("Check for Updates…", #selector(checkForUpdatesClicked))
        }
        add("Open Log", #selector(openLog))
        add("Uninstall…", #selector(uninstall))
        menu.addItem(.separator())
        add("Ext4 Automount \(version)")
        add("Quit", #selector(quit))
    }

    @objc private func showSetup() { setup.show(status) }
    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.log)) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openDrive(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    @objc private func togglePause() {
        if paused {
            try? FileManager.default.removeItem(atPath: Paths.pauseFlag)
        } else {
            FileManager.default.createFile(atPath: Paths.pauseFlag, contents: nil)
        }
    }

    // MARK: Requests to the service

    /// Drop a request file for the service (see Daemon.handle(request:)).
    private func request(_ words: String...) {
        let base = Paths.requests + "/" + UUID().uuidString
        guard (try? words.joined(separator: " ").write(toFile: base + ".tmp", atomically: false, encoding: .utf8)) != nil
        else { return }
        rename(base + ".tmp", base + ".req")
    }

    @objc private func mount(_ sender: NSMenuItem) {
        if let device = sender.representedObject as? String { request("mount", device) }
    }

    @objc private func toggleOption(_ sender: NSMenuItem) {
        guard let o = sender.representedObject as? [Any], let key = o[0] as? String, let on = o[1] as? Bool else { return }
        request("set", key, on ? "yes" : "no")
    }

    @objc private func toggleIgnore(_ sender: NSMenuItem) {
        guard let o = sender.representedObject as? [String] else { return }
        request(o[0], o[1])
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

    // MARK: Updates

    @objc private func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(releaseRepo)/releases/latest")!)
    }

    @objc private func checkForUpdatesClicked() { checkForUpdates(quiet: false) }

    /// Ask GitHub for the latest release tag. Sends nothing about this Mac.
    private func checkForUpdates(quiet: Bool) {
        let url = URL(string: "https://api.github.com/repos/\(releaseRepo)/releases/latest")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let tag = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["tag_name"] as? String
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                let latest = tag?.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                let newer = latest.map { $0.compare(self.version, options: .numeric) == .orderedDescending } ?? false
                self.newerVersion = newer ? latest : nil
                if quiet { return }
                let alert = NSAlert()
                if newer {
                    alert.messageText = "Ext4 Automount \(latest!) is available"
                    alert.informativeText = "You have \(self.version)."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                } else {
                    alert.messageText = latest == nil ? "Couldn't check for updates" : "Ext4 Automount is up to date"
                    alert.informativeText = latest == nil ? "Check your internet connection and try again." : "You have \(self.version)."
                }
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn, newer { self.openReleases() }
            }
        }.resume()
    }

    // MARK: Uninstall

    @objc private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Ext4 Automount?"
        alert.informativeText = "Linux drives will no longer mount automatically. Any mounted Linux drive is ejected. anylinuxfs stays installed."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // macOS asks for an administrator password.
        let script = "do shell script quoted form of \"\(Paths.uninstaller)\" with administrator privileges"
        DispatchQueue.global().async {
            let ok = runTool("/usr/bin/osascript", ["-e", script]).status == 0
            DispatchQueue.main.async { if ok { NSApp.terminate(nil) } }
        }
    }
}
