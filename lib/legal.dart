// Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';

/// Original author of this app and of the SingLink Beta Protocol.
const kOriginalAuthor = 'SingLinkVPN';

/// Attribution required by NOTICE (Apache License 2.0, section 4(d)).
/// Every use, redistribution and derivative work must keep this text.
const kAttribution =
    'Software provided by the original author SingLinkVPN.\n'
    'Based on the SingLinkVPN prototype and the SingLink Beta Protocol by SingLinkVPN\n'
    'Originally developed and provided by SingLinkVPN — https://singlinkvpn.com\n'
    'https://github.com/SingLinkLabs/singlink-vpn-app';

const kCopyright = '© 2026 SingLinkVPN · Apache-2.0';

/// Shown at the bottom of the main screen. Required attribution: see NOTICE.
/// Redistributions and derivative works must keep it on the main screen.
const kMadeBy =
    'Provided by the original author SingLinkVPN\n'
    'Powered by the SingLink Beta Protocol';

const _notice =
    '''SingLinkVPN — first-generation client
Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
Licensed under the Apache License, Version 2.0.

$kAttribution

"SingLink", "SingLinkVPN", their Chinese names and the logo are trademarks of SingLinkVPN.

Includes the SingLink Beta Protocol, originally developed and provided by SingLinkVPN (https://github.com/SingLinkLabs/singlink-protocol, Apache-2.0), and gVisor (https://gvisor.dev, Apache-2.0).''';

bool _registered = false;

/// Adds this app's NOTICE to Flutter's license registry, so it appears in
/// Settings > About > Licenses.
void registerAppLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks([
      'SingLinkVPN',
      'SingLink Beta Protocol',
    ], _notice);
  });
}
