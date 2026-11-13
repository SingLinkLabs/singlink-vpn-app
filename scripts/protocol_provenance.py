#!/usr/bin/env python3
# Copyright 2026 SingLinkLabs
# SPDX-License-Identifier: Apache-2.0
"""Fail-closed source pin and native-artifact provenance (no private inputs)."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

APP = Path(__file__).resolve().parents[1]

def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''): digest.update(chunk)
    return digest.hexdigest()

def expected(app):
    revision = (app / 'core/protocol-revision.txt').read_text().strip()
    if not re.fullmatch(r'[0-9a-f]{40}', revision): raise ValueError('invalid approved protocol revision')
    return revision

def verify(app, protocol=None):
    protocol = protocol or app.parent / 'singlink-protocol'
    def git(*args):
        return subprocess.check_output(['git', '-C', str(protocol), *args], stderr=subprocess.DEVNULL, text=True).strip()
    revision = expected(app)
    if git('rev-parse', 'HEAD') != revision: raise ValueError('protocol revision does not match the approved pin')
    if git('status', '--porcelain', '--untracked-files=all'): raise ValueError('protocol source has unreviewed changes')
    return revision

def fingerprint(app):
    digest = hashlib.sha256()
    for path in sorted((app / 'core').rglob('*')):
        rel = path.relative_to(app / 'core')
        if not path.is_file() or 'build' in rel.parts: continue
        if path.suffix != '.go' and path.name not in {'go.mod', 'go.sum', 'Makefile', 'protocol-revision.txt'}: continue
        digest.update(str(rel).encode() + b'\0' + bytes.fromhex(sha(path)))
    digest.update((app / 'scripts/protocol_provenance.py').read_bytes())
    return digest.hexdigest()

def artifact_state(app, artifact):
    return {'schema': 1, 'protocolCommit': verify(app), 'coreSourceSHA256': fingerprint(app), 'artifactSHA256': sha(artifact)}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['verify', 'pin', 'record', 'check-artifact'])
    parser.add_argument('artifacts', nargs='*')
    args = parser.parse_args()
    if args.command == 'pin': print(expected(APP)); return
    verify(APP)
    for name in args.artifacts:
        artifact = Path(name).resolve()
        stamp = Path(str(artifact) + '.source.json')
        state = artifact_state(APP, artifact)
        if args.command == 'record':
            tmp = Path(str(stamp) + '.tmp')
            tmp.write_text(json.dumps(state, sort_keys=True) + '\n')
            tmp.replace(stamp)
        elif args.command == 'check-artifact':
            if json.loads(stamp.read_text()) != state: raise ValueError('native artifact does not match reviewed source')
    print('Protocol source/provenance verified.')

if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, subprocess.SubprocessError):
        print('ERROR: protocol source or native artifact provenance verification failed.', file=sys.stderr)
        sys.exit(1)
