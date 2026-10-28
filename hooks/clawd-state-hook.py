#!/usr/bin/env python3
"""Clawd 桌宠状态桥:Claude Code hook -> 多会话聚合 -> claude-activity.json。

用法(由 install-state-hooks.sh 写进 ~/.claude/settings.json):
  python3 clawd-state-hook.py <HookEventName>

每个会话写自己的 sessions/<session_id>.json,再按优先级聚合出一个全局状态。
这样多个 Claude Code 会话/窗口同时运行时,不会互相把状态冲掉:
  等待审批 > 等待回复 > 出错 > 调用工具 > 工作中 > 思考中 > 完成 > 空闲
同优先级取最新事件。SessionEnd 会移除该会话文件。
本脚本永远 exit 0,不阻断任何操作。
"""
import fcntl
import json
import os
import re
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

STATE_PRIORITY = {
    "waitingApproval": 8,
    "waitingReply": 7,
    "error": 6,
    "tool": 5,
    "working": 4,
    "thinking": 3,
    "done": 2,
    "idle": 1,
}
SESSION_TTL_MS = 30 * 60 * 1000

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
directory = os.environ.get("CLAWD_FLOAT_DIR") or os.path.expanduser("~/Library/Application Support/ClawdFloat")
sessions_dir = os.path.join(directory, "sessions")
global_path = os.path.join(directory, "claude-activity.json")
log_path = os.path.join(directory, "claude-activity.log")
os.makedirs(sessions_dir, exist_ok=True)

normalized_session = session or "legacy"
safe_session = re.sub(r"[^A-Za-z0-9_.-]", "_", str(normalized_session))[:96] or "legacy"
session_path = os.path.join(sessions_dir, safe_session + ".json")


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
            return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def atomic_write(path, value):
    try:
        tmp = path + ".tmp." + str(os.getpid())
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False)
        os.replace(tmp, path)
    except Exception:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except Exception:
            pass


def recent_session_records():
    records = []
    try:
        names = os.listdir(sessions_dir)
    except Exception:
        return records
    for name in names:
        if not name.endswith(".json"):
            continue
        record = load_json(os.path.join(sessions_dir, name))
        if not isinstance(record, dict) or not record.get("state"):
            continue
        try:
            ts = int(record.get("ts") or 0)
        except Exception:
            ts = 0
        if now_ms - ts > SESSION_TTL_MS:
            continue
        records.append(record)
    return records


def select_record(records):
    if not records:
        return {
            "state": "idle",
            "event": "NoSessions",
            "tool": "",
            "message": "",
            "session": "",
            "last_tool": None,
            "last_tool_ts": None,
            "ts": now_ms,
        }
    # 优先级高的先选;同优先级取最新事件
    return max(
        records,
        key=lambda r: (STATE_PRIORITY.get(str(r.get("state", "")), 0), int(r.get("ts") or 0)),
    )


lock_path = os.path.join(directory, ".state.lock")
try:
    lock_handle = open(lock_path, "a+")
except Exception:
    lock_handle = None

try:
    if lock_handle is not None:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)

    # 升级时把旧版全局状态种成一个会话,避免第一个事件前丢失正在跑的状态
    if not any(name.endswith(".json") for name in os.listdir(sessions_dir)):
        legacy = load_json(global_path)
        legacy_ts = int(legacy.get("ts") or 0) if legacy else 0
        if legacy.get("state") and now_ms - legacy_ts < SESSION_TTL_MS:
            legacy_session = re.sub(r"[^A-Za-z0-9_.-]", "_", str(legacy.get("session") or "legacy"))[:96] or "legacy"
            atomic_write(os.path.join(sessions_dir, legacy_session + ".json"), legacy)

    previous = load_json(session_path)
    last_tool = None
    last_tool_ts = None
    if EVENT == "PreToolUse":
        last_tool = tool
        last_tool_ts = now_ms
    elif EVENT in ("PostToolUse", "PostToolUseFailure"):
        last_tool = previous.get("last_tool")
        last_tool_ts = previous.get("last_tool_ts")

    event_record = {
        "state": state,
        "event": EVENT,
        "tool": tool,
        "message": message[:200] if isinstance(message, str) else "",
        "session": normalized_session,
        "last_tool": last_tool,
        "last_tool_ts": last_tool_ts,
        "ts": now_ms,
    }

    if EVENT == "SessionEnd":
        try:
            os.remove(session_path)
        except FileNotFoundError:
            pass
    else:
        atomic_write(session_path, event_record)

    records = recent_session_records()
    selected = select_record(records)
    aggregate = {
        "state": selected.get("state", "idle"),
        "event": selected.get("event", ""),
        "tool": selected.get("tool", ""),
        "message": selected.get("message", ""),
        "session": selected.get("session", ""),
        "last_tool": selected.get("last_tool"),
        "last_tool_ts": selected.get("last_tool_ts"),
        "ts": selected.get("ts", now_ms),
        "sessions": len(records),
    }
    atomic_write(global_path, aggregate)

    # 诊断日志:每次 hook 追加一行(记录本会话事件,不记录聚合结果)
    try:
        if os.path.exists(log_path) and os.path.getsize(log_path) > 512 * 1024:
            with open(log_path, "r", encoding="utf-8") as handle:
                tail = handle.readlines()[-500:]
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.writelines(tail)
    except Exception:
        pass
    try:
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(event_record, ensure_ascii=False) + "\n")
    except Exception:
        pass
finally:
    if lock_handle is not None:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
        lock_handle.close()

sys.exit(0)
