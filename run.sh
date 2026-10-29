#!/bin/bash
# 手动启动桌宠。若插件被明确禁用,先把插件启用,保证控制器不会立刻把它杀掉。
set -euo pipefail
cd "$(dirname "$0")"

CLAUDE_BIN=""
for candidate in "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
  if [ -x "$candidate" ]; then CLAUDE_BIN="$candidate"; break; fi
done
if [ -n "$CLAUDE_BIN" ]; then
  STATE=$(python3 - <<'PY' 2>/dev/null || true
import json, os
p=os.path.expanduser("~/.claude/settings.json")
try:
    d=json.load(open(p))
    print(d.get("enabledPlugins",{}).get("glm-quota-pet@glm-quota-pet-market"))
except Exception:
    pass
PY
)
  if [ "$STATE" = "False" ]; then
    "$CLAUDE_BIN" plugin enable glm-quota-pet@glm-quota-pet-market --scope user --json >/dev/null 2>&1 || true
  fi
fi

if [ ! -x build/ClawdFloat ]; then ./build.sh; fi
exec ./build/ClawdFloat
