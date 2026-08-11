# heroPanel

A World of Warcraft addon for the **Ascension WoW · Conquest of Azeroth** realm
(3.3.5a / WotLK client) that reskins and repositions the objective trackers:

* the default quest tracker (`WatchFrame`)
* the Mythic+ tracker (`MythicPlusObjectiveTracker`, from `Ascension_MythicPlus`)

heroPanel is standalone. It reads and writes only its own SavedVariables
(`HEROPANEL_DB`), never hooks game logic with raw overwrites, and never touches
protected frames while the player is in combat.

## Status

**Feature complete for 0.1.** Move, lock and rescale work; `WatchFrame` gets
the panel, the header row, the text treatment, right-aligned counts and
heroPanel's own glyph art, and the tracker's own header chrome and stray icons
are dealt with. `MythicPlusObjectiveTracker` gets the same plate with its own
header, keystone timer, threshold bar, enemy-forces meter and boss rows. Fonts
come from LibSharedMedia, and everything configurable is edited in the options
window — `/hp`, or Interface → AddOns → heroPanel — which applies changes live
rather than on the next reload.

| Phase | Scope | State |
|---|---|---|
| 1 | Addon skeleton, frame discovery, conflict detection, move/lock/scale, shared helpers | done |
| 2 | Panel skin — background, border, radius, backdrop texture | done (quest tracker) |
| 3 | Text — fonts, per-state colours, header chrome, collapse caret, right-aligned counts, glyph art | done (quest tracker) |
| 4 | Mythic+ panel — header, keystone timer, chest tiers, threshold bar, enemy forces, boss rows | done |
| 5 | Options panel, LibSharedMedia fonts | done |

Known-good on the Ascension client this was built against. The notes below
record what that client does differently from a stock 3.3.5a one — several of
those cost a long debugging session each and are not guessable from the code.

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
| `/hp` | Open the options window |
| `/hp help` | List the commands |
| `/hp font <8-20>` | Set the base text size |
| `/hp fontface <name>` | Set the LibSharedMedia face by name |
| `/hp glyphs <auto\|art\|tga\|blocks>` | Where the lock and caret come from |
| `/hp texture <path>` | Put any texture in the caret's slot, untinted; no path resets it |
| `/hp mplus` | Report what the Mythic+ panel resolved, and which source each number came from |
| `/hp mode <auto\|own\|holder\|yield>` | Who positions the trackers — see Compatibility |
| `/hp skin [on\|off]` | Skin the trackers, or hand them back to Blizzard |
| `/hp status` | Report which frames were found and hooked |
| `/hp dump` | Report the geometry the skin measured, and what it found in the tracker's header band |
| `/hp probe [all]` | Report what else draws inside the panel, whoever owns it — `all` adds heroPanel's own regions |
| `/hp frame <name>` | Everything about one named frame — use the name `/framestack` gives |
| `/hp debug` | Toggle debug chat output (off by default) |

Unlock, drag a tracker with the left mouse button, and the position is saved.
Scale is 0.5–1.5 in 0.1 steps, from the slash command or the options window —
both go through the same `ns.SetScale`, so they cannot disagree. There is
deliberately no mousewheel binding on the tracker frames.

`/hp skin off` sets `HEROPANEL_DB.enabled = false` and puts the tracker back the
way Blizzard had it — fonts, colours, header art and all — rather than hiding
heroPanel's own chrome over the top of a still-skinned frame. It is the escape
hatch when something looks wrong.

## The skin

The quest tracker gets a panel behind it, a header row over its own, and its
lines recoloured:

* **Panel** — solid `bg.color` at `bg.opacity`, a 1px `border.color` hairline,
  an approximated `radius`, and a dark contour for elevation.
* **Header** — a lock toggle at the left, an `OBJECTIVES` label, a badge with
  the number of tracked quests, and a caret at the right, centred in the row and
  mirroring the lock. The caret is placed against the panel rather than over the
  tracker's own collapse button: that button sits wherever the tracker keeps it,
  which on this client is below the row's centre and against the divider.
  Clicking the header collapses the tracker while it is locked, and the
  tracker's own button still takes its own clicks underneath, so collapsing
  works wherever the glyph is drawn. `header.show = false` turns the row off and
  gives Blizzard's header back.
