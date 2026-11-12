// Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';

/// Attribution required by NOTICE (Apache License 2.0, section 4(d)).
/// Redistributions and derivative works must keep this text.
const kAttribution =
    'Based on the SingLinkVPN prototype and the SingLink Protocol by SingLinkLabs\n'
    'https://github.com/SingLinkLabs/singlink-vpn-app';

const kCopyright = '© 2026 SingLinkLabs · Apache-2.0';

/// Shown at the bottom of the main screen. Required attribution: see NOTICE.
const kMadeBy = 'Made by SingLinkVPN · Powered by the SingLink Protocol';

const _notice =
    '''SingLinkVPN — first-generation prototype client
Copyright 2026 SingLinkLabs
Licensed under the Apache License, Version 2.0.

$kAttribution

"SingLink", "SingLinkVPN", their Chinese names and the logo are trademarks of SingLinkLabs.

Includes the SingLink Protocol (https://github.com/SingLinkLabs/singlink-protocol, Apache-2.0) and gVisor (https://gvisor.dev, Apache-2.0).''';

bool _registered = false;

/// Adds this app's NOTICE to Flutter's license registry, so it appears in
/// Settings > About > Licenses.
void registerAppLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks([
      'SingLinkVPN',
      'SingLink Protocol',
    ], _notice);
  });
}
