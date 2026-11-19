#!/usr/bin/env python3
# Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
# SPDX-License-Identifier: Apache-2.0
"""Release gate for macOS (App F-05): refuse to call a build distributable.

A SingLinkVPN.app may be labelled and published as a release only when every
check passes:

  * the whole bundle verifies (codesign --verify --deep --strict);
  * the app and the bundled libsinglink.dylib are signed with a
    "Developer ID Application" certificate of one team, with a secure
    timestamp, and the app runs with the hardened runtime;
  * the App Sandbox stays as documented (off) and no entitlement outside the
    reviewed list is present;
  * the notarization ticket is stapled (xcrun stapler validate) and
    Gatekeeper accepts the app as a notarized Developer ID build
    (spctl --assess).

CI builds are ad-hoc signed, so this gate rejects them; the CI artifact is
named UNSIGNED. Developer ID signing and notarization need the owner's Apple
Developer account and are done in the protected release process, never in
pull-request CI. No credentials are read or printed here.

Usage: verify_macos_distribution.py path/to/SingLinkVPN.app
"""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

# Entitlements the release build may carry (see macos/Runner/Release.entitlements).
ALLOWED_ENTITLEMENTS = {
    'com.apple.security.app-sandbox': False,
    'com.apple.security.network.client': True,
    'com.apple.security.network.server': True,
}


def run(*args, stdout_only=False):
    proc = subprocess.run(list(args), capture_output=True, text=True)
    return proc.returncode, proc.stdout if stdout_only else proc.stdout + proc.stderr


def parse_codesign_details(text):
    """Fields of `codesign -dv --verbose=4` output that the gate needs."""
    authorities = re.findall(r'^Authority=(.+)$', text, re.M)
    team = re.search(r'^TeamIdentifier=(.+)$', text, re.M)
    flags = re.search(r'^CodeDirectory .*flags=0x[0-9a-f]+\(([^)]*)\)', text, re.M)
    return {
        'authorities': authorities,
        'team': team.group(1).strip() if team else '',
        'flags': set(flags.group(1).split(',')) if flags and flags.group(1) else set(),
        'adhoc': bool(re.search(r'^Signature=adhoc$', text, re.M)),
        'timestamp': bool(re.search(r'^Timestamp=', text, re.M)),
    }


def check_signature(details, label, require_runtime):
    problems = []
    if details['adhoc'] or not details['authorities']:
        problems.append(f'{label}: ad-hoc or unsigned')
    elif not details['authorities'][0].startswith('Developer ID Application:'):
        problems.append(f'{label}: not signed with a Developer ID Application certificate')
    if not details['team'] or details['team'] == 'not set':
        problems.append(f'{label}: no team identifier')
    if not details['timestamp']:
        problems.append(f'{label}: no secure timestamp')
    if require_runtime and 'runtime' not in details['flags']:
        problems.append(f'{label}: hardened runtime is not enabled')
    return problems


def check_entitlements(entitlements):
    problems = []
    for key, value in entitlements.items():
        if key not in ALLOWED_ENTITLEMENTS:
            problems.append(f'unexpected entitlement {key}')
        elif ALLOWED_ENTITLEMENTS[key] != value:
            problems.append(f'entitlement {key} = {value!r}, reviewed value {ALLOWED_ENTITLEMENTS[key]!r}')
    return problems


def entitlement_problems(codesign_code, xml_output):
    """Fails closed: unreadable entitlements are never treated as empty."""
    start = xml_output.find('<?xml')
    if codesign_code != 0 or start < 0:
        return ['cannot read the entitlements']
    try:
        entitlements = plistlib.loads(xml_output[start:].encode())
    except Exception:
        return ['cannot read the entitlements']
    if not isinstance(entitlements, dict):
        return ['cannot read the entitlements']
    return check_entitlements(entitlements)


def check_gatekeeper(spctl_output, spctl_code):
    if spctl_code != 0 or 'accepted' not in spctl_output:
        return ['Gatekeeper rejects the app (spctl --assess)']
    if 'Notarized Developer ID' not in spctl_output:
        return ['Gatekeeper does not report a notarized Developer ID build']
    return []


def verify(app):
    app = Path(app)
    if not (app / 'Contents/MacOS').is_dir():
        return [f'{app} is not an app bundle']
    problems = []
    code, out = run('codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app))
    if code != 0:
        problems.append('codesign --verify --deep --strict failed')
    _, out = run('codesign', '-dv', '--verbose=4', str(app))
    app_details = parse_codesign_details(out)
    problems += check_signature(app_details, 'app', require_runtime=True)
    core = app / 'Contents/Frameworks/libsinglink.dylib'
    if not core.is_file():
        problems.append('bundled core libsinglink.dylib is missing')
    else:
        _, out = run('codesign', '-dv', '--verbose=4', str(core))
        core_details = parse_codesign_details(out)
        problems += check_signature(core_details, 'libsinglink.dylib', require_runtime=False)
        if core_details['team'] != app_details['team']:
            problems.append('libsinglink.dylib is signed by a different team than the app')
    code, out = run('codesign', '-d', '--entitlements', '-', '--xml', str(app), stdout_only=True)
    problems += entitlement_problems(code, out)
    code, _ = run('xcrun', 'stapler', 'validate', str(app))
    if code != 0:
        problems.append('no stapled notarization ticket')
    code, out = run('spctl', '--assess', '--type', 'execute', '-vv', str(app))
    problems += check_gatekeeper(out, code)
    return problems


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    problems = verify(sys.argv[1])
    if problems:
        print('NOT DISTRIBUTABLE: ' + '; '.join(problems), file=sys.stderr)
        return 1
    print('Developer ID signed, hardened runtime, notarized and stapled: distributable.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
