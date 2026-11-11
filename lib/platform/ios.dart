// iOS: device-wide VPN through a Network Extension packet tunnel.
// TODO(ios): replace with the NETunnelProviderManager-backed core.

import '../core/singlink_service.dart';

VpnCore createIosCore() => SingLinkService.locate();
