# In-game test pass

The mock client (`tools/mockclient`) covers structure: what gets built, what
gets written, what gets re-skinned, and which paths run while combat refuses the
protected calls. It cannot cover taint, real draw order, real text metrics, or
anything that depends on the server. Those are below.

Run with `/hp debug` on and `/console scriptErrors 1` set, so a fault reports
itself instead of looking like an addon that decided to do nothing.

There is no BugSack or BugGrabber in this client's `Interface/AddOns`, so
`scriptErrors` plus the `Errors/` folder at the client root is the error log.

---

## 1. Fresh install

Simulates a new public user's first launch, which is the one case an existing
store cannot exercise.

1. Move `WTF/Account/<account>/SavedVariables/heroPanel.lua` and its `.bak`
   somewhere else.
2. Log in.

- [ ] No Lua error at login
- [ ] Both trackers are skinned
- [ ] `/hp status` reports both frames found and hooked
- [ ] `/hp` opens the window, centred, with every control populated
- [ ] Font family reads **Friz Quadrata TT**, font size **12**, radius **8**,
      opacity **100%**, border style **Hairline**, backdrop **Flat**, both
      scales **100%**, Show quest header **on**, pill reads **ENABLED**
- [ ] Log out and back in: the store is written and everything comes back

Then put the old SavedVariables back if you want your positions.

## 2. Fonts

- [ ] Font dropdown lists more than the eleven faces LibSharedMedia ships with
      — SharedMediaAdditionalFonts and SharedMedia_Causese are both installed,
      so a short list means heroPanel is using its own embedded copy instead of
      theirs and the two are not sharing a LibStub
- [ ] Each row is drawn in its own face, not all in one
- [ ] Picking a face changes the text on **both** trackers immediately, with no
      reload
- [ ] It also changes the options window's own labels
- [ ] The choice survives `/reload`
- [ ] `/hp fontface Friz Quadrata TT` puts it back
- [ ] No FontString anywhere goes blank — a blank line means a path resolved and
      the client then refused to draw it, which is what `Media.IsUsableFont`
      exists to prevent

## 3. Options window

- [ ] Opens from `/hp`, closes from `/hp` again, from **Save & close**, and from
      Escape
- [ ] Opens from Interface → AddOns → heroPanel, both by selecting the category
      and by its button
- [ ] **Does not overlap either tracker.** Check at your usual resolution and
      again at a UI scale a couple of notches up, which is where a 684px window
      gets tight
- [ ] Dragging it by the header moves it, and the position survives `/reload`
- [ ] The lock button's **gradient runs light at the top to dark at the bottom**.
      This one is unverified: `SetGradientAlpha("VERTICAL", ...)` is written
      here taking the first stop at the bottom, and if it comes out inverted the
      fix is swapping the two colour triples in `PaintLockGradient` in
      `Options.lua`
- [ ] The toggle knobs are visible and sit at the right end when on, left when
      off
- [ ] Every label is legible against the accent-tinted "Enable skin" row

## 4. Live application

Each of these should be visible on the tracker **while the window is open**,
with no reload:

- [ ] Background colour swatches
- [ ] Background opacity slider
- [ ] Border colour swatches
- [ ] Border style — Hairline, then **Inset** (the line should move a pixel in
      with a dark row outside it), then None (no edge and no contour)
- [ ] Corner radius slider — the chamfer steps at 4, 8 and 12
- [ ] Quest tracker scale slider, and M+ tracker scale slider
- [ ] Font size slider
- [ ] State colour swatches — each opens the client's colour picker, previews as
      you drag inside it, and Cancel puts the old colour back
- [ ] Show quest header — turns heroPanel's row off and gives Blizzard's header
      back; the M+ header is untouched, by design
- [ ] Backdrop texture: Flat is selectable, the other three are greyed and
      explain themselves on hover

## 5. Scale stays in step

The sliders and `/hp scale` are the same function, and the sliders re-read the
store when the window opens.

1. `/hp scale watch 1.3` with the window shut
2. `/hp` — the Quest tracker scale slider should read **130%**
3. Drag it to 80%, close, `/hp status` — should report scale 0.8

- [ ] Both directions agree
- [ ] The tracker's top-left corner stays put across a rescale

## 6. Enable / disable

- [ ] The toggle off restores Blizzard's tracker completely — fonts, colours,
      header art, the tucked quest icons back outside the panel, counters back
      inside their line
- [ ] The M+ panel goes too
- [ ] The pill reads **DISABLED**
- [ ] Back on re-skins both, no reload either direction
- [ ] `/hp skin off` and `/hp skin on` do the same and the window's pill and
      toggle follow

## 7. Reset

- [ ] Change several settings, press **Reset**
- [ ] Everything returns to the defaults listed in section 1 **and is applied**,
      not merely stored
- [ ] The chat line says positions were cleared; `/reload` puts the frames back
      where the game wants them

## 8. Combat

With both trackers visible and quests tracked:

- [ ] Pull something. No error on entering combat
- [ ] Open `/hp` in combat and change a colour, a radius and a scale
- [ ] Leave combat. The scale change applies on the way out — that one is
      deferred by `ns.RunWhenSafe`, the rest are not
- [ ] Collapse the tracker in combat: refused with a message, not an error
- [ ] Nothing in `Errors/` afterwards, and no "Interface action failed because
      of an AddOn" message

## 9. Mythic+

- [ ] Enter a key. The M+ panel is skinned **on first show**, not only after a
      `/reload`
- [ ] Timer, chest tier, threshold ticks, enemy forces and boss rows all draw
- [ ] Kill a boss: its row turns green on the first pass, and the heading count
      agrees with the ticks
- [ ] Open `/hp` mid-run and change the font. Both panels follow
- [ ] Enemy forces over 100% still reads over 100% — the bar clamps, the number
      does not, and that disagreement is deliberate

## 10. Collapse and reload

- [ ] Collapse and expand the quest tracker: the skin survives both, and the
      caret flips
- [ ] `/reload` with it collapsed: it comes back collapsed and skinned
- [ ] `/reload` several times in a row. Nothing stacks — one refresh per
      trigger, not two or four. `/hp debug` makes this visible: a doubled hook
      shows as the same "skin refreshed" line twice for one event

## 11. Alongside another tracker addon

ElvUI is installed in this client. DeModal, if you have it.

- [ ] The conflict notice appears **once** per session, not per event
- [ ] `/hp status` reports what heroPanel resolved — `own`, `holder` or `yield`
- [ ] In `holder` mode the tracker rides the other addon's frame and heroPanel
      moves the holder
- [ ] heroPanel's own skinning still applies whatever the mode is — yielding is
      about position, never about the skin
- [ ] The options window still writes and applies

---

## Known unverified

* **The lock button's gradient direction** (section 3). One line to flip if it
  is wrong.
* **Whether Ascension's `LibStub:NewAscensionLibrary` keeps a separate
  registry.** Ascension-flavoured Ace3 bundles use it and nothing documents
  what it does. If it does keep a separate registry, an LSM registered that way
  is invisible to `LibStub("LibSharedMedia-3.0")` and heroPanel falls back to
  its embedded copy — a shorter font list, never a missing font. Section 2's
  first check is what would show it.
* **Text metrics.** The mock measures five pixels per character, which is enough
  to tell a right-aligned count from a left-aligned one and nothing more. Any
  wrapping or clipping in the options window has to be seen.
