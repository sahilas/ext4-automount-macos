import Foundation

enum Paths {
    static let log = "/var/log/ext4-automount.log"
    static let runDir = "/var/run/ext4-automount"
    static let status = runDir + "/status.json"
    /// World-writable (sticky) folder where the menu bar app drops requests
    /// for the service. See Daemon.handle(request:) for what is accepted.
    static let requests = runDir + "/requests"
    /// Exists = auto-mount paused. Anyone may pause; it only stops mounting.
    static let pauseFlag = "/Users/Shared/.ext4-automount-paused"
    /// Root-owned options file (see config.example).
    static let config = "/Library/Application Support/Ext4 Automount/config"
    /// A file only readable with Full Disk Access.
    static let fdaProbe = "/Library/Application Support/com.apple.TCC/TCC.db"
    static let fdaSettings =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let uninstaller = "/Applications/Ext4 Automount.app/Contents/Resources/uninstall.sh"
    static let anylinuxfs = ["/opt/homebrew/bin/anylinuxfs", "/usr/local/bin/anylinuxfs"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// GitHub repository that publishes releases (used by the update check).
let releaseRepo = "sahilas/ext4-automount-macos"

/// What the service publishes for the menu bar app.
struct Drive: Codable {
    var device: String      // disk4s1
    var label: String
    var state: String       // waiting | mounting | mounted | ejected | failed | ignored
    var mountPoint: String
}

struct Notice: Codable {
    var id: Int
    var title: String
    var text: String
    var path: String?       // opened in Finder when the notification is clicked
}

struct Status: Codable {
    var fullDiskAccess = false
    var drives: [Drive] = []
    var notice: Notice?
}

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

    /// Rewrite the options file (service only; the file is root-owned).
    func save() {
        let text = """
            # Ext4 Automount options. Edit here (needs sudo) or from the menu bar icon.
            # See config.example for what each option means.
            FILESYSTEMS=\(filesystems.sorted().joined(separator: " "))
            READ_ONLY=\(readOnly ? "yes" : "no")
            IGNORE_PERMISSIONS=\(ignorePermissions ? "yes" : "no")
            IGNORE=\(ignore.sorted().joined(separator: " "))

            """
        try? text.write(toFile: Paths.config, atomically: true, encoding: .utf8)
        chmod(Paths.config, 0o644)
    }
}

/// Reading a protected file both answers "do we have Full Disk Access?" and
/// makes macOS list this app under Privacy & Security > Full Disk Access.
func hasFullDiskAccess() -> Bool {
    let fd = open(Paths.fdaProbe, O_RDONLY)
    if fd >= 0 { close(fd); return true }
    return false
}

/// Run a tool and return (exit status, stdout). Arguments are passed as an
/// array, never through a shell.
@discardableResult
func runTool(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// (device, mount point) for every mounted filesystem.
func mountTable() -> [(from: String, on: String)] {
    var list: UnsafeMutablePointer<statfs>?
    let n = getmntinfo(&list, MNT_NOWAIT)
    guard n > 0, let list else { return [] }
    return (0..<Int(n)).map { i in
        var fs = list[i]
        let from = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let on = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return (from, on)
    }
}
