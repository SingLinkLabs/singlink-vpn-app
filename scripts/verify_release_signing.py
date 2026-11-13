#!/usr/bin/env python3
# Copyright 2026 SingLinkLabs
# SPDX-License-Identifier: Apache-2.0
import os
from pathlib import Path
import sys

def validate(env):
    required = ['SINGLINK_RELEASE_STORE_FILE', 'SINGLINK_RELEASE_STORE_PASSWORD',
                'SINGLINK_RELEASE_KEY_ALIAS', 'SINGLINK_RELEASE_KEY_PASSWORD']
    if not all(env.get(k) for k in required): return False
    path = Path(env['SINGLINK_RELEASE_STORE_FILE'])
    return path.is_file() and path.suffix.lower() in {'.jks', '.keystore'} and path.name != 'debug.keystore'

if __name__ == '__main__':
    if not validate(os.environ):
        print('ERROR: release signing requires an external protected keystore and all signing inputs.', file=sys.stderr)
        sys.exit(1)
    print('Release signing inputs present; certificate/artifact verification is still required.')