* **Line art** — the turn-in question mark and the quest POI button hang off the
  *left* of a quest line's text, outside the panel. They are moved back inside,
  into the panel's left margin beside the title on their own row. `PAD_LEFT` is
  34 rather than the design's 14 precisely to make that margin: the tracker's
  titles start flush against the content edge, so there is otherwise nowhere to
  put an icon that does not overlap the text.
  **Everything is compared in screen pixels, never in UI units.** The tracker's
  line container carries a scale of its own, so a POI button sits at effective
  0.64 against a panel at 0.71 — its `GetLeft` reads as comfortably inside the
  panel's range while on screen it is ten pixels off the left edge. Two
  coordinates being in the same units is not something to assume. This is the one place the skin re-anchors
  something the tracker owns, and it is deliberately narrow: only objects that
  are icon-sized *and* actually sticking out are touched, anything already
  inside is left where the tracker put it, and both the line's own Textures and
  the frames it parents are covered without naming either — on this client the
  icon is a level further out than a scan of the line's own regions reaches.
  Anchors and sizes are remembered so `/hp skin off` restores them; the size has
  to be restated when re-anchoring, since an object anchored by two corners
  loses its size the moment its points are cleared. Skipped in combat, because
  anchoring a child of the tracker is protected — the skin refreshes on
  `PLAYER_REGEN_ENABLED` and catches up.
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
* **Fonts grow by at most two points.** The tracker measures each line and
  places the next one before heroPanel sees it, so a line can never ask for more
  room. Growth used to be forbidden outright, which meant the objective size —
  half a point under the base — could only come out *smaller* than Blizzard's,
  and the skin made its own text harder to read than the text it replaced. This
  client lays lines out on a 14px pitch with a 12px font, so two points fits the
  gap already there; beyond that lines would collide, so `font.size` is clamped
  per line however large it is configured.
* **Counters are right-aligned by moving them out of the line.** The count
  arrives inside the line's single FontString — on this client as a *prefix*,
  `"0/1 General Drakkisath slain"` — so it is taken out of that string and drawn
  in heroPanel's own FontString against the panel's right edge. Shortening a
  string is the safe direction: the tracker already placed the line at its full
  length, so it cannot wrap. The original is remembered like any other
  decoration. With no panel to align against, the count keeps its place in the
  sentence and only takes the brighter colour, as before.
* **The panel is as wide as the tracker**, not a fixed 288px, so the header's
  caret still lands on the tracker's collapse button. 288px is the fallback for
  a tracker that has not reported a usable width yet.
* **Corners are chamfered, not rounded.** 3.3.5a has no rounded corners and
  heroPanel ships no art, so `radius` steps the background and border in at each
  corner — at the default 8px that is a 2px cut.
* **Collapsing goes through the tracker's own button.** heroPanel reads the
  collapse state and re-skins the button; it never drives `WatchFrame`'s state
  itself, and it refuses to collapse in combat rather than force it.

## The options window

`/hp`, or Interface → AddOns → heroPanel. 440px, centred, in its own frame
strata.

**Everything applies live.** A control writes `HEROPANEL_DB` and re-skins on the
spot, so the tracker behind the window shows the setting as it is being dragged.
There is no pending-changes buffer, which makes "Save & close" a close button
that says out loud nothing was left uncommitted. Reset puts the defaults back
and re-applies them — it clears the saved positions too, so a `/reload` is what
finally returns the frames to where the game wants them, the same as `/hp reset`.

**The window's own chrome is fixed, not configured.** It is painted from the
design's tokens through `ns.StylePlateChrome`'s style override rather than from
`HEROPANEL_DB`, because this is the window those colours are changed in: a panel
that restyles itself as you drag its own background swatch makes it impossible to
see what you are setting. Everything rounded in it — toggles, pills, swatches,
buttons, tiles — is a frame given the shared plate chrome, so the corner chamfer
is written once and the window steps its corners the way the tracker panels do.

**It will not open on top of a tracker.** Centring is the rule but not the
guarantee: a 440px window in the middle of a 1600px screen reaches x 1020, and a
tracker parked at 1000 is under it. So the centred position is measured against
whatever is actually on screen — both trackers *and* heroPanel's own plates,
which are wider than the frames they skin — and slid clear if it is not, to
whichever side has room. If neither side has room it stays centred: covering a
tracker beats opening off the edge of the screen where it cannot be reached.
Once the window has been dragged, that position is remembered and never
second-guessed.

**Two controls do not do what their labels might suggest.**

