import DiskArbitration
import Foundation

/// Options from Paths.config. The file is parsed, never executed.
struct Config {
    var filesystems: Set<String> = ["ext2", "ext3", "ext4"]
    var readOnly = false
    var ignorePermissions = false
    var ignore: Set<String> = []   // labels or filesystem UUIDs

    static func load() -> Config {
        var c = Config()
        guard let text = try? String(contentsOfFile: Paths.config, encoding: .utf8) else { return c }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let yes = ["yes", "true", "1"].contains(value.lowercased())
            let words = Set(value.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
            switch key {
            case "FILESYSTEMS": if !words.isEmpty { c.filesystems = Set(words.map { $0.lowercased() }) }
            case "READ_ONLY": c.readOnly = yes
            case "IGNORE_PERMISSIONS": c.ignorePermissions = yes
            case "IGNORE": c.ignore = words
            default: break
            }
        }
        return c
    }
}

/// Root service: mounts external Linux partitions with anylinuxfs when they
/// are plugged in, and ejects the disk after the volume is ejected in Finder.
final class Daemon {
    private let queue = DispatchQueue(label: "ext4-automount")   // owns all state below
    private let session = DASessionCreate(kCFAllocatorDefault)!
    private var status = Status()
    private var waiting: [String] = []            // partitions not mounted yet, in arrival order
    private var active: String?                   // partition being mounted or mounted
    private var ejectedAt: [String: Date] = [:]   // filesystem UUID -> when we ejected it
    /// Attached but not mounted (ejected, or mount failed): partition -> UUID.
    /// The menu bar app can ask to mount these.
    private var parked: [String: String] = [:]
    private var retryTimer: DispatchSourceTimer?
    private var askedForAccess = false
    private var noticeID = Int(Date().timeIntervalSince1970)

