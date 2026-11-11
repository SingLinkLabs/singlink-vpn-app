// Android: device-wide VPN through VpnService (see android/app/src/main/kotlin).
// TODO(android): replace with the VpnService-backed core.

import '../core/singlink_service.dart';

VpnCore createAndroidCore() => SingLinkService.locate();

/// Called once at start-up, before the app state is loaded.
// TODO(android): set appSupportDirOverride to Context.getFilesDir().
Future<void> initAndroid() async {}
