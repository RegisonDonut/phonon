#!/usr/bin/env bash
# Build Phonon.app (with embedded frozen server) and zip it up with install
# instructions into a single file you can send to a colleague.
#
#   ./scripts/package.sh
#
# Output: build/Phonon-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Bundle/Info.plist 2>/dev/null || echo 0.1.0)"

echo "==> Building app bundle…"
./scripts/bundle.sh

STAGE="build/Phonon-dist"
ZIP="build/Phonon-${VERSION}.zip"
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
cp -R "build/Phonon.app" "$STAGE/"
cp "Bundle/安装说明.txt" "$STAGE/" 2>/dev/null || true

echo "==> Zipping (ditto preserves the code signature)…"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"

echo "==> Done:"
ls -lh "$ZIP" | awk '{print "    " $9 "  (" $5 ")"}'
echo "    内含 Phonon.app + 安装说明.txt"
echo "    发给同事即可；首次运行会自动下载 5.7GB 模型。"