* **Backdrop texture** offers Flat, Noise, Gradient and Glow, and only Flat
  draws. heroPanel ships no texture art, so the other three are greyed and say
  so on hover. They are present rather than absent because a control that is
  missing reads as a build that is behind, and one that silently does nothing
  reads as a bug.
* **Show quest header** is `header.show`, and it is the *quest* tracker's header
  row. The Mythic+ panel's header carries the dungeon name, the keystone level,
  the affix icons and that panel's own lock button, and turning all four off from
  a control labelled "show header" would be a surprise rather than a setting.

The window height is a fixed budget. `UIParent` is about 768 units tall whatever
the monitor is, because the client scales the UI to suit; laid out at the
design's spacing the panel came to 752, which fits by eight pixels a side and
does not fit at all once a player nudges their UI scale up. It is tightened to
684, and the mock client fails the run if it ever goes over 768.

## Fonts

`HEROPANEL_DB.font.face` is resolved through **LibSharedMedia-3.0**, which is
embedded rather than required — a player installing a skin should not have to go
and find a library first, and `## Dependencies` on a 3.3.5a client is a hard
failure rather than a warning. LibStub keeps one instance per major version and
the highest minor wins, so if another addon already loaded a newer
LibSharedMedia heroPanel's copy is a no-op and heroPanel uses theirs — which is
how faces registered by SharedMediaAdditionalFonts, SharedMedia_Causese or ElvUI
turn up in the font dropdown without heroPanel knowing they exist. See
`heroPanel/libs/README.md` for versions and licences.

Two things `Media.lua` is careful about:

* **Friz Quadrata TT is the fallback and it does not come from the library.**
  It is the face 3.3.5a always has, so "the default works" must not depend on
  LibSharedMedia being present, on it having that key registered, or on the
  player's locale — LSM registers the name per locale and a non-western client
  gets a different key entirely. The path is read off `GameFontNormal`, so no
  asset path is written down.
* **A font path is validated before it is handed out.** `SetFont` on a file the
  client will not read leaves the FontString blank, and blank text on a dark
  panel looks exactly like a skin that did not run. The probe has the same shape
  as `ns.SetTextureFile`'s: ask the client once whether it reports failures at
  all, because believing a client that always answers `nil` would reject every
  path including the good one.

The dropdown draws each row in its own face. A font list you cannot see is a
list of names, and picking a face by name is guesswork.

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
                  glyphs, cursor hit testing, throttled tree scanner
  Plate.lua       the panel chrome both trackers share — background, border,
                  corner chamfer, contour, gradient bars
  Trackers.lua    frame discovery and the collapse-aware height helper
  Move.lua        drag, lock and scale, with saved geometry
  Skin.lua        the quest panel — header row and the refresh triggers
  Lines.lua       line styling, quest blocks, right-aligned counts, hover
  Mplus.lua       the Mythic+ panel — keystone timer, chest tiers, threshold
                  bar, enemy forces and boss rows
  Options.lua     the options window and the Interface → AddOns category
  Compat.lua      conflict detection
  Media.lua       fonts, by way of LibSharedMedia
  libs/           embedded LibStub, CallbackHandler-1.0, LibSharedMedia-3.0
  media/          glyph art — generated, see tools/glyphgen
```

```
tools/
  glyphgen/       rasterises the glyph art into 64×64 TGAs; re-run after
                  editing a shape, and copy media/ into the addon folder
  mockclient/     boots heroPanel outside the game and checks the skin
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
  The Mythic+ skin hangs off that same discovery point — the
  `HEROPANEL_TRACKER_FOUND` event — rather than polling a second time.
* **The Mythic+ tracker is not a 3.3.5a-shaped addon.** It ships inside
  `patch-B.MPQ` as `Interface\AddOns\Ascension_MythicPlus`, and it is written
  against a backported modern API: mixins (`CreateFromMixins`,
  `ObjectiveTrackerBaseMixin`), atlases, `RegisterCallback`, `RunNextFrame` and
  a `C_MythicPlus` namespace. Its layout is fixed in XML, so unlike `WatchFrame`
  the widget names are knowable and heroPanel fades chrome by name rather than
  by geometry.
