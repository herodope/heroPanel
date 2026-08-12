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

## Where the last pass got to

Sections 1, 3, 4, 5 and 6 were run in-game and passed, including the one item
that was written down here as unverified — **the lock button's gradient does run
light at the top to dark at the bottom**, so `PaintLockGradient` is correct as
written and there is nothing to swap.

Section 2 passed on the part that mattered: the font dropdown lists the full
shared-media library, so LibSharedMedia is being shared with the font packs
rather than heroPanel falling back to its embedded copy. The one wrinkle is that
`/hp fontface` and the dropdown can disagree about the current face; the slash
command is on its way out and the options window is meant to be the only way to
pick a face, so it is not being fixed.

Two things did come out of that pass and both are done:

* **The font size controls barely moved the quest text.** `Lines.lua` clamped
  every quest line to two points over the size the tracker had laid it out at,
  which on this client is 12 — so everything from 14 upwards drew identically.
  The header and the objective counts are heroPanel's own FontStrings and were
  never clamped, which is why they kept growing while the names and descriptions
  did not. The clamp is gone.
* **The scale sliders are gone.** Both panels carry a resize grip in their
  bottom-right corner instead, shown only while the trackers are unlocked.

The sections below are rewritten for that, so everything is unchecked again
where the control itself changed.

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
- [ ] **Global**: font family **Friz Quadrata TT**, options font size **16 px**,
      options background the first swatch, backdrop **Flat**
- [ ] **Quest tracker**: background opacity **100%**, border style **Hairline**,
      header **16 px**, quest name **14 px**, description **12 px**
- [ ] **Mythic+ tracker**: the same chrome values, header **13 px**, timer
      **24 px**, body **12 px**
- [ ] **Text shadow off** and thickness **1 px** on both panels
- [ ] **Hide in combat** and **Hide in Mythic+** both off
- [ ] **No corner radius control anywhere**, and both panels are square-cornered
- [ ] **No Transparent swatch** on either border colour row
- [ ] Pill reads **ENABLED**
- [ ] Log out and back in: the store is written and everything comes back

## 1b. A store from an older build is discarded

heroPanel is pre-release. Its store has changed shape four times already and
will change again, and nobody is running a build old enough for an old store to
be worth carrying forward — so a store stamped with anything other than this
build's `dbVersion` is **thrown away**, not migrated.

That is a deliberate trade and it only holds until release. There was a
migration chain here and it was the right code for a released addon: every shape
change knew how to re-say itself in the next shape. It was the wrong code to
keep for one that is not released, because each step had to go on working and
being tested forever, to protect settings that take a minute to set again.

What has to be true is that the rule is **narrow**. It should fire on a
mismatch, stay quiet on a fresh install, never touch a current store, and never
take the geometry with it.

With a SavedVariables file written by an earlier build:

- [ ] Colours, fonts and toggles come up at **the defaults**, not at what the
      old store said
- [ ] **Your tracker positions, tracker sizes and options window placement
      survive.** Those are exempt: dragging three panels into place and sizing
      them is the only part of configuring this addon that costs real effort,
      and the geometry keys have never changed shape while the colour and font
      blocks have changed four times between them
- [ ] The lock state survives too — it lives in the same block
- [ ] A chat line says the settings were written by an older build and have been
      reset, naming the version it found, **and says the frame positions were
      kept**. Throwing settings away is not something to do silently, and nor is
      keeping some of it
- [ ] `/reload` and the message does **not** come back — the new store is
      stamped, so it is discarded once and not on every login
- [ ] No Lua error on the way through

Exempting the geometry is not trusting it blindly. Tracker positions carry their
own stamp — `GEOMETRY_VERSION` in `Move.lua` — and a position written in an
older shape is dropped by that, independently of any of this.

- [ ] Hand-edit `["v"] = 1` into a saved tracker position and log in: that
      tracker returns to where the game wants it, while the rest of the store is
      untouched

