#!/usr/bin/env bash
# Build the SPM target and wrap the binary in a proper .app bundle so
# macOS treats it as a real application (LSUIElement menu bar, TCC
# permission prompts, Info.plist).
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Phonon"
BUILD_DIR=".build/release"
APP_DIR="build/${APP_NAME}.app"

echo "==> Building release binary…"
# Use the Xcode toolchain (matches the installed macOS SDK). Do NOT source the
# swiftly toolchain here — its older swift-frontend crashes against the current
# MacOSX SDK's module map (signal 6 in performSema).
export PATH="/usr/bin:${PATH}"
hash -r 2>/dev/null || true
/usr/bin/swift build -c release --arch arm64

echo "==> Packaging ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Bundle/Info.plist" "${APP_DIR}/Contents/Info.plist"

# App icon (orb) + menu-bar orb image
cp "Bundle/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cp Resources/MenuBarOrb*.png "${APP_DIR}/Contents/Resources/" 2>/dev/null || true

# Bundle the frozen model server (PyInstaller onedir) so colleagues need no
# Python. Optional in dev (falls back to the launchd server if absent).
if [ -d "dist/phonon-server" ]; then
  echo "==> Embedding frozen server (dist/phonon-server)…"
  rm -rf "${APP_DIR}/Contents/Resources/server"
  mkdir -p "${APP_DIR}/Contents/Resources/server"
  cp -R dist/phonon-server/. "${APP_DIR}/Contents/Resources/server/"
else
  echo "==> dist/phonon-server not found — building a thin app (relies on the launchd server)"
fi

# No model is bundled into the .app anymore: transcription + cleanup are done
# by the MLX omni server (scripts/start_server.sh, MiniCPM-o 4.5), which the
# app reaches over http://127.0.0.1:8799.

# Sign with a STABLE self-signed identity so the designated requirement is
# cert-based (not cdhash-based) — TCC permission grants then survive rebuilds.
# Falls back to ad-hoc if the identity isn't installed.
SIGN_ID="${S2T_SIGN_IDENTITY:-Speech2Text}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"${SIGN_ID}\""; then
  echo "==> Signing with '${SIGN_ID}' (stable identity)"
  codesign --force --deep --sign "${SIGN_ID}" "${APP_DIR}"
else
  echo "==> '${SIGN_ID}' identity not found; ad-hoc signing (permissions will reset each build)"
  codesign --force --deep --sign - "${APP_DIR}"
fi

# Keep the installed copy in sync. Building only into build/ meant a stale
# /Applications/Phonon.app kept launching from Launchpad/Spotlight with none of
# the new changes — the copy you actually use must be the copy you just built.
# (ditto preserves the code signature; cp -R does not reliably.)
INSTALLED="/Applications/${APP_NAME}.app"
if [ -d "${INSTALLED}" ] || [ "${S2T_INSTALL:-0}" = "1" ]; then
  echo "==> Installing to ${INSTALLED}…"
  pkill -x "${APP_NAME}" 2>/dev/null || true
  sleep 1
  rm -rf "${INSTALLED}"
  ditto "${APP_DIR}" "${INSTALLED}"
  echo "    installed (relaunch: open '${INSTALLED}')"
else
  echo "==> /Applications/${APP_NAME}.app not present — build only."
  echo "    (S2T_INSTALL=1 bash scripts/bundle.sh 会顺手装进 /Applications)"
fi

echo "==> Done: ${APP_DIR}"
echo "Run it with: open ${APP_DIR}"
