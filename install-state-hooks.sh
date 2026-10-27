#!/bin/bash
# 安装 Claude Code 状态 hooks:把思考/调用工具/工作/等待/完成等状态写给 Clawd 桌宠。
# 会备份 ~/.claude/settings.json,只增删含 clawd-state-hook.py 的 hook 条目。
set -euo pipefail
cd "$(dirname "$0")"
HOOK="$(pwd)/hooks/clawd-state-hook.py"
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"

python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, os, shutil, sys, time

settings_path, hook = sys.argv[1], sys.argv[2]
if os.path.exists(settings_path):
    backup = settings_path + ".clawd-backup-" + time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(settings_path, backup)
    print("backup:", backup)
    with open(settings_path, "r", encoding="utf-8") as fh:
        settings = json.load(fh)
else:
    settings = {}

hooks = settings.setdefault("hooks", {})
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
          "PostToolUse", "Notification", "Stop", "SessionEnd"]

def contains_ours(entry):
    for hook_def in entry.get("hooks", []):
        if "clawd-state-hook.py" in str(hook_def.get("command", "")):
            return True
    return False

# 先清掉旧的本脚本 hook,避免重复
for event in list(hooks.keys()):
    hooks[event] = [entry for entry in hooks[event] if not contains_ours(entry)]
    if not hooks[event]:
        del hooks[event]

cmd = f'python3 "{hook}"'
for event in EVENTS:
    definition = {"type": "command", "command": f"{cmd} {event}", "timeout": 5}
    entry = {"hooks": [definition]}
    if event in ("PreToolUse", "PostToolUse", "PermissionRequest"):
        entry["matcher"] = ".*"
    hooks.setdefault(event, []).append(entry)

with open(settings_path, "w", encoding="utf-8") as fh:
    json.dump(settings, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print("hooks installed for:", ", ".join(EVENTS))
print("settings:", settings_path)
PY

echo "✔ 状态 hooks 已安装。新开/重启 Claude Code 会话后生效。"
echo "  桌宠 App 会在 0.25s 内读取 ~/Library/Application Support/ClawdFloat/claude-activity.json"
