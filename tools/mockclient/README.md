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

Both runs should print `all checks passed`. A failure prints what broke followed
by heroPanel's chat and debug output for the run.

## What the two modes cover

| | full | minimal |
|---|---|---|
| `WatchFrameTitle`, `WatchFrameCollapseExpandButton` | named globals | anonymous, found by scanning |
| `line.text` / `line.dash` parent keys | present | absent, resolved by width |
| `WatchFrame_Update` / `_Collapse` / `_Expand` | present, hooked | absent, events used instead |
| `GetNumQuestWatches` | present | absent, block count used instead |

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