On a genuinely fresh install (no SavedVariables at all):

- [ ] Everything comes up at the defaults, and **no** reset message appears.
      A first login has no stamp either, and warning someone that their
      nonexistent settings were reset is worse than saying nothing

And the case that runs every normal login, which a too-eager rule would quietly
destroy:

- [ ] Change some settings, `/reload`. **They survive.** A store stamped for
      this build is left exactly alone
- [ ] Change a setting, log out fully, log back in. Still there

## 2. Fonts

- [x] Font dropdown lists more than the eleven faces LibSharedMedia ships with
      — SharedMediaAdditionalFonts and SharedMedia_Causese are both installed,
      so a short list means heroPanel is using its own embedded copy instead of
      theirs and the two are not sharing a LibStub
- [ ] Each row is drawn in its own face, not all in one
- [x] Opening the dropdown does not error
- [ ] Picking a face changes the text on **both** trackers immediately, with no
      reload
- [ ] It also changes the options window's own labels
- [ ] The choice survives `/reload`
- [ ] The dropdown list is **not clipped** by the scrolling body — it is
      parented to the window rather than to the scroll child for exactly this
      reason, and a list showing four of its ten rows means that came undone
- [ ] Scroll the body with the list open: the list follows its button
- [ ] No FontString anywhere goes blank — a blank line means a path resolved and
      the client then refused to draw it, which is what `Media.IsUsableFont`
      exists to prevent

`/hp fontface <name>` still works and still disagrees with the dropdown's idea
of the current face. Known, and not worth fixing: the command is being removed.

## 3. Options window

- [x] Opens from `/hp`, closes from `/hp` again, from **Save & close**, and from
      Escape
- [x] Opens from Interface → AddOns → heroPanel, both by selecting the category
      and by its button
- [x] **Does not overlap either tracker**
- [x] Dragging it by the header moves it, and the position survives `/reload`
- [x] The lock button's gradient runs light at the top to dark at the bottom
- [x] The toggle knobs are visible and sit at the right end when on, left when
      off
- [x] Every label is legible against the accent-tinted enable row

New, because the body scrolls now:

- [ ] The window is **440 × 660** and fits on screen. Check again at a UI scale
      a couple of notches up — UIParent is 768 units tall at the default scale
      and *shorter* than that above it, which is the case the old fixed-height
      window did not survive
- [ ] The header, the **enable** rows and the footer stay put while the body
      scrolls under them. The enable row is deliberately outside the scroll: it
      is the escape hatch and must never need scrolling to
- [ ] Mouse wheel scrolls the body, and stops at both ends rather than running
      past them
- [ ] The scrollbar on the right can be dragged, and its thumb is roughly
      proportional to how much of the body is on screen
- [ ] Three groups, in order: **GLOBAL**, **QUEST TRACKER**, **MYTHIC+ TRACKER**,
      each of the last two under a visible rule
- [ ] The group headings are **larger than the rows under them and in the
      accent**, so a heading is something you notice rather than something you
      scroll past. They were set smaller and greyer than the body text, which is
      the wrong way round when the two lower groups carry the same six control
      labels as each other
- [ ] The header reads **heroPanel** over **M+ and Objective tracker skin ·
      v0.1.0**

New, because the one enable switch became two:

- [ ] The fixed block under the header carries **Objective panel skin** and
      **M+ panel skin**, each with its own toggle, and both are fully inside the
      accent-tinted row rather than running off its bottom edge
- [ ] Turning **M+ panel skin** off gives Ascension's own Mythic+ tracker back and
      **leaves the quest tracker skinned**, and the other way round. That is the
      whole reason the flag was split: comparing one panel against the addon it
      is drawn over used to mean losing the other one too
- [ ] The status pill reads **ENABLED** with both on, **PARTIAL** with one, and
      **DISABLED** with neither
