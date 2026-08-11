# mockclient

A throwaway 3.3.5a-shaped mock of the WoW client, enough to boot heroPanel
outside the game and check that the skin does what it says. It is a smoke test,
not a client emulator: the geometry is a small anchor resolver, not the real
layout engine.

It catches the things that are tedious to find by relogging — a nil where a
frame method was expected, a hook that fires in the wrong order, a restore path
that does not restore — and it is the only way to exercise the fallbacks for
clients that do not have the globals heroPanel looks for.

## Running it

Needs [node](https://nodejs.org) and [fengari](https://fengari.io), a Lua VM in
JavaScript. From this directory:

```sh
npm install fengari
node run.js harness.lua          # a client with every global heroPanel expects
HP_MINIMAL=1 node run.js harness.lua   # a client with none of them
HP_NOMEDIA=1 node run.js harness.lua   # a client that cannot read heroPanel's art
```

The three switches are independent, so there are four runs; all of them should
pass. `HP_NOMEDIA` matters because the mock accepts every texture path, which
would mean the shipped glyph art always loads and the block fallback was never
once exercised.

`HP_ADDON` overrides where the addon files are read from; it defaults to
`../../heroPanel/`.

The load order comes out of `heroPanel.toc`, so a file added to the addon is a
file the harness loads. It used to be a list in `harness.lua`, which went stale
the moment a file was added — the new file simply was not loaded, and the run
failed somewhere unrelated on a nil where a helper that had moved into it used
to be. fengari has no `io.open`, so `run.js` reads the manifest and hands it to
Lua as a string.

Both runs should print `all checks passed`. A failure prints what broke followed
by heroPanel's chat and debug output for the run.

## What the two modes cover

| | full | minimal |
|---|---|---|
| `WatchFrameTitle`, `WatchFrameCollapseExpandButton` | named globals | anonymous, found by scanning |
| `line.text` / `line.dash` parent keys | present | absent, resolved by width |
| `WatchFrame_Update` / `_Collapse` / `_Expand` | present, hooked | absent, events used instead |
| `GetNumQuestWatches` | present | absent, block count used instead |
| `C_MythicPlus` | present, the keystone read from the API | absent, read off the tracker's own widgets |
| `InterfaceOptions_AddCategory` | present, the category is registered | absent, `/hp` is the only way into the options |

The Mythic+ tracker is built *after* heroPanel has booted, because the real one
does not exist at `ADDON_LOADED` — so the run also exercises Phase 1's poll and
the skin hanging off that discovery point rather than a timer of its own. Its
enemy-forces row is anchored below the boss rows, as Ascension anchors it, and
its frame is far taller than its contents: both are what the panel's own layout
has to work around rather than follow.

`MouseIsOver` is left undefined in both, so the cursor maths in `ns.MouseIsOver`
is always the path under test.

## Caveats

* fengari is Lua 5.3 and the client is 5.1. Nothing in heroPanel depends on the
  difference, but a 5.1-only construct would pass here and fail in game.
* Draw order, taint and combat lockdown are not modelled. `InCombatLockdown` is
  a flag the harness sets, which is enough to check that the combat paths are
  taken, not that they were necessary.
* The mock returns a texture-load result for every path, so the fallback chains
  in `ns.SetTextureFile` are structurally exercised but never actually miss —
  except for heroPanel's own media under `HP_NOMEDIA`.
* Text is measured as five pixels per character. Enough to tell a right-aligned
  count from a left-aligned one; not enough to say anything about wrapping.

## What the options panel run covers

The window is built, opened, measured, clicked through and reset:

* it is 440 wide and fits inside `UIParent`'s 768 units, which is a fixed budget
  whatever the monitor is
* it does not overlap either tracker **or** either of heroPanel's plates at the
  default position — checked as a rectangle overlap, not by trusting the anchor
* every control with an `OnClick` is clicked, and the ones with an observable
  effect are checked against the store *and* against the tracker, because a
  control that writes the config and does not re-skin is the "needs a reload"
  behaviour the panel exists to avoid
* the font dropdown lists a face registered after boot, and picking it changes
  the file the trackers draw with
* escape-to-close registers exactly once however many times the window opens
* the enable toggle restores and re-applies the skin in both directions
* Reset restores the defaults *and* re-applies them

Alongside it: a combat cycle with both panels up and the window open, a second
tracker addon loaded (the notice is said once and heroPanel's own hooks keep
working), repeated `Enable()` calls creating no second plate and no new frames,
and two fresh-install shapes — no store at all, and a partial one written by an
older build.

None of that is a taint test. The mock does not model taint and nothing here
stands in for a live pull; what it checks is that the paths taken while
protected calls are refused all run, and that the work `ns.RunWhenSafe` defers
is flushed afterwards rather than dropped.
