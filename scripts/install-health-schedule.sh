#!/usr/bin/env bash
# Install the weekly agent-health run as a LaunchAgent: Mondays at 08:00, `context-lens health
# --since 7d`, then `context-lens health judge`. Log: ~/.context-lens/health/schedule.log.
# Remove with: launchctl bootout gui/$(id -u)/com.prismalabs.context-lens.health
set -euo pipefail
label=com.prismalabs.context-lens.health
plist="$HOME/Library/LaunchAgents/$label.plist"
cli="$HOME/.local/bin/context-lens"
log="$HOME/.context-lens/health/schedule.log"
[ -x "$cli" ] || { echo "install the command line tool first (Context Lens > Install Command Line Tool)" >&2; exit 1; }
mkdir -p "$(dirname "$log")" "$(dirname "$plist")"
cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string><string>-lc</string>
    <string>date; "$cli" health --since 7d &gt;/dev/null &amp;&amp; "$cli" health judge</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "$plist"
