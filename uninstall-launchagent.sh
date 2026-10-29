#!/bin/bash
# 卸载 LaunchAgent/启动控制器(不会删除 App、配置或额度数据)
set -euo pipefail
LABEL="com.richarddou.clawdfloat"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_DIR="$HOME/Library/Application Support/ClawdFloat"
APP_BIN="$INSTALL_DIR/ClawdFloat"
CONTROLLER="$INSTALL_DIR/clawdfloat-controller.py"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -f "$CONTROLLER" 2>/dev/null || true
pkill -f "$APP_BIN" 2>/dev/null || true
rm -f "$PLIST"
echo "✔ 已卸载启动控制器:以后登录不再自动启动 Clawd"
echo "  已安装副本保留: $INSTALL_DIR"
