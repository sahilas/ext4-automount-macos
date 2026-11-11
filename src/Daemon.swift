import DiskArbitration
import Foundation

/// Root service: mounts external Linux partitions with anylinuxfs when they
/// are plugged in, and ejects the disk after the volume is ejected in Finder.
final class Daemon {
    private typealias User = (name: String, uid: uid_t, gid: gid_t, home: String)

    private let queue = DispatchQueue(label: "ext4-automount")   // owns all state below
    private let session = DASessionCreate(kCFAllocatorDefault)!
    private var status = Status()
    private var waiting: [String] = []            // partitions to mount, in arrival order
    private var active: String?                   // partition being mounted or mounted
    private var uuids: [String: String] = [:]     // listed partition -> filesystem UUID
    private var ejectedAt: [String: Date] = [:]   // filesystem UUID -> when we ejected it
    private var retryTimer: DispatchSourceTimer?
    private var requestWatcher: DispatchSourceFileSystemObject?
    private var askedForAccess = false
    private var noticeID = Int(Date().timeIntervalSince1970)

    private let blkid = ["/opt/homebrew/opt/util-linux/sbin/blkid", "/usr/local/opt/util-linux/sbin/blkid"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private static let onQueue = DispatchSpecificKey<Bool>()
    init() { queue.setSpecific(key: Daemon.onQueue, value: true) }

    func run() -> Never {
        try? FileManager.default.createDirectory(atPath: Paths.requests, withIntermediateDirectories: true)
        chmod(Paths.runDir, 0o755)
        chmod(Paths.requests, 0o1777)   // any user may drop a request; sticky
        log("started")
        queue.sync {
            status.fullDiskAccess = hasFullDiskAccess()
            watchRequests()
            updateRetryTimer()
            publish()
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            Unmanaged<Daemon>.fromOpaque(ctx!).takeUnretainedValue().appeared(disk)
        }, me)
        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            Unmanaged<Daemon>.fromOpaque(ctx!).takeUnretainedValue().disappeared(disk)
        }, me)
        DASessionSetDispatchQueue(session, queue)
        dispatchMain()
    }

    // MARK: Disk events (on queue)

    private func appeared(_ disk: DADisk) {
        guard let name = DADiskGetBSDName(disk).map({ String(cString: $0) }),
              let d = DADiskCopyDescription(disk) as? [String: Any] else { return }
        let isInternal = d[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true
        let isLeaf = d[kDADiskDescriptionMediaLeafKey as String] as? Bool ?? false
        let proto = d[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
        // External partitions (or unpartitioned disks) only; no disk images.
        guard !isInternal, isLeaf, proto != "Virtual Interface" else { return }
        if !waiting.contains(name), active != name { waiting.append(name) }
        processWaiting()
    }

    private func disappeared(_ disk: DADisk) {
        guard let name = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        waiting.removeAll { $0 == name }
        if state(of: name) != "mounted", state(of: name) != "mounting" { list(name, nil) }
        updateRetryTimer()
        publish()
    }

    private func state(of name: String) -> String? {
        status.drives.first { $0.device == name }?.state
    }

    /// Show a partition in the menu with the given state, or remove it (nil).
    private func list(_ name: String, _ state: String?, label: String = "", uuid: String = "", mountPoint: String = "") {
        status.drives.removeAll { $0.device == name }
        uuids[name] = nil
        guard let state else { return }
        status.drives.append(Drive(device: name, label: label, state: state, mountPoint: mountPoint))
        uuids[name] = uuid
    }

    /// Try to mount the next waiting partition. Called on disk events, when a
    /// mount ends, on requests, and from the retry timer while blocked.
    private func processWaiting() {
        defer { updateRetryTimer(); publish() }
        let fda = hasFullDiskAccess()
        status.fullDiskAccess = fda
        if fda { askedForAccess = false }
        guard !waiting.isEmpty else { return }

        if !fda, !askedForAccess {
            askedForAccess = true
            notify("Full Disk Access needed",
                   "Turn on Ext4 Automount in System Settings > Privacy & Security > Full Disk Access.")
        }
        guard fda else { return }
        guard !FileManager.default.fileExists(atPath: Paths.pauseFlag) else { return }
        guard let user = consoleUser() else { return }
        guard let blkid, Paths.anylinuxfs != nil else {
            log("anylinuxfs or blkid not found; install with: brew install nohajc/anylinuxfs/anylinuxfs")
            notify("anylinuxfs is not installed", "Run: brew install nohajc/anylinuxfs/anylinuxfs")
            waiting.removeAll()
            return
        }

        let config = Config.load()
        for name in waiting {
            let info = probe(blkid, name)
            let type = info["TYPE"] ?? ""
            let label = info["LABEL"] ?? name
            let uuid = info["UUID"] ?? name
            var drop = true
            if !config.filesystems.contains(type) {
                // Not a filesystem we handle (exFAT, swap, LUKS, ...): ignore quietly.
            } else if config.ignore.contains(label) || config.ignore.contains(uuid) {
                log("not mounting /dev/\(name) (\(label)): set to never mount")
                list(name, "ignored", label: label, uuid: uuid)
            } else if let t = ejectedAt[uuid], Date().timeIntervalSince(t) < 20 {
                // Some enclosures reconnect by themselves after an eject. Don't
                // remount; leave it for the menu's Mount item.
                log("not mounting /dev/\(name) (\(label)): reappeared right after eject")
                list(name, "ejected", label: label, uuid: uuid)
            } else if active != nil {
                drop = false   // one anylinuxfs mount at a time; keep waiting
                if state(of: name) != "waiting" {
                    list(name, "waiting", label: label, uuid: uuid)
                    notify("\(label) is waiting", "It will mount after the current Linux drive is ejected.")
                }
            } else {
                active = name
                list(name, "mounting", label: label, uuid: uuid)
                log("mounting /dev/\(name) (\(label), \(type)) for \(user.name)")
                DispatchQueue.global().async { self.mountAndWatch(name, label, uuid, config, user) }
            }
            if drop { waiting.removeAll { $0 == name } }
        }
    }

    /// Re-check every 5 s only while something is blocked: no Full Disk
    /// Access yet, or a partition is waiting (paused, nobody logged in,
    /// another drive mounted).
    private func updateRetryTimer() {
        if waiting.isEmpty && status.fullDiskAccess {
            retryTimer?.cancel()
            retryTimer = nil
        } else if retryTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in self?.processWaiting() }
            t.resume()
            retryTimer = t
        }
    }

    // MARK: Requests from the menu bar app (on queue)

    private func watchRequests() {
        let fd = open(Paths.requests, O_EVTONLY)
        guard fd >= 0 else { return }
        let w = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        w.setEventHandler { [weak self] in self?.readRequests() }
        w.resume()
        requestWatcher = w
        readRequests()
    }

    /// Requests come from unprivileged users, so files are read defensively
    /// (no symlinks, no blocking, small) and every request is validated.
    private func readRequests() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.requests)) ?? []
        var handled = false
        for file in files where file.hasSuffix(".req") {
            let path = Paths.requests + "/" + file
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
            unlink(path)
            guard fd >= 0 else { continue }
            var buf = [UInt8](repeating: 0, count: 128)
            let n = read(fd, &buf, buf.count)
            close(fd)
            guard n > 0 else { continue }
            let words = String(decoding: buf[..<n], as: UTF8.self)
                .split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            handle(request: words)
            handled = true
        }
        if handled { processWaiting() }
    }

    /// Accepted requests:
    ///   mount <partition>            an ejected or failed partition we listed
    ///   ignore <partition>           never mount this drive again
    ///   unignore <partition>         undo that, and mount it
    ///   set READ_ONLY yes|no
    ///   set IGNORE_PERMISSIONS yes|no
    private func handle(request words: [String]) {
        guard let verb = words.first else { return }
        var config = Config.load()
        switch (verb, words.count) {
        case ("mount", 2):
            let name = words[1]
            guard let uuid = uuids[name], ["ejected", "failed"].contains(state(of: name) ?? "") else { return }
            log("mount of /dev/\(name) requested from the menu")
            ejectedAt[uuid] = nil
            list(name, nil)
            waiting.append(name)
        case ("ignore", 2):
            let name = words[1]
            guard let uuid = uuids[name] else { return }
            log("/dev/\(name) set to never mount")
            config.ignore.insert(uuid)
            config.save()
            if let i = status.drives.firstIndex(where: { $0.device == name }),
               ["ejected", "failed", "waiting"].contains(status.drives[i].state) {
                status.drives[i].state = "ignored"
                waiting.removeAll { $0 == name }
            }
        case ("unignore", 2):
            let name = words[1]
            guard let uuid = uuids[name], let drive = status.drives.first(where: { $0.device == name }) else { return }
            log("/dev/\(name) no longer set to never mount")
            config.ignore.remove(uuid)
            config.ignore.remove(drive.label)
            config.save()
            if drive.state == "ignored" {
                list(name, nil)
                waiting.append(name)
            }
        case ("set", 3):
            guard ["yes", "no"].contains(words[2]) else { return }
            switch words[1] {
            case "READ_ONLY": config.readOnly = words[2] == "yes"
            case "IGNORE_PERMISSIONS": config.ignorePermissions = words[2] == "yes"
            default: return
            }
            log("option \(words[1]) set to \(words[2]) from the menu")
            config.save()
        default:
            return
        }
    }

    // MARK: Mounting (background thread; state changes hop back to queue)

    private func mountAndWatch(_ name: String, _ label: String, _ uuid: String, _ config: Config, _ user: User) {
        func finish(_ state: String?) {
            queue.sync {
                list(name, state, label: label, uuid: uuid)
                active = nil
                processWaiting()
            }
        }
        func mountPoint() -> String? {
            mountTable().first { $0.from.hasPrefix("\(name).local:") }?.on
        }

        // Already mounted by anylinuxfs (the service restarted, or someone ran
        // it by hand): adopt the mount instead of fighting over the device.
        if let point = mountPoint() {
            log("/dev/\(name) is already mounted at \(point)")
            queue.sync { list(name, "mounted", label: label, uuid: uuid, mountPoint: point); publish() }
            return watchUntilEjected(name, uuid, finish)
        }

        sleep(3)   // give macOS or another driver time to claim it first
        if mountTable().contains(where: { $0.from == "/dev/\(name)" }) {
            log("skip /dev/\(name): already mounted by another ext4 driver")
            notify("\(label) is read-only", "Another ext4 driver (such as ExtendFS) mounted it first. Remove that driver, then replug.")
            return finish(nil)
        }

        var args = ["mount"]
        if config.ignorePermissions { args.append("--ignore-permissions") }
        if config.readOnly { args += ["-o", "ro"] }
        args.append("/dev/\(name)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.anylinuxfs!)
        p.arguments = args
        // anylinuxfs expects to be run with sudo by the user who owns the mount.
        p.environment = [
            "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": user.home, "SUDO_USER": user.name,
            "SUDO_UID": String(user.uid), "SUDO_GID": String(user.gid),
        ]
        let out = FileHandle(forWritingAtPath: Paths.log)
        out?.seekToEndOfFile()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch {
            log("cannot start anylinuxfs: \(error.localizedDescription)")
            return finish("failed")
        }

        // anylinuxfs may return before or stay running after the mount is up,
        // so watch the mount table instead of the process.
        var waited = 0
        while mountPoint() == nil, waited < 180 {
            if !p.isRunning, p.terminationStatus != 0 { break }
            sleep(2); waited += 2
        }
        guard let point = mountPoint() else {
            if hasFullDiskAccess() {
                log("/dev/\(name) did not mount; run 'anylinuxfs log' for details")
                notify("Couldn't mount \(label)", "Choose Retry from the menu bar icon, or open the log there.")
            } else {
                log("/dev/\(name) did not mount: no Full Disk Access")
                notify("Full Disk Access needed",
                       "Turn on Ext4 Automount in System Settings > Privacy & Security > Full Disk Access.")
            }
            return finish("failed")
        }
        log("/dev/\(name) mounted at \(point)")
        queue.sync { list(name, "mounted", label: label, uuid: uuid, mountPoint: point) }
        notify("\(label) is ready", config.readOnly ? "Mounted read-only. Click to open." : "Click to open in Finder.",
               path: point)
        watchUntilEjected(name, uuid, finish)
    }

    /// Wait for the volume to be unmounted (Finder or menu eject), then eject
    /// the physical disk so it powers down.
    private func watchUntilEjected(_ name: String, _ uuid: String, _ finish: (String?) -> Void) {
        while mountTable().contains(where: { $0.from.hasPrefix("\(name).local:") }) { sleep(2) }
        sleep(5)   // let the VM shut down and release the disk
        let whole = name.replacingOccurrences(of: #"^(disk\d+)s\d+$"#, with: "$1", options: .regularExpression)
        log("/dev/\(name) unmounted; ejecting \(whole)")
        queue.sync { ejectedAt[uuid] = Date() }
        runTool("/usr/sbin/diskutil", ["eject", whole])
        finish(nil)
    }

    // MARK: Helpers

    private func probe(_ blkid: String, _ name: String) -> [String: String] {
        var info: [String: String] = [:]
        for line in runTool(blkid, ["-o", "export", "/dev/\(name)"]).output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            info[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return info
    }

    /// The user logged in at the screen, if any.
    private func consoleUser() -> User? {
        var st = stat()
        guard stat("/dev/console", &st) == 0, st.st_uid != 0, let pw = getpwuid(st.st_uid) else { return nil }
        return (String(cString: pw.pointee.pw_name), pw.pointee.pw_uid, pw.pointee.pw_gid,
                String(cString: pw.pointee.pw_dir))
    }

    /// Ask the menu bar app to show a notification.
    private func notify(_ title: String, _ text: String, path: String? = nil) {
        let post = {
            self.noticeID += 1
            self.status.notice = Notice(id: self.noticeID, title: title, text: text, path: path)
            self.publish()
        }
        if DispatchQueue.getSpecific(key: Daemon.onQueue) == true { post() } else { queue.sync(execute: post) }
    }

    private func publish() {
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.status), options: .atomic)
        chmod(Paths.status, 0o644)
    }

    private func log(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date())) \(message)\n"
        if !FileManager.default.fileExists(atPath: Paths.log) {
            FileManager.default.createFile(atPath: Paths.log, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        if let h = FileHandle(forWritingAtPath: Paths.log) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            h.closeFile()
        }
    }
}