- [ ] `/hp skin off` still turns **both** off, and `/hp skin on` both on — it is
      the escape hatch, and the pill and both toggles follow it live
- [ ] Under **QUEST TRACKER**, **Hide when empty** takes the whole quest panel
      off screen once nothing is being tracked — header, plate and all, with
      Blizzard's own header staying hidden rather than reappearing in its place —
      and brings it straight back the moment a quest is tracked again
- [ ] The padlock in the top-left corner is noticeably bigger, and the accent
      tile behind it is the same size it was

### 3b. The window resizes

It has the same corner grip as the two trackers, wired to its own scale.

- [ ] There is a grip in the bottom-right corner, beside the footer buttons
- [ ] It **goes away when the trackers are locked**, like theirs. It was
      always-on at first, on the reasoning that the lock governs the trackers
      and this window's header has never consulted it either — which is true and
      still read as the third panel having missed the memo. The lock button is in
      this window's own header, so the way back is one click
- [ ] Dragging it scales the whole window, text and all
- [ ] **The top-left corner stays put** across the drag
- [ ] It clamps at 50% and 150%
- [ ] Drag the window somewhere by its header at a non-default scale, close it,
      reopen: **it comes back where you left it**. The saved offsets are in
      UIParent's space and converted on the way out — a plain subtraction is
      right only at scale 1, so this is the check that catches it
- [ ] `/reload` and both the position and the scale survive
- [ ] At a large scale it is clamped to the screen rather than running off it

## 4. Live application

Each of these should be visible on the tracker **while the window is open**,
with no reload.

Global:

- [ ] Backdrop texture: Flat is selectable, the other three are greyed and
      explain themselves on hover
- [ ] **Options font size** moves this window's own text and nothing else
- [ ] **Options background** repaints this window and neither tracker. Its
      border and corner should not move — those are still design tokens, and
      only the background is a control

Then, for **each** of the two panel groups — this is the part that is new, so
run it twice and watch the *other* panel each time:

- [ ] Background colour swatches
- [ ] Background opacity slider
- [ ] Border colour swatches. There are **four, and no Transparent entry** — it
      zeroed the border alpha, which is what border style **None** already does
      one row down, and two controls reaching one outcome is a panel you have to
      check twice to know what it is obeying
- [ ] With border style **None** and background opacity at **0**, and the
      tracker **collapsed**, nothing is drawn at all — no line, no dark contour,
      and no divider under the header. This is the case the header outline
      survived before, and a collapsed tracker is where it showed up
- [ ] Border style — Hairline, then **Inset** (the line should move a pixel in
      with a dark row outside it), then None (no edge and no contour)
- [ ] **Changing one panel leaves the other alone.** This is the whole point of
      the split, and a shared table underneath would look right until you
      checked

Quest tracker text — the three sizes are separate on purpose:

- [ ] **Header font size** moves the QUESTS row and its count, and nothing else
- [ ] **Quest name font size** moves the quest names, and nothing else
- [ ] **Description font size** moves the objective lines *and* the right-aligned
      counts, which belong to the objective they annotate
- [ ] Drag any of them from 16 to 20 to 30. **The text keeps growing the whole
      way.** This is the fix — it used to stop dead at 14
- [ ] At a large size the lines crowd each other, because the tracker measured
      and placed them before heroPanel saw them. That is expected: resize the
      panel with its grip rather than expecting the skin to re-lay-out lines

Text shadow — one toggle and one thickness per panel, and the case it exists
for is a panel turned transparent over bright terrain:

- [ ] **Off by default** on both panels
- [ ] Turning it on darkens behind **every** string in that panel — the quest
      names, the descriptions and the right-aligned counts, not just the header
- [ ] **Thickness 1, 2, 3** are visibly different. A FontString has one offset
      copy rather than the four-way surround the glyphs use, so 1 reads as a
      soft drop shadow and 3 closes up into something like an outline
- [ ] The two panels are independent — turning it on for one does nothing to
      the other
