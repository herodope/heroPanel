Pre-release. Feature complete and playable, still being tested. Your settings
carry across updates.

## Install

Download **`heroPanel-0.2.5.zip`** below — the file under *Assets*, not the
*Source code* ones under it. Unzip it, and drop the single `heroPanel` folder
into `Interface\AddOns`. You should end up with
`Interface\AddOns\heroPanel\heroPanel.toc`.

Use this ZIP rather than **Code → Download ZIP** on the repo page: GitHub names
the folder in that one `heroPanel-main`, and WoW will not load an addon whose
folder name does not match its `.toc`.

## New in 0.2.5 — the boon bar speaks

Two switches in the **Boons** group that put a line in party chat on their own.
Both are **off by default**, both are silent when you are not in a group, and
both only speak while the boon bar is on screen — so with *Only in Mythic
dungeons* left on, they speak during a key and nowhere else.

* **Announce boons you pick up** — names each boon in party chat as it lands in
  your bags. Two boons out of one crystal are one line, not two. A `/reload`
  mid-key announces nothing, because a reload is not a pickup.
* **Announce boons about to expire** — the expiry glow, said out loud. **Call
  at** picks the thresholds: 30s, 1 min, 2 min, or any combination of the
  three, so you can have a two-minute heads-up and a thirty-second last call.
  Each threshold is called once per boon. Switching it on partway through a
  boon's life gives you one line at the tightest threshold already passed,
  rather than three at once.

`/hp boons` now reports both switches, which thresholds are ticked, and which
channel would hear them — or that you are not in a group.

The existing *Shift-click reports remaining duration* is unchanged, and the
expiry glow is unchanged; the two new switches are separate from both, so you
can have either, both or neither.

## Fixes in this build

* **"Hide in combat" now actually hides the tracker during the fight.** It used
  to fade it to nothing and wait for the fight to end before hiding it, so a
  pull was spent with an invisible tracker still swallowing clicks meant for
  whatever was behind it. Both halves land immediately now. The same goes the
  other way: a key that ends mid-fight gives the tracker back there and then.
* **Quest markers stop drifting off their titles.** The turn-in question mark
  and the super-track arrow are re-anchored to the end of the quest name on
  every pass. The client re-anchors them as well, without clearing first, so a
  marker ends up carrying two anchors at once and reporting the span between
  them as its size - a 15px icon measuring 127. heroPanel sized the placement
  off that measurement, decided the marker was too big to be an icon and left
  it alone, and nothing else re-anchors these - so one stretched marker sat
  adrift of its quest name for the rest of the session. The size now comes from
  what the marker declares itself to be, which is right either way, and a
  marker heroPanel cannot place goes back on the client's own anchor instead of
  staying frozen on heroPanel's. Markers that draw nothing no longer hold a
  place on the row.
* **The three panels stop rewriting a scale that has not changed.** Each one
  re-asserted its scale from the tracker on every redraw - every timer, trash
  and encounter update - for a number that had not moved since login.
* **The boon bar stops asking the client for things it will not do in combat.**
  A pull on a CoA realm produced a run of "Interface action failed because of
  an AddOn" errors: sixty-four refused calls at a single combat login, none of
  which needed to be made at all.

  Three separate passes were writing values that had not changed. The bar
  rewrote its own width and height on every refresh - the same two numbers,
  while you were carrying no boons at all. Every button had its mouse switched
  on again and its click area rewritten on every restyle, fifteen buttons at a
  time, on a pass that a *font* change triggered. None of it altered anything
  on screen, and all of it is refused while you are in combat, which is what
  turned a redundant call into an error message.

  All three now read the current value first and write only when it has really
  moved. Two things heroPanel believed about this client turned out to be
  wrong and are fixed with it: the bar's own size is protected in combat
  (every button on it is a secure frame), and so is a button's click area -
  which had been relied on as the one thing that could still be changed
  mid-fight. Where the client really does refuse, heroPanel now finds out
  once, stops asking, and waits for the fight to end.

  The one thing given up: a boon looted mid-fight that was hidden by *Hide
  when you have none* is drawn immediately, as before, but does not take a
  tooltip until the fight ends. It could never be *used* mid-fight regardless,
  because the bag slot behind it cannot be bound under lockdown.
* **Refused calls are reported with a file and a line.** `/hp status` used to
  fold every refusal the client would not name into one `UNKNOWN()` row, which
  said how many had happened and nothing about where. The client sends the
  word "UNKNOWN" itself for most of them, so they are now identified by the
  heroPanel line nearest the refusal instead - `UNKNOWN() at Boons.lua:1840`.
  Two refusals from two places take two rows.

  New: **`/hp blocked`** prints every refused call with its whole stack, one
  line per frame. `/hp status` prints one frame, which is rarely the useful
  one; this is the command to run when something needs reporting.

## Also in this release

Everything from 0.2.4, which had no release of its own — the boon bar fixes
(the bar hiding itself inside a key, the two bag events a looted boon most
often arrives on, and the in-combat reveal landing outside the bar), the
dungeon panel from 0.2.3, and the store that carries your settings across an
update value by value.
