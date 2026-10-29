#!/bin/bash
# 安装并启动 LaunchAgent:登录后自动拉起 Clawd,崩溃自动重启(只做用户级安装,不需要 sudo)
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

LABEL="com.richarddou.clawdfloat"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Application Support/ClawdFloat"
INSTALL_BIN="$LOG_DIR/ClawdFloat"

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

# 先停掉旧服务/旧进程,避免同一只宠物启动两份
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -f "$(pwd)/build/ClawdFloat" 2>/dev/null || true
pkill -f "$INSTALL_BIN" 2>/dev/null || true
sleep 0.3

# 安装到固定路径:以后移动/重建仓库也不会影响登录启动
install -m 0755 build/ClawdFloat "$INSTALL_BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_BIN</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$HOME</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
# bootstrap 的 RunAtLoad 已经会启动;这里再确保一次
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true
sleep 1

if pgrep -f "$INSTALL_BIN" >/dev/null; then
  echo "✔ LaunchAgent 已安装并启动: $PLIST"
  echo "  可执行文件: $INSTALL_BIN"
  echo "  登录后自动启动;异常退出会自动重启;菜单里正常退出不会重启。"
  echo "  状态: launchctl print $DOMAIN/$LABEL | head"
  echo "  卸载: ./uninstall-launchagent.sh"
else
  echo "✘ LaunchAgent 已安装,但进程没有启动。请检查:" >&2
  launchctl print "$DOMAIN/$LABEL" 2>&1 | head -30 >&2 || true
  echo "  日志: $LOG_DIR/launchd.err.log" >&2
  exit 1
fi