- [ ] The header's **QUESTS** row and its count keep their shadow whatever the
      toggle says. Those are forced on: the header band is the part of the panel
      most often over open sky
- [ ] `/hp skin off` hands the tracker back with **no** shadow on its lines

Mythic+ text — split three ways, same as the quest tracker:

- [ ] **Header font size** moves the dungeon name and the keystone level, and
      keeps the keystone a point under the name at every size
- [ ] **Timer font size** moves the clock and nothing else. This is the one that
      earns its own control: the clock is deliberately about twice everything
      around it, so a single size for the panel meant enlarging the boss rows
      gave the timer a third of the panel
- [ ] **Body font size** moves the chest tiers, enemy forces and the boss rows,
      keeping the required boss over the extra-bosses heading over the rest
- [ ] State colour swatches — each opens the client's colour picker, previews as
      you drag inside it, and Cancel puts the old colour back

## 4b. Glyph outlines and the caret's hit box

The lock and the caret are drawn in a mid grey, which is fine over the panel's
own background and stops being fine the moment that background is turned down.
A texture has no `SetShadowColor`, so an outlined glyph draws four black copies
of itself on a lower layer.

Do this with **background opacity at 0** and **border style None**, standing
somewhere bright — a snowfield or a lit desert, which is where the grey
disappeared.

- [ ] The **lock** on the quest tracker's header is legible against the terrain
- [ ] So is the **collapse caret**
- [ ] So is the **Mythic+ panel's own lock**
- [ ] Neither has picked up a visible black halo at full background opacity —
      an outline is meant to disappear into a dark panel, not sit on it
- [ ] `/hp glyphs blocks` — the outline follows the fallback route too, rather
      than only working when the shipped art loads
- [ ] `/hp glyphs auto` puts it back

The caret's click target:

- [ ] Clicking **anywhere on the chevron** collapses the tracker, including its
      thin outer arms
- [ ] It still works **after the tracker has been unlocked once** in the session.
      This is the case that was broken: an unlocked tracker keeps the mouse, so
      the header strip underneath stops receiving anything and what was left was
      whatever part of Blizzard's own button happened to sit under the glyph
- [ ] Hovering it tints the area and says **Collapse the tracker** / **Expand the
      tracker**
- [ ] The tint no longer follows the cursor across the whole header row — it
      lights the caret, which is the thing that will actually respond

## 4c. Auto-hide

Both toggles are in the **Quest tracker** group and are off by default. They
fade the tracker to nothing rather than hiding it: `WatchFrame` is protected,
`Hide` is refused under lockdown, and "hide in combat" has to work at the exact
moment lockdown begins.

- [ ] **Hide in combat** off: pulling something changes nothing
- [ ] On: the tracker **and heroPanel's panel** both vanish on the pull
- [ ] They come back the moment combat ends
- [ ] Turn in a quest or pick one up mid-fight — the tracker stays hidden. A
      refresh while auto-hidden must not put the panel back up over a tracker
      that is not there
- [ ] `/hp skin off` **mid-fight** hands back a visible tracker rather than
      leaving a faded one behind
- [ ] **Hide in Mythic+** on: the quest tracker goes away when a key starts and
      comes back when it ends, without a reload
- [ ] Both on at once, in a key: it stays hidden through the whole run rather
      than flickering back between pulls
- [ ] Known and accepted: an invisible tracker still occupies its rectangle for
      targeting if it has been unlocked at some point in the session.
      `EnableMouse` is protected, so there is nothing to be done about it in
      combat — it is the same trade the lock already makes

## 5. Resize grips

The scale sliders are gone. Each panel has a handle in its bottom-right corner:
a triangle of dots, shown only while the trackers are unlocked.