* **Where the Mythic+ numbers come from.** `C_MythicPlus.IsKeystoneActive`,
  `GetActiveKeystoneInfo` (`keystoneLevel`, `dungeonID`), `GetActiveKeystoneTime`
  (`timeLeft, totalTime`) and `GetActiveKeystoneTrash`
  (`trashDead, trashRequired`); the dungeon name is
  `GetLFGDungeonInfo(dungeonID)`. Boss state is read off the tracker's own
  objective rows, which carry `.Text` and `.progress` / `.progressMax` — the
  same pair the tracker itself tests to decide whether to draw a check. If
  `C_MythicPlus` is absent the panel falls back to reading the tracker's own
  widgets, which `/hp mplus` reports on.
* **Ascension's own chest-tier clocks are wrong, so heroPanel does not read
  them.** `MYTHIC_PLUS_BONUS_LEVEL_PERCENT` is `{ 0.55, 0.4 }` — the fraction of
  the timer that must be *left* for +3 and +2 — and that is how
  `MythicPlusUtil.GetCompletionInfo` and the completion banner both read it. The
  tracker's `TimeLeft2` / `TimeLeft3` fields instead compute their countdowns
  from `(1 - PERCENT[n])`, and are swapped against the notches they are coloured
  to match: on a 30 minute key its "+3" field counts down to 18:00 remaining
  where the real threshold is 16:30. heroPanel computes the tier itself from
  the timer and the client's own constant, so a retune still follows.
* **Two things the design asks for have no data on this client.** There is no
  death counter and no time penalty anywhere in Ascension's Mythic+ code or in
  `C_MythicPlus`, so the death line is not drawn — the footer keeps only the
  rule and the heroPanel mark. And there is no per-boss "engaged" flag, nor
  `ENCOUNTER_START` or `IsEncounterInProgress`, so the boss rows are drawn as
  slain or still-up; the "in combat" state is implemented but nothing sets it,
  because deciding it from "the player is fighting and this is the next boss in
  the list" would be heroPanel inventing state and getting it wrong on any pull
  that is out of order.
* **Ascension restyles an objective row every time its progress changes.**
  `ScenarioObjectiveMixin:SetProgress` calls `SetFontObject` on the row's text
  and counter, which throws away whatever font and colour anyone else put
  there. Because the panel only redrew on an event, killing a boss left that
  row wearing Ascension's disabled font — dark grey on a dark panel, so the
  name looked like it had vanished, and it never came back for the rest of the
  run. Every row the panel styles is now hooked with `hooksecurefunc`
  (`SetObjective` / `SetProgress` / `SetLabel` / `UpdateSubObjectives` /
  `Expand` / `Collapse`) so any change Ascension makes queues a redraw.
* **Chrome is faded as a subtree, not widget by widget.** The affix buttons
  keep their icon on a child frame, so a pass over the button's own regions and
  its four button textures missed it.
* **The live tracker has a lock button the extracted XML does not.**
  `MythicPlusObjectiveTrackerLockButton` — named by `/framestack`, not by
  reading the source, because the build in `patch-B.MPQ` has no
  `$parentLockButton`. heroPanel draws its own lock in the header's top-left
  corner, so Ascension's is faded *and* has its mouse turned off; leaving it
  live would let it swallow hovers meant for the affix icons beside it. It is
  resolved by parent key and by global name, and is simply absent on a client
  that does not have it.
* **A boss's state is re-read at draw time, not taken from its row.** The two
  numbers on the panel come from different places: the heading's count from
  `GetActiveKeystoneEncounters().encountersCompleted`, each boss's state from
  `GetEncounterInfo(encounterID).isDead`. `UpdateEncounters` reads the second
  the instant `MYTHIC_PLUS_ENCOUNTER_UPDATE` fires, and the server has not
  committed `isDead` for the boss that just died — so that row stays grey until
  the *next* encounter update refreshes everything, which is why a live run
  showed the count one ahead of the green ticks every time. heroPanel calls
  `GetEncounterInfo` itself when it draws, matching rows by name (with the kill
  time Ascension appends stripped off first), so it is right on the first pass.
  A name the API does not know keeps the row's own state, so the override can
  never invent a kill.
* **Affixes are spell IDs.** `GetActiveKeystoneInfo().activeAffixes` is a list
  of them; `GetSpellInfo(affixID)` gives the name and icon, and this client
  ships a `GameTooltip:SetAffix(affixID)` extension that builds the full
  tooltip. heroPanel draws its own affix icons in the header's top-right corner
  rather than keeping Ascension's, so they take the panel's size and spacing
  while still showing the game's tooltip on hover. They and the lock are the
  only things the panel puts above the tracker, because both need the mouse.
