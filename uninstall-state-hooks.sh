#!/bin/bash
# 卸载 Clawd 状态 hooks(只删含 clawd-state-hook.py 的条目)
set -euo pipefail
SETTINGS="$HOME/.claude/settings.json"
python3 - "$SETTINGS" <<'PY'
import json, os, sys, time, shutil
path = sys.argv[1]
if not os.path.exists(path):
    print("no settings file"); sys.exit(0)
with open(path, "r", encoding="utf-8") as fh:
    settings = json.load(fh)
hooks = settings.get("hooks", {})
removed = 0
for event in list(hooks.keys()):
    kept = []
    for entry in hooks[event]:
        ours = any("clawd-state-hook.py" in str(h.get("command", "")) for h in entry.get("hooks", []))
        if ours:
            removed += 1
        else:
            kept.append(entry)
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)
if removed:
    backup = path + ".clawd-backup-" + time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(path, backup)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(settings, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print("backup:", backup)
print("removed hook entries:", removed)
PY
echo "✔ 状态 hooks 已卸载(桌宠本身不受影响)"