ElvUI is loaded on this client and docks the quest tracker into
`WatchFrameHolder`, so `/hp status` reports **positioning: moving holder
WatchFrameHolder**. That is the case the old scale bug lived in: heroPanel
scaled the holder, which is a sibling of the tracker rather than its parent, so
the tracker never resized — it only slid sideways as the holder's centre moved.
Scale goes to the tracker and position keeps going to the holder.

- [ ] Locked: **no grip on either panel**
- [ ] `/hp unlock`: a grip appears in the bottom-right of both
- [ ] Hovering one highlights it and shows "Drag to resize"
- [ ] The grip takes its own click even though the unlocked tracker is
      mouse-enabled across its whole rectangle — it is raised above the tracker
      the same way the header's lock button is
- [ ] **Dragging it out resizes the quest tracker**, and does not slide it left
      or right
- [ ] heroPanel's panel behind it resizes with it, rather than staying put and
      leaving the text hanging off the edge
- [ ] The tracker's top-left corner stays put across the whole drag
- [ ] The same for the M+ tracker, which has no holder
- [ ] Release the mouse **away from the grip** — outside the panel entirely. The
      drag has to stop anyway; a release outside never reaches the grip's own
      OnMouseUp, so the button state is what ends it
- [ ] It clamps at both ends: 50% and 150%, not smaller and not larger
- [ ] `/hp lock`: both grips go away again
- [ ] Dragging the tracker itself still works and still moves the holder

`/hp scale` and the grip are the same function underneath:

1. `/hp scale watch 1.3`
2. Drag the grip a little, then `/hp status` — the reported scale should be
   near 1.3 and moving from there, not jumping back to 1.0

- [ ] Both agree

## 6. Enable / disable

- [x] The toggle off restores Blizzard's tracker completely — fonts, colours,
      header art, the tucked quest icons back outside the panel, counters back
      inside their line
- [x] The M+ panel goes too
- [x] The pill reads **DISABLED**
- [x] Back on re-skins both, no reload either direction
- [x] `/hp skin off` and `/hp skin on` do the same and the window's pill and
      toggle follow

## 7. Reset

- [ ] Change several settings, press **Reset**
- [ ] Everything returns to the defaults listed in section 1 **and is applied**,
      not merely stored
- [ ] The chat line says positions were cleared; `/reload` puts the frames back
      where the game wants them

## 7b. Header and line art

- [ ] The header reads **QUESTS**, not OBJECTIVES
- [ ] The label and the count are legible with background opacity turned down
      over a bright zone — both are brightened and carry a shadow
- [ ] The lock glyph is larger again (19px) and the caret smaller than it
      (15px). The Mythic+ panel's own padlock is 15px, up from 13
- [ ] The turn-in question mark still sits in the left margin beside its title
- [ ] The **POI arrow** sits to the *right* of its quest's name, on that quest's
      row, and does not stack with the question mark
- [ ] A quest with a long name does not push the arrow out of the panel
- [ ] `/hp skin off` puts both back where the tracker had them

## 8. Combat

With both trackers visible and quests tracked:

- [ ] Pull something. No error on entering combat
- [ ] **Unlock mid-fight and drag the tracker.** It should move straight away,
      with no "applies when you leave combat" message. Note the trade: once the
      tracker has been unlocked in a session it keeps the mouse, so you can no
      longer click through its rectangle to target something behind it
- [ ] Open `/hp` in combat and change a colour and a radius
- [ ] **Drag the quest tracker's resize grip in combat.** It says once that the
      game refuses to rescale in combat and that the new size lands on the way
      out, and then does not repeat itself for the rest of the drag
- [ ] Leave combat. The size change applies on the way out — that one is
      deferred by `ns.RunWhenSafe`, the rest are not. Both grips behave this
      way: `ns.SetScale` defers for either tracker rather than deciding which
      frames the client protects, which is a judgement it has no business making
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

### 9a. The affix row

The affixes moved out of the header's top-right corner onto their own row under
the dungeon name, and grew from 15px to 20px. Eight at 20px is 181px of a 262px
content width, so sharing the name row was never going to survive a full key
however short the dungeon name was made.

