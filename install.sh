#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
task_label='local.ychen.CmdSplit'
task_domain="gui/$(id -u)"
task_app="$HOME/Applications/CmdSplit.app"
task_agent="$HOME/Library/LaunchAgents/$task_label.plist"
task_extract="$(mktemp -d "${TMPDIR:-/tmp}/cmdsplit-install.XXXXXX")"
trap 'rm -rf "$task_extract"' EXIT
/usr/bin/ditto -x -k CmdSplit.app.zip "$task_extract"
test -x "$task_extract/CmdSplit.app/Contents/MacOS/CmdSplit"
/usr/bin/codesign --verify --strict "$task_extract/CmdSplit.app"
/bin/launchctl bootout "$task_domain/$task_label" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/CmdSplit"
if test -e "$task_app"; then
    task_backup="$HOME/Applications/CmdSplit-backup-$(date +%Y%m%d-%H%M%S).app"
    mv "$task_app" "$task_backup"
fi
/usr/bin/ditto --norsrc --noextattr "$task_extract/CmdSplit.app" "$task_app"
rm -f "$task_agent"
/usr/bin/plutil -create xml1 "$task_agent"
/usr/bin/plutil -insert Label -string "$task_label" "$task_agent"
/usr/bin/plutil -insert ProgramArguments -json "[]" "$task_agent"
/usr/bin/plutil -insert ProgramArguments.0 -string "$task_app/Contents/MacOS/CmdSplit" "$task_agent"
/usr/bin/plutil -insert RunAtLoad -bool YES "$task_agent"
/usr/bin/plutil -insert KeepAlive -bool YES "$task_agent"
/usr/bin/plutil -insert ThrottleInterval -integer 3 "$task_agent"
/usr/bin/plutil -insert ProcessType -string Interactive "$task_agent"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$task_agent"
/usr/bin/plutil -insert StandardOutPath -string "$HOME/Library/Logs/CmdSplit/stdout.log" "$task_agent"
/usr/bin/plutil -insert StandardErrorPath -string "$HOME/Library/Logs/CmdSplit/stderr.log" "$task_agent"
chmod 600 "$task_agent"
/usr/bin/plutil -lint "$task_agent"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$task_app"
/bin/launchctl enable "$task_domain/$task_label"
/usr/bin/defaults write "$task_label" paused -bool false
/usr/bin/defaults write "$task_label" requestedAccessibility -bool false
/bin/launchctl bootstrap "$task_domain" "$task_agent"
printf '%s\n' '已安装并开启。请在系统设置的辅助功能中允许 CmdSplit / 左右分屏。'
