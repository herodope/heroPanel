<img width="329" height="304" alt="image" src="https://github.com/user-attachments/assets/e17b4b41-3845-4603-88bc-a64e604f21cb" />

<img width="342" height="354" alt="image" src="https://github.com/user-attachments/assets/eea43c1b-520d-4c0f-b694-12e00a1a8aa1" />

<img width="411" height="194" alt="image" src="https://github.com/user-attachments/assets/a0612495-78ca-41ef-96c5-5af8192a1cd2" />

<img width="412" height="209" alt="image" src="https://github.com/user-attachments/assets/84d9bc42-26ec-48e8-82d4-be6dff042e9e" />

<img width="451" height="681" alt="image" src="https://github.com/user-attachments/assets/f6a888a5-b880-47dc-b8d3-a0e615d8ed2c" />

<img width="448" height="686" alt="image" src="https://github.com/user-attachments/assets/ff5704c8-9c35-424f-a19f-4d8793102916" />





# heroPanel

A clean, movable, configurable skin for your objective trackers on
**Ascension WoW · Conquest of Azeroth** (3.3.5a / WotLK client).

heroPanel gives the quest tracker and the Mythic+ tracker a proper panel, a
readable header, better fonts and colours, and lets you drag them anywhere on
screen and lock them there. It also ships an optional **Mythic+ boon bar**, so
the Mythical Boons in your bags are one click or one keypress away instead of
buried in an inventory slot mid-run. Everything is configured in an in-game
options window, and changes apply immediately — no reloading to see what a
setting did.

> **Pre-release (0.2.1).** Feature complete and playable, but still being
> tested. Your settings carry across updates — see
> [Updating](#updating).

---

## Requirements

* The Ascension **Conquest of Azeroth** client (3.3.5a).
* Nothing else. The libraries heroPanel needs are bundled with it, so there is
  no separate download to hunt down.

The Mythic+ panel needs Ascension's own `Ascension_MythicPlus` addon, which the
server delivers to you automatically. If it isn't there, heroPanel just skins
the quest tracker and says nothing about it.

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
`/hp unlock`), then drag the tracker with your left mouse button. Drag the
little grip in its bottom-right corner to resize it. Click **Lock** when you're
happy — that hides the grips and stops you nudging things by accident.

**To change how it looks:** everything is in the options window, in four
groups:

* **Global** — the font, and the options window's own size and background.
* **Quest tracker** — panel colour and transparency, border, three text sizes,
  text shadow, and the auto-hide switches.
* **Mythic+ tracker** — the same panel controls again, its own three text
  sizes, and the colours it uses for objective states.
* **Boons** — the Mythic+ boon bar, which is off until you turn it on.

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

**Text you can read over anything.** Turn the panel down to nearly transparent
and the header still reads over snow or open sky. There's an optional text
shadow (1–3 px) if you want more.

## Mythic+ boon bar

Mythic keystone dungeons have Boon Crystals. Clicking one hands everybody nearby
a random **Mythical Boon**, which is a consumable that buffs the whole party for
about thirty seconds. They share a cooldown, they expire after a few minutes,
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
* **Keybinds** are five slots under **Key Bindings → heroPanel**. A slot is a
  position on the bar; turn on *Line boons up in slots 1-5* and the boons you
  are actually carrying move to the front, so a bound key always fires one. The
  key you bound is drawn in the corner of the icon.
* It can hang under the Mythic+ panel instead of sitting where you drag it —
  *Anchor under Mythic+ panel*.
* Two boons only help melee. *Mark melee-only boons* puts a gold border on them.
* Hovering a boon out of combat shows its real item tooltip, with the expiry.
  In combat you get a one-line summary instead, so you are not reading a wall of
  text mid-pull.

One limitation to know about: the game will not let an addon point a button at a
bag slot while you are in combat. So a boon looted mid-fight lights up on the
bar straight away, but does not become clickable until the fight ends. Nothing
is lost — it is there waiting.

`/hp boons` on its own reports what it found: which boons are in your bags,
which key fires which slot, and whether the bar thinks it is in a key.

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

## Auto-hide

Two optional switches in the Quest tracker group, both off by default:

* **Hide in combat** — the quest tracker goes away when you pull and comes back
  when the fight ends.
* **Hide during Mythic+** — the quest tracker stays out of the way for the
  length of a key run.

One thing to know about the combat one: while you're actually in a fight, the
game won't let an addon fully remove the tracker, so it becomes invisible but
its area can still catch mouse clicks until combat ends. The Mythic+ one has no
such limit — that region is properly click-through for the whole run.

There is a third switch in the same group, **Header on mouseover**, which is
smaller in scope: the header row — `QUESTS`, the count, the lock and the collapse
arrow — is only drawn while the cursor is over the panel. The row keeps its
height, so your quest lines stay exactly where they are.

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
and `/hp status` will tell you what it settled on. heroPanel never disables
another addon for you, and never touches another addon's settings.

## Commands

Everything below is also in the options window, except where noted.

| Command | What it does |
|---|---|
| `/hp` | Open the options window |
| `/hp help` | List the commands |
| `/hp lock` / `/hp unlock` | Lock or unlock both trackers for dragging |
| `/hp scale <watch\|mplus> <0.5-1.5>` | Set a tracker's scale |
| `/hp reset [watch\|mplus\|boons]` | Clear saved position and scale |
| `/hp font <8-30>` | Set every text size at once |
| `/hp fontface <name>` | Pick a font by name |
| `/hp keys [on\|off]` | Answer `?keys` in group chat — no argument posts your key now |
| `/hp boons [on\|off\|reset]` | The Mythic+ boon bar — no argument reports what it found |
| `/hp mode <auto\|own\|holder\|yield>` | Who positions the trackers |
| `/hp skin [on\|off]` | Style the trackers, or hand them back to the game |
| `/hp status` | Report what heroPanel found and hooked |
| `/hp store` | Report what this login did to your saved settings |

## If something looks wrong

**`/hp skin off`** is the escape hatch. It puts both trackers back exactly the
way the game and Ascension's own addon had them — fonts, colours, header and
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
