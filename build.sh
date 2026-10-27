#!/bin/bash
# 编译 ClawdFloat(只需 macOS 自带的 swiftc,无需 Xcode)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -swift-version 5 Sources/main.swift -o build/ClawdFloat
echo "✔ 已编译: $(pwd)/build/ClawdFloat"
