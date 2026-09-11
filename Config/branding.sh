#!/usr/bin/env bash
# ============================================================================
# Centralized product branding + bundle metadata for Lenscap.
#
# Every user-visible name, identifier, URL, and Sparkle feed constant lives in
# this single file so the upcoming rename is a one-file, auditable change.
# Do not let "Lenscap" literals snowball elsewhere in the packaging scripts —
# reference these variables from Scripts/make-app.sh and Scripts/release-update.sh.
#
# Sourced (not executed) by make-app.sh / release-update.sh. Every variable
# is overridable from the environment so CI and ad-hoc builds can vary them.
# ============================================================================
set -euo pipefail

# --- Product identity (these all change together on a rename) --------------
export PRODUCT_NAME="${PRODUCT_NAME:-Lenscap}"            # display name: menu bar, DMG, About
export EXECUTABLE_NAME="${EXECUTABLE_NAME:-Lenscap}"      # binary name / CFBundleExecutable
export BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.rutmehta.lenscap}"
export DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-Lenscap}"      # DMG volume base name (version appended)
export PRODUCT_VERSION="${PRODUCT_VERSION:-1.1.2}"        # CFBundleShortVersionString / CFBundleVersion

# --- Distribution / update endpoints ---------------------------------------
export GITHUB_REPO_URL="${GITHUB_REPO_URL:-https://github.com/rutmehta/Lenscap}"
# Stable Sparkle feed URL. Committed appcast.xml is served here (public repo).
# Swap to GitHub Pages (https://<user>.github.io/Lenscap/appcast.xml) if you
# prefer Pages over raw.githubusercontent.
export SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/rutmehta/Lenscap/main/appcast.xml}"

# --- Sparkle EdDSA public key ----------------------------------------------
# Public half of the update-signing keypair, embedded in the app so Sparkle can
# verify the appcast + downloaded update. The matching PRIVATE seed is never
# committed — see Scripts/release-update.sh for how the release signs updates.
export SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-3fY79ciYrDtMK+UcU2fFZ0qTv3HrMffH9GUOJoIrcyc=}"
