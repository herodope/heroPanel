<img width="329" height="304" alt="image" src="https://github.com/user-attachments/assets/e17b4b41-3845-4603-88bc-a64e604f21cb" />

<img width="342" height="354" alt="image" src="https://github.com/user-attachments/assets/eea43c1b-520d-4c0f-b694-12e00a1a8aa1" />

<img width="411" height="194" alt="image" src="https://github.com/user-attachments/assets/a0612495-78ca-41ef-96c5-5af8192a1cd2" />

<img width="412" height="209" alt="image" src="https://github.com/user-attachments/assets/84d9bc42-26ec-48e8-82d4-be6dff042e9e" />

<img width="451" height="681" alt="image" src="https://github.com/user-attachments/assets/f6a888a5-b880-47dc-b8d3-a0e615d8ed2c" />

<img width="448" height="686" alt="image" src="https://github.com/user-attachments/assets/ff5704c8-9c35-424f-a19f-4d8793102916" />





# heroPanel

A clean, movable, configurable skin for your objective trackers on
**Ascension WoW · Conquest of Azeroth** (3.3.5a / WotLK client).

heroPanel gives the quest tracker, the Mythic+ tracker and the dungeon
tracker a proper panel, a readable header, better fonts and colours, and lets
you drag them anywhere on screen and lock them there. It also ships an optional **Mythic+ boon bar**, so
the Mythical Boons in your bags are one click or one keypress away instead of
buried in an inventory slot mid-run. Everything is configured in an in-game
options window, and changes apply immediately — no reloading to see what a
setting did.