* **Dragging a tracker in combat is allowed.** `StartMoving` /
  `StopMovingOrSizing` are not among the calls the client refuses under
  lockdown. The calls that genuinely are protected — `SetPoint`, `Show`,
  `Hide`, `SetScale`, `EnableMouse` — still go through `ns.RunWhenSafe`.
* **The expanded "Defeat additional bosses" row is a heading, not a boss.**
  While it is expanded its sub-rows are the bosses and it is a label over them,
  so it gets no indicator; collapsed, the sub-rows are not drawn and it stands
  in for them. Its count moves out of the right-aligned counter and into the
  sentence — "Defeat Additional Bosses (1/6)" — and is left off entirely until
  the first extra boss dies. Rewriting a tracker string is the one thing here
  that changes what the game drew, so it follows Lines.lua's rule: the original
  is kept and the rewrite is only treated as ours while the string on screen is
  still the one heroPanel wrote, which is what stops a second pass stacking a
  second count. It turns green once its requirement is met, expanded or
  collapsed — collapsed it is an ordinary completed objective and was already
  green, so the same finished run used to read as unfinished depending on which
  way the chevron pointed.
* **Enemy forces can read over 100%, on purpose.** `GetActiveKeystoneTrash`
  reports raw counts, so a group that pulled more than the key needed shows
  114% or 160%. Ascension's own objective row clamps that away with `MClamp`
  and shows a flat 100%; heroPanel does not, because the overflow is the one
  number that says how much trash was overpulled, which is worth knowing both
  during a run and after one. The bar underneath *does* clamp — a fill cannot
  run past the end of its track — so above 100% the two deliberately disagree:
  the bar says "done", the number says "and this much again". This is a
  feature. Do not "fix" it.
* **The extra-bosses list is drawn by heroPanel, not restyled in place.** This
  is the one place that departs from "recolour and refont only", and the reason
  is length: a dungeon can offer far more minibosses than the key requires —
  fifteen for a requirement of five in Lower Blackrock Spire — which made a
  panel taller than the screen. Windowing the tracker's own rows would mean
  hiding the ones outside the window and re-anchoring the rest as it scrolls,
  and showing, hiding and moving pooled objective rows is exactly what must not
  happen, because the tracker owns their layout and reasserts it on every
  update. So Ascension's sub-rows are faded whole — alpha only, as reversible
  as everything else here — and the list is drawn again on heroPanel's plate,
  six rows tall with the wheel scrolling it. The required boss and the
  extra-bosses heading are still restyled where the tracker drew them; only the
  variable-length list is taken over.
* **The scroll catcher takes the wheel but not the mouse.** `EnableMouseWheel`
  without `EnableMouse`, so a scroll reaches the list while a click or a drag
  still falls through to the tracker underneath, which is mouse-enabled for
  dragging.
* **The boss block is three sizes, not one.** The required boss is title-sized,
  the extra-bosses heading sits a step under it and the bosses under that, all
  as offsets from the configured base so `/hp font` still moves them together.
  A defeated boss is marked by a check mark alone: it was a tick knocked out of
  a filled disc, which at 14 pixels read as a green blob with a notch in it.
* **Ascension anchors enemy forces below the boss rows; the design puts it
  above.** heroPanel draws its own enemy-forces row where the design wants it
  and fades the tracker's, rather than re-anchoring an objective row. The panel
  is therefore sized from the boss rows it drew rather than from the tracker's
  frame, which is both far taller than its contents and still reserving space
  for the row that is now invisible.
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
  collapse button and everything the tracker draws through it is faded. The walk
  reaches as deep as the line walk does, deliberately: anything the line walk can
  mistake for a quest title has to be something the fade can reach.
  The band is a strip of screen, so the test is whether a region **overlaps** it,
  not whether it starts inside it — the tracker's own background art overhangs
  the frame's top edge and runs the height of the panel, so a top-inside test
  threw it out for being too high. Quest lines are drawn below the band and are
  a line tall, so none of them reaches into it; what overlap adds is the large
  art that spans the header, which is chrome by definition.
  Separately, a frame that draws inside the band is a header frame and the rest
  of what it draws is header too, for art anchored just below the band. Only the
  owning frame's own regions are taken, never its children's and never the
  tracker's, so nothing carrying quest text can be caught that way either.