- [ ] The affixes sit **under the dungeon name**, left to right, starting on the
      same left margin as the timer glyph and the bars
- [ ] **Nothing overlaps the dungeon name**, on a key with the most affixes you
      can find
- [ ] A key with **eight** affixes still fits inside the panel on one row
- [ ] Hovering each one gives the game's own tooltip, and it goes away on leave
- [ ] The timer, bars and enemy forces moved down and **nothing collides with
      the first boss row**. On a compact tracker they move down by less than the
      row's full height — see 9e, that is the gap budget paying for it
- [ ] A key with no affixes draws **no row and no extra height** — the panel is
      exactly as tall as it was before

### 9b. Invisible affixes

The bug: an affix with no icon was still drawn as a button and still took the
mouse, so there was a hoverable hole in the header that answered with a tooltip.
`GetSpellInfo` returning an icon path is not a promise the client can draw it,
and `SetTexture` does not complain — Ascension's own creature and player affixes
are the ones that do this.

An affix whose icon does not load is now left out of the row entirely.

- [ ] The affixes on screen are exactly the ones with **visible art**. No gaps,
      no dead space in the row
- [ ] Sweep the cursor along the affix row and to the **left of the `+3` text**,
      where the ghosts used to be: no tooltip appears anywhere there is nothing
      drawn
- [ ] `/hp debug` on: an affix that was dropped says so, naming the spell ID and
      the path that failed. Compare that list against the affixes the key
      actually has — a real affix being dropped is a different bug from a ghost
      being suppressed, and this is what tells them apart
- [ ] Hover an affix and **let the key end while the cursor is still on it**.
      The tooltip goes away with the panel

Known limit: the guard asks the client whether the texture loaded. On a client
that does not report texture results — `ns.SetTextureFile` probes for this once,
and `/hp debug` prints which way it answered at boot — there is nothing to ask,
every path is taken on faith, and the ghosts would come back. This client
reports, so the guard works here.

### 9c. Short dungeon names

The header gives the dungeon name about 158px between the padlock and the affix
icons, and nothing clamps it — a long name runs underneath them. `SHORT_NAMES`
in `Mplus.lua` shortens the long ones to 20 characters or less, which is what
fits at the 13px header default.

The mock checks the table and the wiring. What it cannot check is whether the
aliases match the strings *this* client returns, because it supplies its own —
and a wrong alias fails silently, leaving the full name drawn.

- [ ] Run a key in **Blackrock Depths - Upper City** and one in **Dire Maul -
      East**. The header reads **BRD - Upper City** and **DM - East**
- [ ] `/hp mplus` reports the **full** name, not the short one. That is
      deliberate: it is how an alias that never matched gets noticed
- [ ] Run one key in a dungeon of each shape — a wing (`SM Library`), a
      gate (`Strat - Live`), a plain one (`Gnomeregan`). Any that still show
      their full name need their row's alias corrected to whatever `/hp mplus`
      printed
- [ ] With three affixes up, the name and the `(12)` clear the affix icons with
      room to spare. **Four affixes** costs about two and a half characters —
      if this client's keys ever carry four, check the longest name again
- [ ] Raise the **Mythic+ header font size** past 16px: the name starts running
      under the affixes again. Known and not fixed by the table — a character
      limit cannot follow a runtime setting, and the fix for that is a width cap
      on the name, which has not been written

### 9d. The enemy-forces animation

The bug: Ascension animates its own enemy-forces bar as trash dies — the fill
runs up and a glow runs across it. An animation writes the alpha of what it
animates for as long as it plays, so heroPanel's fade was gone for the length of
it and Ascension's glow drew across the bottom of the panel on every pull.

That row is now hidden as well as faded, and its `Show` is hooked so the
animation cannot put it back. The mock can prove the hiding and the restore; it
cannot prove the glow is on that row at all rather than on some frame
`Mplus.lua` does not name, which is what this is for.

