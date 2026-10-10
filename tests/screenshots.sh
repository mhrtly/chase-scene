#!/bin/bash
# CI helper: runs the real app (not test mode) in a throwaway state folder and captures
# screenshots of the first-run welcome, the menu-bar icon during a chase, and the menus.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Benny Hill Climber.app/Contents/MacOS/ChaseScene"
agent="$root/build/demo-agent"
out="$root/build/screenshots"
mkdir -p "$out"
swiftc -swift-version 5 -module-cache-path "$root/build/module-cache" "$root/tests/demo-agent.swift" -o "$agent"
scratch="$(mktemp -d)"
export CHASE_SCENE_STATE_DIR="$scratch/state" CHASE_SCENE_HOME="$scratch/home" CHASE_SCENE_NO_AUTO_LAUNCH=1
mkdir -p "$CHASE_SCENE_HOME/.claude" "$CHASE_SCENE_HOME/.codex"
report="$out/report.txt"
: > "$report"
icon_x="${ICON_X:-789}"
settings_y="${SETTINGS_Y:-0}"

# 1. First run: the welcome dialog.
"$app" & pid=$!
sleep 5
screencapture -x "$out/1-welcome.png"
kill "$pid"; wait "$pid" 2>/dev/null

# 2. A chase in progress: a reported session plus the demo agent driving the mouse.
mkdir -p "$CHASE_SCENE_STATE_DIR"
printf '{"welcomed":true}' > "$CHASE_SCENE_STATE_DIR/preferences.json"
"$app" & pid=$!
sleep 3
"$app" signal '{"action":"begin","session_id":"shot","agent":"Claude Code"}' >> "$report"
"$agent" move 500 400 sleep 0.3 move 520 410
sleep 1
screencapture -x "$out/2-chasing.png"
"$agent" click "$icon_x" 11 sleep 1
"$app" status >> "$report"
screencapture -x "$out/3-menu.png"
if [ "$settings_y" != 0 ]; then
  "$agent" move "$((icon_x + 40))" "$settings_y" sleep 1.5
  screencapture -x "$out/4-settings.png"
fi
"$agent" key 53 sleep 0.3 key 53
"$app" signal '{"action":"end","session_id":"shot"}' >> "$report"
sleep 2
"$app" status >> "$report"
kill "$pid"; wait "$pid" 2>/dev/null
cat "$report"
