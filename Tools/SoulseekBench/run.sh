#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ ! -x "Plug-ins/Soulseek/bin/macos/soulseek-plugin" ]; then
    swift build --product SoulseekPlugin
    mkdir -p Plug-ins/Soulseek/bin/macos
    cp "$(swift build --show-bin-path)/SoulseekPlugin" Plug-ins/Soulseek/bin/macos/soulseek-plugin
fi
python3 Tools/SoulseekBench/bench.py "$@"
