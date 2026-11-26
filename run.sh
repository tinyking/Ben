#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$ROOT/.build/Build/Products/Debug/Ben.app"

cd "$ROOT"
xcodebuild -project BenApp.xcodeproj -scheme Ben \
  -configuration Debug -derivedDataPath .build build

# Quit all existing Ben instances so Launch Services cannot reactivate an older
# process with the same bundle identifier.
/usr/bin/killall Ben 2>/dev/null || true
/usr/bin/open "$APP"
