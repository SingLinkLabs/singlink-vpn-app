#!/usr/bin/env python3
# Copyright 2026 SingLinkVPN (https://singlinkvpn.com)
# SPDX-License-Identifier: Apache-2.0
"""Synthetic-only source pin, artifact invalidation and release signing tests."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('provenance', HERE / 'protocol_provenance.py')
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)

class SourceGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='synthetic-build-gate-')
        self.base = Path(self.temp.name)
        self.app = self.base / 'app'
        self.protocol = self.base / 'singlink-protocol'
        (self.app / 'core').mkdir(parents=True)
        (self.app / 'scripts').mkdir()
        (self.app / 'scripts/protocol_provenance.py').write_text('synthetic verifier')
        (self.app / 'core/main.go').write_text('package main\n')
        self.protocol.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Synthetic Build Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.protocol / 'source.go').write_text('package fixture\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'Synthetic fixture')
        self.pin = self.git('rev-parse', 'HEAD')
        (self.app / 'core/protocol-revision.txt').write_text(self.pin)
        self.write_go_mod(self.pseudo_version())
    def pseudo_version(self, revision=None):
        stamp = subprocess.check_output(['git', '-C', str(self.protocol), 'show', '-s', '--format=%cd',
            '--date=format-local:%Y%m%d%H%M%S', revision or self.pin], text=True,
            env={**os.environ, 'TZ': 'UTC'}).strip()
        return f'v0.0.0-{stamp}-{(revision or self.pin)[:12]}'
    def write_go_mod(self, version):
        (self.app / 'core/go.mod').write_text('module synthetic/core\n\ngo 1.22\n\nrequire (\n'
            f'\tgithub.com/SingLinkLabs/singlink-protocol {version}\n)\n\n'
            'replace github.com/SingLinkLabs/singlink-protocol => ../../singlink-protocol\n')
    def tearDown(self): self.temp.cleanup()
    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.protocol), *args], stderr=subprocess.DEVNULL, text=True).strip()
    def test_pin_accepts_only_exact_clean_revision(self):
        self.assertEqual(provenance.verify(self.app), self.pin)
        (self.protocol / 'unreviewed').write_text('fixture')
        with self.assertRaises(ValueError): provenance.verify(self.app)
        (self.protocol / 'unreviewed').unlink()
        self.git('commit', '--allow-empty', '-qm', 'Moved branch')
        with self.assertRaises(ValueError): provenance.verify(self.app)
    def test_stale_source_and_artifact_are_detected(self):
        artifact = self.app / 'core/synthetic.bin'
        artifact.write_bytes(b'synthetic artifact')
        before = provenance.artifact_state(self.app, artifact)
        (self.app / 'core/main.go').write_text('package main\n// changed\n')
        self.assertNotEqual(before, provenance.artifact_state(self.app, artifact))
        artifact.write_bytes(b'changed artifact')
        self.assertNotEqual(before['artifactSHA256'], provenance.artifact_state(self.app, artifact)['artifactSHA256'])
    def test_upstream_main_moving_keeps_the_approved_dependency(self):
        # A newer upstream commit exists, but the app revision still names the
        # approved one: checking out the pin passes, the moved head is refused.
        self.git('commit', '--allow-empty', '-qm', 'Upstream main moved')
        moved = self.git('rev-parse', 'HEAD')
        with self.assertRaises(ValueError): provenance.verify(self.app)
        self.git('checkout', '-q', self.pin)
        self.assertEqual(provenance.verify(self.app), self.pin)
        self.assertNotEqual(moved, self.pin)
    def test_go_mod_must_pin_the_same_commit(self):
        self.write_go_mod('v0.0.0')
        with self.assertRaises(ValueError): provenance.expected(self.app)
        self.write_go_mod('v0.0.0-20000101000000-' + 'f' * 12)
        with self.assertRaises(ValueError): provenance.expected(self.app)
        self.write_go_mod('v0.0.0-20000101000000-' + self.pin[:12])
        self.assertEqual(provenance.expected(self.app), self.pin)
        with self.assertRaises(ValueError): provenance.verify(self.app)  # wrong commit time
        self.write_go_mod(self.pseudo_version())
        self.assertEqual(provenance.verify(self.app), self.pin)
    def test_repository_pin_is_consistent(self):
        # The real checked-in record and go.mod requirement agree.
        revision = provenance.expected(HERE.parent)
        self.assertRegex(revision, r'^[0-9a-f]{40}$')
        workflow = (HERE.parent / '.github/workflows/build.yml').read_text()
        checkouts = workflow.count('repository: SingLinkLabs/singlink-protocol')
        self.assertGreaterEqual(checkouts, 5)
        self.assertEqual(workflow.count('ref: ${{ steps.protocol-pin.outputs.revision }}'), checkouts)
    def test_nonimmutable_pin_is_rejected(self):
        (self.app / 'core/protocol-revision.txt').write_text('main')
        with self.assertRaises(ValueError): provenance.verify(self.app)

class SigningGateTests(unittest.TestCase):
    def run_gate(self, values):
        env = {key: value for key, value in os.environ.items() if not key.startswith('SINGLINK_')}
        env.update(values)
        return subprocess.run(['python3', str(HERE / 'verify_release_signing.py')], env=env, capture_output=True, text=True)
    def test_missing_signing_configuration_is_rejected_without_values(self):
        result = self.run_gate({})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('PASSWORD=', result.stdout + result.stderr)
    def test_debug_keystore_is_never_release_fallback(self):
        with tempfile.TemporaryDirectory(prefix='synthetic-signing-gate-') as tmp:
            path = Path(tmp) / 'debug.keystore'
            path.write_bytes(b'not a signing key')
            values = {'SINGLINK_RELEASE_STORE_FILE': str(path), 'SINGLINK_RELEASE_STORE_PASSWORD': 'synthetic',
                      'SINGLINK_RELEASE_KEY_ALIAS': 'synthetic', 'SINGLINK_RELEASE_KEY_PASSWORD': 'synthetic'}
            self.assertNotEqual(self.run_gate(values).returncode, 0)
    def test_no_private_signing_inputs_are_requested_by_pull_request_build(self):
        text = (HERE.parent / '.github/workflows/build.yml').read_text()
        self.assertNotIn('SINGLINK_RELEASE_', text)
        self.assertNotIn('PROTOCOL_REPO_TOKEN', text)
        self.assertIn('flutter build apk --debug', text)
        self.assertNotRegex(text, r'flutter build (apk|appbundle) --release')
    def test_ci_artifacts_are_named_as_unsigned_or_debug(self):
        text = (HERE.parent / '.github/workflows/build.yml').read_text()
        names = [line.split('name:', 1)[1].strip() for line in text.splitlines()
                 if line.strip().startswith('name: SingLinkVPN-')]
        self.assertEqual(len(names), 3)
        for name in names:
            self.assertRegex(name, r'(DEMO-debug|UNSIGNED)', name)
    def test_gradle_release_has_no_debug_signing_fallback(self):
        text = (HERE.parent / 'android/app/build.gradle.kts').read_text()
        self.assertNotIn('signingConfigs.getByName("debug")', text)
        self.assertIn('debug fallback is disabled', text)
        for key in ('SINGLINK_RELEASE_STORE_FILE', 'SINGLINK_RELEASE_STORE_PASSWORD',
                    'SINGLINK_RELEASE_KEY_ALIAS', 'SINGLINK_RELEASE_KEY_PASSWORD'):
            self.assertIn(key, text)

if __name__ == '__main__': unittest.main()
