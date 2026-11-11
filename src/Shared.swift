import Foundation

enum Paths {
    static let log = "/var/log/ext4-automount.log"
    static let runDir = "/var/run/ext4-automount"
    static let status = runDir + "/status.json"
    /// Exists = auto-mount paused. Anyone may pause; it only stops mounting.
    static let pauseFlag = "/Users/Shared/.ext4-automount-paused"
    /// The menu bar app writes a partition name here to ask for a mount.
    static let mountRequest = "/Users/Shared/.ext4-automount-mount"
    /// Root-owned options file (see config.example).
    static let config = "/Library/Application Support/Ext4 Automount/config"
    /// A file only readable with Full Disk Access.
    static let fdaProbe = "/Library/Application Support/com.apple.TCC/TCC.db"
    static let fdaSettings =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
}

/// What the service publishes for the menu bar app.
struct Drive: Codable {
    var device: String      // disk4s1
    var label: String
    var state: String       // waiting | mounting | mounted | ejected | failed
    var mountPoint: String
}

struct Notice: Codable {
    var id: Int
    var title: String
    var text: String
}

struct Status: Codable {
    var fullDiskAccess = false
    var drives: [Drive] = []
    var notice: Notice?
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