- [ ] Pull trash and watch the **bottom edge of the panel** while the count
      climbs. No bar, no glow, no flash — nothing of Ascension's appears there
- [ ] Do it again on a **big pull**, where the count jumps several percent at
      once and the animation has furthest to run
- [ ] If anything does show through, run `/hp mplus` **while it is on screen**
      and read the stray list at the end of the dump — it names the widget and
      the frame that owns it. That is the answer to "which one is it", which a
      screenshot cannot give
- [ ] `/hp skin off` mid-run: Ascension's own enemy-forces row comes back
      **visible**, not blank, and animates again on the next pull
- [ ] `/hp skin on` again: it goes away, and the panel's own forces bar is the
      only one on screen

### 9e. The gap budget

Everything above the first boss row is heroPanel's; the row itself is
Ascension's and heroPanel does not move objective rows. So the space between
them is a fixed budget, and this client's tracker is compact enough that the
panel's block does not fit inside it once the affix row is in place — which is
how heroPanel's own enemy-forces bar came to be drawn straight through "Lord
Vyletongue".

The gaps now give when the block does not fit, in this order and no further:
forces 14→7, timer row 12→6, bar 9→5, affix row 4→2. A tracker with room keeps
every gap at its design value.

The mock proves the mechanism on its own compact tracker. What it cannot say is
whether 19px of budget is enough on *this* client, which is the whole question.

- [ ] Run a key and look at the first boss row. The forces bar **clears it** —
      no bar, no track, no percentage sitting on the name
- [ ] `/hp mplus` reports the clearance in pixels and which gaps were squeezed.
      A green number is the answer; an orange one names how far short it is
- [ ] Compare the spacing against a key with **no affixes** if you can find one:
      that one should be at the design values and read slightly looser
- [ ] `/hp debug` on: if the budget runs out the panel says so once per draw,
      naming the shortfall. If that line appears, the fix is more budget or a
      shorter header block, not more squeezing
- [ ] Raise the **Mythic+ font size**: the rows grow but the budget does not.
      Check the boss row again at the largest size you would use

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

* **Whether Ascension's `LibStub:NewAscensionLibrary` keeps a separate
  registry.** Answered in practice by the last pass — the font dropdown listed
  the full shared-media library, so heroPanel and the font packs are on the same
  LibStub and the question is moot on this client. Left here because it is a
  property of the client rather than of heroPanel, so a different Ascension
  build could still answer it the other way.
* **Text metrics.** The mock measures five pixels per character, which is enough
  to tell a right-aligned count from a left-aligned one and nothing more. Any
  wrapping or clipping in the options window has to be seen. This matters more
  now: the font sizes go to 30 and nothing clamps them, so the wrapping in
  section 4 is real behaviour rather than a thing the addon prevents.

  It is also why the Mythic+ header's name budget is enforced as a **character**
  limit rather than a pixel one. The pixel budget is real and the mock resolves
  it exactly — 158px at three affixes, 140px at four — but converting that to
  characters took measuring real faces at 13px outside the mock, which put a
  Friz-Quadrata-width font at about 7.2px per character. Twenty characters is
  that number with room left for a wider face and a fourth affix.
* **Whether the aliases in `SHORT_NAMES` match this client.** The mock supplies
  its own dungeon names, so it can only check that a name it already knows is
  shortened. Section 9c.
* **The scrollbar thumb's drag.** The harness drives the wheel, which goes
  through the same slider, but a thumb that draws in the wrong place or cannot
  be grabbed is geometry the mock does not model. Section 3.

## Resolved since the last pass

* **The lock button's gradient direction.** Runs light at the top, as written.
  `PaintLockGradient` is correct and the note about swapping its colour triples
  is gone.
* **How far the font size actually reaches a quest line.** It used to stop two
  points over whatever the tracker laid the line out at. It does not stop now.
