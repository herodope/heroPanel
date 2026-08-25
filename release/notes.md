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

## Also in this release

Everything from 0.2.4, which had no release of its own — the boon bar fixes
(the bar hiding itself inside a key, the two bag events a looted boon most
often arrives on, and the in-combat reveal landing outside the bar), the
dungeon panel from 0.2.3, and the store that carries your settings across an
update value by value.
