import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.title = "SingLinkVPN"
    // Phone-like single column, like consumer VPN apps; still resizable.
    self.setContentSize(NSSize(width: 420, height: 760))
    self.minSize = NSSize(width: 380, height: 620)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