* **Nothing on a Blizzard region is destroyed.** Header chrome is faded with
  `SetAlpha`, not hidden — `Show`/`Hide` on a frame the game manages is what gets
  refused in combat — and every font, colour, alpha and rewritten string is
  remembered so `/hp skin off` can put it back exactly. The original alpha is
  recorded once but the fade is re-applied on every refresh, because the tracker
  will happily show a region again on its next update.
* **Glyphs are heroPanel's own art, with a drawn fallback.** Blizzard's icons
  cannot be used: `SetVertexColor` multiplies, so a gold padlock tinted
  `#75798C` comes out muted gold, and nothing in the client's set is neutral
  enough to tint cleanly. So `heroPanel/media/` ships four 64×64 white alpha
  masks — caret, check, closed and open lock — generated by
  `tools/glyphgen/glyphgen.py`, which authors the shapes in a 32-unit space and
  scales them, so the texture can grow without touching a coordinate. White
  tints exactly and the client filters the shape smoothly.
  Each ships as **one `.tga`**: 64×64, 32-bit BGRA, RLE compressed, TGA 2.0
  footer, fully transparent pixels black. Every one of those was matched
  against the textures this client is known to load rather than assumed, and
  the header and footer are byte-identical to them.
  **Fully transparent pixels must be `000000`, not `FFFFFF`.** That is the one
  change that separated a glyph rendering from a glyph coming out as the
  client's missing-texture green, and it is the convention every reference
  texture sampled on this client uses. It is not obvious why it matters — a
  transparent pixel's colour should not affect whether a file decodes — so
  treat it as observed behaviour rather than a rule with a known mechanism.
  Ruled out along the way, each having cost a round:
  - **Power-of-two dimensions.** The usual cause of green squares, and never in
    play here: these have been 32×32 or 64×64 throughout.
  - **Image type.** Uncompressed and RLE both load on this client; 32 of the
    reference files sampled are uncompressed.
  - **A sibling `.blp` shadowing the `.tga`.** Believed for a while and false.
    The `.blp` files were still sitting in the addon folder when the glyphs
    started working, so they cannot have been masking anything.
  **One file per glyph and no candidate chain**, kept on its own merits: a chain
  makes "the glyph is green" ambiguous about which file produced it.
  None of this is visible from Lua: `SetTexture` reports success as soon as the
  path resolves, so `auto` cannot tell a decoded texture from a rejected one and
  `/hp status` will report `shipped art` over a green square. Diagnosing that
  needs `/hp texture <path>`, which puts any texture in the caret's slot
  untinted — pointing it at a texture known to work is what separates "our file
  is wrong" from "our use of it is wrong".
  Textures are also cached by path for the life of the session: replacing a file
  and running `/reload` does **not** re-read it. Restart the client.
  If the art will not load, `ns.NewGlyph` falls back to building the same shapes
  from `WHITE8X8` blocks on a cell grid (`ns.GLYPHS`, as
  `{ column, row, columnSpan, rowSpan }`). The grids are fine — the chevron is
  14 cells across — so the unit lands near a pixel and the arms read as strokes;
  a coarse grid gives blocks two or three pixels square and a chevron built from
  those reads as Lego.
  The two routes look very different and which one is live is invisible in a
  screenshot, so `/hp status` reports it and `/hp glyphs <auto|art|blocks>`
  forces either. `auto` decides from whether the client reports the texture as
  loaded, from the one `.tga` path — a path the client rejects sends the glyph
  to blocks with the art sitting there unread.
* **Texture paths are candidate lists.** heroPanel ships no art, and which
  client textures exist varies between 3.3.5a builds, so `ns.SetTextureFile`
  tries each path and falls back to a plain square. It probes once whether the
  client reports texture load failures at all, because believing a client that
  always answers `nil` would reject every path.

* **`ns.StylePlateChrome(plate, style)` takes an optional override.** The
  trackers paint from `HEROPANEL_DB`; the options window passes its own fixed
  tokens. Zero is a meaningful value for opacity, radius and alpha, and zero is
  truthy in Lua, so the plain `or` fallbacks do the right thing with it.
* **`border.style = "inset"` is a real style now**, not a synonym for hairline:
  the 1px line moves one pixel in and the dark contour moves from outside the
  plate onto the pixel it vacated. Two rows — dark outside, coloured inside — is
  what reads as recessed at this size. A genuine bevel needs two tones on
  opposite corners, which needs art heroPanel does not ship, so this is the cheap
  read of the same idea, the way the chamfer stands in for a radius.
