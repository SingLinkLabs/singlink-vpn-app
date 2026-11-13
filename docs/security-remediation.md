# Security controls for the first-generation open-source client

This document describes implementation boundaries, not an audit-pass or commercial
application claim. Independent verification and device testing are separate steps.

## Protected credentials and migration

Ordinary app JSON contains display metadata and opaque references. The complete
connection link and exact warning acknowledgement live together in a native
protected record. Production does not select the in-memory store used by tests.

- Android: a non-exportable Android Keystore AES-GCM key protects per-reference
  ciphertext, with fresh IVs and reference-bound authentication. Ciphertext is
  stored under `noBackupFilesDir`; ordinary backup is disabled explicitly. Hardware
  backing, StrongBox and device-lock behavior require device-specific verification.
- iOS: app and extension use a matching build-expanded Keychain access group and
  `AfterFirstUnlockThisDeviceOnly`, without iCloud synchronization. The OS tunnel
  configuration contains only a reference. A real signed device is still needed
  to verify extension sharing, provisioning, reboot and locked-device behavior.
- macOS: the native login Keychain is used without claiming iOS accessibility
  semantics or hardware protection. Distribution signing/notarization is separate.
- Windows: DPAPI uses the current user, with encrypted files in app-local storage,
  reference-bound entropy and immutable-reference writes. Full Windows runtime
  tests are separate from compilation. Other code running as that user can still
  be inside the threat boundary.

The legacy JSON migration writes and verifies a protected record before committing
metadata. A reference-only transaction journal supports crash recovery. Locked,
missing, corrupt or unavailable stores block connection rather than using a
plaintext fallback. Failed migration keeps the existing legacy data for retry.
After metadata commit, removed app-owned records are deleted; failed cleanup stays
queued and is retried. This does not erase user-created backups, snapshots, swap,
crash dumps or historical disk blocks. Do not place real profiles in tests/logs.

## Lifecycle and warnings

Connection generations invalidate late completions. New starts wait for obsolete
owned cleanup, and shutdown waits for start/proxy cleanup before returning.
Normal quit waits for that barrier; a cleanup failure cancels quit and allows a
visible retry. A forced process termination cannot make the same guarantee.
Platform callbacks reject obsolete consent, service and tunnel starts. The Go TUN
watcher stops only its owning client, using `Engine.StopClient`.

Warnings from the real parser reach an explicit confirmation dialog. Cancellation
or absent acknowledgement prevents import. Acknowledgement is bound to the exact
protected link and is rechecked on connection, including extension starts from
iOS Settings. Unknown warning forms fail closed for review.

## Protected release signing

Debug/demo builds use only a generated debug identity and must be labelled as such.
Android release tasks require externally supplied values for:

- `SINGLINK_RELEASE_STORE_FILE`
- `SINGLINK_RELEASE_STORE_PASSWORD`
- `SINGLINK_RELEASE_KEY_ALIAS`
- `SINGLINK_RELEASE_KEY_PASSWORD`

Use a private external keystore and a protected local/CI environment. Never commit
keystores, passwords, signing certificates, personal team identifiers or production
secrets. The release gate rejects absent inputs and the default `debug.keystore`;
Gradle still validates the actual certificate/password when signing. Presence of
inputs alone does not prove a distribution artifact is properly signed. Verify
its certificate fingerprint through the trusted release process. Public pull
requests have no release signing inputs and produce demo debug artifacts only.

## Pinned core source

`core/protocol-revision.txt` is the single immutable reviewed protocol revision.
Every supported Make/build/package entry point and CI job verifies the sibling
checkout and rejects a dirty or mismatched tree. Native `.source.json` stamps bind
the protocol commit, app core source hash and artifact hash. Android rebuilds stale
artifacts; Apple/Windows packaging rejects them. Rebuild artifacts after changing
the pin or app-core source. A stamp is reproducibility bookkeeping, not a signed
release attestation and not a replacement for independent review.

## Verification commands

Use fresh synthetic profiles and isolated test environments only:

```
python3 scripts/test_security_build_gates.py
make -C core test macos
flutter analyze
flutter test
```

The real-parser test generates fresh issuer/node/device keys at runtime and uses
loopback profile addresses without connecting. Native Android instrumentation must
run on a fresh test emulator. iOS `RunnerTests` must run only on a newly created
isolated Simulator; a missing entitlement is an explicit skip, not a successful
shared-Keychain result. Simulator support does not imply a working VPN extension.

## Platform references

- [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
- [Android backup controls](https://developer.android.com/identity/data/autobackup)
- [Android signing](https://developer.android.com/studio/publish/app-signing)
- [Apple shared Keychain access](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- [Apple Keychain accessibility](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)
- [Windows current-user DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)
