import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var vpnPluginRegistered = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    AppDelegate.excludeAppDataFromBackup()
    // The iOS 27 SDK requires the UIScene life cycle (Info.plist
    // UIApplicationSceneManifest -> FlutterSceneDelegate), so the Flutter view
    // controller only exists once the scene is connected: register the
    // device-wide VPN channel (SingLinkVpnPlugin.swift) on its engine then.
    NotificationCenter.default.addObserver(
      forName: UIScene.didActivateNotification, object: nil, queue: .main
    ) { [weak self] note in
      self?.registerVpnPlugin(in: note.object as? UIWindowScene)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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

  private func registerVpnPlugin(in scene: UIWindowScene?) {
    guard !vpnPluginRegistered, let scene else { return }
    for window in scene.windows {
      if let flutter = window.rootViewController as? FlutterViewController,
         let registrar = flutter.registrar(forPlugin: "SingLinkVpnPlugin") {
        SingLinkVpnPlugin.register(with: registrar)
        SecretStorePlugin.register(with: registrar)
        vpnPluginRegistered = true
        return
      }
    }
  }
}
