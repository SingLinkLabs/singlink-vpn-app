#!/bin/bash
# Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_ROOT"
python3 scripts/protocol_provenance.py verify
# Verify the actual framework slices consumed by Xcode, not a stale sibling .a.
count=0
while IFS= read -r -d '' artifact; do
  python3 scripts/protocol_provenance.py check-artifact "$artifact"
  count=$((count + 1))
done < <(find core/build/apple/Singlink.xcframework -name libsinglink.a -type f -print0)
[[ "$count" == 3 ]] || { echo 'ERROR: approved iOS core framework is incomplete.' >&2; exit 1; }
