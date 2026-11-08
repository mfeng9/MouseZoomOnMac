#!/bin/sh
# Install (or stop) the MouseZoomOnMac LaunchAgent so the helper starts at login.
cd "$(dirname "$0")" || exit 1

# NOTE: do NOT 'make app' here — rebuilding changes the adhoc cdhash and
# invalidates the TCC grant (Accessibility + Input Monitoring). Only build
# manually when the grant is re-granted afterwards.
if [ ! -x "MouseZoomOnMac.app/Contents/MacOS/MouseZoomOnMac" ]; then
    echo "MouseZoomOnMac.app not built — run 'make app' first (then re-grant TCC permissions)"
    exit 1
fi

APPDIR="$(pwd)/MouseZoomOnMac.app"
BIN="$APPDIR/Contents/MacOS/MouseZoomOnMac"
PLIST="$HOME/Library/LaunchAgents/local.mousezoomonmac.plist"
# Working config (2026-07): scale=150 gave a comfortable zoom rate with an
# external mouse wheel. Extra args can be appended via $@, e.g. --scale=100.
EXTRA_ARGS="$*"

case "$1" in
stop)
    launchctl bootout "gui/$(id -u)/local.mousezoomonmac" 2>/dev/null
    rm -f "$PLIST"
    echo "stopped and removed local.mousezoomonmac"
    ;;
*)
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.mousezoomonmac</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        $(for a in $EXTRA_ARGS; do printf '        <string>%s</string>\n' "$a"; done)
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/mousezoomonmac.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/mousezoomonmac.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/local.mousezoomonmac" 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "installed local.mousezoomonmac (log: ~/Library/Logs/mousezoomonmac.log)"
    ;;
esac
