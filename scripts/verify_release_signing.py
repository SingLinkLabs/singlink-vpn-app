#!/usr/bin/env python3
# Copyright 2026 SingLinkLabs
# SPDX-License-Identifier: Apache-2.0
"""Release-pipeline pre-check; Gradle enforces the same rule when signing."""
import os
from pathlib import Path
import sys

def validate(env):
    required = ['SINGLINK_RELEASE_STORE_FILE', 'SINGLINK_RELEASE_STORE_PASSWORD',
                'SINGLINK_RELEASE_KEY_ALIAS', 'SINGLINK_RELEASE_KEY_PASSWORD']
    if not all(env.get(k) for k in required): return False
    path = Path(env['SINGLINK_RELEASE_STORE_FILE'])
    # Same rule as android/app/build.gradle.kts: an existing external file that
    # is not the Android SDK's generated debug keystore.
    return path.is_file() and path.name != 'debug.keystore' and path.parent.name != '.android'

if __name__ == '__main__':
    if not validate(os.environ):
        print('ERROR: release signing requires an external protected keystore and all signing inputs.', file=sys.stderr)
        sys.exit(1)
    print('Release signing inputs present; certificate/artifact verification is still required.')
