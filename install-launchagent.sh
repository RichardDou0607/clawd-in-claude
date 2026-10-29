#!/bin/bash
# 安装/更新 ClawdFloat 启动控制器(LaunchAgent):
# - 登录后自动启动;
# - 绑定 Claude 插件 glm-quota-pet 的 enabled 状态:启用→拉起桌宠,禁用→停止桌宠;
# - 桌宠异常退出由控制器自动重启。
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

LABEL="com.richarddou.clawdfloat"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_DIR="$HOME/Library/Application Support/ClawdFloat"
APP_BIN="$INSTALL_DIR/ClawdFloat"
CONTROLLER="$INSTALL_DIR/clawdfloat-controller.py"

mkdir -p "$HOME/Library/LaunchAgents" "$INSTALL_DIR"

# 停掉旧的“直接运行 App”的 LaunchAgent 和旧进程
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -f "$APP_BIN" 2>/dev/null || true
pkill -f "$CONTROLLER" 2>/dev/null || true
pkill -f "$(pwd)/build/ClawdFloat" 2>/dev/null || true
sleep 0.3

install -m 0755 build/ClawdFloat "$APP_BIN"
install -m 0755 clawdfloat-controller.py "$CONTROLLER"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$CONTROLLER</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$HOME</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/controller.out.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/controller.err.log</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true
sleep 1.2

echo "✔ LaunchAgent 已安装: $PLIST"
echo "  控制器: $CONTROLLER"
echo "  App 二进制: $APP_BIN"
echo "  插件启用 → 自动拉起桌宠;插件禁用 → 自动停止桌宠"
echo "  状态: launchctl print $DOMAIN/$LABEL | head -30"
echo "  日志: $INSTALL_DIR/controller.log"
echo "  卸载: ./uninstall-launchagent.sh"
