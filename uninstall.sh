#!/bin/bash
set -euo pipefail
task_label='local.ychen.CmdSplit'
task_domain="gui/$(id -u)"
/bin/launchctl bootout "$task_domain/$task_label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$task_label.plist"
if test -e "$HOME/Applications/CmdSplit.app"; then
    task_trash="$HOME/.Trash/CmdSplit-$(date +%Y%m%d-%H%M%S).app"
    mv "$HOME/Applications/CmdSplit.app" "$task_trash"
fi
/usr/bin/defaults delete local.ychen.CmdSplit 2>/dev/null || true
printf '%s\n' '已停止分屏工具、移除自动启动，并将应用移至废纸篓。'
