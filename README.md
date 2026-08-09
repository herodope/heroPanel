# heroPanel

A World of Warcraft addon for the **Ascension WoW · Conquest of Azeroth** realm
(3.3.5a / WotLK client) that reskins and repositions the objective trackers:

* the default quest tracker (`WatchFrame`)
* the Mythic+ tracker (`MythicPlusObjectiveTracker`, from `Ascension_MythicPlus`)

heroPanel is standalone. It reads and writes only its own SavedVariables
(`HEROPANEL_DB`), never hooks game logic with raw overwrites, and never touches
protected frames while the player is in combat.

## Status

**Phases 1–3 — the quest tracker is skinned.** Move, lock and rescale work, and
`WatchFrame` gets the panel, header row and text treatment. The Mythic+ tracker
is discovered and movable but not yet skinned; the options panel is still to
come, so colours and sizes are read from `HEROPANEL_DB` rather than edited in a
UI.

| Phase | Scope | State |
|---|---|---|
| 1 | Addon skeleton, frame discovery, conflict detection, move/lock/scale, shared helpers | done |
| 2 | Panel skin — background, border, radius, backdrop texture | done (quest tracker) |
| 3 | Text — fonts, per-state colours, header chrome, collapse caret | done (quest tracker) |
| 4 | Options panel, LibSharedMedia fonts, M+ chest tiers and timer chrome | planned |

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
| `/hp skin [on\|off]` | Skin the trackers, or hand them back to Blizzard |
| `/hp status` | Report which frames were found and hooked |
| `/hp debug` | Toggle debug chat output (off by default) |

Unlock, drag a tracker with the left mouse button, and the position is saved.
Scale is 0.5–1.5 in 0.1 steps; it moves into the options panel in Phase 4.

`/hp skin off` sets `HEROPANEL_DB.enabled = false` and puts the tracker back the
way Blizzard had it — fonts, colours, header art and all — rather than hiding
heroPanel's own chrome over the top of a still-skinned frame. It is the escape
hatch when something looks wrong.

## The skin

The quest tracker gets a panel behind it, a header row over its own, and its
lines recoloured:

* **Panel** — solid `bg.color` at `bg.opacity`, a 1px `border.color` hairline,
  an approximated `radius`, and a dark contour for elevation.
* **Header** — a lock toggle, an `OBJECTIVES` label, a badge with the number of
  tracked quests, and a caret drawn over the tracker's own collapse button.
  Clicking the caret collapses the tracker; so does clicking the header, while
  the tracker is locked. `header.show = false` turns the row off and gives
  Blizzard's header back.
* **Lines** — quest titles in gold, objectives in the normal colour with their
  counter picked out brighter, completed objectives in green with a check where
  their dash was, and text objectives keeping their leading dash.
* **Hover** — the quest block under the cursor gets an 8% accent tint and an
  accent strip down its left edge; the collapse button gets an accent square.

### What the skin deliberately does not do

The tracker pools and lays out its own lines, and heroPanel has to stay out of
that. So:

* **No line is moved, resized, shown, hidden or given a script.** Only colour,
  font and the counter highlight change.
* **Fonts only ever get smaller.** The tracker measures each line and places the
  next one before heroPanel sees it, so a larger font would wrap a line into its
  neighbour — and the fix for that would be moving lines. A configured
  `font.size` larger than the tracker's own is clamped down per line.
* **Counters are not right-aligned.** The design right-aligns them; that needs
  the number in its own anchored region on a pooled line, so the brighter colour
  carries the distinction instead and the alignment stays Blizzard's.
* **The panel is as wide as the tracker**, not a fixed 288px, so the header's
  caret still lands on the tracker's collapse button. 288px is the fallback for
  a tracker that has not reported a usable width yet.
* **Corners are chamfered, not rounded.** 3.3.5a has no rounded corners and
  heroPanel ships no art, so `radius` steps the background and border in at each
  corner — at the default 8px that is a 2px cut.
* **Collapsing goes through the tracker's own button.** heroPanel reads the
  collapse state and re-skins the button; it never drives `WatchFrame`'s state
  itself, and it refuses to collapse in combat rather than force it.

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
  Core.lua        namespace, defaults, design tokens, event dispatch, slash commands
  Util.lua        timers, tickers, combat-safe deferral, colours, fonts,
                  cursor hit testing, throttled tree scanner
  Trackers.lua    frame discovery and the collapse-aware height helper
  Move.lua        drag, lock and scale, with saved geometry
  Skin.lua        the panel plate, the header row and the refresh triggers
  Lines.lua       line styling, quest blocks and the hover state
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
  Use it instead of writing per-frame `OnUpdate` handlers. `ns.NewTicker` is the
  same idea for work that is not a tree walk.
* **The skin is trigger-driven, never per-tick.** It re-applies on show, on
  size change, on `WatchFrame_Update` / `_Collapse` / `_Expand`, and on
  `QUEST_WATCH_UPDATE`; every trigger is coalesced onto the next frame, so a
  quest turn-in costs one pass rather than one per event. The only `OnUpdate`
  the skin runs is a 10Hz hover sample.
* **Hover does not enable the mouse.** A mouse-enabled overlay would sit between
  the player and the tracker's clickable quest lines, so hover is sampled with
  `ns.MouseIsOver` — pure geometry — and the wrapper's own `OnEnter`/`OnLeave`
  are called from there. Nothing heroPanel draws can swallow a click.
* **The plate sits a strata below the tracker, not a couple of frame levels.**
  Levels bottom out at zero and only compare within one strata, so subtracting
  from the tracker's level is only safe if the tracker is high enough — and this
  client puts `WatchFrame` at level 1, which clamped the plate to 0 and pushed
  the glyph overlay *above* the tracker. A strata step has no floor, so the
  plate, the hover tint and the check glyphs are behind the tracker whatever
  level it picks. The only thing above the tracker is the lock button, which has
  to take its own clicks even while the tracker is mouse-enabled for dragging;
  it gets the tracker's own strata and one level up.
* **The tracker's header is cleared by geometry, not by name.** heroPanel's
  header row replaces the tracker's own, so everything drawn in that band has to
  go. Naming the regions does not work: the string on screen is not reliably the
  one a `WatchFrameTitle` lookup finds, and on this client it is not even a
  region of `WatchFrame` — it hangs off a child frame, where a name lookup and a
  regions-of-the-root scan both miss it. So the band is measured from the
  collapse button and everything the tracker draws inside it is faded. The walk
  reaches as deep as the line walk does, deliberately: anything the line walk can
  mistake for a quest title has to be something the fade can reach.
* **Nothing on a Blizzard region is destroyed.** Header chrome is faded with
  `SetAlpha`, not hidden — `Show`/`Hide` on a frame the game manages is what gets
  refused in combat — and every font, colour, alpha and rewritten string is
  remembered so `/hp skin off` can put it back exactly. The original alpha is
  recorded once but the fade is re-applied on every refresh, because the tracker
  will happily show a region again on its next update.
* **Texture paths are candidate lists.** heroPanel ships no art, and which
  client textures exist varies between 3.3.5a builds, so `ns.SetTextureFile`
  tries each path and falls back to a plain square. It probes once whether the
  client reports texture load failures at all, because believing a client that
  always answers `nil` would reject every path.
