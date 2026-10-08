#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cmdsplit-build.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_bundle="$task_build/CmdSplit.app"
mkdir -p "$task_bundle/Contents/MacOS"
cp -X Info.plist "$task_bundle/Contents/Info.plist"
/usr/bin/swiftc -O -target arm64-apple-macosx13.0 CmdSplit.swift \
    -o "$task_bundle/Contents/MacOS/CmdSplit" \
    -framework AppKit -framework ApplicationServices -framework Carbon
/usr/bin/xattr -cr "$task_bundle"
/usr/bin/codesign --force --sign - --identifier local.ychen.CmdSplit "$task_bundle"
/usr/bin/codesign --verify --strict "$task_bundle"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$task_bundle" CmdSplit.app.zip
printf '%s\n' '构建完成：CmdSplit.app.zip'