> **Pre-release (0.2.4).** Feature complete and playable, but still being
> tested. Your settings carry across updates — see
> [Updating](#updating).

---

## Requirements

* The Ascension **Conquest of Azeroth** client (3.3.5a).
* Nothing else. The libraries heroPanel needs are bundled with it, so there is
  no separate download to hunt down.

The Mythic+ panel needs Ascension's own `Ascension_MythicPlus` addon, which the
server delivers to you automatically. If it isn't there, heroPanel just skins
the quest tracker and says nothing about it. The dungeon panel needs nothing
extra — that tracker is part of the client.

## Installation

1. Download this repository as a ZIP (**Code → Download ZIP**) and unzip it.
2. Copy the inner **`heroPanel`** folder into your WoW folder's
   `Interface\AddOns` directory.
3. Check you ended up with this file:
   `Interface\AddOns\heroPanel\heroPanel.toc`
   — if you have `Interface\AddOns\heroPanel\heroPanel\heroPanel.toc`, you
   copied one folder too many. Move the inner one up a level.
4. Restart the game, or type `/reload` if you're already logged in.

heroPanel enables itself, so there's nothing to tick on the character screen.

## Using it

Type **`/hp`** (or `/heropanel`) to open the options window. It's also under
**Interface → AddOns → heroPanel**.

**To move a tracker:** click **Unlock** in the options window (or type
`/hp unlock`), then drag the panel by its **header row** — the strip with
`QUESTS` and the padlock in it — with your left mouse button. Drag the little
grip in its bottom-right corner to resize it. Click **Lock** when you're happy —
that hides the grips and stops you nudging things by accident.

The header is the only part of the quest panel that takes a click. The rest of
it is click-through: you can right-click through it to swing the camera and
left-click an NPC standing behind it, whether the tracker is collapsed or
expanded. The exceptions are the ones you'd want — the padlock, the collapse
arrow, the resize grip, and the game's own quest titles, which still open the
quest log on a left-click and offer share/untrack on a right-click.

**To change how it looks:** everything is in the options window, in four
groups:

* **Global** — the font, and the options window's own size and background.
* **Quest tracker** — panel colour and transparency, border, three text sizes,
  text shadow, and the switches that decide where the tracker goes during a
  fight or a key.
* **Mythic+ and dungeon trackers** — the same panel controls again, its own
  three text sizes, and the colours it uses for objective states. One group for
  two panels, because the dungeon panel *is* the Mythic+ panel with the
  keystone taken out of it: whatever you set here it draws with, so the two can
  never end up looking like different addons. What it keeps of its own is a
  position and a switch.
* **Boons** — the Mythic+ boon bar, which is off until you turn it on.

**Click a group heading to fold it away**, and click it again to bring it back.
The arrow at the right of the heading says which way it is. The window shrinks
to fit whatever is left open, and remembers what you folded — so if you only ever
touch two of the four groups, the other two need not be in your way.

Each tracker is styled separately on purpose: the Mythic+ panel is a block of
numbers that usually wants something solid behind it, while the quest tracker is
a list you may want nearly see-through over the world.

One control isn't finished yet: **Backdrop texture** only offers Flat. The other
three options are greyed out and say why when you hover them — heroPanel doesn't
ship that artwork yet.

## What you get

**On the quest tracker** — a panel behind it, a header row with a lock button, a
`QUESTS` label, a count of your tracked quests and a collapse arrow. Quest names
in gold, objectives in plain text with the counter picked out brighter, finished
objectives in green with a tick. Objective counts are pulled out of the sentence
and right-aligned against the panel edge. The quest you're hovering gets a
subtle highlight, and the turn-in "?" and quest arrow are tucked in beside the
quest they belong to instead of hanging off the left edge.

**On the Mythic+ tracker** — the same panel, with the dungeon name and keystone
level in the header, a large timer, the chest/threshold bar, the enemy forces
meter and the boss rows.

**On the dungeon tracker** — Normal, Heroic and Mythic 0, the panel Ascension
draws when you zone into a dungeon through the group finder. The same panel
again with everything keystone-shaped removed: no timer, no thresholds, no
affixes, no enemy forces. The header carries the dungeon and how hard it is —
`Mara (Mythic)` — where the Mythic+ header carries the dungeon and the key
level, and the objectives sit under it with the same tick and the same colours
the Mythic+ boss rows use.

Ascension's own version of that panel says `Dungeon` at the top whatever
difficulty you are in, so a Normal, a Heroic and a Mythic 0 all look the same.
heroPanel's says which.

**Placing the Mythic+ panel without being in a key.** That panel only exists
during a keystone run, so normally the first chance you get to see where you put
it is thirty seconds into a timed pull. Turn on *Show panel for placement* in the
Mythic+ tracker group — or type `/hp mplus preview` — and it draws itself over
sample data anywhere in the world. Drag it where you want it and it saves exactly
as an ordinary drag does.

It turns itself off the moment a real keystone starts, and it doesn't survive a
`/reload`, so it can't be left on by accident. The affix row is the one thing it
can't show you: those are real icons off the client's own affix table, and
inventing them would draw art that doesn't match what you'll get in a key.

The dungeon panel has the same switch for the same reason — *Show dungeon panel
for placement*, or `/hp dungeon preview` — since that tracker is only on screen
inside a dungeon. The two panels are placed separately, because they are two
frames and only one of them is ever up at a time.

**Text you can read over anything.** Turn the panel down to nearly transparent
and the header still reads over snow or open sky. There's an optional text
shadow (1–3 px) if you want more.

## Mythic+ boon bar

Mythic keystone dungeons have Boon Crystals. Clicking one hands everybody nearby
a random **Mythical Boon**, which is a consumable that buffs the whole party for
about thirty seconds. They share a cooldown, they rot out of your bags after ten
minutes,
and the only way to see what you are holding is to open your bags — in the
middle of a timed run.

The boon bar is a row of icons, one per boon. Ones you are carrying are in full
colour with a stack count and can be clicked; ones you are not are greyed out
but still show you what they do. There is a cooldown sweep, and using any boon
greys the rest, because they share the cooldown.

It is **off by default**, since it only means anything inside a key. Turn it on
with *Boon bar* in the Boons group, or `/hp boons on`.

Worth knowing:

* By default it only appears in a Mythic dungeon. Turn *Only in Mythic
  dungeons* off to place it.
* **Labels** — turn on *Boon labels* and each icon gets a word saying what the
  boon *does*: Dmg, Crit, Haste, DR, AP/SP. Not the boon's name — "Ascension"
  and "Bountiful" tell you nothing about which one to press. *Label position*
  puts them above or below the icons. Off by default, because once you know the
  bar you aim at a position rather than read it; on, for the runs before that.
* **Two rows instead of one** — nineteen icons in a line is a lot of screen.
  Turn on *Split into rows* and the bar wraps; *Icons per row* is where it
  breaks, 8 by default, which puts the fifteen boons into two rows. Set it
  shorter for a tighter grid.
* **One key for everything** — bind *Cycle boons* under **Key Bindings →
  heroPanel** and each press fires the next boon you are holding, left to right
  along the bar and round again. A small accent bar under an icon shows which
  one is next. This is the binding most people want.
* **Or five direct keys** — *Boon slot 1-5*, in the same place, still there
  alongside it. A slot is a position on the bar; turn on *Line boons up in slots
  1-5* and the boons you are actually carrying move to the front, so a bound key
  always fires one. The key you bound is drawn in the corner of the icon.
* It can hang under the Mythic+ panel instead of sitting where you drag it —
  *Anchor under Mythic+ panel*. Anchored, it pins to the panel's bottom-left
  corner and draws only the boons you are holding, packed left, so the first
  icon is always in the same place and the nth icon is the nth slot.
* **Expiry glow** — boons rot in your bags, and that is the number that decides
  whether to use one now or hold it. Set *Expiry glow* to 30s, 1 min or 2 min
  and an icon that is about to go grows an orbit of sparks, faster and brighter
  the closer it gets. The time is read off the item's own `Duration:` line.
* **Shift-click to ask, not to use** — turn on *Shift-click reports remaining
  duration* and holding shift while you left-click a boon puts how long that
  boon has left in party chat instead of using it. Your keybinds are unaffected,
  including shift-modified ones.
* Hovering a boon out of combat shows its real item tooltip, with the expiry.
  In combat you get a one-line summary instead, so you are not reading a wall of
  text mid-pull.

One limitation to know about: the game will not let an addon point a button at a
bag slot while you are in combat. So a boon looted mid-fight lights up on the
bar straight away, but does not become clickable until the fight ends. Nothing
is lost — it is there waiting.

The cycle key is the exception. It is bound to a hidden button that chooses its
boon inside the game's own restricted environment, which is the one place an
addon may change what a button will use during a fight — so it keeps advancing
through the boons you were holding when the pull started, while every other key
on the bar is frozen. `/hp boons` says which of the two paths your client got.

`/hp boons` on its own reports what it found: which boons are in your bags and
how long each has left, which key fires which slot, what the cycle key would
fire next, and whether the bar thinks it is in a key.

`/hp boons expiry` is the one to run if the glow fires at the wrong time. There
is no API for an item's remaining lifetime, so heroPanel reads the `Duration:`
line off the item's tooltip — coarse above a minute, exact below one — and runs
a smooth clock between readings, correcting it as the reading ticks over. This
prints the tooltip lines and what it made of each.

## Party key checks

Someone types **`?keys`** in party, raid or instance chat, and heroPanel links
your keystone straight from your bags — you don't have to open anything.

It answers to eight spellings, so it works whichever one your group has settled
on:

```
!keys  ?keys  #keys  $keys
!key   ?key   #key   $key
```

The reply is a normal item link, so everyone in the group can see it whether or
not they run heroPanel. If you have no keystone, it says so rather than staying
silent. It answers at most once every five seconds so it can't spam the group
under your name.

This is **on by default**. Turn it off with the *Answer party key checks* switch
at the bottom of the Mythic+ group, or `/hp keys off`. Type `/hp keys` on its
own to post your key right now.

## Getting the quest tracker out of the way

Three optional switches in the Quest tracker group, all off by default:

* **Hide in combat** — the quest tracker goes away when you pull and comes back
  when the fight ends.
* **Hide in Mythic+** — the quest tracker stays out of the way for the length of
  a key run.
* **Anchor under Mythic+ panel** — instead of hiding it, the quest tracker moves
  under the Mythic+ panel for the run and goes back where you put it when the
  key ends. Use this one if you still want to read your objectives in there. If
  the boon bar is anchored under that panel too, the tracker goes below the bar
  rather than on top of it.

The last two are alternatives, so turning one on turns the other off. While the
tracker is anchored you cannot drag it — it is following the Mythic+ panel, so
there is nowhere for a drag to put it; heroPanel says so if you try.

One thing to know about the combat one: while you're actually in a fight, the
game won't let an addon fully remove the tracker, so it becomes invisible but
its area can still catch mouse clicks until combat ends. The Mythic+ one has no
such limit — that region is properly click-through for the whole run.

There is one more switch in the same group, **Header on mouseover**, which is
smaller in scope: the header row — `QUESTS`, the count, the lock and the collapse
arrow — is only drawn while the cursor is over the panel. The row keeps its
height, so your quest lines stay exactly where they are. It is ignored while the
trackers are unlocked, because the header is also what you drag the panel by and
you cannot drag what you cannot see; heroPanel says so in chat when it happens,
and the setting comes back the moment you lock them again.

## Fonts

heroPanel reads its font list from **LibSharedMedia**, which is bundled. Out of
the box you get the client's own Friz Quadrata; install any font pack that
registers with LibSharedMedia — SharedMediaAdditionalFonts, SharedMedia_Causese,
ElvUI, and others — and its fonts appear in heroPanel's dropdown automatically.
Each row in the dropdown is drawn in its own font so you can see what you're
picking.

Font sizes are set per role — the header row, quest names, and body text are
three separate sizes — so you can make quest names easy to scan without the
descriptions filling the panel.

## Alongside other addons

Other addons — **ElvUI** and **DeModal** among them — also want to position the
tracker frames. heroPanel notices and adapts rather than fighting them: if
another addon has docked the tracker somewhere, heroPanel moves that dock
instead of the tracker, and if the frame is clearly owned by someone else it
stops positioning it and only styles it.

This is automatic. If you want to force it, `/hp mode <auto|own|holder|yield>`,
and `/hp status` will tell you what it settled on.

Three addons take the tracker in a way that does not degrade gracefully — you
get a mover that snaps back or does nothing at all, with nothing on screen to
say why. Each of those has one setting of its own that hands the tracker back,
and heroPanel offers to change **that one setting**, once, in a dialog you can
say no to:

| Addon | The setting | Where you'd find it yourself |
|---|---|---|
| **DeModal** | Disable Objectives Features | Escape → Interface → AddOns → DeModal |
| **MoveAnything** | Reset the `WatchFrame` entry | `/ma` — its own window, not the Blizzard panel |
| **Leatrix Plus** | Manage Quest Tracker | `/ltp` → Frames |

Nothing else those addons do is touched, the change is made through their own
control rather than by editing their settings behind their back, and saying no
just prints the manual steps. heroPanel never disables another addon for you.

## Commands

Everything below is also in the options window, except where noted.

| Command | What it does |
|---|---|
| `/hp` | Open the options window |
| `/hp help` | List the commands |
| `/hp lock` / `/hp unlock` | Lock or unlock every tracker for dragging |
| `/hp scale <watch\|mplus\|dungeon> <0.5-1.5>` | Set a tracker's scale |
| `/hp reset [watch\|mplus\|dungeon\|boons]` | Clear saved position and scale |
| `/hp font <8-30>` | Set every text size at once |
| `/hp fontface <name>` | Pick a font by name |
| `/hp keys [on\|off]` | Answer `?keys` in group chat — no argument posts your key now |
| `/hp boons [on\|off\|reset\|expiry]` | The Mythic+ boon bar — no argument reports what it found; `expiry` dumps the tooltip lines the glow reads |
| `/hp mplus [preview]` | Report what the Mythic+ panel resolved — `preview` draws it outside a key so you can place it |
| `/hp dungeon [preview]` | The same for the dungeon panel — Normal, Heroic and Mythic 0 |
| `/hp mode <auto\|own\|holder\|yield>` | Who positions the trackers |
| `/hp skin [on\|off]` | Style the trackers, or hand them back to the game |
| `/hp status` | Report what heroPanel found and hooked |
| `/hp store` | Report what this login did to your saved settings |

## If something looks wrong

**`/hp skin off`** is the escape hatch. It puts every tracker back exactly the
way the game and Ascension's own addons had them — fonts, colours, header and
all. `/hp skin on` brings heroPanel back. Nothing is lost either way.

**`/hp reset`** clears saved positions and scales if a tracker has ended up
somewhere you can't reach.

If you want to report a problem, `/hp status` output is the most useful thing to
include, along with which other UI addons you run.

## Updating

Copy the new `heroPanel` folder over the old one and `/reload`.

**Your settings carry across.** heroPanel checks the saved settings against the
build it is running: everything that still means something is kept exactly as
you set it, and only a setting whose shape genuinely changed goes back to its
default. If any did, it says so once in chat — `/hp store` then lists which, so
you know what to set again rather than having to hunt for it.

Downgrading is safe too. An older build will not rewrite settings written by a
newer one; it uses the parts it understands, leaves the rest alone, and says so.

## Licence

heroPanel is released under the **GNU General Public License v3** — see
[LICENSE](LICENSE).

The bundled libraries keep their own licences; see
[heroPanel/libs/README.md](heroPanel/libs/README.md) for versions and terms.
