#!/bin/bash
# 启动 Clawd 悬浮窗(前台运行;先编译如果还没编译过)
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -x build/ClawdFloat ]; then ./build.sh; fi
exec ./build/ClawdFloat "$@"
