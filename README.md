# Desk Duck

A little 3D robot duck that lives on your Mac desktop. It treats your screen like a platformer:
desktop icons, window title bars, screen edges and the menu bar are all platforms. It hops between
them, wanders off to far-away spots (even other monitors), rocket-jumps, hangs upside down like a bat
from the menu bar or the top of a maximized window (or peeks out of the notch),
naps, quacks, and occasionally surfs one of your desktop icons to a new spot.

- **Click** it to make it quack and hop. **Drag** it to pick it up, and fling it to throw it.
- With **Accessibility** access it can also see inside the app you're using (buttons, images, text,
  list rows) and hop around on them. It reads positions and sizes only, never text.
- **Right-click** it, or use the bird icon in the menu bar, for **Settings…**: permissions (with what
  each one allows), where the duck can go, personality sliders, color, size and sound, plus a reset.

## Build & run

```sh
./build.sh
open build/DeskDuck.app
```

The first launch opens Settings, which explains the two optional permissions: Automation of Finder
(desktop icons) and Accessibility (app contents). Without either, the duck still plays on windows
and screen edges.

## How it works

| File | What it does |
| --- | --- |
| `DuckRig.swift` | Builds the robot duck from SceneKit primitives, with joints for legs, neck, head and bill |
| `DuckController.swift` | Brain + physics: state machine, ballistic jumps, ceiling hangs, drag/throw, procedural animation |
| `World.swift` | Collects platforms: screens, menu bars, the notch, window tops (CGWindowList), icons (Finder via JXA), app contents |
| `AXScanner.swift` | Reads element frames in the focused window via the Accessibility API, on a background thread |
| `Settings.swift`, `SettingsWindow.swift` | Persisted settings, permission checks, and the SwiftUI settings window |
| `IconMover.swift` | Streams positions to a long-lived Finder script so icons glide smoothly |
| `DuckWindow.swift` | Transparent click-through panel + a lean Metal renderer for the scene |
| `Sound.swift` | Synthesized robot quacks (no audio files) |

Preview the model without launching the app: `swift run DeskDuck --snapshot /tmp/duck` renders PNGs.
