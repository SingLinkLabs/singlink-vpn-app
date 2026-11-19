import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// App F-07: the folder with the settings file (display metadata and
  /// opaque references only) and, on macOS, the system-proxy journal is
  /// excluded from device backups (iCloud/Finder on iOS, Time Machine on
  /// macOS). Protected credentials live in the Keychain, not in this folder.
  @discardableResult
  static func excludeAppDataFromBackup(base: URL? = nil) -> Bool {
    let fm = FileManager.default
    guard let root = base ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return false }
    var dir = root.appendingPathComponent("com.singlinklabs.singlinkvpn", isDirectory: true)
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try dir.setResourceValues(values)
      return true
    } catch {
      return false
    }
  }
}
