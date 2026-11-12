#!/bin/bash
# Copyright 2026 SingLinkLabs (https://github.com/SingLinkLabs)
# SPDX-License-Identifier: Apache-2.0

# Copies the SingLink Protocol core (libsinglink.dylib) into <App>.app/Contents/Frameworks
# and code-signs it.
#
# Two modes:
#   --xcode                 Run from the Runner target's "Bundle libsinglink core"
#                           build phase (automatic on `flutter build macos` /
#                           `flutter run -d macos`). Xcode signs the whole app
#                           afterwards, so only the dylib is signed here.
#   [debug|profile|release] Standalone, after `flutter build macos --<mode>`.
#                           Copies, signs the dylib, then re-signs the .app with
#                           the matching entitlements. Default: release.
#
# Environment:
#   SINGLINK_CORE_LIB        source dylib (default: the app's own core
#                            <app>/core/build/macos/libsinglink.dylib from
#                            `make -C core macos`, same ABI plus TUN; falls back to
#                            <app>/../singlink-protocol/build/libsinglink.dylib)
#   SINGLINK_REQUIRE_CORE=1  fail instead of warning when the dylib is missing
#   CODESIGN_IDENTITY   standalone mode only (default "-" = ad-hoc)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_CORE_LIB="$APP_DIR/core/build/macos/libsinglink.dylib"
PROTOCOL_CORE_LIB="$APP_DIR/../singlink-protocol/build/libsinglink.dylib"
if [[ -n "${SINGLINK_CORE_LIB:-}" ]]; then
  LIB_SRC="$SINGLINK_CORE_LIB"
elif [[ -f "$APP_CORE_LIB" ]]; then
  LIB_SRC="$APP_CORE_LIB"
else
  LIB_SRC="$PROTOCOL_CORE_LIB"
fi
LIB_NAME="libsinglink.dylib"

warn() { echo "warning: [singlink] $*" >&2; }
die() { echo "error: [singlink] $*" >&2; exit 1; }

missing_core() {
  if [[ "${SINGLINK_REQUIRE_CORE:-0}" == "1" ]]; then
    die "core library not found at $LIB_SRC"
  fi
  warn "core library not found at $LIB_SRC — app will start and show the 'libsinglink.dylib missing' banner."
  exit 0
}

sign_dylib() { # $1 = dylib, $2 = identity
  local id="$2"
  if [[ -z "$id" ]]; then id="-"; fi
  codesign --force --sign "$id" --timestamp=none "$1"
}

# Xcode only re-signs the .app when one of its own tracked inputs changed. On
# an incremental build where only Dart code changed, Flutter's embed phase
# replaces and re-signs App.framework but Xcode skips the final CodeSign, so
# the outer seal goes stale ("nested code is modified or invalid"). This phase
# always runs after Flutter's, so it re-seals the app with the entitlements
# Xcode itself produced (.xcent). When Xcode's CodeSign does run afterwards it
# simply signs again.
reseal_app() {
  [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" ]] && return 0
  local app="$BUILT_PRODUCTS_DIR/${WRAPPER_NAME:-}"
  [[ -n "${WRAPPER_NAME:-}" && -d "$app" && -f "$BUILT_PRODUCTS_DIR/${EXECUTABLE_PATH:-}" ]] || return 0
  local id="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  [[ -z "$id" ]] && id="-"
  local ent="${TARGET_TEMP_DIR:-}/${WRAPPER_NAME}.xcent"
  [[ -f "$ent" ]] || ent="${SRCROOT:-}/${CODE_SIGN_ENTITLEMENTS:-}"
  local args=(--force --sign "$id" --timestamp=none)
  [[ -f "$ent" ]] && args+=(--entitlements "$ent")
  [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]] && args+=(--options runtime)
  codesign "${args[@]}" "$app"
}

if [[ "${1:-}" == "--xcode" ]]; then
  : "${BUILT_PRODUCTS_DIR:?must run inside an Xcode build phase}"
  : "${FRAMEWORKS_FOLDER_PATH:?must run inside an Xcode build phase}"
  if [[ -f "$LIB_SRC" ]]; then
    DEST_DIR="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
    mkdir -p "$DEST_DIR"
    cp -f "$LIB_SRC" "$DEST_DIR/$LIB_NAME"
    chmod 755 "$DEST_DIR/$LIB_NAME"
    if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
      sign_dylib "$DEST_DIR/$LIB_NAME" "${EXPANDED_CODE_SIGN_IDENTITY:-}"
    fi
    echo "[singlink] bundled $LIB_SRC -> $DEST_DIR/$LIB_NAME"
  elif [[ "${SINGLINK_REQUIRE_CORE:-0}" == "1" ]]; then
    die "core library not found at $LIB_SRC"
  else
    warn "core library not found at $LIB_SRC — app will start and show the 'libsinglink.dylib missing' banner."
  fi
  reseal_app
  exit 0
fi

MODE="$(echo "${1:-release}" | tr '[:upper:]' '[:lower:]')"
case "$MODE" in
  debug)   CONFIG=Debug;   ENT="$APP_DIR/macos/Runner/DebugProfile.entitlements" ;;
  profile) CONFIG=Profile; ENT="$APP_DIR/macos/Runner/DebugProfile.entitlements" ;;
  release) CONFIG=Release; ENT="$APP_DIR/macos/Runner/Release.entitlements" ;;
  *) die "usage: $0 [--xcode | debug | profile | release]" ;;
esac

APP="$APP_DIR/build/macos/Build/Products/$CONFIG/SingLinkVPN.app"
[[ -d "$APP" ]] || die "$APP not found — run: flutter build macos --$MODE"
[[ -f "$LIB_SRC" ]] || missing_core

ID="${CODESIGN_IDENTITY:--}"
mkdir -p "$APP/Contents/Frameworks"
cp -f "$LIB_SRC" "$APP/Contents/Frameworks/$LIB_NAME"
chmod 755 "$APP/Contents/Frameworks/$LIB_NAME"
sign_dylib "$APP/Contents/Frameworks/$LIB_NAME" "$ID"
# Contents changed, so the outer signature must be regenerated. Nested
# frameworks are already signed by the Flutter build; no --deep needed.
codesign --force --sign "$ID" --timestamp=none --entitlements "$ENT" "$APP"
codesign --verify --strict "$APP"
echo "[singlink] bundled $(lipo -archs "$APP/Contents/Frameworks/$LIB_NAME" 2>/dev/null || echo '?') $LIB_NAME into $APP"
