# heroPanel

A World of Warcraft addon for the **Ascension WoW · Conquest of Azeroth** realm
(3.3.5a / WotLK client) that reskins and repositions the objective trackers:

* the default quest tracker (`WatchFrame`)
* the Mythic+ tracker (`MythicPlusObjectiveTracker`, from `Ascension_MythicPlus`)

heroPanel is standalone. It reads and writes only its own SavedVariables
(`HEROPANEL_DB`), never hooks game logic with raw overwrites, and never touches
protected frames while the player is in combat.

## Status

**Phase 1 — foundation.** Move, lock and rescale work. Visual skinning, the
options panel and per-line text/colour handling are not implemented yet.

| Phase | Scope | State |
|---|---|---|
| 1 | Addon skeleton, frame discovery, conflict detection, move/lock/scale, shared helpers | done |
| 2 | Panel skin — background, border, radius, backdrop texture | planned |
| 3 | Text — fonts, per-state colours, header chrome, collapse caret | planned |
| 4 | Options panel, M+ chest tiers and timer chrome | planned |

## Installation

Copy the `heroPanel` folder into your WoW installation's
`Interface\AddOns` directory, so that `Interface\AddOns\heroPanel\heroPanel.toc`
exists. Restart the client or `/reload`.

## Commands

| Command | What it does |
|---|---|
| `/hp lock` | Lock both trackers in place |
| `/hp unlock` | Unlock both trackers — drag with the left mouse button |
| `/hp scale <watch\|mplus> <0.5-1.5>` | Set a tracker's scale |
| `/hp reset [watch\|mplus]` | Clear saved position and scale |
| `/hp mode <auto\|own\|holder\|yield>` | Who positions the trackers — see Compatibility |
| `/hp status` | Report which frames were found and hooked |
| `/hp debug` | Toggle debug chat output (off by default) |

Unlock, drag a tracker with the left mouse button, and the position is saved.
Scale is 0.5–1.5 in 0.1 steps; it moves into the options panel in Phase 4.

## Compatibility

Other addons — **ElvUI** and **DeModal** among them — also want to place the
tracker frames. heroPanel adapts instead of fighting them, per tracker:

| Mode | Behaviour |
|---|---|
| `own` | heroPanel anchors the tracker to `UIParent` itself |
| `holder` | another addon docks the tracker into a holder frame; heroPanel leaves the tracker alone and moves that holder instead |
| `yield` | another addon owns the frame outright; heroPanel stops positioning it and only skins it |

The default, `auto`, uses `own` until it sees the tracker docked into a named
holder frame, at which point it switches to `holder` straight away — an addon
that docks the tracker somewhere has already said where it wants it, so there
is nothing to fight about. If contention persists with no usable holder, it
steps down to `yield`.

In `holder` mode heroPanel stops correcting the tracker's own anchor entirely;
that anchor belongs to the other addon. It only places the holder, and the
tracker comes along with it.

The holder is found by **observing** which frame the tracker gets docked into
(plus a check of known holder names at login, since addons load in any order),
so this works with any addon that behaves this way — heroPanel hardcodes no
other addon's frame names and never reads or writes another addon's saved
variables.

Force a mode with `/hp mode <auto|own|holder|yield>`, and check what resolved
with `/hp status`. heroPanel never disables another addon on your behalf.

## Files

```
heroPanel/
  heroPanel.toc   addon manifest, declares SavedVariables HEROPANEL_DB
  Core.lua        namespace, defaults, event dispatch, slash commands
  Util.lua        timers, combat-safe deferral, colours, throttled tree scanner
  Trackers.lua    frame discovery and the collapse-aware height helper
  Move.lua        drag, lock and scale, with saved geometry
  Compat.lua      conflict detection
```

## Development notes

* **Client API is 3.3.5a only.** No modern WoW API.
* **`WatchFrame` is protected.** `SetPoint` / `Show` / `Hide` / `SetMovable` /
  `SetScale` / `EnableMouse` on it must go through `ns.RunWhenSafe`, which runs
  immediately out of combat and otherwise defers to `PLAYER_REGEN_ENABLED`.
* **Never overwrite game scripts.** Use `ns.HookScript` (hooks if a handler
  exists, sets only when the slot is empty) and `hooksecurefunc` for global
  functions, to avoid taint.
* **`MythicPlusObjectiveTracker` may not exist at `ADDON_LOADED`.** It is polled
  by `ns.PollForTracker`, which backs off and gives up rather than spinning.
* **Timers go through `ns.After`.** `C_Timer` is not present on every 3.3.5a
  client, so `ns.After` falls back to an `OnUpdate` queue.
* **Holding a position on `WatchFrame` needs three measures**, because the
  client re-anchors it from more than one place: removal from
  `UIPARENT_MANAGED_FRAME_POSITIONS`, a `hooksecurefunc` on
  `UIParent_ManageFramePositions`, and a `hooksecurefunc` on the frame's own
  `SetPoint`. Positions are stored as UIParent-space offsets from `TOPLEFT`,
  not as whatever anchor the frame happened to be using.
* **Frame-tree walks are throttled.** `ns.NewTreeScanner(frame, callback, opts)`
  drives passes from a shared `OnUpdate` accumulator, capped at ~10 per second.
  Use it instead of writing per-frame `OnUpdate` handlers.
