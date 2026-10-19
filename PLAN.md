# WLED Menu Bar — Plan

Native SwiftUI client for WLED. macOS 14+. No dependencies.

## Surfaces
_All planned work is complete._

- **Menu bar** — quick stuff only: All On / All Off, sectioned Groups and
  Controllers, per-row named quick actions (on, off, brightness steps, presets,
  open in window), power toggles and brightness.
- **Main window** — the real control surface: colour picker, effects, palettes,
  speed/intensity. Sidebar of groups + controllers, one shared detail pane.

App launches as `LSUIElement` (no Dock icon). Opening any window promotes it to
`.regular` for a Dock icon and Cmd-Tab; closing the last one demotes it back.

## Constraints (verified 2026-10-19)
- Only Command Line Tools installed, **no Xcode** → no `xcodebuild`/`.xcodeproj`.
  Build is `swiftc` + hand-assembled `.app` bundle via `build.sh`. Verified working.
- No Apple Developer account → **ad-hoc signing** (`codesign -s -`). Runs locally
  forever; cannot be distributed to other machines without notarization.
- macOS 26: Local Network privacy prompt applies. `Info.plist` needs
  `NSLocalNetworkUsageDescription` + `NSBonjourServices` = `_wled._tcp`.
- Swift language mode 5 (not 6) to avoid strict-concurrency churn.

## WLED API surface
- `GET  /json`        → `{state, info, effects[], palettes[]}` in one request
- `POST /json/state`  → `{"on":"t"}` `{"bri":128}` `{"fx":12}` `{"ps":3}`
- `GET  /presets.json`→ preset slots (phase 2)
- `ws://<ip>/ws`      → state pushed on change from any source. ~1 msg/sec max,
                        8 clients on ESP32. Keeps UI correct when phone app is used.
- mDNS `_wled._tcp.local` → discovery, no IP scanning

## Phase 1 — core (goal: usable)
1. [x] Scaffold: `build.sh`, `Info.plist`, dirs
2. [x] `Models.swift`   — Codable WLED state/info/effects/palettes
3. [x] `WLEDClient.swift`— HTTP GET/POST + brightness throttling
4. [x] `Discovery.swift`— NWBrowser on `_wled._tcp` + NWConnection IP resolve
5. [x] `Store.swift`    — devices, groups, UserDefaults persistence
6. [x] `MenuView.swift` — device rows: power toggle + brightness slider
7. [x] Groups + **All Off**  ← top priority feature
8. [x] WebSocket live state (`LiveConnection.swift`)

## Phase 2 — control depth
9.  [x] Effects picker (per device / per group) + speed/intensity — main window
10. [x] Palette picker — main window
11. [x] Presets (`/presets.json`) — parser unit-tested; quick-apply in menu bar
12. [x] Colour picker — inline hue/saturation wheel + 12 swatches + hex.
        No NSColorPanel anywhere. HSB conversion unit-tested.
13. [x] Main window: sidebar + shared detail pane for groups and devices
14. [x] Device and group management folded into the main window. The separate
        Settings window is gone: you configure the thing you are looking at.
15. [x] All On / All Off in both surfaces. Per-row power is the toggle only;
        the overflow menu carries only presets and Open in Window — anything
        the row can already do in one click stays out of it.
16. [x] Inline colour swatches per row (superseded by 18: rows collapse when
        off, so the swatches are only ever shown on a lit device).
17. [x] Fixed: ScrollView collapsed to ~0pt inside the MenuBarExtra popover,
        hiding the whole device list since Phase 1. Content height is now
        measured and pinned.
18. [x] Rows collapse to name + toggle when off — a brightness slider and
        colour swatches on a dark light control something you cannot see.
19. [x] Transient failures no longer stick. 503 is retried with backoff (WLED
        shares one JSON buffer and means "ask again" by it), unreachable
        devices are re-checked every 15s, and the UI stays quiet until three
        consecutive failures.

## Explicitly out of scope
Room mapping/visualization, Stream Deck automation, segment editing, "copy look".

## Build
    ./build.sh && open ./build/WLED.app

## Verified so far (2026-10-19)
- SwiftUI + `MenuBarExtra` compile against CLT-only toolchain — no Xcode.
- Ad-hoc signed bundle launches and stays resident (`LSUIElement`).
- ATS does **not** block plain HTTP to private LAN IPs, even with no
  Info.plist exception. Our exception is belt-and-braces, not load-bearing.
- Full decode path tested against a realistic WLED 0.15 `/json` payload:
  name, power, brightness, effect index->name, palette index->name, LED count.
- Not yet tested against real hardware: discovery, and all POST writes.

## Notes
- Moving colour into the main window also sidesteps `ColorPicker` opening
  NSColorPanel from inside a menu bar popover, which would have dismissed it.
- The activation-policy demote is driven by an open-window count. That existed
  to cope with two windows; with the Settings window gone there is only one, so
  the edge case it guarded against can no longer happen.

## RGBW
Strips with separate white LEDs get a white-channel slider; RGB-only strips do
not. Capability comes from WLED's light-capabilities bitfield — per-segment
`seglc` preferred over the combined `lc`, falling back to the pre-0.13 `rgbw`
bool. Bit 2 is CCT, which is not implemented.

WLED's colour slot is one array, so RGB and white are always written together.

## Screenshots
`docs/menubar.png` and `docs/window.png` are captures with example data, not a
real setup. Taken by hand — the main window uses NavigationSplitView, which
cannot be rendered offscreen. Retake them if the layout changes.

## Icon
Generated from code by `Tools/make-icon.swift` (CoreGraphics draws the PNGs,
`iconutil` packs them) so it is reproducible and reviewable rather than an
opaque binary. `AppIcon.icns` is committed; the intermediate `.iconset` is not.

## Not done, deliberately
- **Launch at login** (`SMAppService`). A menu bar app usually wants it; this
  one must be started by hand.
- **No tests in the repo.** The preset-parser and HSB-conversion harnesses were
  run as throwaway scratchpad programs and committed nowhere, so neither is
  protected against regression.
- **Distribution.** Ad-hoc signing runs forever on the machine that built it;
  any other Mac needs Developer ID signing and notarization.
