#!/usr/bin/env bash
# Builds Lenscap in release mode, assembles dist/Lenscap.app, wraps it in a
# dist/Lenscap-<version>.dmg, and (optionally) notarizes + staples when a
# Developer ID certificate and notary credentials are configured.
#
# Requirements (best-effort, script degrades gracefully):
#   swift           — the Swift toolchain (Xcode CLT).
#   codesign        — a codesigning identity. Defaults to the first "Apple
#                     Development" cert on the machine so the Screen
#                     Recording TCC grant survives rebuilds. Override with
#                     LENSCAP_SIGN_IDENTITY="Developer ID Application: …".
#   hdiutil         — DMG creation (part of macOS).
#
# Notarization (only runs when ALL are present; silently skipped otherwise):
#   LENSCAP_SIGN_IDENTITY   set to a "Developer ID Application: …" identity.
#   LENSCAP_NOTARY_PROFILE  a `xcrun notarytool` keychain profile created via
#                           `xcrun notarytool store-credentials <profile> --apple-id …`.
#                           Omit to skip notarization.
#   hardened runtime        --- applied automatically for Developer ID builds ---
#
# Shell out nothing we don't need; fail loudly, not silently.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="1.0.0"
APP="dist/Lenscap.app"
DMG="dist/Lenscap-${VERSION}.dmg"

echo "==> Building Lenscap (release)…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/Lenscap"

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Lenscap"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.rutmehta.lenscap</string>
    <key>CFBundleName</key>
    <string>Lenscap</string>
    <key>CFBundleExecutable</key>
    <string>Lenscap</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# --- Signing ---------------------------------------------------------------
# Sign with a stable identity when one is available. Ad-hoc signatures get a
# new code identity on every build, which makes macOS forget the Screen
# Recording grant after each rebuild; a real (even "Apple Development")
# identity keeps the designated requirement stable so TCC grants survive.
# A hardened runtime (`--options runtime`) is required for notarization and is
# applied automatically when a Developer ID identity is used.
#
# The auto-detected identity is a *candidate* only: it is only used if the
# codesign attempt succeeds. If it fails (missing chain / wrong keychain) and
# no explicit LENSCAP_SIGN_IDENTITY was given, we fall back to ad-hoc signing
# rather than aborting — an ad-hoc DMG is still installable, just not notarized.
IDENTITY="${LENSCAP_SIGN_IDENTITY:-}"
EXPLICIT_IDENTITY="${LENSCAP_SIGN_IDENTITY:-}"
if [[ -z "${IDENTITY}" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Apple Development/ {print $2; exit}' || true)
fi

SIGN_OPTS=(--force)
if [[ "${IDENTITY}" == "Developer ID"* ]]; then
    SIGN_OPTS+=(--options runtime)
fi

if [[ -n "${IDENTITY}" ]]; then
    echo "==> Code signing with: ${IDENTITY}"
    if codesign "${SIGN_OPTS[@]}" -s "${IDENTITY}" "$APP" 2>/dev/null; then
        :
    elif [[ -n "${EXPLICIT_IDENTITY}" ]]; then
        echo "ERROR: explicit LENSCAP_SIGN_IDENTITY failed to codesign; aborting."
        codesign "${SIGN_OPTS[@]}" -s "${IDENTITY}" "$APP"
        exit 1
    else
        echo "    NOTE: auto-detected identity could not code-sign this machine"
        echo "    (missing certificate chain). Falling back to ad-hoc signature."
        IDENTITY=""
    fi
fi

if [[ -z "${IDENTITY}" ]]; then
    echo "==> No usable signing identity — ad-hoc signing."
    echo "    NOTE: ad-hoc builds get a new code identity every rebuild, so macOS"
    echo "    will re-ask for Screen Recording permission after each rebuild, and"
    echo "    the DMG will show a Gatekeeper warning on fresh Macs."
    codesign --force -s - "$APP"
fi

# --- DMG --------------------------------------------------------------------
echo "==> Creating ${DMG}…"
STAGE="dist/.dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Lenscap ${VERSION}" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# --- Notarization (optional) ------------------------------------------------
# Requires Developer ID signing + a stored notarytool profile. Skipped with a
# clear note when either is missing.
if [[ "${LENSCAP_NOTARY_PROFILE:-}" != "" && "${IDENTITY}" == "Developer ID"* ]]; then
    echo "==> Submitting ${DMG} to Apple notary service…"
    xcrun notarytool submit "$DMG" --keychain-profile "$LENSCAP_NOTARY_PROFILE" \
        --wait 2>&1 | tail -n +1
    echo "==> Stapling notarization ticket into ${DMG}…"
    xcrun stapler staple "$DMG"
else
    if [[ "${LENSCAP_NOTARY_PROFILE:-}" != "" ]]; then
        echo "    NOTE: LENSCAP_NOTARY_PROFILE is set but the signing identity is not a"
        echo "    Developer ID cert — notarization skipped. Re-run with a Developer ID"
        echo "    Application certificate to notarize."
    else
        echo "    NOTE: LENSCAP_NOTARY_PROFILE unset — DMG is signed but NOT notarized."
        echo "    Fresh Macs will show a Gatekeeper warning until it is notarized."
    fi
fi

echo
echo "Done:"
echo "  ${APP}"
echo "  ${DMG}"
echo
echo "Next steps:"
echo "  1. Mount ${DMG} and drag Lenscap.app to /Applications."
echo "  2. First launch (if not notarized): right-click Lenscap.app > Open."
echo "  3. Grant Screen Recording permission when prompted:"
echo "     System Settings > Privacy & Security > Screen Recording."