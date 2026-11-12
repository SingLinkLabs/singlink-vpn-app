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

  private func registerVpnPlugin(in scene: UIWindowScene?) {
    guard !vpnPluginRegistered, let scene else { return }
    for window in scene.windows {
      if let flutter = window.rootViewController as? FlutterViewController,
         let registrar = flutter.registrar(forPlugin: "SingLinkVpnPlugin") {
        SingLinkVpnPlugin.register(with: registrar)
        vpnPluginRegistered = true
        return
      }
    }
  }
}
