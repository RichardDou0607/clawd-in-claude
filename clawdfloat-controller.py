#!/usr/bin/env python3
"""ClawdFloat launcher controller.

把 Claude 插件 glm-quota-pet 的 enabled 状态和桌宠启动器绑定:
- 插件 enabled / 未安装 → 确保 ClawdFloat 运行;
- 插件明确 disabled → 停止 ClawdFloat;
- 每 0.5s 检查一次,所以在 Claude 插件管理页 turn on/off 后约 1 秒内生效。

由 LaunchAgent com.richarddou.clawdfloat 启动;本身常驻。
"""
import json
import os
import signal
import subprocess
import time

HOME = os.path.expanduser("~")
BASE = os.path.join(HOME, "Library/Application Support/ClawdFloat")
BIN = os.path.join(BASE, "ClawdFloat")
SETTINGS = os.path.join(HOME, ".claude/settings.json")
PLUGIN_ID = "glm-quota-pet@glm-quota-pet-market"
LOG = os.path.join(BASE, "controller.log")
POLL_SECONDS = 0.5
MAX_LOG_BYTES = 256 * 1024

os.makedirs(BASE, exist_ok=True)


def log(message):
    line = time.strftime("%Y-%m-%dT%H:%M:%S%z") + " " + message + "\n"
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > MAX_LOG_BYTES:
            with open(LOG, "r", encoding="utf-8", errors="ignore") as handle:
                tail = handle.readlines()[-300:]
            with open(LOG, "w", encoding="utf-8") as handle:
                handle.writelines(tail)
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(line)
    except Exception:
        pass


def plugin_enabled():
    """只有明确 false 才关闭。插件不存在/配置读不到时保持默认启动。"""
    try:
        with open(SETTINGS, "r", encoding="utf-8") as handle:
            root = json.load(handle)
    except Exception:
        return True
    plugins = root.get("enabledPlugins")
    if not isinstance(plugins, dict):
        return True
    value = plugins.get(PLUGIN_ID)
    if value is None:
        return True
    return bool(value)


def app_pids():
    try:
        output = subprocess.check_output(
            ["/bin/ps", "-axo", "pid=,command="],
            text=True, errors="ignore", timeout=5,
        )
    except Exception:
        return []
    pids = []
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        pid_text, command = parts
        if command == BIN or command.startswith(BIN + " "):
            try:
                pids.append(int(pid_text))
            except ValueError:
                pass
    return pids


def start_app():
    if not os.path.isfile(BIN):
        log("missing binary: " + BIN)
        return
    try:
        with open(LOG, "a", encoding="utf-8") as out:
            subprocess.Popen(
                [BIN],
                cwd=HOME,
                stdin=subprocess.DEVNULL,
                stdout=out,
                stderr=out,
                start_new_session=True,
            )
        log("started ClawdFloat (plugin enabled)")
    except Exception as error:
        log("start failed: " + repr(error))


def stop_app(pids):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except Exception as error:
            log(f"SIGTERM {pid} failed: {error!r}")
    deadline = time.time() + 4.0
    while time.time() < deadline:
        if not app_pids():
            log("stopped ClawdFloat (plugin disabled)")
            return
        time.sleep(0.1)
    for pid in app_pids():
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
    log("force-killed ClawdFloat (plugin disabled)")


def main():
    log("controller started")
    last_enabled = None
    while True:
        enabled = plugin_enabled()
        if enabled != last_enabled:
            log("plugin enabled state -> " + ("true" if enabled else "false"))
            last_enabled = enabled
        pids = app_pids()
        if enabled and not pids:
            start_app()
        elif not enabled and pids:
            stop_app(pids)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
