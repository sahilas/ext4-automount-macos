import Foundation

// One executable, two roles:
//   --daemon   root service started by launchd (mounts drives)
//   (no args)  menu bar app for the logged-in user
// Both are the same app bundle, so one Full Disk Access switch covers it.

_ = hasFullDiskAccess()   // registers the app in the Full Disk Access list

if CommandLine.arguments.contains("--daemon") {
    guard getuid() == 0 else {
        FileHandle.standardError.write(Data("--daemon must run as root\n".utf8))
        exit(1)
    }
    Daemon().run()
} else {
    MenuApp.main()
}
