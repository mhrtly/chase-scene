#!/bin/bash
# CI helper: runs the real app (not test mode) in a throwaway state folder and captures
# screenshots of the first-run welcome and of the menu-bar icon / menu during a chase.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Chase Scene.app/Contents/MacOS/ChaseScene"
out="$root/build/screenshots"
mkdir -p "$out"
scratch="$(mktemp -d)"
export CHASE_SCENE_STATE_DIR="$scratch/state" CHASE_SCENE_HOME="$scratch/home" CHASE_SCENE_NO_AUTO_LAUNCH=1
mkdir -p "$CHASE_SCENE_HOME/.claude" "$CHASE_SCENE_HOME/.codex"
report="$out/report.txt"
: > "$report"

# 1. First run: the welcome dialog.
"$app" & pid=$!
sleep 5
screencapture -x "$out/1-welcome.png"
kill "$pid"; wait "$pid" 2>/dev/null

# 2. A chase in progress: menu-bar icon, then the open menu.
mkdir -p "$CHASE_SCENE_STATE_DIR"
printf '{"welcomed":true}' > "$CHASE_SCENE_STATE_DIR/preferences.json"
"$app" & pid=$!
sleep 3
"$app" signal '{"action":"begin","session_id":"shot","agent":"Claude Code"}' >> "$report"
sleep 2
"$app" status >> "$report"
screencapture -x "$out/2-chasing.png"
osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$pid"') to click menu bar item 1 of menu bar 2' >> "$report" 2>&1
sleep 1
screencapture -x "$out/3-menu.png"
osascript -e 'tell application "System Events" to key code 53' >> "$report" 2>&1
"$app" signal '{"action":"end","session_id":"shot"}' >> "$report"
sleep 2
"$app" status >> "$report"
kill "$pid"; wait "$pid" 2>/dev/null
cat "$report"