* **Frame level beats draw layer between two frames.** The options window's
  accent-tinted "Enable skin" row is a child frame laid over the window, and
  with the row's labels drawn on the *window* they were simply not there — the
  tint covered them however high their layer. Anything drawn inside a tinted row
  has to be a child of that row. Sibling frames on the same level have no defined
  draw order either, which is why the toggle's knob states its level rather than
  relying on being created after its track.
* **`string.format("%d", x)` on a float is an error under Lua 5.3.** The game is
  5.1 and truncates silently; the mock client runs fengari, which is 5.3 and
  throws. Slider values arrive as floats even with a whole-number step, so they
  are floored before formatting. This is the one direction the caveat runs the
  wrong way — a bug the harness catches that the game would have hidden.
* **The mock client reads the load order out of the `.toc`.** It used to hold its
  own list, which went stale the moment a file was added: the new file was not
  loaded and the run failed somewhere unrelated, on a nil where a helper that had
  moved into it used to be. fengari has no `io.open`, so `run.js` reads the
  manifest and hands it over as a string.
* **The embedded libraries need 5.1 and FrameXML globals the addon itself never
  used.** `getfenv`, `bit.band` and `loadstring` are 5.1 and gone in 5.3;
  `strmatch`, `geterrorhandler` and `GetLocale` are FrameXML's rather than Lua's.
  The mock provides all of them. `loadstring` in particular stayed hidden until
  the harness registered a font, because CallbackHandler only builds its
  dispatchers when a callback actually fires.
* **CallbackHandler's `RegisterCallback` is a dot call whose first argument is
  the registering object, not the library.** `lib:RegisterCallback(...)` is an
  error — the library reads itself as the event name. heroPanel passes its addon
  name, which is a supported `self` and avoids the question.

## Testing

`tools/mockclient` boots heroPanel outside the game and checks the skin; all
four of its runs should pass. It covers structure — what gets built, what gets
written, what gets re-skinned, and which paths run while combat refuses the
protected calls — and it cannot cover taint, real draw order, real text metrics
or anything that depends on the server.

`TESTING.md` is the pass for those: fresh install, fonts, the options window,
live application, combat, a Mythic+ run, reloads, and another tracker addon in
the same UI. It also lists what is knowingly unverified.

## Diagnosing the skin

Five commands, in the order they are usually worth reaching for. Each exists
because the one before it could not answer some question.

| Question | Command |
|---|---|
| What is this frame called? | `/framestack` — the client's own, not heroPanel's |
| Where is that frame, and is it drawn? | `/hp frame <name>` |
| What did the skin measure, and what did it decide? | `/hp dump` |
| What else is drawing inside the panel? | `/hp probe` |
| Is this texture file the problem, or our use of it? | `/hp texture <path>` |

**Use `/framestack` first.** heroPanel's reports answer questions the client
will not — geometry the skin measured, which texture path resolved, why a
decision went the way it did. Identifying a frame is not one of those: the
client answers it exactly, and three rounds were spent guessing at a quest POI
button's parentage that one `/framestack` named immediately.

Things that cost a session each, none of them visible from inside the addon:

* **Textures are cached by path for the life of the session.** Replacing a file
  and running `/reload` does not re-read it. Restart the client, or a whole
  round of testing measures the previous file.
* **`SetTexture` reports path resolution, not decode.** It returns success for a
  file the client then refuses to draw, so `/hp status` will report `shipped art`
  over a green square. Only `/hp texture` pointed at art known to work separates
  "our file is wrong" from "our use of it is wrong".
* **Frames are not all in the same coordinate space.** The tracker's line
  container carries its own scale, so a POI button at effective 0.64 has a
  `GetLeft` that reads as inside a panel at 0.71 while being ten pixels off its
  edge on screen. Convert to screen pixels before comparing anything.
* **A report that truncates is worse than no report.** Both the probe and the
  tuck walk buried the object being chased — once past a row limit, once behind
  a filter — and a listing that hides its answer reads as though it answered.
  Both now keep named objects and drop only clutter.
* **Green squares here were not the documented causes.** Not power-of-two
  dimensions (these have always been 32×32 or 64×64) and not image type
  (uncompressed and RLE both load). See the glyph notes above for what is
  actually known, which is less than one round of debugging appeared to show.
