# MouseZoomOnMac

macOS helper that gives an external mouse **trackpad-style pinch-zoom**.
**Personal use.**

## What it does

| Action | Result |
|---|---|
| Hold **⌥ (Option)** + scroll wheel | Pinch **zoom in / out** in any app that supports trackpad pinch (Safari, Maps, Photos, Preview, Chromium browsers, …) |
| Hold a **side button** (back / forward) + scroll wheel | Same (the side button is captured) |
| **Release** the trigger | Gesture ends |
| **Plain scroll, no trigger** | Passes through untouched → **panning** in the zoomed view (horizontal: wheel x-axis, or Shift+scroll in browsers) |

It fabricates a genuine trackpad magnification event from scratch using
undocumented `CGEvent` fields (type 29 = gesture, field 110 = 8 = zoom,
field 132 = phase, field 113 = amount). Apps cannot tell it apart from a
real trackpad pinch.
For Chromium-based browsers (Chrome/Chromium/Arc/Opera/Edge/Vivaldi/Brave/Steam,
detected by bundle id under the pointer) it additionally posts an extra delta
burst, because Chromium needs a large first delta before it actually starts zooming.

## Build

    make            # or: make app  (binary + "MouseZoomOnMac.app" bundle)

## First run (permissions)

1. `open "MouseZoomOnMac.app"` — the system shows an Accessibility prompt.
2. Click **"Open System Settings"** in the prompt (or do it manually):
   Privacy & Security → **Accessibility** → enable `MouseZoomOnMac`.
3. Also enable it under **Input Monitoring** (same section, different list).
4. It is now running. To restart after changes: `pkill -f "MouseZoomOnMac" && open "MouseZoomOnMac.app"`

(Grant is keyed to the binary's code — see the warning below.)

## Options

    open "MouseZoomOnMac.app"             # defaults: Option key + side buttons
    ./bin/mousezoomonmac --modifier=command   # use ⌘ instead of ⌥
    ./bin/mousezoomonmac --no-buttons         # keyboard trigger only
    ./bin/mousezoomonmac --buttons=4,5        # which side buttons (CGMouseButton: back=4, forward=5)
    ./bin/mousezoomonmac --scale=150          # zoom sensitivity; SMALLER = faster (default: 800)
    ./bin/mousezoomonmac --no-burst          # skip the Chromium zoom-start burst
    ./bin/mousezoomonmac -v                 # verbose event log
    ./bin/mousezoomonmac --verify           # passive 2nd tap that logs every type-29 gesture event (debug)
    ./bin/mousezoomonmac --log-file=/tmp/x.log  # tee the log to a file

Quit: `pkill -f "MouseZoomOnMac"`

## Working configuration (verified on macOS 26.3, external mouse)

`--scale=150` gives a comfortable zoom rate (≈5.3× faster than the default 800).
Tune per feel: `--scale=100` = 8×, `--scale=200` = 4×. Chromium keeps the burst
hack on by default (expect one small jump on the first notch, then smooth
per-notch zoom at matched speed).

## ⚠ Rebuilding invalidates the TCC grant

The app is adhoc-signed; every `make app` produces a new code hash, and macOS
then treats it as a *new* app. After a rebuild: remove `MouseZoomOnMac` from
the Accessibility (and Input Monitoring) lists and re-add it — the easiest
path is to just run `open "MouseZoomOnMac.app"` again and use the system
prompt's "Open System Settings" button. Restarting the *same* build (new args,
`pkill` + `open`) does NOT lose the grant.

The launch-agent installer deliberately does **not** rebuild for this reason.
(Launch the app via `open` or launchd, not from an SSH session — TCC then
attributes the prompt to sshd instead of the app.)

## Run at login (optional)

    ./install-launch-agent.sh --scale=150
    # stop: ./install-launch-agent.sh stop

## Testing checklist

1. Safari / Maps / Photos: hold ⌥, scroll → zoom in; scroll the other way → zoom out; release.
2. Chromium browser: hold ⌥ (or side button), scroll → zoom starts immediately (burst hack).
3. While zoomed: release trigger, scroll → page pans. Horizontal: Shift+scroll or wheel x-axis.
4. Plain scrolling without the trigger must be completely unaffected.
