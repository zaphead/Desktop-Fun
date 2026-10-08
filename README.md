# Desk Duck

A little 3D robot duck that lives on your Mac desktop. It treats your screen like a platformer:
desktop icons, window title bars, screen edges and the menu bar are all platforms. It hops between
them, wanders off to far-away spots (even other monitors), rocket-jumps, hangs upside down like a bat
from the menu bar or the top of a maximized window (or peeks out of the notch),
naps, quacks, and occasionally surfs one of your desktop icons to a new spot.

- **Click** it to make it quack and hop. **Drag** it to pick it up, and fling it to throw it.
- **Right-click** it, or use the bird icon in the menu bar, for color, size, mute, and the
  "Let Duck Move Icons" toggle.

## Build & run

```sh
./build.sh
open build/DeskDuck.app
```

The first time, macOS asks to let Desk Duck control Finder. That's how it finds (and moves) your
desktop icons. Without it, the duck still plays on windows and screen edges.

## How it works

| File | What it does |
| --- | --- |
| `DuckRig.swift` | Builds the robot duck from SceneKit primitives, with joints for legs, neck, head and bill |
| `DuckController.swift` | Brain + physics: state machine, ballistic jumps, ceiling hangs, drag/throw, procedural animation |
| `World.swift` | Collects platforms: screens, menu bars, the notch, window tops (CGWindowList), icons (Finder via JXA) |
| `IconMover.swift` | Streams positions to a long-lived Finder script so icons glide smoothly |
| `DuckWindow.swift` | Transparent click-through panel + a lean Metal renderer for the scene |
| `Sound.swift` | Synthesized robot quacks (no audio files) |

Preview the model without launching the app: `swift run DeskDuck --snapshot /tmp/duck` renders PNGs.
