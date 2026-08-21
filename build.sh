#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release 2>&1 | tail -5

APP="build/TokenSpend.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TokenSpend "$APP/Contents/MacOS/TokenSpend"
cp packaging/Info.plist "$APP/Contents/Info.plist"

SIGN_IDENTITY="${TOKENSPEND_SIGN_IDENTITY:-TokenSpend Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    codesign --force --sign "$SIGN_IDENTITY" --identifier com.peilin.tokenspend "$APP"
    echo "Signed with: $SIGN_IDENTITY"
else
    codesign --force --sign - --identifier com.peilin.tokenspend "$APP" >/dev/null 2>&1 || true
    echo "Signed: ad-hoc (stable identity not found)"
fi

echo "Built: $(pwd)/$APP"
echo "Run:   open $APP"
