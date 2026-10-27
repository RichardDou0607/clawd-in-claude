#!/usr/bin/env python3
"""Clawd 桌宠状态桥:Claude Code hook -> 写 claude-activity.json。

用法(由 install-state-hooks.sh 写进 ~/.claude/settings.json):
  python3 clawd-state-hook.py <HookEventName>
stdin 是 Claude Code 传入的 JSON;本脚本永远 exit 0,不阻断任何操作。
"""
import json
import os
import sys
import time

EVENT = sys.argv[1] if len(sys.argv) > 1 else "Unknown"

EVENT_STATE = {
    "SessionStart": "idle",
    "SessionEnd": "idle",
    "UserPromptSubmit": "thinking",
    "PreToolUse": "tool",
    # 工具执行完 = agent 还在工作(继续拆解/写代码/生成),显示“工作中”
    "PostToolUse": "working",
    "PostToolUseFailure": "error",
    "PermissionRequest": "waitingApproval",
    "Notification": "waitingReply",
    "Stop": "done",
    "SubagentStop": "working",
    "PreCompact": "thinking",
}

raw = ""
try:
    if not sys.stdin.isatty():
        raw = sys.stdin.read()
except Exception:
    raw = ""
payload = {}
try:
    if raw.strip():
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            payload = {}
except Exception:
    payload = {}

tool = payload.get("tool_name") or payload.get("tool") or ""
message = payload.get("message") or ""
session = payload.get("session_id") or ""

# Claude Code 内部 turn 编排工具(update_plan / wrap_up 等)不是用户可见动作,
# 不写状态,否则会把真实的 思考/工具/工作 状态冲掉。
if isinstance(tool, str) and tool.startswith("mcp__ccd_turn__"):
    sys.exit(0)

state = EVENT_STATE.get(EVENT, "idle")
if EVENT == "Notification":
    text = message.lower() if isinstance(message, str) else ""
    approval_words = ("permission", "approve", "allow", "许可", "权限", "审批", "批准")
    state = "waitingApproval" if any(word in text for word in approval_words) else "waitingReply"
elif EVENT == "PreToolUse" and tool == "AskUserQuestion":
    state = "waitingReply"

now_ms = int(time.time() * 1000)
directory = os.path.expanduser("~/Library/Application Support/ClawdFloat")
os.makedirs(directory, exist_ok=True)
target = os.path.join(directory, "claude-activity.json")

# 保留最近一次工具调用,让 App 能在快速工具(Edit/Read)的 Pre/Post 间隔极短时,
# 仍然至少展示一次“编辑中/读取中/…”,而不是直接跳到 working。
previous = {}
try:
    with open(target, "r", encoding="utf-8") as handle:
        previous = json.load(handle)
except Exception:
    previous = {}
last_tool = None
last_tool_ts = None
if EVENT == "PreToolUse":
    last_tool = tool
    last_tool_ts = now_ms
elif EVENT in ("PostToolUse", "PostToolUseFailure"):
    last_tool = previous.get("last_tool")
    last_tool_ts = previous.get("last_tool_ts")

record = {
    "state": state,
    "event": EVENT,
    "tool": tool,
    "message": message[:200] if isinstance(message, str) else "",
    "session": session,
    "last_tool": last_tool,
    "last_tool_ts": last_tool_ts,
    "ts": now_ms,
}

try:
    tmp = target + ".tmp." + str(os.getpid())
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(record, handle, ensure_ascii=False)
    os.replace(tmp, target)
    # 诊断日志:每次 hook 追加一行,方便排查状态切换顺序/延迟
    log_path = os.path.join(directory, "claude-activity.log")
    try:
        if os.path.exists(log_path) and os.path.getsize(log_path) > 512 * 1024:
            with open(log_path, "r", encoding="utf-8") as handle:
                tail = handle.readlines()[-500:]
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.writelines(tail)
    except Exception:
        pass
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False) + "\n")
except Exception:
    pass

sys.exit(0)
