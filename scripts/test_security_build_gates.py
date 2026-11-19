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

class WorkflowHardeningTests(unittest.TestCase):
    """A-H01: immutable actions, least-privilege tokens, signed provenance."""
    def setUp(self):
        import re
        self.re = re
        self.text = (HERE.parent / '.github/workflows/build.yml').read_text()
    def jobs(self):
        body = self.text.split('\njobs:\n', 1)[1]
        parts = self.re.split(r'\n  (?=[a-z][a-z0-9_-]*:\n)', '\n' + body)
        return {part.split(':', 1)[0].strip(): part for part in parts if part.strip()}
    def test_every_action_is_pinned_to_a_full_commit_sha(self):
        uses = [line.strip() for line in self.text.splitlines() if line.strip().startswith(('uses:', '- uses:'))]
        self.assertGreater(len(uses), 20)
        for line in uses:
            self.assertRegex(line, r'uses: [\w.-]+/[\w.-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+$', line)
    def test_token_permissions_are_least_privilege_per_job(self):
        self.assertIn('\npermissions: {}\n', self.text)
        jobs = self.jobs()
        self.assertEqual(set(jobs), {'test', 'windows', 'android', 'macos', 'ios'})
        for name, body in jobs.items():
            self.assertIn('    permissions:\n      contents: read\n', body, name)
            self.assertNotIn('write-all', body)
            self.assertNotRegex(body, r'contents: write|packages: write|actions: write', name)
            uploads = body.count('actions/upload-artifact@')
            if 'name: SingLinkVPN-' in body:
                self.assertIn('id-token: write', body, name)
                self.assertIn('attestations: write', body, name)
                self.assertEqual(body.count('actions/attest-build-provenance@'), uploads, name)
            else:
                self.assertNotIn('id-token: write', body, name)
    def test_windows_runs_the_full_flutter_suite(self):
        windows = self.jobs()['windows']
        self.assertRegex(windows, r'run: flutter test\n')

class FollowUpHardeningTests(unittest.TestCase):
    """VPN Labs follow-up (2026-11-19): App F-03, F-05, F-06, F-08."""
    def setUp(self):
        import re
        self.re = re
        self.root = HERE.parent
        self.text = (self.root / '.github/workflows/build.yml').read_text()
    def test_runner_images_are_pinned(self):
        runs_on = self.re.findall(r'runs-on: (\S+)', self.text)
        self.assertEqual(len(runs_on), 5)
        for image in runs_on:
            self.assertNotIn('latest', image)
            self.assertRegex(image, r'^(macos-\d+|ubuntu-\d+\.\d+|windows-\d{4})$')
    def test_every_checkout_drops_the_token(self):
        steps = self.text.split('- uses: actions/checkout@')[1:]
        self.assertEqual(len(steps), 10)
        for step in steps:
            self.assertIn('persist-credentials: false', step.split('\n      - ', 1)[0])
    def test_go_toolchain_and_govulncheck_are_pinned(self):
        gomod = (self.root / 'core/go.mod').read_text()
        version = self.re.search(r'^go (\d+)\.(\d+)\.(\d+)$', gomod, self.re.M)
        self.assertIsNotNone(version)
        self.assertGreaterEqual(tuple(map(int, version.groups())), (1, 27, 4))  # GO-2026-6859
        self.assertEqual(self.text.count('go-version-file: singlink-vpn-app/core/go.mod'), 5)
        self.assertRegex(self.text, r'go install golang.org/x/vuln/cmd/govulncheck@v\d+\.\d+\.\d+\n')
        self.assertNotRegex(self.text, r'govulncheck@(latest|master|main)')
        self.assertIn('/bin/govulncheck" ./...', self.text)
        # Every shipped core target is scanned: macOS, iOS, Android, Windows.
        self.assertIn('GOOS=ios GOARCH=arm64 CGO_ENABLED=1', self.text)
        self.assertIn('GOOS=android GOARCH=arm64 CGO_ENABLED=1', self.text)
        self.assertIn('go run golang.org/x/vuln/cmd/govulncheck@v1.10.0 ./...', self.text)
    def test_android_ndk_and_pub_lockfile_are_pinned(self):
        makefile = (self.root / 'core/Makefile').read_text()
        pinned = self.re.search(r"NDK_VERSION: '([\d.]+)'", self.text).group(1)
        self.assertIn('ndk/' + pinned, makefile)
        self.assertNotIn('ANDROID_NDK_LATEST_HOME', self.text)
        self.assertNotRegex(self.text, r'flutter pub get(?! --enforce-lockfile)')
    def test_mingw_is_pinned(self):
        self.assertRegex(self.text, r"MINGW_VERSION: '\d+\.\d+\.\d+'")
        self.assertIn('choco install mingw --version $env:MINGW_VERSION', self.text)
        self.assertNotRegex(self.text, r'choco install mingw(?! --version)')
    def test_gradle_distribution_is_checksummed(self):
        props = (self.root / 'android/gradle/wrapper/gradle-wrapper.properties').read_text()
        self.assertRegex(props, r'(?m)^distributionSha256Sum=[0-9a-f]{64}$')
        self.assertRegex(props, r'(?m)^distributionUrl=https\\://services\.gradle\.org/')
    def test_native_tests_run_in_ci(self):
        self.assertGreaterEqual(self.text.count("SINGLINK_REQUIRE_CABI_TEST: '1'"), 2)
        self.assertIn(':app:testDebugUnitTest', self.text)
    def test_macos_release_has_hardened_runtime_and_a_distribution_gate(self):
        pbx = (self.root / 'macos/Runner.xcodeproj/project.pbxproj').read_text()
        for name in ('Release', 'Profile'):
            block = self.re.search(r'/\* ' + name + r' \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbaseConfigurationReference = '
                                   r'[0-9A-F]+ /\* AppInfo\.xcconfig \*/;.*?\n\t\t\};', pbx, self.re.S)
            self.assertIsNotNone(block, name)
            self.assertIn('ENABLE_HARDENED_RUNTIME = YES;', block.group(0), name)
        self.assertIn('scripts/verify_macos_distribution.py', self.text)
        self.assertIn('runtime', self.text.split('Hardened runtime and distribution gate', 1)[1].split('- name:', 1)[0])
    def test_packet_tunnel_logs_no_public_detail(self):
        for path in list((self.root / 'ios').rglob('*.swift')) + list((self.root / 'macos').rglob('*.swift')) + \
                list((self.root / 'apple').rglob('*.swift')):
            text = path.read_text()
            for call in self.re.findall(r'os_log\((.*?)\)\n', text, self.re.S):
                # Every public object/string argument must be an error category.
                public = len(self.re.findall(r'%\{public\}[@s]', call))
                self.assertLessEqual(public, call.count('errorCategory('), f'{path.name}: public string in os_log')
            self.assertNotRegex(text, r'Logger\(|NSLog\(|print\(', path.name)

class MacDistributionGateTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('macgate', HERE / 'verify_macos_distribution.py')
        self.gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.gate)
    ADHOC = ('Executable=/x/SingLinkVPN.app/Contents/MacOS/SingLinkVPN\n'
             'CodeDirectory v=20500 size=1 flags=0x10002(adhoc,runtime) hashes=1+7 location=embedded\n'
             'Signature=adhoc\nTeamIdentifier=not set\n')
    DEVID = ('CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+7 location=embedded\n'
             'Authority=Developer ID Application: Example Org (ABCDE12345)\n'
             'Authority=Developer ID Certification Authority\nAuthority=Apple Root CA\n'
             'Timestamp=19 Nov 2026 at 10:00:00\nTeamIdentifier=ABCDE12345\n')
    def test_adhoc_build_is_rejected(self):
        problems = self.gate.check_signature(self.gate.parse_codesign_details(self.ADHOC), 'app', True)
        self.assertTrue(any('ad-hoc' in p for p in problems))
        self.assertTrue(any('team' in p for p in problems))
    def test_developer_id_with_runtime_and_timestamp_passes_signature_checks(self):
        details = self.gate.parse_codesign_details(self.DEVID)
        self.assertEqual(self.gate.check_signature(details, 'app', True), [])
        no_runtime = self.gate.parse_codesign_details(self.DEVID.replace('0x10000(runtime)', '0x0(none)'))
        self.assertTrue(self.gate.check_signature(no_runtime, 'app', True))
        no_ts = self.gate.parse_codesign_details(self.DEVID.replace('Timestamp=19 Nov 2026 at 10:00:00\n', ''))
        self.assertTrue(self.gate.check_signature(no_ts, 'app', True))
    def test_entitlements_and_gatekeeper(self):
        self.assertEqual(self.gate.check_entitlements({'com.apple.security.app-sandbox': False,
                                                       'com.apple.security.network.client': True}), [])
        self.assertTrue(self.gate.check_entitlements({'com.apple.security.cs.disable-library-validation': True}))
        self.assertTrue(self.gate.check_entitlements({'com.apple.security.cs.allow-jit': True}))
        self.assertEqual(self.gate.check_gatekeeper('x: accepted\nsource=Notarized Developer ID\n', 0), [])
        self.assertTrue(self.gate.check_gatekeeper('x: rejected\nsource=no usable signature\n', 3))
        self.assertTrue(self.gate.check_gatekeeper('x: accepted\nsource=Developer ID\n', 0))
    def test_release_entitlements_keep_library_validation(self):
        import plistlib
        runner = HERE.parent / 'macos/Runner'
        strict = plistlib.loads((runner / 'Release.entitlements').read_bytes())
        adhoc = plistlib.loads((runner / 'Release-AdHoc.entitlements').read_bytes())
        self.assertEqual(self.gate.check_entitlements(strict), [])
        self.assertNotIn('com.apple.security.cs.disable-library-validation', strict)
        self.assertNotIn('com.apple.security.cs.allow-jit', strict)
        self.assertTrue(self.gate.check_entitlements(adhoc), 'the ad-hoc variant must never pass the gate')
        pbx = (HERE.parent / 'macos/Runner.xcodeproj/project.pbxproj').read_text()
        # Team builds (Developer ID) resolve to Release.entitlements; only a
        # team-less (ad-hoc) build gets the -AdHoc suffix.
        self.assertIn('CODE_SIGN_ENTITLEMENTS = "Runner/Release$(SINGLINK_ADHOC_ENTITLEMENTS_$(DEVELOPMENT_TEAM)).entitlements";', pbx)
        self.assertEqual(pbx.count('SINGLINK_ADHOC_ENTITLEMENTS_ = "-AdHoc";'), 1)
    def test_unreadable_entitlements_fail_closed(self):
        self.assertTrue(self.gate.entitlement_problems(0, ''))
        self.assertTrue(self.gate.entitlement_problems(1, '<?xml version="1.0"?><plist><dict/></plist>'))
        self.assertTrue(self.gate.entitlement_problems(0, '<?xml version="1.0"?><plist><array/></plist>'))
        ok = ('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
              '<key>com.apple.security.network.client</key><true/></dict></plist>')
        self.assertEqual(self.gate.entitlement_problems(0, ok), [])
    def test_gate_rejects_a_folder_that_is_not_an_app(self):
        with tempfile.TemporaryDirectory(prefix='synthetic-mac-gate-') as tmp:
            self.assertTrue(self.gate.verify(tmp))

if __name__ == '__main__': unittest.main()
