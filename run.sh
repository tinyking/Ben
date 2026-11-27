#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$ROOT/.build/Build/Products/Debug/Ben.app"

cd "$ROOT"
xcodebuild -project BenApp.xcodeproj -scheme Ben \
  -configuration Debug -derivedDataPath .build build

# Bind Info.plist & debug dylib with an ad-hoc bundle signature for LaunchServices.
/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# Quit existing Ben instances and wait until the old PID fully exits, avoiding
# LaunchServices error -600 (procNotFound) when `open` races a dying process.
if /usr/bin/pgrep -x Ben >/dev/null 2>&1; then
  /usr/bin/killall Ben 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    /usr/bin/pgrep -x Ben >/dev/null 2>&1 || break
    /bin/sleep 0.1
  done
  if /usr/bin/pgrep -x Ben >/dev/null 2>&1; then
    /usr/bin/killall -9 Ben 2>/dev/null || true
    /bin/sleep 0.1
  fi
fi

/usr/bin/open "$APP" || /usr/bin/open -n "$APP"
