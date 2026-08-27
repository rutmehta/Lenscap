#!/usr/bin/env bash
# ============================================================================
# Cut a Sparkle-signed release for Lenscap.
#
# Builds the DMG (delegating to make-app.sh), signs the DMG payload so Sparkle
# can verify it, prepends a matching <item> to appcast.xml, then signs the feed
# itself. Prints the git tag + GitHub release commands (does NOT push/tag or
# publish a release on its own).
#
# The EdDSA PRIVATE seed never lives in this repo. It is read from
# LENSCAP_EDDSA_KEY_FILE each run. The matching PUBLIC key is committed in
# Config/branding.sh as SPARKLE_PUBLIC_ED_KEY and embedded in the app.
#
# Required prerequisites:
#   * Signing key. Generate once, keep private:
#         python3 - <<'PY'
#         from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
#         import base64
#         k = Ed25519PrivateKey.generate()
#         seed = k.private_bytes(__import__('cryptography').hazmat.primitives.serialization.Encoding.Raw,
#                                __import__('cryptography').hazmat.primitives.serialization.PrivateFormat.Raw,
#                                __import__('cryptography').hazmat.primitives.serialization.NoEncryption())
#         print(base64.b64encode(seed).decode())
#         PY
#     Store that base64 seed in a file, e.g. ~/.lenscap-dist-keys/sparkle_seed.b64
#     (default path below). Set SPARKLE_PUBLIC_ED_KEY in Config/branding.sh to the
#     matching public key.
#   * sign_update tool from the official Sparkle release tarball
#     (https://github.com/sparkle-project/Sparkle/releases) — point SPARKLE_BIN_DIR
#     at the dir containing it (defaults to ./bin adjacent to this repo + /usr/local/bin).
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source Config/branding.sh

DMG="dist/${PRODUCT_NAME}-${PRODUCT_VERSION}.dmg"

# --- Locate dependencies ----------------------------------------------------
KEY_FILE="${LENSCAP_EDDSA_KEY_FILE:-$HOME/.lenscap-dist-keys/sparkle_seed.b64}"
SIGN_UPDATE="${SPARKLE_BIN_DIR:+$SPARKLE_BIN_DIR/sign_update}"
if [[ -z "${SIGN_UPDATE}" || ! -x "${SIGN_UPDATE}" ]]; then
  candidate="$(command -v sign_update || true)"
  if [[ -n "${candidate}" ]]; then SIGN_UPDATE="${candidate}"; fi
fi
if [[ -z "${SIGN_UPDATE}" || ! -f "${SIGN_UPDATE}" ]]; then
  echo "ERROR: sign_update not found. Point SPARKLE_BIN_DIR at the Sparkle release dir." >&2
  exit 1
fi
if [[ ! -f "${KEY_FILE}" ]]; then
  echo "ERROR: signing seed not found at ${KEY_FILE}. Set LENSCAP_EDDSA_KEY_FILE." >&2
  exit 1
fi

# --- Build the DMG -----------------------------------------------------------
Scripts/make-app.sh

# --- Sign the DMG payload → enclosure signature + length ---------------------
DMG_SIZE="$(stat -f %z "$DMG")"
DMG_SIG="$("$SIGN_UPDATE" -p --ed-key-file "$KEY_FILE" "$DMG" | tr -d '\n')"
echo "==> DMG signature: ${DMG_SIG}"
echo "==> DMG length:    ${DMG_SIZE}"

# --- Prepend a signed <item> to appcast.xml ----------------------------------
# Keep an in-repo placeholder feed in sync: build a new <item> and inject it
# after <channel>. Preserve existing items (each older release stays listed).
NEW_ITEM="    <item>
      <title>Version ${PRODUCT_VERSION}</title>
      <pubDate>$(date -u +'%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>${PRODUCT_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${PRODUCT_VERSION}</sparkle:shortVersionString>
      <description>${PRODUCT_NAME} ${PRODUCT_VERSION}</description>
      <enclosure url=\"${GITHUB_REPO_URL}/releases/download/v${PRODUCT_VERSION}/${PRODUCT_NAME}-${PRODUCT_VERSION}.dmg\" sparkle:edSignature=\"${DMG_SIG}\" length=\"${DMG_SIZE}\" type=\"application/octet-stream\"/>
    </item>"

# Insert new item right after the channel opening tag, stripping the old
# unsigned feed signature block so sign_update re-signs cleanly.
TMP="$(mktemp)"
python3 - "$TMP" "$NEW_ITEM" <<'PY'
import re, sys
out_path, new_item = sys.argv[1], sys.argv[2]
src = open('appcast.xml').read()
# Remove trailing Sparkle sig + warning comment blocks if present
src = re.sub(r'\s*<!-- sparkle-signatures:.*?-->\s*$', '\n', src, flags=re.S)
src = re.sub(r'\s*<!-- sparkle-sign-warning:.*?-->\s*', '', src, flags=re.S)
# Insert the new item immediately BEFORE the first existing <item> element
# (anchored at line-start so doc-comment mentions of "<item>" are ignored),
# keeping channel metadata (title/link/description/language) above all items.
m = re.search(r'^\s*<item>', src, flags=re.M)
if not m:
    sys.exit('appcast.xml: no <item> element found to anchor new item')
src = src[:m.start()] + new_item + "\n" + src[m.start():]
open(out_path, 'w').write(src)
PY
mv "$TMP" appcast.xml

# --- Re-sign the feed --------------------------------------------------------
"$SIGN_UPDATE" --ed-key-file "$KEY_FILE" appcast.xml

echo
echo "==> appcast.xml updated and re-signed."
echo
echo "To ship this release (manual, not automated):"
echo "  1. Commit the source, version metadata, and signed appcast (not the DMG)."
echo "  2. git tag v${PRODUCT_VERSION} && git push origin v${PRODUCT_VERSION}"
echo "  3. Publish a GitHub release for v${PRODUCT_VERSION} and attach:"
echo "       ${DMG}"
echo "     replacing the placeholder enclosure URL in appcast.xml if your"
echo "     release asset name differs, then re-run sign_update on appcast.xml."
echo "  4. Verify the release asset URL is public, then push the commit to main"
echo "     to publish the appcast. Upload the DMG before updating the live feed."
