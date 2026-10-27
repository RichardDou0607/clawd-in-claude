#!/bin/bash
# 卸载 LaunchAgent(不会删除 App 本体)
set -euo pipefail
LABEL="com.richarddou.clawdfloat"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
echo "✔ 已卸载 LaunchAgent(不再随登录启动)"
