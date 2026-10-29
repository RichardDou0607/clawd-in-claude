#!/bin/bash
# 卸载 LaunchAgent(不会删除 App 本体/配置/额度数据)
set -euo pipefail
LABEL="com.richarddou.clawdfloat"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_BIN="$HOME/Library/Application Support/ClawdFloat/ClawdFloat"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -f "$INSTALL_BIN" 2>/dev/null || true
rm -f "$PLIST"
echo "✔ 已卸载 LaunchAgent:以后登录不再自动启动 Clawd"
echo "  已安装副本保留: $INSTALL_BIN"