    private let anylinuxfs = ["/opt/homebrew/bin/anylinuxfs", "/usr/local/bin/anylinuxfs"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    private let blkid = ["/opt/homebrew/opt/util-linux/sbin/blkid", "/usr/local/opt/util-linux/sbin/blkid"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func run() -> Never {
        try? FileManager.default.createDirectory(atPath: Paths.runDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        log("started")
        queue.sync {
            status.fullDiskAccess = hasFullDiskAccess()
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
        parked[name] = nil
        status.drives.removeAll { $0.device == name && $0.state != "mounted" && $0.state != "mounting" }
        updateRetryTimer()
        publish()
    }

    /// Try to mount the next waiting partition. Called on disk events, when a
    /// mount ends, and from the retry timer while something is blocked.
    private func processWaiting() {
        defer { updateRetryTimer(); publish() }
        status.fullDiskAccess = hasFullDiskAccess()
        guard !waiting.isEmpty else { return }

        let fda = hasFullDiskAccess()
        if !fda, !askedForAccess {
            askedForAccess = true
            notify("Full Disk Access needed",
                   "Turn on Ext4 Automount in System Settings > Privacy & Security > Full Disk Access.")
        }
        status.fullDiskAccess = fda
        guard fda else { return }
        askedForAccess = false
        guard !FileManager.default.fileExists(atPath: Paths.pauseFlag) else { return }
        guard let user = consoleUser() else { return }
        guard let blkid, anylinuxfs != nil else {
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
                log("skip /dev/\(name) (\(label)): on the ignore list")
            } else if let t = ejectedAt[uuid], Date().timeIntervalSince(t) < 20 {
                // Some enclosures reconnect by themselves after an eject. Don't
                // remount; leave it for the menu's Mount item.
                log("not mounting /dev/\(name) (\(label)): reappeared right after eject")
                parked[name] = uuid
                status.drives.removeAll { $0.device == name }
                status.drives.append(Drive(device: name, label: label, state: "ejected", mountPoint: ""))
            } else if active != nil {
                drop = false   // one anylinuxfs mount at a time; keep waiting
                if !status.drives.contains(where: { $0.device == name }) {
                    status.drives.append(Drive(device: name, label: label, state: "waiting", mountPoint: ""))
                    notify("\(label) is waiting", "It will mount after the current Linux drive is ejected.")
                }
            } else {
                active = name
                status.drives.removeAll { $0.device == name }
                status.drives.append(Drive(device: name, label: label, state: "mounting", mountPoint: ""))
                log("mounting /dev/\(name) (\(label), \(type)) for \(user.name)")
                DispatchQueue.global().async { self.mountAndWatch(name, label, uuid, config, user) }
            }
            if drop { waiting.removeAll { $0 == name } }
        }
    }

    /// The menu bar app asks to mount a parked partition by writing its name
    /// to Paths.mountRequest. Only names we parked ourselves are accepted.
    private func checkMountRequest() {
        let fd = open(Paths.mountRequest, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buf, buf.count)
        close(fd)
        unlink(Paths.mountRequest)
        guard n > 0 else { return }
        let name = String(decoding: buf[..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = parked[name] else { return }
        log("mount of /dev/\(name) requested from the menu")
        parked[name] = nil
        ejectedAt[uuid] = nil
        status.drives.removeAll { $0.device == name }
        waiting.append(name)
    }

    /// Re-check every 5 s only while a partition is blocked (no Full Disk
    /// Access, paused, nobody logged in, another drive mounted) or parked.
    private func updateRetryTimer() {
        if waiting.isEmpty && parked.isEmpty {
            retryTimer?.cancel()
            retryTimer = nil
        } else if retryTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in self?.checkMountRequest(); self?.processWaiting() }
            t.resume()
            retryTimer = t
        }
    }

    // MARK: Mounting (background thread; state changes hop back to queue)

    private func mountAndWatch(_ name: String, _ label: String, _ uuid: String,
                               _ config: Config, _ user: (name: String, uid: uid_t, gid: gid_t, home: String)) {
        func finish(_ state: String?) {
            queue.sync {
                status.drives.removeAll { $0.device == name }
                if let state {
                    status.drives.append(Drive(device: name, label: label, state: state, mountPoint: ""))
                    parked[name] = uuid   // failed: the menu offers a retry
                }
                active = nil
                processWaiting()
            }
        }
        func mountPoint() -> String? {
            mountTable().first { $0.from.hasPrefix("\(name).local:") }?.on
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
        p.executableURL = URL(fileURLWithPath: anylinuxfs!)
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
            if waited == 20 {
                notify("Preparing \(label)…", "The first mount downloads a small Linux image and can take a minute.")
            }
        }
        guard let point = mountPoint() else {
            if hasFullDiskAccess() {
                log("/dev/\(name) did not mount; run 'anylinuxfs log' for details")
                notify("Couldn't mount \(label)", "See /var/log/ext4-automount.log")
            } else {
                log("/dev/\(name) did not mount: no Full Disk Access")
                notify("Full Disk Access needed",
                       "Turn on Ext4 Automount in System Settings > Privacy & Security > Full Disk Access, then replug.")
            }
            return finish("failed")
        }
        log("/dev/\(name) mounted at \(point)")
        queue.sync {
            if let i = status.drives.firstIndex(where: { $0.device == name }) {
                status.drives[i].state = "mounted"
                status.drives[i].mountPoint = point
            }
            publish()
        }

        while mountPoint() != nil { sleep(2) }
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
    private func consoleUser() -> (name: String, uid: uid_t, gid: gid_t, home: String)? {
        var st = stat()
        guard stat("/dev/console", &st) == 0, st.st_uid != 0, let pw = getpwuid(st.st_uid) else { return nil }
        return (String(cString: pw.pointee.pw_name), pw.pointee.pw_uid, pw.pointee.pw_gid,
                String(cString: pw.pointee.pw_dir))
    }

    /// Ask the menu bar app to show a notification.
    private func notify(_ title: String, _ text: String) {
        let post = {
            self.noticeID += 1
            self.status.notice = Notice(id: self.noticeID, title: title, text: text)
            self.publish()
        }
        if DispatchQueue.getSpecific(key: Daemon.onQueue) == true { post() } else { queue.sync(execute: post) }
    }

    private static let onQueue = DispatchSpecificKey<Bool>()
    init() { queue.setSpecific(key: Daemon.onQueue, value: true) }

    private func publish() {
        guard let data = try? JSONEncoder().encode(status) else { return }
        let url = URL(fileURLWithPath: Paths.status)
        try? data.write(to: url, options: .atomic)
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
