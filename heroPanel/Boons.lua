--[[--------------------------------------------------------------------------
    heroPanel - Boons.lua

    The Mythic+ boon bar.

    Mythic keystone dungeons on Conquest of Azeroth have Boon Crystals. Clicking
    one hands everybody in line of sight a random "Mythical Boon: X" consumable
    that buffs the whole party for about thirty seconds. They are bind-on-pickup,
    they expire out of the bags after ten minutes, they share a
    cooldown, and using one while its effect is up stacks it to a maximum of
    five. So a boon is something you are carrying, on a timer, that everybody
    benefits from - and the only way to find out what is in your bags is to open
    them, in the middle of a timed run.

    This is a bar of icons, one per boon, that says what you are holding and
    fires it with a click or a keybind.

    The client's own boon UI
    ------------------------
    There is one, at Interface\FrameXML\Ascension_MythicalBoons, and it is off:
    both files are commented out of FrameXML.toc and its show function is gated
    behind C_Realm.IsDevelopment(). Nothing to hook, so this is standalone - but
    its implementation is a free reference and this file follows it where it was
    right: bag-slot attribute binding, shared cooldown propagation, the instance
    check, and the two tooltip modes. Not its radial menu, and not its tooltip
    text - see the notes in BoonData.lua.

    Combat lockdown is the whole design
    -----------------------------------
    Using an item from a button needs SecureActionButtonTemplate, and a
    protected frame refuses SetAttribute, Show, Hide, SetPoint, SetParent,
    SetScale and EnableMouse while the player is in combat. Everything below
    follows from that:

      * The button pool is fixed and built once, at login, out of combat. It is
        never grown, reordered or reparented. Fifteen known boons plus a few
        spares for boons a later build adds - see BoonData.lua on why the set is
        expected to grow, and why the spares exist rather than creating a button
        when an unknown boon is first seen.

      * The buttons live inside a plain container frame. The container is not
        protected, so it is what carries the drag, the scale, the chrome and the
        show/hide.

      * Work is split in two. Visual work - alpha, desaturation, stack counts,
        cooldown swipes, and which cells are in the input path - is not
        protected and runs immediately, in combat or out. Secure work - binding
        a button to a bag slot, laying the bar out, installing keybinds - is
        guarded by InCombatLockdown() and deferred through ns.RunWhenSafe, which
        flushes on PLAYER_REGEN_ENABLED.

      * Which cells take clicks is therefore the hit rect's job and never
        EnableMouse's. EnableMouse is on that refused list, so a button parked
        with its mouse off is one no mid-fight reveal can rescue; the mouse is
        turned on once and left on, and SetHitRectInsets does the parking. See
        the note on SetClickable.

    A boon looted in the middle of a fight therefore lights up straight away,
    takes its hover and its tooltip straight away, and becomes usable when the
    fight ends - the bag slot behind it cannot be bound until then. That last
    part is a real limitation and it is the one the client's own implementation
    shipped with.

    The cycle key is the way out of that
    ------------------------------------
    The paragraph above used to end in a TODO saying the proper fix was to move
    the binding into the restricted environment, where the client trusts secure
    code to change an attribute mid-fight. The cycler does that.

    It is one hidden secure button carrying the whole list of held boons as
    attributes, with a snippet wrapped around its OnClick that picks the next
    entry and writes it into `item` before the click resolves. The snippet runs
    inside the restricted environment, so it is allowed to do in combat the one
    thing the fifteen visible buttons cannot: change what it is about to use.

    That does not make the whole bar combat-safe - the *list* is still written
    from ordinary Lua and so is still frozen at the start of a pull - but it
    means one key reaches every boon you were holding when the fight started,
    in order, rather than five keys frozen to five fixed positions. Which of
    the two paths a client got is reported by /hp boons.

    What else is in here
    --------------------
      * Expiry. A boon rots in the bags after ten minutes, and that is the
        number that decides whether to use one now or hold it for the pull.
        There is no API for it - it is read off the "Duration:" line of the
        item's own tooltip, and counted between readings. The bar can glow when
        a boon is about to go.

      * Shift and left-click says how long a boon has left in party chat
        instead of using it, for the tank who keeps asking.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local boons = {}
ns.Boons = boons

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

-- The step is 2 rather than 1 because a one-pixel change to an icon is not
-- something anybody can see, and the slider is 44 stops wide at that step
-- rather than 88.
local ICON_MIN, ICON_MAX, ICON_STEP = 20, 64, 2
ns.BOON_ICON_MIN, ns.BOON_ICON_MAX, ns.BOON_ICON_STEP = ICON_MIN, ICON_MAX, ICON_STEP

ns.BOON_ORIENTATIONS = { "horizontal", "vertical" }

local ICON_GAP  = 4    -- between two buttons in the same category
local GROUP_GAP = 12   -- between categories, so the three groups read apart
local BAR_PAD   = 6    -- container edge to the first button
local ROW_GAP   = 4    -- between one row of icons and the next, when the bar wraps

--------------------------------------------------------------------------------
-- Captions
--
-- A word under - or over - each icon saying what the boon does. Off by default,
-- because the bar's own claim is that you aim at a position rather than read it,
-- and fifteen captions is a bar you read. It is on offer because that claim only
-- holds once the positions have been learned, and the run where you are still
-- learning them is a run where "Dmg" beats "Ascension" by a distance.
--
-- The words are BoonData's, not this file's: what a boon does is a property of
-- the boon. See the note on the label column there for why they are not the
-- names shortened.
--------------------------------------------------------------------------------

ns.BOON_LABEL_ANCHORS = { "above", "below" }

-- Between the icon's edge and the caption. Two rather than nothing, because the
-- expiry sparks orbit one pixel outside the button and a caption flush against
-- that edge would have them running through it.
local LABEL_GAP = 2

-- The caption's own colour. The bright token rather than the accent one: the
-- accent is what the hotkey and the cycle mark are drawn in, and a third thing
-- in that colour on a 32px button is a button with no hierarchy left.
local LABEL_COLOUR = "bright"

--------------------------------------------------------------------------------
-- Wrapping
--
-- Fifteen known boons plus four spares is a row about seven hundred pixels wide
-- at the default icon size, which is a third of a 1920 screen laid across the
-- middle of it. Wrapping cuts that in half.
--
-- Stated as "start a new row after n icons" rather than as "split into two
-- rows", and the difference is worth knowing because the request was the second
-- one. A fixed split into two has to answer what happens when the bar is nine
-- icons and n is three, and every answer is a surprise: either the second row
-- is six long against a first of three, or the setting quietly stops meaning
-- what it says. Wrapping has no such case - it is two rows for any n at or past
-- half the bar, which is every sensible setting, and it degrades into a tidy
-- grid rather than into a lopsided pair for the rest.
--
-- The floor is 2 because a row of one is a vertical bar, which the orientation
-- control already offers. The ceiling is the button pool: a row longer than the
-- bar can never wrap, and a slider whose top half does nothing reads as broken.
local ROW_MIN = 2
ns.BOON_ROW_MIN = ROW_MIN

-- Spare buttons for boons this build does not know about.
--
-- BoonData.lua explains why they can exist: five reserved item slots say the
-- set is meant to grow. They are built at load with the rest of the pool
-- because a SecureActionButtonTemplate button cannot be created in combat, and
-- a boon is looted in combat as often as not - so "create one when we first see
-- an unknown boon" would create it at the one moment the client refuses.
--
-- Four, because the reserved block is five and a build that has fallen five
-- boons behind is a build to update rather than to paper over.
local SPARE_SLOTS = 4

-- The top of the row-length slider: every button the bar can ever draw. Read off
-- the pool rather than written down, so adding a boon to BoonData moves it.
ns.BOON_ROW_MAX = #ns.BoonData.ORDER + SPARE_SLOTS

-- How often the cooldown swipes are re-read while the bar is on screen. The
-- swipe animates itself once set; this only has to notice a cooldown starting
-- or ending, which the reference does off a per-frame OnUpdate. Five times a
-- second is enough to notice and costs a fifteenth of that.
local COOLDOWN_TICK = 0.2

-- Unowned boons keep their place in the bar rather than being pulled out of it,
-- so the icon a player reaches for is always in the same spot. They are
-- desaturated and dropped to this alpha.
local UNOWNED_ALPHA = 0.35

-- The melee-only mark: a ring drawn over the icon's outer edge in a colour
-- nothing else on the bar uses.
--
-- This dimmed the two boons at first, and dimming was the wrong signal - it is
-- what an unowned boon already looks like, so a melee boon you *were* carrying
-- read as one you were not. A border adds a signal rather than subtracting one,
-- which is what a "you are about to click this" warning has to do.
--
-- Two pixels, because one reads as the button's own edge at 32px. The gold is
-- the design's chest-tier token, which is the one colour in the palette that is
-- neither the accent purple the bar's own chrome uses nor a state colour that
-- means something else on the trackers.
local MELEE_MARK_WIDTH  = 2
local MELEE_MARK_COLOUR = "chest"

-- Shelved.
--
-- The mark is built, styled and wired as before and simply never drawn. Left in
-- place rather than taken out because the idea is a sound one and the data
-- behind it is confirmed - the client's own melee-only flags on Piercing and
-- Adaptation are both right, and Piercing's armour penetration does nothing
-- whatever for a caster. What it is not is something worth a row in the options
-- window right now.
--
-- This gate rather than only removing that row, because a store that already
-- had markMelee on would otherwise keep drawing a border with nothing left to
-- turn it off. The setting stays in the defaults and in the store so nothing is
-- lost, and it is inert while this is true.
--
-- To bring it back: set this false and restore the "Mark melee-only boons"
-- toggle to the Boons group in Options.lua. Nothing else has to change.
local MELEE_MARK_SHELVED = true

-- How far below the Mythic+ panel the bar hangs when it is anchored to it.
local ANCHOR_GAP = 6

-- Keybind slots. Five, because five is more boons than anybody is holding at
-- once and fifteen rows in the Key Bindings window is a list nobody reads.
local SLOT_COUNT = 5

--------------------------------------------------------------------------------
-- The reserve
--
-- Cells a packed bar keeps behind the boons you are holding, for the ones you
-- loot during a fight.
--
-- A packed bar draws only what you are carrying, so a boon looted mid-pull has
-- to appear in a cell that was already there: SetPoint is refused on a
-- SecureActionButtonTemplate under lockdown, and no amount of care gets around
-- that. Parking every unowned button on a cell of its own was the first spelling
-- and it is why the reveal still looked broken after the reveal itself was
-- fixed - nineteen buttons is nineteen cells, so a boon that happens to sit
-- twelfth in bar order lit up twelve cells past the end of a bar three cells
-- wide, a lone icon out in the world with the bar's own plate nowhere near it.
--
-- So the parked buttons share a short run of cells instead, round-robin. What
-- that buys is a bound: whatever is looted mid-fight lands within RESERVE_CELLS
-- of the pack, which is inside the bar rather than out beyond it.
--
-- What it costs is a collision. Two boons looted in the same fight whose bar
-- positions are congruent modulo the reserve land on the same cell and one
-- covers the other until the fight ends. That is the trade being made here and
-- it is made in this direction on purpose: a gap is a bar with a hole in it and
-- is never wrong about what you are carrying, while a stack of one cell - the
-- zero-gap version of this - would hide a held boon every time two arrived, on
-- the bar whose whole job is to say what you are holding.
--
-- Five, and the same five as everywhere else in this file: it is what the
-- keybinds reach and more boons than anybody holds at once, so a reserve that
-- size is one the bar can always afford to grow into.
--------------------------------------------------------------------------------
local RESERVE_CELLS = SLOT_COUNT

--------------------------------------------------------------------------------
-- The expiry warning
--
-- A boon is a three-minute item, and the bar has no way to say so: an icon that
-- is lit means "you have this", whether it landed ten seconds ago or is about
-- to evaporate. The glow is that missing half.
--
-- The thresholds the options window offers. Zero is off and is the default -
-- see the note in Core.lua on why an animation is opted into rather than out
-- of. The rest are the three answers to "how much warning do you want", and
-- there is no slider because the difference between forty and forty-five
-- seconds is not a thing anybody has an opinion about.
--
-- Declared here with their labels rather than in Options.lua, so the file that
-- owns the setting owns the set of values it can take - the same arrangement
-- ns.BOON_ORIENTATIONS has, and for the same reason: two lists of the same
-- thing in two files is two lists that eventually disagree.
--------------------------------------------------------------------------------

ns.BOON_EXPIRY_WARNINGS = {
    { key = 0,   label = "Off"   },
    { key = 30,  label = "30s"   },
    { key = 60,  label = "1 min" },
    { key = 120, label = "2 min" },
}

-- The top of the range, for the store's rule on the saved value. Read off the
-- list rather than written down twice.
ns.BOON_EXPIRY_MAX = ns.BOON_EXPIRY_WARNINGS[#ns.BOON_EXPIRY_WARNINGS].key

-- Sparks marching around the icon's outside edge, action-bar style.
--
-- Outside rather than over it: the melee-only mark is already a ring drawn on
-- the icon's own outer pixels, and two rings in two colours fighting for the
-- same two pixels is a button that reads as neither. One pixel out puts the
-- glow clear of it, and a boon can be melee-only *and* about to expire.
local GLOW_INSET   = -1   -- how far outside the button the sparks orbit
local GLOW_SPARKS  = 8    -- around the whole perimeter, evenly spaced
local GLOW_COLOUR  = "expiry"

-- How long one full lap takes, in seconds, at the two ends of the warning.
-- The lap gets shorter as the boon gets closer to rotting, so the glow reads
-- as "soon" and then as "now" without needing a second colour to say it.
local GLOW_LAP_SLOW, GLOW_LAP_FAST = 2.0, 0.6

-- And how bright, over the same span. The bottom end is deliberately low: a
-- warning that opens at full brightness has nowhere left to go.
local GLOW_ALPHA_LOW, GLOW_ALPHA_HIGH = 0.45, 1.0

-- How often the remaining lifetimes are re-read. Not the animation rate - that
-- is a real OnUpdate below, because a spark stepping at five hertz is a spark
-- that stutters. This is only how often "is it warning yet" is asked, and the
-- answer changes once per boon per run.
local EXPIRY_TICK = 0.5

-- And how often the counted clocks are checked back against the tooltip.
--
-- Slower than the tick above, because it costs a tooltip scan per held boon to
-- correct a drift of at most a minute. Two seconds catches the minute-to-minute
-- transition - the reading that pins a clock exactly - within two seconds of it
-- happening, and a pinned clock does not drift again.
local EXPIRY_RESYNC = 2

--------------------------------------------------------------------------------
-- The expiry call
--
-- The same warning again, said out loud in party chat instead of drawn on the
-- icon. It is a separate feature rather than a mode of the glow because the two
-- answer different people: the glow tells the person holding the boon, and this
-- tells the four who cannot see their bags.
--
-- The thresholds are the glow's, minus its Off row - that one is the toggle's
-- job here. Derived rather than written out again, so the two cannot drift: a
-- fourth warning added above becomes a fourth button in both places.
--
-- More than one may be picked, which is the difference from the glow. The glow
-- is a state - an icon is either warning or it is not - and a call is an event,
-- so "tell me at two minutes and again at thirty seconds" is a thing to want
-- and "glow from two minutes and also from thirty seconds" is not.
--------------------------------------------------------------------------------

ns.BOON_ANNOUNCE_THRESHOLDS = {}
for i = 1, #ns.BOON_EXPIRY_WARNINGS do
    local entry = ns.BOON_EXPIRY_WARNINGS[i]
    if entry.key > 0 then
        table.insert(ns.BOON_ANNOUNCE_THRESHOLDS, entry)
    end
end

--------------------------------------------------------------------------------
-- The pickup call
--
-- The other automatic line: a boon landing in the bags, named in party chat.
-- There is no threshold to pick and nothing to tune, so the whole of its
-- configuration is the switch - and the only constant it needs is a guard
-- against the bag scan, not against the player.
--------------------------------------------------------------------------------

-- How long a boon has to have been out of the bags before landing in them again
-- counts as a second pickup.
--
-- Not a throttle on the message - a pickup is announced once per boon and there
-- are fifteen of them. It is against the scan: a bag event caught mid-move can
-- read a slot as empty and then as full again, and without this the party gets
-- told twice about one boon.
local GAIN_DEBOUNCE = 3

--------------------------------------------------------------------------------
-- The chat report
--
-- Shift and left-click a boon to say how long it has left in party chat rather
-- than using it. Throttled, because it goes in somebody else's chat window and the
-- gesture is one click - a player who mashes it should not be the reason their
-- group turns heroPanel off.
--------------------------------------------------------------------------------

local REPORT_THROTTLE = 3

-- Which mouse button a keybind's synthesised click arrives as.
--
-- Not LeftButton, and the reason is the shift-click report above. An override
-- binding does not carry its own modifier state - the client reads the keyboard
-- at the moment the key fires - so a player whose boon slot is bound to SHIFT-1
-- presses it with shift genuinely held, and the secure attribute cascade would
-- find the "shift-type1" that turns a left click into a report. Their keybind
-- would stop firing boons the moment they switched reporting on.
--
-- Sending keybinds through a button the mouse cannot press keeps the two apart.
-- The cascade for button five is shift-type5, type5, shift-type, type - none of
-- the first three are ever set, so it lands on "type" and uses the boon,
-- whatever modifier is being held. The report is then gated on a real
-- LeftButton in the click hook, so a shift-modified keybind fires its boon and
-- says nothing.
local BIND_CLICK = "Button5"

--------------------------------------------------------------------------------
-- Config
--
-- Read through here rather than indexed straight off ns.db, because this module
-- runs from events that can fire before the store exists - a login where
-- PLAYER_ENTERING_WORLD beats ADDON_LOADED is unusual and not impossible - and
-- an unfilled store must read as "off" rather than throw.
--------------------------------------------------------------------------------

local DEFAULT_CONFIG = {
    enabled        = false,
    orientation    = "horizontal",
    iconSize       = 32,
    labels         = false,
    labelAnchor    = "above",
    splitRows      = false,
    rowSize        = 8,
    mythicOnly     = true,
    hideUnowned    = false,
    hideEmpty      = false,
    markMelee      = false,
    anchorMplus    = false,
    slotOrder      = false,
    rawTooltip     = false,
    expiryWarn     = 0,
    reportDuration = false,
    announceGain   = false,
    announceExpiry = false,
    announceExpiryAt = { [30] = false, [60] = true, [120] = false },
    scale          = 1.0,
    x              = 0,
    y              = 0,
}

local function Config()
    local block = ns.db and ns.db.boons
    if type(block) ~= "table" then return DEFAULT_CONFIG end
    return block
end

-- A whole number for string.format's %d.
--
-- The game's Lua 5.1 would truncate a float silently; the mock client runs 5.3,
-- where "%d" on one is a hard error. A count read back out of the item API or a
-- size read back out of a slider both arrive as floats often enough that this
-- is worth having rather than being a bug that only ever shows up in one of the
-- two places. Options.lua carries the same helper for the same reason.
local function Int(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

-- The writable form. Only used by setters, and it creates the block if a store
-- from an older build does not have one.
local function Saved()
    if not ns.db then return nil end
    if type(ns.db.boons) ~= "table" then ns.db.boons = {} end
    return ns.db.boons
end

function boons.IsEnabled()
    return Config().enabled and true or false
end

--------------------------------------------------------------------------------
-- Party chat
--
-- Three of this module's features end in somebody else's chat window: the
-- shift-click report, the pickup announcement and the expiry announcement. They
-- ask the same two questions first - is there a group, and which channel is it -
-- so they ask them here rather than each their own way.
--
-- Declared this early because the two automatic announcements run off the bag
-- scan and the expiry ticker, both of which are a long way above the click hook
-- that was the first caller.
--------------------------------------------------------------------------------

-- The same pair Keys.lua carries, for the same reason and with the same
-- precedence: a player in a raid is in a party too, and PARTY would reach four
-- of the forty. Local copies rather than a shared helper because they are three
-- lines each and the alternative is Boons.lua depending on Keys.lua loading.
local function GroupSize(fn)
    if type(fn) ~= "function" then return 0 end
    local ok, count = pcall(fn)
    if not ok then return 0 end
    return tonumber(count) or 0
end

local function ReplyChannel()
    if GroupSize(_G.GetNumRaidMembers) > 0 then return "RAID" end
    return "PARTY"
end

local function InGroup()
    return GroupSize(_G.GetNumPartyMembers) > 0
        or GroupSize(_G.GetNumRaidMembers) > 0
end

-- Seconds as something a person reads at a glance. Bare seconds under a minute,
-- because "0:47" is a stopwatch and "47s" is an answer.
local function FormatSpan(seconds)
    seconds = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
    if seconds < 60 then return string.format("%ds", seconds) end
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Put a line in the group's chat. Three answers rather than two, because the
-- callers want different things from the third:
--
--   true   it went to the party or the raid
--   false  there was a channel to send on and the client refused it
--   nil    there was nobody to tell - solo, or a build with no SendChatMessage
--
-- The shift-click report answers locally on nil, because the gesture is also how
-- you ask yourself. The two automatic announcements say nothing at all on it: a
-- line nobody asked for, in your own chat window, about a bar you are looking
-- at, is noise.
local function SendToGroup(message)
    if not (InGroup() and type(SendChatMessage) == "function") then return nil end
    if pcall(SendChatMessage, message, ReplyChannel()) then return true end
    return false
end

--------------------------------------------------------------------------------
-- Capabilities
--
-- Ascension ships bag APIs a stock 3.3.5a client does not have, and the client's
-- own boon UI uses them: C_InventoryState keeps a pre-scanned cache of every bag
-- slot, and C_Hook adds bucketed registration plus granular per-item bag events.
-- They are much cheaper than scanning five bags on every BAG_UPDATE, so they are
-- the preferred path.
--
-- They are also not guaranteed. heroPanel is shared publicly and runs on
-- whatever build the player has, so both are probed rather than assumed and
-- there is a stock fallback behind each. Probed once, at build time, and
-- reported by /hp boons - "which path is it on" is the first question when bag
-- tracking misbehaves.
--------------------------------------------------------------------------------

local caps = {}

local function ProbeCapabilities()
    caps.inventoryState =
        type(_G.C_InventoryState) == "table"
        and type(_G.C_InventoryState.Inventory) == "table"

    caps.hook =
        type(_G.C_Hook) == "table"
        and type(_G.C_Hook.RegisterBucket) == "function"

    -- Two ways to read an item out of a bag slot, because there are two
    -- vintages of client in play. GetContainerItemID is the direct one and is
    -- what this realm's client has - C_InventoryState is built on it - but it
    -- is not a stock 3.3.5a function, so the link is parsed when it is absent.
    -- An item link always carries the ID and every client of this era has
    -- GetContainerItemLink; Keys.lua already relies on that.
    caps.containerScan =
        type(_G.GetContainerNumSlots) == "function"
        and (type(_G.GetContainerItemID) == "function"
             or type(_G.GetContainerItemLink) == "function")

    -- Whether this client can make a button that uses an item at all. It always
    -- can; asked anyway, because the answer decides whether the bar is a bar or
    -- a read-only display, and finding out by throwing at login is not a way to
    -- find out. Probed by building one rather than by looking for the template
    -- name, since a template that exists and does not bring SetAttribute with
    -- it would pass that test and fail every real use.
    --
    -- Not in combat, though. Creating a frame from a protected template under
    -- lockdown is refused, and this particular frame is the only unnamed one
    -- the addon ever asks for - so the refusal is reported against no name at
    -- all, as UNKNOWN(), which is a bug report nobody can act on. pcall is no
    -- help: it catches the Lua error and the client still counts the block.
    --
    -- Left unresolved rather than answered "no" when that happens. A false here
    -- is latched for the session and turns the bar into a read-only display for
    -- the rest of it; nil means the question has not been asked yet, and
    -- BuildBar asks it again once the fight is over.
    if InCombatLockdown() then
        caps.secureButtons = nil
        ns.Debug("boons: secure buttons not probed - the client is in combat.")
    else
        local ok, probe = pcall(CreateFrame, "Button", nil, UIParent, "SecureActionButtonTemplate")
        caps.secureButtons = ok and type(probe) == "table"
                             and type(probe.SetAttribute) == "function"
        if ok and type(probe) == "table" and probe.Hide then pcall(probe.Hide, probe) end
    end

    -- Whether the cycle key can work in combat.
    --
    -- SecureHandlerWrapScript is what lets a snippet run inside the restricted
    -- environment before a click resolves, which is the only place an attribute
    -- may be changed during a fight. It arrived in 3.0 and this client is
    -- 3.3.5a, so it should always be here - asked anyway, because heroPanel is
    -- shared publicly and the fallback is real: without it the cycle key is
    -- re-pointed from ordinary Lua and so freezes on the pull like the slot
    -- keys do.
    caps.secureHandlers = type(_G.SecureHandlerWrapScript) == "function"

    caps.itemCooldown  = type(_G.GetItemCooldown) == "function"
    caps.spellDesc     = type(_G.C_Spell) == "table"
                         and type(_G.C_Spell.GetSpellDescription) == "function"
    caps.overrideBinds = type(_G.SetOverrideBindingClick) == "function"
                         and type(_G.ClearOverrideBindings) == "function"

    -- Reading an item's remaining lifetime.
    --
    -- There is no stock 3.3.5a call for this and the research turned none up on
    -- Ascension either, so the primary source is heroPanel watching a boon
    -- arrive and counting from there. A named function is probed all the same,
    -- because a build that has one would be authoritative where the count is
    -- only nearly right - and probing costs a type() at login.
    caps.itemDuration = type(_G.GetContainerItemDurationLeft) == "function"

    ns.Debug("boons: bag path %s, events %s, cooldowns %s, clickable %s, "
        .. "keybinds %s, in-combat cycling %s, expiry %s.",
        caps.inventoryState and "C_InventoryState" or
            (caps.containerScan and "container scan" or "none"),
        caps.hook and "C_Hook buckets" or "BAG_UPDATE",
        caps.itemCooldown and "yes" or "no",
        caps.secureButtons == nil and "not probed yet"
            or (caps.secureButtons and "yes" or "no"),
        caps.overrideBinds and "yes" or "no",
        caps.secureHandlers and "yes" or "no",
        caps.itemDuration and "client API" or "tracked")

    -- Only on a definite no. Unprobed is not the same answer and must not be
    -- announced as one: the probe is skipped in combat, and telling a player
    -- mid-pull that their client cannot use boons would be a false alarm that
    -- the next out-of-combat probe silently contradicts.
    if caps.secureButtons == false then
        ns.Warn("this client has no secure action buttons, so the boon bar can "
            .. "show what you are holding but cannot use it. Use the boons from "
            .. "your bags.")
    end
end

-- Attributes are what make a boon button use the boon, and they are the calls
-- the client refuses in combat. Every one of them goes through here: guarded on
-- the capability so a client without secure buttons gets a read-only bar rather
-- than a Lua error at login, and guarded on lockdown so a bag event during a
-- fight cannot taint anything. The callers all run inside ApplySecure, which is
-- itself deferred - this is the belt to that pair of braces.
local function SetSecureAttribute(button, key, value)
    if not caps.secureButtons or InCombatLockdown() then return false end
    return pcall(button.SetAttribute, button, key, value)
end

--------------------------------------------------------------------------------
-- What is in the bags
--
--   owned[itemID] = { count = n, slots = { { bag = b, slot = s }, ... } }
--
-- The button is bound to the first slot; the count is what the stack number
-- shows. Slots rather than a single position because boons are bind-on-pickup
-- and arrive one at a time, so five of the same boon is five bag slots, and
-- using one has to fall through to the next.
--
-- unknownSeen records boon itemIDs this build does not have in BoonData, so
-- each one is only reported once per session. A new boon turning up is
-- something to notice and not something to hear about every time a bag changes.
--------------------------------------------------------------------------------

local owned       = {}
local ownedCount  = 0     -- distinct boons held, for "hide when no boons owned"
local unknownSeen = {}
local unknownIDs  = {}    -- itemIDs, in discovery order, for the spare buttons

local function Remember(itemID, bag, slot, count)
    local record = owned[itemID]
    if not record then
        record = { count = 0, slots = {} }
        owned[itemID] = record
        ownedCount = ownedCount + 1
    end
    table.insert(record.slots, { bag = bag, slot = slot })
    record.count = record.count + (tonumber(count) or 1)
end

-- Is this bag item a boon, and is it one we already know about?
--
-- Known boons are answered from the table without touching the item API at all,
-- which is the common case and the cheap one. Anything else is only worth a
-- name lookup if it could plausibly be a boon, and the only way to ask that is
-- to read the name - so the ID range is checked first as a cheap filter. It is
-- deliberately generous: the block ends at 2104940 today and the point of the
-- prefix fallback is boons that do not exist yet.
local function ClassifyItem(itemID)
    if not itemID then return nil end

    local entry = ns.BoonData.BY_ID[itemID]
    if entry then return entry end

    if itemID < 2000000 then return nil end

    local name = GetItemInfo and GetItemInfo(itemID) or nil
    if not name then
        -- Not in the item cache yet. GetSpellInfo answers for these without a
        -- cache, because itemID == spellID for every boon - which is the one
        -- assumption in this whole feature that the client's own code depends
        -- on too.
        name = GetSpellInfo and GetSpellInfo(itemID) or nil
    end
    if not ns.BoonData.IsBoonName(name) then return nil end

    if not unknownSeen[itemID] then
        unknownSeen[itemID] = true
        table.insert(unknownIDs, itemID)
        ns.Debug("boons: %s (%d) is not in heroPanel's boon table - "
            .. "showing it on a spare slot.", tostring(name), itemID)
    end
    return { id = itemID, name = name, cat = 0, melee = false, unknown = true }
end

local function ScanInventoryState()
    for bag, bagData in pairs(_G.C_InventoryState.Inventory) do
        if type(bagData) == "table" then
            for slot, slotData in pairs(bagData) do
                if type(slotData) == "table" and ClassifyItem(slotData.item) then
                    Remember(slotData.item, bag, slot, slotData.count)
                end
            end
        end
    end
end

-- The item in one bag slot, by ID. See the capability note above on why there
-- are two routes: the direct call is not on a stock client of this vintage, and
-- the link always carries the ID.
local function ContainerItemID(bag, slot)
    if type(_G.GetContainerItemID) == "function" then
        local ok, itemID = pcall(_G.GetContainerItemID, bag, slot)
        if ok and itemID then return itemID end
    end
    if type(_G.GetContainerItemLink) == "function" then
        local ok, link = pcall(_G.GetContainerItemLink, bag, slot)
        if ok and type(link) == "string" then
            return tonumber(string.match(link, "item:(%d+)"))
        end
    end
    return nil
end

local function ScanContainers()
    -- 0 to 4: the backpack and the four bag slots. The bank is not searched -
    -- it cannot be read away from it, and a boon in the bank is one that
    -- expired hours ago anyway.
    for bag = 0, 4 do
        local slots = 0
        local ok, count = pcall(_G.GetContainerNumSlots, bag)
        if ok then slots = tonumber(count) or 0 end

        for slot = 1, slots do
            local itemID = ContainerItemID(bag, slot)
            if ClassifyItem(itemID) then
                local stack = 1
                if type(_G.GetContainerItemInfo) == "function" then
                    local gotInfo, _, n = pcall(_G.GetContainerItemInfo, bag, slot)
                    if gotInfo then stack = tonumber(n) or 1 end
                end
                Remember(itemID, bag, slot, stack)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- How long a boon has left
--
-- A boon evaporates out of the bags after ten minutes, and that is the number
-- that decides whether to use one now or hold it for the pull. The bar has no
-- way to say it: a lit icon means "you have this" whether it landed ten seconds
-- ago or is about to go.
--
-- There is no API for it. A stock 3.3.5a client has nothing that returns an
-- item's remaining lifetime, and the research into Ascension's additions turned
-- up nothing either - C_InventoryState carries the item and the count and not
-- this. But the client *draws* it: a boon is a Conjured Item and its tooltip
-- carries a "Duration: 10 minutes" line, which is a countdown rather than the
-- item's original span.
--
-- So the number is available, off a hidden tooltip, and it is coarse. Above a
-- minute the client rounds down to whole minutes, so "Duration: 9 minutes"
-- means somewhere in [9:00, 10:00) - a window, not a value. Below a minute it
-- switches to seconds and is exact, which is the half that matters most.
--
-- The clock is therefore built from both:
--
--   counted    A boon seen in a slot gets a start time, and the remaining time
--              is arithmetic from there. Smooth, which is what the glow's ramp
--              wants, and what a tooltip read twice a second could not be.
--
--   corrected  Every few seconds the tooltip is re-read, and the counted clock
--              is snapped back if it has drifted outside the window that
--              reading implies. This is what makes the minute-resolution
--              reading converge: "10 minutes" becoming "9 minutes" happens at
--              exactly 9:00, so catching that transition is an exact fix.
--
-- Together they handle the case a single read cannot: a boon that was already
-- in the bags before a /reload, where "first sight" is not "looted" and the
-- first reading could be most of a minute out.
--
-- When the tooltip cannot be read at all, the counted clock runs alone from
-- BoonData's per-boon lifetime, which is correct for anything looted while the
-- addon was loaded - nearly everything, since a boon does not live long.
--
-- Corrections snap to the *near* end of the window rather than the far one. A
-- warning that comes a little early costs a boon used a few seconds sooner than
-- it had to be; one that comes late costs the boon.
--------------------------------------------------------------------------------

-- The moment the boon in a given bag slot came into existence.
--
-- Keyed by item *and* place, because a slot that empties and refills has a
-- different boon in it with a different clock, and reusing the old one would
-- show a fresh boon as nearly expired.
local bornAt = {}

local function SlotKey(itemID, bag, slot)
    return string.format("%d:%d:%d", Int(itemID), Int(bag), Int(slot))
end

-- "10 minutes", "10 min", "45 seconds", "2 min 58 sec", "2:58" -> seconds.
--
-- The first two are both real: this client writes Bloodlust's line as
-- "Duration: 10 minutes" and Critical's as "Duration: 10 min". Units are
-- matched on their first three letters for exactly that reason - one client
-- does not have to spell a thing one way, and a parser that insisted would
-- have read one of those two boons and not the other.
--
-- Returns nil for anything that is not made of numbers and units of time, which
-- is what keeps a line like "Requires Level 80 Paladin" from being read as a
-- duration: the number is there, the word after it is not a unit.
local function ParseSpan(text)
    local clockMin, clockSec = string.match(text, "(%d+):(%d%d)")
    if clockMin then return tonumber(clockMin) * 60 + tonumber(clockSec) end

    local total, found = 0, false
    for value, unit in string.gmatch(text, "(%d+)%s*(%a+)") do
        local head = string.sub(unit, 1, 3)
        if head == "hou" or head == "hrs" or unit == "h" or unit == "hr" then
            total, found = total + tonumber(value) * 3600, true
        elseif head == "min" or unit == "m" then
            total, found = total + tonumber(value) * 60, true
        elseif head == "sec" or unit == "s" then
            total, found = total + tonumber(value), true
        else
            -- A number followed by a word that is not a unit of time. This is
            -- not a duration line and reading a span out of part of it would be
            -- worse than reading none.
            return nil
        end
    end

    return found and total or nil
end

-- Whether a line is *nothing but* a span.
--
-- The gate that matters. "Use: Increases damage by 20% for 30 sec" contains a
-- perfectly parseable "30 sec" and it is the buff's duration, not the item's
-- own clock - so a line only counts when taking the numbers and the units out
-- of it leaves nothing behind.
local function IsBareSpan(text)
    local rest = text
    rest = string.gsub(rest, "%d+", " ")
    rest = string.gsub(rest, "hours?", " ")
    rest = string.gsub(rest, "hrs?", " ")
    rest = string.gsub(rest, "minutes?", " ")
    rest = string.gsub(rest, "mins?", " ")
    rest = string.gsub(rest, "seconds?", " ")
    rest = string.gsub(rest, "secs?", " ")
    rest = string.gsub(rest, "[%s:%.,]", "")
    return rest == ""
end

-- The words a line uses when the span on it is the item's own clock.
--
-- "duration" is the one this client actually writes. A boon is a Conjured Item
-- and its tooltip reads:
--
--     Mythical Boon: Critical
--     Conjured Item
--     Binds when picked up
--     Duration: 10 min
--     Use: This Mythical Boon empowers your party's Critical Strike Chance
--          by 20% for 30 sec.
--     1 Charge
--
-- "expire" is kept alongside it because it is the other common wording and
-- costs one string to accept.
--
-- Note which line is *not* wanted: "Use: ... for 30 sec" is the buff's
-- duration, not the item's, and it parses as a span perfectly well. That is
-- what the gate is for, and why a keyword match beats reading the first number
-- on the tooltip.
local DURATION_WORDS = { "duration", "expire" }

local function LineDuration(text)
    if type(text) ~= "string" or text == "" then return nil end
    local lower = string.lower(text)

    -- Either the line says what it is, or the line is only a clock. Those are
    -- the two shapes a client draws an item's remaining time in, and anything
    -- else on a boon tooltip that contains a number is describing the buff.
    for i = 1, #DURATION_WORDS do
        if string.find(lower, DURATION_WORDS[i], 1, true) then
            return ParseSpan(lower)
        end
    end

    if IsBareSpan(lower) then return ParseSpan(lower) end
    return nil
end

-- The scanning tooltip. Its own frame, never shown, never anchored to anything
-- the player can see - SetOwner with ANCHOR_NONE is what makes SetBagItem fill
-- the text in without drawing a box in the corner of the screen.
local scanner

local function TooltipRemaining(bag, slot)
    if not scanner then return nil end

    scanner:SetOwner(UIParent, "ANCHOR_NONE")
    scanner:ClearLines()
    if not pcall(scanner.SetBagItem, scanner, bag, slot) then return nil end

    local name  = scanner:GetName()
    local lines = 0
    if type(scanner.NumLines) == "function" then
        local ok, count = pcall(scanner.NumLines, scanner)
        if ok then lines = tonumber(count) or 0 end
    end

    local found
    for i = 1, lines do
        local left  = _G[name .. "TextLeft" .. i]
        local right = _G[name .. "TextRight" .. i]
        for _, fs in ipairs({ left, right }) do
            if not found and fs and type(fs.GetText) == "function" then
                local span = LineDuration(fs:GetText())
                -- Zero is not a remaining time, it is a line that parsed to
                -- nothing. A boon with no time left is gone from the bags.
                if span and span > 0 then found = span end
            end
        end
    end

    -- Put away rather than left filled. SetBagItem shows the tooltip it is
    -- called on, and this one is owned by UIParent with no anchor - which on
    -- most clients means it draws nothing anywhere, and on the ones where it
    -- does means a grey box in the corner of the screen that nothing takes
    -- down again. One call is cheaper than finding out which kind this is.
    pcall(scanner.Hide, scanner)
    return found
end

-- How much of a boon's life has already run, at the moment it is first seen.
-- Zero when nothing can be read, which is the assumption that it has just been
-- looted - see the note above on why erring fresh is the right direction.
local function ElapsedAlready(itemID, bag, slot)
    local life = ns.BoonData.LifeOf(itemID)

    if caps.itemDuration then
        local ok, left = pcall(_G.GetContainerItemDurationLeft, bag, slot)
        if ok and tonumber(left) and tonumber(left) > 0 then
            return math.max(0, life - tonumber(left))
        end
    end

    local left = TooltipRemaining(bag, slot)
    if left then return math.max(0, life - left) end

    return 0
end

-- Stamp every held slot with the moment its boon was created, and put the
-- oldest first.
--
-- The order is load-bearing rather than tidy. The button binds to slots[1], so
-- with two of the same boon in the bags this is what makes the click spend the
-- one that is about to rot and keep the fresh one - which is what a player
-- would do by hand, and is the only sensible reading of "use a boon".
local function NoteLifetimes()
    local now, present = GetTime(), {}

    for itemID, record in pairs(owned) do
        for i = 1, #record.slots do
            local place = record.slots[i]
            local key   = SlotKey(itemID, place.bag, place.slot)
            present[key] = true

            if not bornAt[key] then
                bornAt[key] = now - ElapsedAlready(itemID, place.bag, place.slot)
            end
            place.bornAt = bornAt[key]
        end

        table.sort(record.slots, function(a, b)
            return (a.bornAt or 0) < (b.bornAt or 0)
        end)
    end

    -- Slots that no longer hold a boon. Clearing a key during pairs() is the
    -- one table mutation Lua defines as safe during traversal.
    for key in pairs(bornAt) do
        if not present[key] then bornAt[key] = nil end
    end
end

-- What a tooltip reading actually tells us: a window, not a number.
--
-- A whole number of minutes is the client rounding down, so the truth is
-- anywhere in the following minute. Anything else came from the seconds form
-- and is exact bar the second it was read in.
local function ReadingWindow(reading)
    if reading >= 60 and (reading % 60) == 0 then
        return reading, reading + 60
    end
    return reading - 1, reading + 1
end

-- Re-read the tooltips and correct the counted clocks that have drifted out of
-- the window their reading implies.
--
-- Only slots[1] of each boon, which is the stack the button is bound to and the
-- only one whose remaining time is ever shown. Reading all of them would be a
-- tooltip scan per stack per tick to correct a number nothing displays.
local function ResyncLifetimes()
    if not scanner then return end
    local now = GetTime()

    for itemID, record in pairs(owned) do
        local place = record.slots[1]
        local key   = place and SlotKey(itemID, place.bag, place.slot)
        local born  = key and bornAt[key]

        if born then
            local reading = TooltipRemaining(place.bag, place.slot)
            if reading then
                local life = ns.BoonData.LifeOf(itemID)
                local predicted = born + life - now
                local low, high = ReadingWindow(reading)

                if predicted < low or predicted > high then
                    bornAt[key] = now - (life - low)
                    place.bornAt = bornAt[key]
                    ns.Debug("boons: %d re-anchored, clock said %.0fs and the "
                        .. "tooltip said %ds.", Int(itemID), predicted, Int(reading))
                end
            end
        end
    end
end

-- Seconds until this boon rots out of the bags, or nil when it is not held.
-- The oldest stack, because that is the one the button is bound to.
local function RemainingLife(itemID)
    local record = itemID and owned[itemID]
    if not (record and record.slots[1] and record.slots[1].bornAt) then return nil end

    local left = record.slots[1].bornAt + ns.BoonData.LifeOf(itemID) - GetTime()
    if left <= 0 then return 0 end
    return left
end

boons.RemainingLife = RemainingLife

--------------------------------------------------------------------------------
-- Announcements
--
-- Two automatic party-chat lines, both off by default: one when a boon lands in
-- the bags, one as a held boon runs down. They are the bar's two facts said out
-- loud - what you are carrying, and how long you have got - for the four people
-- who cannot see it.
--
-- Both are gated on the bar being on screen rather than merely on their own
-- checkbox, and that is the whole of what stops them being a nuisance. "Only in
-- Mythic dungeons" is on by default, so a player who ticks these gets them
-- during a key and nowhere else - not while sorting bags in a city, and not on
-- the boon somebody hands them between runs.
--
-- Silent outside a group. There is no local fallback the way the shift-click
-- report has one: that report answers a deliberate gesture, and these two answer
-- nothing anybody did.
--------------------------------------------------------------------------------

-- Forward declaration. Both announcements ask whether the bar is up, and that
-- answer lives with the visibility code a long way below - see the note on the
-- gate above for why it is that question and not "is the feature ticked".
local ShouldShow

-- The name to put in chat. BoonData's own, then whatever the item API can be
-- persuaded to say about a boon this build has never seen - which is the same
-- pair ClassifyItem asks, and in the same order.
local function BoonName(itemID)
    local entry = itemID and ns.BoonData.BY_ID[itemID]
    if entry and entry.name then return entry.name end

    local name = itemID and GetItemInfo and GetItemInfo(itemID)
    if not name and itemID and GetSpellInfo then name = GetSpellInfo(itemID) end
    return name or "Mythical Boon"
end

-- itemID -> the last time it was announced as picked up. Only ever read against
-- GAIN_DEBOUNCE, so nothing has to clean it out: fifteen boons is fifteen
-- entries and every one of them is stale within three seconds of being written.
local gainAnnounced = {}

-- Whether a bag scan has happened yet.
--
-- The first one is not a pickup. It runs at login and after a /reload, and it
-- finds whatever is already in the bags - which mid-key is every boon the player
-- is carrying. Announcing that set would put five lines in party chat for a
-- reload nobody else can see.
local gainPrimed = false

-- itemID -> { [threshold] = true } for the calls already made about that boon.
--
-- Re-armed by the clock going back up rather than by anything watching the bags,
-- which is what makes it right for the two cases that are not a simple
-- countdown: a boon spent and looted again jumps from seconds to ten minutes,
-- and so does one that had a second stack behind it, since the button - and
-- RemainingLife - always read the oldest.
local expiryAnnounced = {}

-- What landed in the bags since the last scan.
--
-- Called from RebuildOwned with the set as it was before it, because that is the
-- only moment the two sets both exist. Everything it decides is a comparison of
-- those two and nothing polls.
local function NoteGains(before)
    for itemID in pairs(expiryAnnounced) do
        if not owned[itemID] then expiryAnnounced[itemID] = nil end
    end

    if not gainPrimed then
        gainPrimed = true
        return
    end

    if not (Config().announceGain and ShouldShow and ShouldShow()) then return end

    local now, fresh = GetTime(), {}
    for itemID in pairs(owned) do
        if not before[itemID] then
            local at = gainAnnounced[itemID]
            if not (at and (now - at) < GAIN_DEBOUNCE) then
                gainAnnounced[itemID] = now
                fresh[#fresh + 1] = BoonName(itemID)
            end
        end
    end

    if #fresh == 0 then return end

    -- One line for the lot rather than one line each. Opening a chest is one
    -- moment and can be two boons, and two messages a frame apart read as the
    -- addon stuttering rather than as two pickups.
    --
    -- Sorted so the line does not depend on pairs() order, which is not stable
    -- between sessions and would make the same two boons read differently twice.
    table.sort(fresh)
    SendToGroup("Boons: picked up " .. table.concat(fresh, ", "))
end

-- The calls due this tick.
--
-- Ascending, and the tightest threshold that has just been crossed is the one
-- announced - the looser ones crossed in the same pass are marked as made
-- without being said. That is what keeps a player who ticks all three from
-- getting three lines at once when they turn the feature on partway through a
-- boon's life, or when a /reload finds one already down to its last thirty
-- seconds.
--
-- A threshold is marked whether or not it was asked for, which is the same idea
-- from the other end: ticking "2 min" on a boon that is already under a minute
-- should say nothing, because that moment has been and gone.
local function NoteExpiries()
    if not Config().announceExpiry then return end
    if not (ShouldShow and ShouldShow()) then return end

    local wanted = Config().announceExpiryAt
    if type(wanted) ~= "table" then return end

    local list = ns.BOON_ANNOUNCE_THRESHOLDS
    local due  = {}

    for itemID in pairs(owned) do
        local left = RemainingLife(itemID)
        if left then
            local done = expiryAnnounced[itemID]
            if not done then
                done = {}
                expiryAnnounced[itemID] = done
            end

            local crossed = nil
            for i = 1, #list do
                local threshold = list[i].key
                if left > threshold then
                    done[threshold] = nil
                elseif not done[threshold] then
                    done[threshold] = true
                    if wanted[threshold] and crossed == nil then crossed = i end
                end
            end

            if crossed then
                due[crossed] = due[crossed] or {}
                table.insert(due[crossed], BoonName(itemID))
            end
        end
    end

    -- One line per threshold, however many boons crossed it together. The
    -- threshold's own label rather than the remaining time, because this is a
    -- warning and not a clock: "expires in 1 min" is what was asked for, where
    -- "expires in 59s" is a number that was already wrong when it was sent.
    for i = 1, #list do
        local names = due[i]
        if names then
            table.sort(names)
            SendToGroup(string.format("Boons: %s %s in %s",
                table.concat(names, ", "),
                #names == 1 and "expires" or "expire",
                list[i].label))
        end
    end
end

local function RebuildOwned()
    local before = owned
    owned, ownedCount = {}, 0

    if caps.inventoryState then
        ScanInventoryState()
    elseif caps.containerScan then
        ScanContainers()
    end

    NoteLifetimes()
    NoteGains(before)
    return ownedCount
end

--------------------------------------------------------------------------------
-- The frames
--------------------------------------------------------------------------------

local bar             -- the plain container. Everything below is its child.
local buttons  = {}   -- index -> button, in bar order, fixed at build
local byItem   = {}   -- itemID -> button, rebuilt whenever a spare is assigned
local tooltip         -- the compact in-combat tooltip
local ticker          -- cooldown poller

-- What the last layout decided, so the combat-safe resize can follow it
-- without re-running arithmetic that is only legal out of combat.
--
-- Both axes, since the bar can wrap: a revealed boon can land on a row that was
-- not there before, which grows the bar across as well as along.
local layout = { vertical = false, minExtent = 0, minThickness = 0 }

-- Forward declaration. RefreshVisuals has to ask whether the bar is packing to
-- know which buttons it may reveal, and the answer lives with the layout code a
-- long way below it. Declared rather than duplicated: there are now four
-- callers of this and they must all get the same answer - see the note above
-- OwnedOnly itself.
local OwnedOnly
local cycler          -- the hidden secure button the cycle key clicks
local expiryTicker    -- re-reads remaining lifetimes
local glowDriver      -- OnUpdate frame that marches the expiry sparks
local glowing  = {}   -- button -> how urgent, 0..1, for the ones warning now

-- Set while a piece of secure work is already waiting on the end of combat.
--
-- ns.RunWhenSafe queues the closure it is handed, so pushing one per bag event
-- would queue a few dozen identical rebuilds across a boss fight and run all of
-- them the moment it ended. One flag and one queued call does the same job once.
local securePending = false

local function ApplySecure(reason) end   -- forward declaration; defined below

local function QueueSecure(reason)
    if securePending then return end
    securePending = true
    ns.RunWhenSafe(function()
        securePending = false
        ApplySecure(reason)
    end, "Boons:" .. tostring(reason or "update"))
end

--------------------------------------------------------------------------------
-- Tooltips
--
-- Two modes, which is what the client's own UI does and is worth copying.
--
-- Out of combat the real item tooltip is what a player wants: it carries the
-- expiry, which is the one number that actually decides whether to use a boon
-- now or hold it, and heroPanel has no business reimplementing it.
-- SetBagItem for a boon in the bags, SetHyperlink for one that is not, because
-- an empty slot has no bag item to describe.
--
-- In combat that tooltip is a wall of text over the middle of a fight, so this
-- is a three-line version anchored to the cursor: the name, the category, and
-- the one-line summary from BoonData. The summaries are written out rather than
-- parsed off the live spell description - BoonData.lua says why at length; the
-- short version is that three of the fifteen live strings are wrong.
--
-- boons.rawTooltip puts the full client description back for anyone who would
-- rather have it, and it is what an unknown boon always gets, since there is no
-- hand-written line for a boon nobody has seen.
--------------------------------------------------------------------------------

local function LiveDescription(itemID)
    if caps.spellDesc then
        local ok, text = pcall(_G.C_Spell.GetSpellDescription, _G.C_Spell, itemID)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    if type(_G.GetSpellDescription) == "function" then
        local ok, text = pcall(_G.GetSpellDescription, itemID)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return nil
end

-- Drawn into heroPanel's own tooltip frame when there is one, and into
-- GameTooltip when there is not. A client that could not give us a second
-- tooltip frame should still get the compact text, because the case this exists
-- for - a wall of item text over the middle of a fight - does not go away just
-- because the frame did.
local function ShowCompactTooltip(button)
    local tt = tooltip or GameTooltip
    if not tt then return end

    local entry = button.entry
    tt:SetOwner(button, "ANCHOR_CURSOR", 0, 0)
    tt:ClearLines()
    tt:AddLine(entry and entry.name or "Mythical Boon", 1, 1, 1)

    local categoryName = entry and ns.BoonData.CATEGORY_NAMES[entry.cat]
    if categoryName then
        tt:AddLine(categoryName, 0.55, 0.56, 0.66)
    end

    local summary = (not Config().rawTooltip) and entry and entry.summary or nil
    local body = summary or LiveDescription(button.itemID)
    if body then tt:AddLine(body, 0.47, 0.78, 0.55, true) end

    local record = button.itemID and owned[button.itemID]
    if record and record.count > 1 then
        tt:AddLine(string.format("%d in your bags", Int(record.count)), 0.76, 0.78, 0.85)
    elseif not record then
        tt:AddLine("Not in your bags", 0.55, 0.56, 0.66)
    end

    tt:Show()
end

local function ShowFullTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_CURSOR", 0, 0)

    local record = button.itemID and owned[button.itemID]
    local shown  = false

    if record and record.slots[1] then
        shown = pcall(GameTooltip.SetBagItem, GameTooltip,
            record.slots[1].bag, record.slots[1].slot)
    end
    if not shown and button.itemID then
        shown = pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. button.itemID)
    end

    -- pcall answers "did that throw", which is not the same as "did that draw".
    -- A hyperlink to an item the client has never cached does neither: it comes
    -- back cleanly and leaves the tooltip empty. NumLines is what actually
    -- answers the question, so it is asked when the client has it.
    if shown and type(GameTooltip.NumLines) == "function" then
        local counted, lines = pcall(GameTooltip.NumLines, GameTooltip)
        if counted and (tonumber(lines) or 0) == 0 then shown = false end
    end

    -- An item the client has never cached has no tooltip to draw, and an empty
    -- GameTooltip is a grey box with nothing in it. Fall back to the compact
    -- one rather than showing that.
    if not shown then
        GameTooltip:Hide()
        ShowCompactTooltip(button)
        return
    end

    if Config().rawTooltip then
        local text = LiveDescription(button.itemID)
        if text then GameTooltip:AddLine(text, 0.47, 0.78, 0.55, true) end
    end

    GameTooltip:Show()
end

local function ButtonOnEnter(button)
    if InCombatLockdown() then
        if tooltip then GameTooltip:Hide() end
        ShowCompactTooltip(button)
    else
        if tooltip then tooltip:Hide() end
        ShowFullTooltip(button)
    end
    button.highlight:Show()
end

local function ButtonOnLeave(button)
    button.highlight:Hide()
    GameTooltip:Hide()
    if tooltip then tooltip:Hide() end
end

--------------------------------------------------------------------------------
-- Cooldowns
--
-- Boons share one cooldown, so using any of them puts every other one you are
-- holding on it. The client's own UI reads GetItemCooldown for the boon that
-- was clicked and pushes that same start and duration onto every other owned
-- button rather than waiting to observe it, which is what makes the whole bar
-- go grey at once instead of one icon at a time as each is polled.
--
-- The poller below is still needed - it is what notices a cooldown that started
-- somewhere else, and what clears the swipe when one ends.
--------------------------------------------------------------------------------

local function SetCooldown(button, start, duration, enable)
    if not button.cooldown then return end
    if type(_G.CooldownFrame_SetTimer) == "function" then
        pcall(_G.CooldownFrame_SetTimer, button.cooldown, start, duration, enable)
    else
        pcall(button.cooldown.SetCooldown, button.cooldown, start, duration)
    end
end

-- What the last use said the shared cooldown is.
--
-- Remembered rather than only pushed onto the buttons, because the poller below
-- would otherwise undo it. GetItemCooldown answers for the item it is asked
-- about, and a boon that was not the one clicked can report nothing for the
-- moment it takes the server to say otherwise - so a poll landing in that gap
-- would clear a swipe that had just been set, and the bar would flicker back to
-- ready and then grey again.
--
-- It expires on its own and is never trusted past its own end, so a cooldown
-- that turns out to have been shorter than this thought costs at most one poll.
local shared = { start = 0, duration = 0 }

local function SharedRemaining()
    if shared.duration <= 0 then return 0 end
    local left = (shared.start + shared.duration) - GetTime()
    if left <= 0 then
        shared.start, shared.duration = 0, 0
        return 0
    end
    return left
end

local function PropagateCooldown(start, duration, enable)
    if not (duration and duration > 0) then return end

    shared.start, shared.duration = start or GetTime(), duration

    for i = 1, #buttons do
        local button = buttons[i]
        if button.itemID and owned[button.itemID] then
            SetCooldown(button, start, duration, enable)
        end
    end
end

local function PollCooldowns()
    if not caps.itemCooldown then return end

    local remaining = SharedRemaining()

    for i = 1, #buttons do
        local button = buttons[i]
        if button.itemID and owned[button.itemID] then
            local ok, start, duration, enable = pcall(_G.GetItemCooldown, button.itemID)
            if ok then
                -- The client has not caught up with the shared cooldown for
                -- this one yet. Keep what the last use told us rather than
                -- clearing a swipe that is still running.
                if (not duration or duration <= 0) and remaining > 0 then
                    start, duration, enable = shared.start, shared.duration, 1
                end
                SetCooldown(button, start or 0, duration or 0, enable or 0)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- The expiry glow
--
-- Sparks marching around the outside of an icon whose boon is about to rot.
-- The action bar idiom, because it is the one animation a player of this game
-- already reads without being told what it means.
--
-- Two things move, and both are driven by how close the boon is to going
-- rather than by a tier: the lap gets shorter and the sparks get brighter as
-- the remaining time runs from the configured threshold down to zero. A tiered
-- version came out worse - three discrete steps read as three unrelated
-- effects, where a ramp reads as one thing getting more urgent, which is what
-- it is.
--
-- Textures, alpha and points are all unprotected, so every line below is safe
-- in combat. That matters more here than anywhere else on the bar: a boon
-- expiring during a boss fight is the exact case this exists for.
--
-- The animation is a real OnUpdate rather than one of ns.NewTicker's slots.
-- The shared ticker floors at five hertz, which is fine for asking "is this
-- warning yet" - that is what expiryTicker does - and is not fine for moving a
-- spark, which at five hertz visibly hops instead of travelling. The driver is
-- hidden whenever nothing is glowing, so it costs nothing the rest of the time.
--------------------------------------------------------------------------------

-- Where one spark sits, given how far round the lap it is.
--
-- The orbit is the button's rectangle pushed out by GLOW_INSET, walked
-- clockwise from the top-left corner. Anchored to the button's TOPLEFT rather
-- than sized and centred, so it follows the icon size slider with nothing
-- having to reposition it.
local function PlaceSpark(button, spark, progress)
    local size = button:GetWidth() or 0
    if size <= 0 then return end

    local low  = GLOW_INSET
    local high = size - GLOW_INSET
    local edge = high - low
    if edge <= 0 then return end

    local along = (progress - math.floor(progress)) * edge * 4
    local x, y

    if along < edge then
        x, y = low + along, low
    elseif along < edge * 2 then
        x, y = high, low + (along - edge)
    elseif along < edge * 3 then
        x, y = high - (along - edge * 2), high
    else
        x, y = low, high - (along - edge * 3)
    end

    spark:ClearAllPoints()
    spark:SetPoint("CENTER", button, "TOPLEFT", x, -y)
end

local function ShowGlow(button)
    local size  = button:GetWidth() or 32
    -- Proportional to the icon, floored at two pixels: one pixel at any size is
    -- a spark that reads as a rendering artefact rather than as a warning.
    local spark = math.max(2, math.floor(size / 10))

    for i = 1, GLOW_SPARKS do
        local texture = button.glow[i]
        texture:SetWidth(spark)
        texture:SetHeight(spark)
        texture:Show()
    end
    button.glowPhase = button.glowPhase or 0
end

local function HideGlow(button)
    for i = 1, GLOW_SPARKS do button.glow[i]:Hide() end
end

local function GlowOnUpdate(_, elapsed)
    local running = false

    for button, urgency in pairs(glowing) do
        running = true

        -- Phase is accumulated rather than taken from GetTime() modulo the lap
        -- length. The lap length changes as the boon gets closer to expiring,
        -- and a modulo of a changing period makes the sparks jump backwards
        -- every time the urgency is re-read.
        local lap = GLOW_LAP_SLOW + (GLOW_LAP_FAST - GLOW_LAP_SLOW) * urgency
        local phase = (button.glowPhase or 0) + (elapsed / lap)
        button.glowPhase = phase - math.floor(phase)

        local alpha = GLOW_ALPHA_LOW + (GLOW_ALPHA_HIGH - GLOW_ALPHA_LOW) * urgency

        for i = 1, GLOW_SPARKS do
            local texture = button.glow[i]
            PlaceSpark(button, texture, button.glowPhase + (i - 1) / GLOW_SPARKS)
            texture:SetAlpha(alpha)
        end
    end

    if not running then glowDriver:Hide() end
end

-- Which buttons are warning, and how hard. Called off expiryTicker rather than
-- per frame: a remaining time only crosses the threshold once.
local function UpdateGlow()
    if not bar then return end

    local threshold = tonumber(Config().expiryWarn) or 0

    for i = 1, #buttons do
        local button  = buttons[i]
        local urgency = nil

        -- A hidden button is not warning about anything. That covers both the
        -- unowned icons in a full bar and the whole bar when it is off, so
        -- nothing has to ask about either case separately.
        if threshold > 0 and button.itemID and owned[button.itemID] and button:IsShown() then
            local left = RemainingLife(button.itemID)
            if left and left <= threshold then
                urgency = ns.Clamp(1 - (left / threshold), 0, 1)
            end
        end

        if urgency then
            -- Re-sized on every tick rather than only on the way in, so a glow
            -- that is already running follows the icon size slider. Eight
            -- SetWidth calls twice a second on the one or two icons that are
            -- warning is not a cost worth tracking a transition to avoid.
            ShowGlow(button)
            glowing[button] = urgency
        elseif glowing[button] then
            glowing[button] = nil
            HideGlow(button)
        end
    end

    if glowDriver then
        if next(glowing) then glowDriver:Show() else glowDriver:Hide() end
    end
end

-- What the expiry ticker actually runs. Two jobs at two rates: the glow is
-- re-decided every tick and the clocks are checked against the tooltips a good
-- deal less often, because one is arithmetic and the other is a tooltip scan
-- per held boon.
local lastResync = 0

local function ExpiryTick()
    local now = GetTime()
    if (now - lastResync) >= EXPIRY_RESYNC then
        lastResync = now
        ResyncLifetimes()
    end
    UpdateGlow()
    NoteExpiries()
end

--------------------------------------------------------------------------------
-- Visuals
--
-- Everything in here is safe in combat: SetAlpha, SetDesaturated,
-- SetVertexColor, texture swaps, font strings and cooldown frames are all
-- unprotected. This is what runs when a boon is looted or used mid-fight, and
-- it is the whole of what can run then.
--------------------------------------------------------------------------------

-- Growing the bar around whatever is currently revealed.
--
-- The bar itself is a plain frame, so its size is not protected and this can
-- run mid-fight - which is the point. A boon revealed by the alpha pass below
-- would otherwise be drawn outside the bar's own rectangle.
--
-- This is also where Layout finishes, rather than Layout sizing the bar itself
-- and this second-guessing it afterwards. Two pieces of code measuring the same
-- grid two different ways is two answers that eventually disagree, and the
-- disagreement shows up as the bar changing size on a refresh that moved
-- nothing.
--
-- In combat it only ever grows
-- ----------------------------
-- This used to do nothing at all under lockdown, on the rule that the bar must
-- not change size under the player mid-pull. That rule was reading its own
-- purpose too widely and it took the reveal down with it: a boon revealed into
-- a reserve cell was drawn past the edge of a plate that could not follow it,
-- so the icon sat outside its own bar with no background behind it.
--
-- Growing moves nothing. Every button is anchored to the bar's TOPLEFT, so the
-- bar getting longer or thicker leaves every icon already on screen exactly
-- where it was and moves one edge of the plate. What the rule is actually about
-- is icons shifting under the cursor mid-fight, and that is what packing is
-- deferred for and still is.
--
-- Shrinking is refused, though, and that is what keeps the rule honest. A boon
-- spent mid-fight would otherwise pull the plate back off the reserve cells and
-- the bar would breathe in and out for the length of the pull - and with the
-- quest tracker chained under it, so would that.
local function SizeBarToRevealed()
    if not (bar and layout.minThickness > 0) then return end

    local reach, across = 0, 0
    for i = 1, #buttons do
        local button = buttons[i]
        if button.layoutEdge and button:IsShown() and (button:GetAlpha() or 1) > 0 then
            if button.layoutEdge > reach then reach = button.layoutEdge end
            if (button.layoutCross or 0) > across then across = button.layoutCross end
        end
    end

    local extent    = (reach  > 0) and (reach  + BAR_PAD) or layout.minExtent
    local thickness = (across > 0) and (across + BAR_PAD) or layout.minThickness

    if InCombatLockdown() then
        local wasExtent    = layout.vertical and bar:GetHeight() or bar:GetWidth()
        local wasThickness = layout.vertical and bar:GetWidth()  or bar:GetHeight()
        extent    = math.max(extent,    tonumber(wasExtent)    or 0)
        thickness = math.max(thickness, tonumber(wasThickness) or 0)
    end

    if layout.vertical then
        bar:SetHeight(extent)
        bar:SetWidth(thickness)
    else
        bar:SetWidth(extent)
        bar:SetHeight(thickness)
    end
end

-- Whether a button is in the input path - without touching EnableMouse.
--
-- EnableMouse is protected on a SecureActionButtonTemplate, so a button parked
-- with its mouse off could not get it back until the fight ended. That is
-- exactly the state a boon looted mid-pull arrives into: the alpha pass drew
-- it, and then it took no clicks and showed no tooltip, on the one bar whose
-- whole job is to be clicked. The leak ran the other way too - a boon spent in
-- combat went to alpha zero and kept its mouse, which is an invisible thing
-- eating clicks, the precise failure parking was introduced to prevent.
--
-- So the mouse stays on for every placed button and the hit rect does the
-- parking instead. SetHitRectInsets is not one of the calls the client refuses
-- under lockdown, so this lands mid-combat where EnableMouse cannot.
--
-- If some build does refuse it, the pcall swallows it and the button is left
-- mouse-enabled and clickable. That is the right way round to fail on this bar:
-- the cost is a parked cell eating a click inside the bar's own full-size
-- footprint, and the alternative is a boon that cannot be clicked at all.
local function SetClickable(button, on)
    if not button then return end

    -- Always on, and never turned off again. This is the call that cannot be
    -- taken back in combat, so it is only ever made in the direction that
    -- leaves the bar working.
    pcall(button.EnableMouse, button, true)

    if type(button.SetHitRectInsets) ~= "function" then return end

    if on then
        pcall(button.SetHitRectInsets, button, 0, 0, 0, 0)
        return
    end

    -- Inset by the button's whole width and height on each side, which leaves
    -- the rect inside out and so catching nothing. Measured off the button
    -- rather than off the icon-size setting, because a reveal in combat has to
    -- work from whatever size the last layout gave it.
    local width  = tonumber(button:GetWidth())  or 0
    local height = tonumber(button:GetHeight()) or 0
    pcall(button.SetHitRectInsets, button, width, width, height, height)
end

local function RefreshVisuals()
    if not bar then return end
    local cfg = Config()
    local packing = OwnedOnly()

    for i = 1, #buttons do
        local button = buttons[i]
        local record = button.itemID and owned[button.itemID]
        local entry  = button.entry

        -- The whole button, not the icon: this is what reveals a boon looted
        -- mid-fight, when Show and SetPoint are refused and SetAlpha is not.
        -- Sampled buttons are the placement-preview stand-ins and are meant to
        -- be seen while unowned, so they keep theirs.
        if button.itemID and not button.sampled then
            -- Drawn and clickable move together. Splitting them is what left a
            -- boon looted mid-fight visible and dead, and a boon spent
            -- mid-fight invisible and live.
            local drawn = not (packing and not record)
            button:SetAlpha(drawn and 1 or 0)
            SetClickable(button, drawn)
        end

        button.icon:SetDesaturated(not record)

        local alpha = record and 1 or UNOWNED_ALPHA
        button.icon:SetAlpha(alpha)
        button.border:SetAlpha(record and 1 or 0.5)

        -- The caption fades with the icon it names. Left at full brightness it
        -- would be the most legible thing on a button that is greyed out
        -- precisely to say you are not carrying it, so the row of words would
        -- read as the row of boons you have.
        button.label:SetAlpha(alpha)

        -- The mark is a property of the boon rather than of what is in the
        -- bags, so it is drawn on an unowned melee boon too - faded with the
        -- icon it is around, or it would be the brightest thing on a button
        -- that is otherwise greyed out.
        local marked = not MELEE_MARK_SHELVED
            and cfg.markMelee and entry and entry.melee and button.itemID ~= nil
        for _, edge in pairs(button.meleeMark) do
            if marked then
                edge:SetAlpha(alpha)
                edge:Show()
            else
                edge:Hide()
            end
        end

        if record and record.count > 1 then
            button.count:SetText(tostring(record.count))
            button.count:Show()
        else
            button.count:Hide()
        end

        if not record then SetCooldown(button, 0, 0, 0) end
    end

    PollCooldowns()
    UpdateGlow()

    -- Last, so it measures what the alpha pass above just decided.
    SizeBarToRevealed()
end

-- A boon was just spent. Shared by the icon's own click and by the cycle key,
-- which fire the same item through two different buttons and must leave the
-- addon in the same state afterwards.
--
-- Returns false when the click cannot have used anything, which is what the
-- cycler needs to know before it counts a press as a use.
local function NoteUsed(button)
    local record = button and button.itemID and owned[button.itemID]
    if not record then return false end

    if caps.itemCooldown then
        local ok, start, duration, enable = pcall(_G.GetItemCooldown, button.itemID)
        -- A boon that is already on cooldown was not used, so there is nothing
        -- to propagate and nothing to take out of the bags. The 0.01 window is
        -- the reference's: a cooldown that started this instant is the one this
        -- click just caused.
        if ok and duration and duration > 0 and (GetTime() - (start or 0)) >= 0.01 then
            return false
        end
        if ok then PropagateCooldown(start, duration, enable) end
    end

    -- Taken out of the local picture without waiting for the bag event, so the
    -- icon goes grey on the click rather than a tenth of a second later. The
    -- next rebuild is authoritative either way, so being wrong here costs one
    -- refresh and not a stuck button.
    --
    -- slots[1] rather than any slot, and slots are sorted oldest first, so two
    -- of the same boon spend the one that was about to rot.
    if #record.slots <= 1 then
        owned[button.itemID] = nil
        ownedCount = math.max(0, ownedCount - 1)
    else
        local place = table.remove(record.slots, 1)
        record.count = math.max(1, record.count - 1)
        if place then bornAt[SlotKey(button.itemID, place.bag, place.slot)] = nil end
    end

    RefreshVisuals()

    -- Deliberately not a full Refresh. That would re-read the bags, and the
    -- server has not taken the boon out of them yet - so the icon would light
    -- straight back up and go out again a tenth of a second later when the bag
    -- event lands. QueueSecure runs inline when the player is not fighting, so
    -- the button is unbound now either way.
    QueueSecure("boon used")
    return true
end

--------------------------------------------------------------------------------
-- Visibility
--
-- The default is the check the client's own UI makes: a party instance at
-- dungeon difficulty 3. "Show only in Mythic dungeons" off turns that check
-- into nothing, which is how the bar gets positioned somewhere other than
-- mid-run.
--
-- The difficulty comes from GetInstanceInfo first and GetDungeonDifficulty only
-- as the fallback, which is the order Dungeon.lua already uses. They are not
-- the same question: GetInstanceInfo answers for the instance the player is
-- standing in, while GetDungeonDifficulty answers for the difficulty selector -
-- and a key run is entered through the keystone rather than through that
-- dropdown, so the selector can still read normal or heroic inside a Mythic.
-- The client's own boon UI asks the selector and that is the bug being copied:
-- the bar hid itself mid-key while the Mythic+ panel beside it drew a +15.
--
-- IsInInstance returns 1 rather than true on this client, so it is tested for
-- truth rather than compared - a build that returns a boolean must not turn the
-- bar off.
--------------------------------------------------------------------------------

-- The instance the player is in: whether it is a party instance, and at what
-- difficulty index. Either half may come back nil on a build that answers one
-- call and not the other.
local function InstanceState()
    local instanceType, difficulty

    if type(_G.GetInstanceInfo) == "function" then
        local ok, _, kind, index = pcall(_G.GetInstanceInfo)
        if ok then
            if type(kind) == "string" and kind ~= "" then instanceType = kind end
            difficulty = tonumber(index)
        end
    end

    if instanceType == nil and type(_G.IsInInstance) == "function" then
        local ok, inInstance, kind = pcall(_G.IsInInstance)
        if ok and inInstance and inInstance ~= 0 then instanceType = kind end
    end

    if difficulty == nil and type(_G.GetDungeonDifficulty) == "function" then
        local ok, index = pcall(_G.GetDungeonDifficulty)
        if ok then difficulty = tonumber(index) end
    end

    return instanceType, difficulty
end

local function InMythicDungeon()
    local instanceType, difficulty = InstanceState()
    if instanceType ~= "party" then return false end
    return difficulty == 3
end

function ShouldShow()
    if not boons.IsEnabled() then return false end

    local cfg = Config()
    if cfg.mythicOnly and not InMythicDungeon() then return false end
    if cfg.hideEmpty and ownedCount == 0 then return false end
    return true
end

-- Show or hide the container.
--
-- The alpha lands whatever is happening, and the Show/Hide is deferred if the
-- player is fighting. The container itself is a plain frame and hiding it in
-- combat is very probably fine - it is not protected, only its children are -
-- but "very probably" is not a thing to find out from an error report in the
-- middle of a key, and the alpha alone is enough to get the bar out of the way
-- on time. It is the same split Skin.lua makes for hiding the quest tracker,
-- for the same reason.
--
-- The cost is that in combat the buttons are invisible rather than gone, and a
-- secure button cannot have its mouse turned off in combat either. So a hidden
-- bar keeps its click targets until the fight ends. In practice the bar is
-- hidden because the player left the dungeon or ran out of boons, and neither
-- happens mid-fight.

-- Whether the bar was something to hang off at the end of the last pass.
--
-- The quest tracker can be set to follow the Mythic+ panel, and when this bar
-- is doing the same it chains under the bar rather than landing on top of it -
-- see the anchor notes in Skin.lua. Which frame it picks depends on the answer
-- below, so a change to it is a moment that tracker has to be told about.
--
-- Announced on the transition rather than on every pass, because the bar
-- re-lays itself out on a ticker while a key is up and the chain is a SetPoint
-- against this frame: a bar that has merely grown a row taller carries whatever
-- hangs off it down with it, and needs no second call.
local anchorHostNotified = false

local function NoteAnchorHost()
    local host = boons.IsAnchorHost()
    if host == anchorHostNotified then return end
    anchorHostNotified = host
    ns:Fire("HEROPANEL_BOONBAR_ANCHOR", host)
end

local function ApplyVisibility()
    if not bar then return end

    local show = ShouldShow()
    bar:SetAlpha(show and 1 or 0)

    if InCombatLockdown() then
        -- Showing is allowed; hiding still waits.
        --
        -- The two directions are not the same problem. A bar that cannot appear
        -- during a fight cannot do its one job during a fight: with "hide when
        -- you have none" ticked, the pull starts with the bar hidden - which
        -- is the normal way a pull starts, since the crystal has not been
        -- clicked yet - and every boon looted after that lit its icon inside a
        -- frame nobody could see. Alpha was 1, the button was drawn and
        -- clickable, and the container was still Hidden.
        --
        -- The frame this shows is heroPanel's own plain container, not one of
        -- the secure buttons inside it. Show and Hide are refused on protected
        -- frames and the container is not one - measured with IsProtected
        -- rather than reasoned from its parentage, which is what this comment
        -- used to do. Protection does not descend the parent chain on this
        -- client: UIParent is protected and heroPanel's frames under it are
        -- not. See Util.lua. It is pcall'd all the same: if some
        -- build disagrees, the cost of being wrong here should be a bar that
        -- appears late rather than an error in the middle of a key.
        if show then pcall(bar.Show, bar) end
        QueueSecure("visibility")
    elseif show then
        bar:Show()
    else
        bar:Hide()
    end

    -- Both pollers follow the bar. A hidden bar has nothing to draw a swipe on
    -- and nothing to glow, and a boon that expires while the bar is away is one
    -- the next Refresh will notice.
    for _, poller in ipairs({ ticker, expiryTicker }) do
        if poller then
            if show and not poller:IsRunning() then
                poller:Start()
            elseif not show and poller:IsRunning() then
                poller:Stop()
            end
        end
    end

    if not show then
        for button in pairs(glowing) do
            glowing[button] = nil
            HideGlow(button)
        end
        if glowDriver then glowDriver:Hide() end
    end

    -- Last, so anything asking what the bar is now gets the state it is in
    -- rather than the one it was in before this pass. Every boons.Refresh path
    -- ends here, in and out of combat.
    NoteAnchorHost()
end

--------------------------------------------------------------------------------
-- Bar order and keybind slots
--
-- The button pool is fixed and each button belongs to one boon for the life of
-- the session - that is what makes it safe under combat lockdown. What can
-- change out of combat is the order they are *drawn* in, and which of them the
-- five keybind slots point at.
--
-- Two orders:
--
--   default     the boons in category order, every one of them always in the
--               same place. The bar's main virtue: you aim at an icon rather
--               than reading the bar.
--   slot order  the boons you are actually carrying first, then the rest. The
--               five keybind slots then always point at something usable, at
--               the cost of the bar rearranging itself as boons are looted and
--               spent. Recomputed out of combat only, like everything else
--               that moves a secure button.
--
-- Anchoring implies slot order
-- ----------------------------
-- A bar hanging under the Mythic+ panel is a strip of the panel rather than a
-- thing of its own, and fifteen icons is wider than that panel. So anchoring
-- also packs: only the boons you are holding are drawn, hard against the
-- panel's left edge, which makes the nth icon the nth keybind slot and the nth
-- step of the cycle key. That is the whole of what "slots 1-5" means here - the
-- positions are the slots.
--
-- It is stated as a consequence of anchoring rather than as a fourth checkbox
-- because the two are the same request: somebody who wants the bar tucked under
-- the panel wants it panel-sized, and a version where they had to find and tick
-- two more boxes to get that would be a version where the anchor setting looks
-- broken on its own.
--
-- Nothing is capped at five. Five is what the keybinds reach and what anybody
-- ever holds, but a sixth boon still gets an icon: hiding a boon the player is
-- carrying, on the bar whose job is to say what they are carrying, would be the
-- one failure this feature cannot afford.
--------------------------------------------------------------------------------

-- Whether held boons come first. Read through a function rather than off the
-- config directly because there are now two ways to ask for it, and three
-- callers that must all get the same answer.
local function SlotOrdered()
    return (Config().slotOrder and true or false) or boons.IsAnchored()
end

-- Whether unowned boons are drawn at all.
function OwnedOnly()
    return (Config().hideUnowned and true or false) or boons.IsAnchored()
end

local function BarOrder()
    if not SlotOrdered() then return buttons end

    local order, rest = {}, {}
    for i = 1, #buttons do
        local button = buttons[i]
        if button.itemID and owned[button.itemID] then
            table.insert(order, button)
        else
            table.insert(rest, button)
        end
    end
    for i = 1, #rest do table.insert(order, rest[i]) end
    return order
end

-- The held boons, left to right, which is what the cycle key walks. Empty when
-- nothing is held, and that is a state the cycler has to be told about rather
-- than left to guess - see LoadCycler.
local function CycleOrder()
    local order, held = BarOrder(), {}
    for i = 1, #order do
        local button = order[i]
        if button.itemID and owned[button.itemID] then
            table.insert(held, button)
        end
    end
    return held
end

-- The button each keybind slot fires, or nil for a slot with nothing behind it.
--
-- In slot order a slot is only ever given a boon that is in the bags, so slot 3
-- with two boons held is deliberately empty - a key that fires an empty slot is
-- better than one that fires a boon you cannot use, because the second teaches
-- you to distrust the keys.
--
-- Otherwise a slot is simply the nth icon on the bar, which is fixed for the
-- session and so can be learned.
local function SlotButtons()
    local order, slots = BarOrder(), {}

    if SlotOrdered() then
        for i = 1, #order do
            local button = order[i]
            if button.itemID and owned[button.itemID] then
                slots[#slots + 1] = button
                if #slots >= SLOT_COUNT then break end
            end
        end
    else
        for i = 1, math.min(SLOT_COUNT, #order) do slots[i] = order[i] end
    end

    return slots
end

--------------------------------------------------------------------------------
-- Layout
--
-- Out of combat only, because SetPoint, Show and Hide on a secure button are
-- all refused under lockdown. Nothing here is allowed to run from a bag event
-- during a fight; ApplySecure is the only caller and it is guarded.
--
-- Three groups, one per category, with a wider gap between them than within
-- them - the categories are how a player thinks about which boon to reach for,
-- and fifteen evenly spaced icons is a row you have to read rather than one you
-- can aim at. Unknown boons form a fourth group on the end.
--
-- Laid out in cells rather than in icons. A cell is one icon plus the band its
-- caption sits in, and it is what wraps, what the gaps go between and what the
-- bar is measured in. Doing it that way is what keeps the captions, the row
-- wrap and the two orientations from each needing their own arithmetic: a
-- caption grows the cell across the bar in one orientation and along it in the
-- other, and every line below that number is the same either way.
--------------------------------------------------------------------------------

-- Whether the captions are drawn, and how much room they need.
--
-- Asked through functions rather than read off the config at each site, because
-- the layout, the sizing and the restyle all have to get the same answer, and
-- the height is arithmetic on a font size the options window can change under
-- any of them.
local function LabelsOn()
    return Config().labels and true or false
end

local function LabelFontSize()
    return ns.GetFontSize(-2, "mplusBody")
end

-- The band one caption occupies across the cell: the text plus its gap to the
-- icon. Zero when the captions are off, which is what makes every piece of
-- geometry below fall back to what it was before this existed.
local function LabelBand()
    if not LabelsOn() then return 0 end
    return Int(LabelFontSize()) + 2 + LABEL_GAP
end

-- How many icons go in a row before the bar wraps, or nil for one long row.
local function RowLength()
    local cfg = Config()
    if not cfg.splitRows then return nil end
    return Int(ns.Clamp(cfg.rowSize or 8, ROW_MIN, ns.BOON_ROW_MAX))
end

local function Layout()
    if not bar or InCombatLockdown() then return end

    local cfg         = Config()
    local size        = ns.Clamp(cfg.iconSize or 32, ICON_MIN, ICON_MAX)
    local vertical    = (cfg.orientation == "vertical")
    local hideUnowned = OwnedOnly()
    local slotOrder   = SlotOrdered()

    local labels      = LabelsOn()
    local labelBand   = LabelBand()
    local labelAbove  = (cfg.labelAnchor ~= "below")
    local perRow      = RowLength()

    -- Sample slots, while the Mythic+ panel is in placement preview.
    --
    -- Anchoring packs the bar down to the boons you are actually holding, and
    -- outside a key you are holding none - so the anchored bar drew nothing at
    -- exactly the moment it most needs to be seen. Preview exists to place this
    -- stuff from a capital city; an anchored bar that is invisible there cannot
    -- be placed at all, and reads as the anchor setting being broken.
    --
    -- The panel already fakes a run for this, so the bar fakes a hand of boons
    -- to match. Five, because five is what the keybinds reach and so is the
    -- width the bar has in the case worth positioning for. They draw greyed,
    -- like any boon you are not carrying, which is what says they are stand-ins
    -- rather than a bar that has gone wrong.
    local sample = 0
    if boons.IsAnchored() and ownedCount == 0
        and ns.Mplus and ns.Mplus.IsPreview and ns.Mplus.IsPreview() then
        sample = SLOT_COUNT
    end

    local order = BarOrder()

    ------------------------------------------------------------------
    -- The cell
    --
    -- A caption in a vertical bar sits where the next icon in the column would
    -- be, so it makes the cell longer. The same caption in a horizontal bar is
    -- beside the row rather than in it, so it makes the cell thicker instead.
    -- That is the only place the two orientations differ here.
    ------------------------------------------------------------------

    local cellMain  = vertical and (size + labelBand) or size
    local cellCross = vertical and size or (size + labelBand)

    -- A caption can be wider than the icon it names. In a horizontal bar that
    -- costs nothing - it overhangs into the gap either side, which is what the
    -- key label on every action bar already does - but in a vertical one it
    -- overhangs the bar's own edge, so the column widens to the longest word
    -- and the icons centre in it.
    --
    -- Measured across every button rather than only the drawn ones, so the
    -- column does not change width as boons are looted and spent. A bar that
    -- breathes sideways every time you pick something up is the thing the
    -- corner anchor was introduced to stop.
    if vertical and labels then
        for i = 1, #buttons do
            local label = buttons[i].itemID and buttons[i].label
            local width = label and label:GetStringWidth() or 0
            if width > cellCross then cellCross = math.ceil(width) end
        end
    end

    -- Where the icon sits inside its cell. The caption takes the other end.
    local iconMain  = (vertical and labelAbove) and labelBand or 0
    local iconCross = vertical
        and math.floor((cellCross - size) / 2)
        or  (labelAbove and labelBand or 0)

    local along, across = BAR_PAD, BAR_PAD
    local lastGroup, inRow, placed = nil, 0, 0

    -- Putting one button on a cell whose position is already known. Records how
    -- far it reaches on both axes, because that is what the sizing pass
    -- measures - it cannot re-run any of this arithmetic while the player is
    -- fighting.
    --
    -- Split out from Place so the parked pass can put more than one button on
    -- the same cell without walking the cursor along the grid each time. See
    -- the reserve note at the top of the file for why it wants to.
    local function PlaceAt(button, atAlong, atAcross)
        button:ClearAllPoints()
        if vertical then
            button:SetPoint("TOPLEFT", bar, "TOPLEFT",
                atAcross + iconCross, -(atAlong + iconMain))
        else
            button:SetPoint("TOPLEFT", bar, "TOPLEFT",
                atAlong, -(atAcross + iconCross))
        end
        button:Show()

        button.layoutEdge  = atAlong  + cellMain
        button.layoutCross = atAcross + cellCross
    end

    -- The next cell along, and the button that goes on it. Returns where it
    -- landed, so a cell can be handed to the parked pass to be shared.
    local function Place(button, group)
        -- A row that has filled up starts the next one flush against the bar's
        -- own edge, with no group gap carried into it: a gap at the start of a
        -- row is an indent rather than a separator, and it would put the first
        -- icon of every row in a different place.
        if perRow and inRow >= perRow then
            along, inRow, lastGroup = BAR_PAD, 0, nil
            across = across + cellCross + ROW_GAP
        end

        if lastGroup and group ~= lastGroup then along = along + GROUP_GAP end
        lastGroup = group

        local atAlong, atAcross = along, across
        PlaceAt(button, atAlong, atAcross)

        along = along + cellMain + ICON_GAP
        inRow = inRow + 1

        return atAlong, atAcross
    end

    local parked = {}

    for i = 1, #order do
        local button  = order[i]
        local visible = button.itemID ~= nil
            and (not hideUnowned or owned[button.itemID] ~= nil)

        if not visible and button.itemID and placed < sample then
            visible = true
            button.sampled = true
        else
            button.sampled = nil
        end

        button:SetWidth(size)
        button:SetHeight(size)

        -- The caption is anchored to its own button, so it follows the icon
        -- wherever the pass below puts it and needs no placing of its own. What
        -- has to be re-stated here is which side of the icon it sits on, since
        -- that is a setting and can have just changed.
        button.label:ClearAllPoints()
        if labelAbove then
            button.label:SetPoint("BOTTOM", button, "TOP", 0, LABEL_GAP)
        else
            button.label:SetPoint("TOP", button, "BOTTOM", 0, -LABEL_GAP)
        end
        if labels and button.itemID then button.label:Show() else button.label:Hide() end

        if visible then
            -- What the gap separates. Normally the three categories, which is
            -- how a player thinks about which boon to reach for. In slot order
            -- it is the boons you are carrying from the ones you are not, since
            -- that is the division the keybinds follow and drawing the category
            -- gaps as well would put three arbitrary breaks inside your slots.
            local group
            if slotOrder then
                group = (owned[button.itemID] ~= nil) and "owned" or "rest"
            else
                group = button.entry and button.entry.cat or 0
            end

            Place(button, group)
            button:SetAlpha(1)
            SetClickable(button, true)
            placed = placed + 1

        elseif hideUnowned and button.itemID then
            -- Parked, not hidden. See the note above the parked pass.
            parked[#parked + 1] = button
        else
            button.layoutEdge, button.layoutCross = nil, nil
            button:Hide()
        end
    end

    ----------------------------------------------------------------
    -- The parked pass
    --
    -- Hide-unowned used to call button:Hide() on everything you were not
    -- carrying, and that is why a boon looted mid-fight did not appear. Hide
    -- and SetPoint are both refused on a SecureActionButtonTemplate under
    -- lockdown, so the bar could not draw the new boon until the fight ended -
    -- what the player got was heroPanel's empty rectangle and no icon, while
    -- everything unprotected about the boon updated correctly underneath. It
    -- read as a missing texture and was nothing of the kind: the art has been
    -- on the button since login.
    --
    -- So the buttons stay shown and positioned, and alpha does the hiding.
    -- SetAlpha is not protected, which means RefreshVisuals can reveal a boon
    -- the instant it is looted, in the middle of a pull, with its real icon.
    --
    -- They share a short run of reserve cells immediately after the drawn run,
    -- continuing the same grid, so whatever is revealed lands within a few
    -- cells of the pack rather than wherever its own position in bar order
    -- happens to fall. See the reserve note at the top of the file: parking one
    -- button per cell put a boon looted mid-fight out beyond the end of the bar
    -- and is why the reveal still read as broken after the reveal itself
    -- worked.
    --
    -- The bar is still sized to the drawn run, so none of this shows until
    -- something is revealed - and then the sizing pass grows it into the
    -- reserve.
    --
    -- Out of the input path while parked, because an invisible button that
    -- still takes clicks is a click the world behind it never sees.
    --
    -- Done with the hit rect and not with EnableMouse. The mouse being off was
    -- the older spelling of this and it could not be undone in combat, so a
    -- boon revealed mid-pull was drawn and then took no clicks and showed no
    -- tooltip. See the note on SetClickable.
    ----------------------------------------------------------------
    local reserve = {}
    for i = 1, #parked do
        local button = parked[i]
        local cell   = ((i - 1) % RESERVE_CELLS) + 1
        local spot   = reserve[cell]

        if spot then
            PlaceAt(button, spot[1], spot[2])
        else
            local atAlong, atAcross = Place(button, "rest")
            reserve[cell] = { atAlong, atAcross }
        end

        button:SetAlpha(0)
        SetClickable(button, false)
    end

    -- A bar with nothing in it still needs a rectangle, or the drag handle and
    -- the resize grip have nothing to sit on. This is what "hide unowned" plus
    -- an empty bag comes out as, and it is reachable on purpose: the player can
    -- still find and move the bar.
    layout.vertical     = vertical
    layout.minExtent    = cellMain  + BAR_PAD * 2
    layout.minThickness = cellCross + BAR_PAD * 2

    -- The bar's own rectangle is measured rather than computed here. See the
    -- note on SizeBarToRevealed: the alphas set above are what say which cells
    -- are drawn, and one piece of code reading them is one answer.
    SizeBarToRevealed()

    ns.StylePlateChrome(bar, ns.PanelStyle("mplus"))
    if bar.grip then bar.grip:Raise(nil, bar:GetFrameLevel()) end
end

--------------------------------------------------------------------------------
-- Keybinds
--
-- Override bindings rather than SetBindingClick, which is what the action bar
-- libraries on this client reach for. SetBindingClick writes the player's own
-- binding set, so heroPanel would be editing a file it does not own and would
-- have to put it back; SetOverrideBindingClick is scoped to an owner frame and
-- ClearOverrideBindings takes the whole lot away again, which is what turning
-- the feature off has to do.
--
-- The bindings themselves are declared in Bindings.xml so they appear in the
-- client's own Key Bindings window and the key the player picks is saved by the
-- client. The declared action is a fallback that only ever runs when no
-- override is installed - the bar being switched off - and says so rather than
-- doing nothing, because a key that silently does nothing reads as a broken
-- addon.
--
-- Both calls are protected, so this goes through the same deferral as the rest
-- of the secure work.
--
-- Five slots rather than one binding per boon. Fifteen rows in the Key Bindings
-- window is a list nobody reads to the bottom of, and nobody is carrying
-- fifteen boons - so a slot points at whatever is in that position on the bar,
-- and "line boons up in the slots" makes the first five slots the five boons
-- you actually have.
--------------------------------------------------------------------------------

-- The bound key, short enough to sit in the corner of a 32px icon.
--
-- The same abbreviations every action bar addon on this client uses, because
-- they are the ones a player already reads without thinking: s- for shift, c-
-- for control, a- for alt, and the mouse and numpad names cut to something that
-- fits.
-- An ordered list rather than a keyed table, and the order is load-bearing:
-- BACKSPACE contains SPACE, and MOUSEWHEELUP contains neither but would be cut
-- to nonsense by a stray pass. pairs() walks a table in whatever order it likes,
-- so a keyed version of this abbreviates the same key differently on different
-- logins. Longest match first, always.
local KEY_SHORT = {
    { "SHIFT%-", "s-" }, { "CTRL%-", "c-" }, { "ALT%-", "a-" },
    { "MOUSEWHEELUP", "mwu" }, { "MOUSEWHEELDOWN", "mwd" },
    { "BACKSPACE", "bs" }, { "SPACE", "sp" },
    { "PAGEUP", "pu" }, { "PAGEDOWN", "pd" },
    { "INSERT", "ins" }, { "DELETE", "del" },
    { "NUMPAD", "n" }, { "BUTTON", "m" },
    { "HOME", "hm" }, { "END", "end" },
}

local function AbbreviateKey(key)
    if type(key) ~= "string" then return "" end
    local short = key
    for i = 1, #KEY_SHORT do
        short = string.gsub(short, KEY_SHORT[i][1], KEY_SHORT[i][2])
    end
    return short
end

--------------------------------------------------------------------------------
-- The cycle key
--
-- One key that fires the next boon you are carrying, left to right along the
-- bar and round to the start again. Five slot keys are direct access - slot 2
-- is always slot 2 - and this is sequential: press it, get a boon, press it
-- again, get the next one. Holding three boons then needs one key rather than
-- three, and the key does not have to be re-learned when the bar reorders.
--
-- Why it needs its own button
-- ---------------------------
-- The obvious implementation is to re-point the override binding at whichever
-- icon is next, from ordinary Lua, on every press. That works out of combat and
-- is useless in it: SetOverrideBindingClick is protected, so the key would
-- freeze on whatever it pointed at when the pull started, and boons are used in
-- combat.
--
-- So the key is bound once, to one hidden secure button that never moves, and
-- the *choice* is made inside it. The button carries the whole list of held
-- boons as attributes - boonSlot1..n, each a "<bag> <slot>" string - plus a
-- count and the index it last fired. A snippet wrapped around its OnClick reads
-- those, picks the next non-empty entry and writes it into `item` before the
-- click resolves.
--
-- That snippet runs in the restricted environment, which is the one place the
-- client permits SetAttribute during combat. This is the piece of work the
-- header comment used to carry as a TODO.
--
-- What is still frozen
-- --------------------
-- The list itself. Writing boonSlot1..n is ordinary Lua and so is refused in
-- combat like everything else, which means the cycle key reaches every boon you
-- were holding when the fight started and not one looted during it. That is the
-- same limitation the rest of the bar has and it is a much smaller one than
-- five keys frozen to five positions.
--
-- A boon spent mid-fight leaves its bag slot empty and the snippet goes on
-- offering it. In practice that costs nothing: boons share a cooldown, so by
-- the time a second press is worth making the index has moved on to a slot that
-- is still full, and the dead entry is only reached again after a full lap.
--------------------------------------------------------------------------------

local CYCLE_SNIPPET = [[
    local count = tonumber(self:GetAttribute("boonCount")) or 0
    if count < 1 then
        self:SetAttribute("type", "")
        self:SetAttribute("item", "")
        return
    end

    local index = tonumber(self:GetAttribute("boonIndex")) or 0

    for step = 1, count do
        local try = index + step
        while try > count do
            try = try - count
        end

        local place = self:GetAttribute("boonSlot" .. try)
        if place and place ~= "" then
            self:SetAttribute("boonIndex", try)
            self:SetAttribute("type", "item")
            self:SetAttribute("item", place)
            return
        end
    end

    self:SetAttribute("type", "")
    self:SetAttribute("item", "")
]]

-- What the cycler was last loaded with. Compared rather than blindly rewritten
-- so that a bag event which does not change the boon list - moving a potion
-- around, on the BAG_UPDATE path where every change costs a rebuild - does not
-- reset the cycle position back to the first boon.
local cycleSignature

local function LoadCycler()
    if not cycler or InCombatLockdown() then return end

    local held, places = CycleOrder(), {}
    for i = 1, #held do
        local record = owned[held[i].itemID]
        local place  = record and record.slots[1]
        places[i] = place and string.format("%d %d", Int(place.bag), Int(place.slot)) or ""
    end

    -- Cleared past the end as well as written up to it, or a list that has just
    -- got shorter would leave the tail of the previous one behind and the
    -- snippet would eventually offer a boon that has been gone for a minute.
    for i = 1, #buttons do
        SetSecureAttribute(cycler, "boonSlot" .. i, places[i] or "")
    end
    SetSecureAttribute(cycler, "boonCount", #held)

    local signature = table.concat(places, "|")
    if signature ~= cycleSignature then
        cycleSignature = signature
        SetSecureAttribute(cycler, "boonIndex", 0)
    end
end

-- Which icon the cycle key would fire next.
--
-- Read back off the button rather than tracked alongside it, because in combat
-- the snippet is the only thing that moves the index and its attribute is the
-- only record of where it got to. Reading an attribute is not protected.
local function CycleNextButton()
    local held = CycleOrder()
    if #held == 0 then return nil end

    local index = 0
    if cycler then
        local ok, value = pcall(cycler.GetAttribute, cycler, "boonIndex")
        if ok then index = tonumber(value) or 0 end
    end

    local target = index + 1
    while target > #held do target = target - #held end
    return held[target]
end

-- Which icon the cycle key just fired. The snippet leaves the index it chose
-- behind in the attribute, so after a press that is where it landed.
local function CycleFiredButton()
    if not cycler then return nil end

    local held = CycleOrder()
    local ok, value = pcall(cycler.GetAttribute, cycler, "boonIndex")
    local index = (ok and tonumber(value)) or 0

    if index < 1 or index > #held then return nil end
    return held[index]
end

-- A thin accent bar under the icon the cycle key would fire next.
--
-- Under rather than around: the icon already carries a border for the melee
-- mark and an orbit for the expiry glow, and a third ring would be a button
-- with three frames on it. Drawn only when the key is actually bound - a marker
-- for a key nobody has set is a mark on the bar that means nothing.
local function ApplyCycleMark()
    local target = GetBindingKey("HEROPANEL_BOON_CYCLE") and CycleNextButton() or nil

    for i = 1, #buttons do
        local button = buttons[i]
        if button.cycleMark then
            if button == target then button.cycleMark:Show() else button.cycleMark:Hide() end
        end
    end
end

local function BuildCycler()
    if not caps.secureButtons then return end

    -- SecureHandlerBaseTemplate is what SecureHandlerWrapScript needs to attach
    -- a snippet to. Asked for only when the client has the wrap function, so a
    -- build without it gets a plain secure button and the out-of-combat
    -- fallback rather than a frame that fails to create.
    local template = caps.secureHandlers
        and "SecureActionButtonTemplate,SecureHandlerBaseTemplate"
        or  "SecureActionButtonTemplate"

    local ok, button = pcall(CreateFrame, "Button", "HeroPanelBoonCycler", UIParent, template)
    if not (ok and type(button) == "table" and type(button.SetAttribute) == "function") then
        ns.Debug("boons: the cycle button would not build; the cycle key will "
            .. "fall back to the first held boon.")
        return
    end

    cycler = button

    -- Present but invisible and unclickable. It exists to be clicked by the
    -- binding system and by nothing else, so it takes no mouse and draws
    -- nothing - but it is left shown, because it is a click target and hiding
    -- click targets is how they stop being ones.
    cycler:SetWidth(1)
    cycler:SetHeight(1)
    cycler:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
    cycler:SetAlpha(0)
    cycler:EnableMouse(false)
    pcall(cycler.RegisterForClicks, cycler, "AnyUp")
    SetSecureAttribute(cycler, "type", "")
    SetSecureAttribute(cycler, "item", "")
    SetSecureAttribute(cycler, "boonCount", 0)
    SetSecureAttribute(cycler, "boonIndex", 0)

    if caps.secureHandlers then
        cycler.snippet = pcall(_G.SecureHandlerWrapScript,
            cycler, "OnClick", cycler, CYCLE_SNIPPET)
        if not cycler.snippet then
            ns.Debug("boons: the cycle snippet would not install; the cycle key "
                .. "will not advance during combat.")
        end
    end

    -- The insecure half of a press. The snippet has already chosen and fired by
    -- the time this runs, and it left the index it used behind - so the button
    -- that went off is the one at that index, and the bookkeeping the icon's
    -- own click does has to happen here too.
    pcall(cycler.HookScript, cycler, "PostClick", function(self)
        -- The snippet blanks `type` when it could not find a boon to fire, so
        -- this is how a press that did nothing is told from one that spent
        -- something. Without it, pressing the key with an empty bar would count
        -- as a use and take a boon out of the local picture that was never
        -- there.
        local ok, kind = pcall(self.GetAttribute, self, "type")
        if ok and kind == "item" then NoteUsed(CycleFiredButton()) end
        ApplyCycleMark()
    end)
end

local function ApplyBindings()
    if not (bar and caps.secureButtons) or InCombatLockdown() then return end

    -- Cleared on every pass rather than only where one is set, so a slot that
    -- has just lost its boon does not keep the key label of the boon that used
    -- to be there.
    for i = 1, #buttons do buttons[i].hotkey:SetText("") end

    if caps.overrideBinds then pcall(_G.ClearOverrideBindings, bar) end
    if not boons.IsEnabled() then return end

    local slots = SlotButtons()
    for slot = 1, SLOT_COUNT do
        local button = slots[slot]
        if button then
            local key1, key2 = GetBindingKey("HEROPANEL_BOON" .. slot)
            if key1 then button.hotkey:SetText(AbbreviateKey(key1)) end

            if caps.overrideBinds then
                if key1 then
                    pcall(_G.SetOverrideBindingClick, bar, true, key1,
                        button:GetName(), BIND_CLICK)
                end
                if key2 then
                    pcall(_G.SetOverrideBindingClick, bar, true, key2,
                        button:GetName(), BIND_CLICK)
                end
            end
        end
    end

    ----------------------------------------------------------------------
    -- The cycle key.
    --
    -- Bound to the cycler, once, and never re-pointed: the choice of which
    -- boon it fires is made inside the button by the snippet, which is what
    -- lets it keep working through a fight.
    --
    -- Without a snippet - a client with no SecureHandlerWrapScript, or one
    -- where the wrap refused - the key is pointed straight at the leftmost
    -- held boon instead. That still cycles out of combat, because a boon
    -- that is used leaves the bags and the next one becomes leftmost; it
    -- simply stops advancing once a fight starts, exactly like the five
    -- slot keys do.
    ----------------------------------------------------------------------

    local target = (cycler and cycler.snippet) and cycler or CycleNextButton()

    if caps.overrideBinds and target then
        local key1, key2 = GetBindingKey("HEROPANEL_BOON_CYCLE")
        if key1 then
            pcall(_G.SetOverrideBindingClick, bar, true, key1,
                target:GetName(), BIND_CLICK)
        end
        if key2 then
            pcall(_G.SetOverrideBindingClick, bar, true, key2,
                target:GetName(), BIND_CLICK)
        end
    end

    ApplyCycleMark()
end

-- Reached from Bindings.xml when a bound key fires without an override behind
-- it, which means the bar is off. Public because the XML calls it by name.
function boons.BindingFallback(index)
    if boons.IsEnabled() then
        -- The one case that reaches here with the bar switched on and is not a
        -- fault: the cycle key on a client with no snippet, with nothing in the
        -- bags to point it at. There is no override installed because there is
        -- no boon for it to fire.
        if index == "cycle" and ownedCount == 0 then
            ns.Debug("boons: the cycle key fired with no boons held.")
            return
        end

        -- An override should have caught this. Say so rather than nothing: it
        -- means the binding was installed while the key was already down, or
        -- the client has no override binding API at all.
        ns.Debug("boons: binding %s fired without an override.", tostring(index))
        return
    end
    ns.Print("the boon bar is off - turn it on in |cFFC2C6D8/hp|r, or with "
        .. "|cFFC2C6D8/hp boons on|r.")
end

--------------------------------------------------------------------------------
-- Saying it in chat
--
-- Shift and left-click a boon and heroPanel says how long that boon has before
-- it expires, instead of using it. The question the gesture answers is the one
-- that gets asked out loud in a key - "how long have you got" - and the answer
-- is worth more to the party than to the person holding the boon.
--
-- The expiry and not the shared use cooldown. They are two different clocks and
-- only one of them is anybody else's business: the cooldown is already drawn as
-- a swipe on the icon in front of you, while how long your boon has left is the
-- thing nobody else can see.
--
-- The click is stopped by the secure attribute set in ApplySecure, not here.
-- This runs from the ordinary hook afterwards, by which point the client has
-- already declined to use anything.
--
-- Throttled, and the throttle is not optional: this is one click, it goes in
-- four other people's chat windows, and a feature that lets somebody flood
-- their own group by holding shift is a feature that gets the addon banned from
-- the group rather than turned off.
--------------------------------------------------------------------------------

local lastReport = 0

-- Returns sent, detail - the same shape Keys.Announce uses, so the slash
-- command and the debug line can both say why nothing happened.
local function ReportDuration(button)
    local entry = button and button.entry
    local name  = (entry and entry.name) or "Mythical Boon"

    -- How long the boon has before it expires, which is the whole of what this
    -- reports. Not the shared use cooldown: that is a different clock and a
    -- different question, and the swipe on the icon already answers it for the
    -- person holding the boon.
    --
    -- Said plainly when it is not known rather than guessed at or left off. A
    -- report that silently drops the number reads as the boon having no timer,
    -- which is the one wrong idea this must not put in four other people's chat.
    local life = button and RemainingLife(button.itemID)
    local message = life
        and string.format("Boons: %s expires in %s", name, FormatSpan(life))
        or  string.format("Boons: %s, duration unknown", name)

    local now = GetTime()
    if lastReport > 0 and (now - lastReport) < REPORT_THROTTLE then
        return false, "throttled"
    end
    lastReport = now

    local sent = SendToGroup(message)
    if sent then return true, message end

    if sent == false then
        -- The send refused. Say it locally rather than silently: the player
        -- made a deliberate gesture and got nothing back.
        ns.Print(message)
        return false, "SendChatMessage refused"
    end

    -- Solo, or a client with no SendChatMessage. Still worth answering - the
    -- gesture is also how you ask yourself.
    ns.Print(message)
    return true, message
end

--------------------------------------------------------------------------------
-- The secure pass
--
-- Everything the client refuses in combat, in one place, called through
-- QueueSecure so it is deferred as a unit. Binding attributes, spare
-- assignment, layout, visibility and keybinds all have to agree with each
-- other, and running them separately is how they end up disagreeing.
--------------------------------------------------------------------------------

-- Give any unknown boon a spare button, so a boon a later build adds is usable
-- rather than merely detected.
local function AssignSpares()
    local spare = 0
    for i = 1, #buttons do
        local button = buttons[i]
        if button.spare then
            spare = spare + 1
            local itemID = unknownIDs[spare]

            if itemID ~= button.itemID then
                button.itemID = itemID
                if itemID then
                    local name, _, icon = GetSpellInfo(itemID)
                    button.entry = {
                        id = itemID, cat = 0, melee = false, unknown = true,
                        name = name or ("Boon " .. itemID),
                    }
                    ns.SetTextureFile(button.icon, icon or ns.BoonData.FALLBACK_ICON)
                else
                    button.entry = nil
                end

                -- A boon nobody has written a word for gets its own name cut
                -- short. Worse than a chosen caption and much better than one
                -- icon in a captioned row silently having none, which reads as
                -- a rendering fault rather than as a boon this build has not
                -- caught up with. LabelOf does the cutting.
                button.label:SetText(button.entry
                    and (ns.BoonData.LabelOf(button.entry) or "") or "")
            end

            if itemID then byItem[itemID] = button end
        end
    end
end

function ApplySecure(reason)
    if not bar or InCombatLockdown() then return end

    AssignSpares()

    local reporting = Config().reportDuration and true or false

    for i = 1, #buttons do
        local button = buttons[i]
        local record = button.itemID and owned[button.itemID]

        -- Bound by bag slot and not by item ID. "item:<id>" would be the
        -- obvious spelling and it is the wrong one for a bind-on-pickup
        -- consumable: the client resolves it against the first matching item it
        -- finds, and these arrive one per slot. The reference binds by slot for
        -- the same reason.
        if record and record.slots[1] then
            SetSecureAttribute(button, "type", "item")
            SetSecureAttribute(button, "item", string.format("%d %d",
                Int(record.slots[1].bag), Int(record.slots[1].slot)))
        else
            SetSecureAttribute(button, "type", "")
            SetSecureAttribute(button, "item", "")
        end

        ----------------------------------------------------------------
        -- Shift and left-click reports instead of using.
        --
        -- Done by taking the action away from that one combination rather
        -- than by trying to stop the click in Lua, which cannot be done:
        -- the secure OnClick is the client's and it uses the item before
        -- any hook of ours is reached.
        --
        -- "shift-type1" is the attribute the client looks up first for
        -- shift plus button one - the cascade is prefix+name+suffix, then
        -- name+suffix, then prefix+name, then name - so an empty string
        -- there is a shift-click that resolves to no action at all, while
        -- a plain left click still falls through to "type" and fires the
        -- boon. Cleared to nil when the setting is off, so the cascade
        -- goes back to finding nothing and the modifier stops mattering.
        --
        -- The client cannot tell left shift from right shift here, and
        -- neither can IsShiftKeyDown. Either one reports.
        ----------------------------------------------------------------
        SetSecureAttribute(button, "shift-type1", reporting and "" or nil)
    end

    LoadCycler()

    Layout()
    -- After the layout, because anchoring to the Mythic+ panel puts the bar's
    -- TOPLEFT against that panel's BOTTOMLEFT and the bar's height is what
    -- Layout has just decided.
    boons.RestorePosition()
    ApplyBindings()

    local show = ShouldShow()
    if show then bar:Show() else bar:Hide() end
    bar:SetAlpha(show and 1 or 0)

    -- The deferred pass reaches here without going through ApplyVisibility, so
    -- a bar that came back after a fight has to announce itself from here too.
    NoteAnchorHost()

    ns.Debug("boons: secure pass ran (%s), %d boon(s) held.",
        tostring(reason or "update"), ownedCount)
end

--------------------------------------------------------------------------------
-- Refresh
--
-- The one entry point everything else calls. Visuals always; the secure half
-- now if the client will take it and on PLAYER_REGEN_ENABLED if it will not.
--------------------------------------------------------------------------------

function boons.Refresh(reason)
    if not bar then return false end

    RebuildOwned()
    RefreshVisuals()

    if InCombatLockdown() then
        QueueSecure(reason)
        ApplyVisibility()
        return false
    end

    ApplySecure(reason)
    ApplyVisibility()
    return true
end

--------------------------------------------------------------------------------
-- Position and scale
--
-- The container is a plain frame, so none of this is protected - but it is
-- blocked in combat all the same, because a bar that moves under the cursor
-- during a pull is not a feature and the brief for this module asks for it.
-- Offsets are kept in UIParent's space and converted through the same helpers
-- Move.lua uses on the trackers, because the bar is scalable and an offset
-- measured in a scaled frame's own units means a different place on screen at a
-- different scale.
--
-- The lock is heroPanel's single global one, the same flag the padlock in the
-- options header and /hp lock govern. There is deliberately not a second lock:
-- two locks is two things to check when a frame will not move.
--------------------------------------------------------------------------------

function boons.SavePosition()
    local block = Saved()
    if not (bar and block) then return false end

    local x, y = ns.GetUIOffsets(bar)
    if not x then return false end

    block.point, block.x, block.y = "TOPLEFT", x, y
    ns.Debug("boons: position saved at %.0f, %.0f", x, y)
    return true
end

-- The frame the bar hangs off when it is anchored to the Mythic+ panel.
--
-- heroPanel's own plate first, because that is the rectangle the player sees -
-- it is sized to the lines actually drawn, where Ascension's tracker frame is
-- far taller than its contents and would leave the bar floating in empty space.
-- The tracker itself is the fallback for when the Mythic+ skin is switched off,
-- since "under the Mythic+ panel" is still a thing the player can ask for then.
--
-- nil when there is nothing on screen to hang off, which is most of the time:
-- the setting then does nothing and the bar stays where it was put.
local function MplusAnchor()
    local plate = ns.Mplus and ns.Mplus.GetPlate and ns.Mplus.GetPlate()
    if plate and plate.IsVisible and plate:IsVisible() and plate:GetBottom() then
        return plate
    end

    local tracker = ns.GetTrackerFrame and ns.GetTrackerFrame("mplus")
    if tracker and tracker.IsVisible and tracker:IsVisible() and tracker:GetBottom() then
        return tracker
    end

    return nil
end

-- Whether the bar is currently hanging off the Mythic+ panel rather than
-- sitting where it was dragged. Asking for the anchor is not the same as having
-- one - the panel has to be on screen - and the drag guard and the options
-- window both need to know which is true right now.
function boons.IsAnchored()
    return Config().anchorMplus and MplusAnchor() ~= nil
end

-- Whether the bar is currently something another frame can hang off the bottom
-- of: anchored under the Mythic+ panel, drawn, and with a resolved edge to
-- measure from.
--
-- Stricter than IsAnchored on purpose. That one answers "is the bar following
-- the panel", which stays true while the bar is gated off - outside a Mythic
-- dungeon, or set to hide itself when you are carrying nothing. A tracker hung
-- off a bar that is not drawn would sit in the gap where the bar would have
-- been, which reads as a gap nobody asked for.
function boons.IsAnchorHost()
    if not (bar and boons.IsAnchored()) then return false end
    if not (bar:IsShown() and bar:GetBottom()) then return false end
    return true
end

function boons.RestorePosition()
    if not bar then return false end
    local cfg = Config()

    if cfg.anchorMplus then
        local anchor = MplusAnchor()
        if anchor then
            -- SetPoint rather than a computed offset, so the bar follows the
            -- Mythic+ panel when that is moved, rescaled or redrawn taller by a
            -- dungeon with more bosses - without heroPanel having to watch for
            -- any of it.
            --
            -- Corner to corner rather than TOP to BOTTOM. Centring was the
            -- first version and it is wrong for a bar whose width changes:
            -- holding one boon put a single icon under the middle of the panel,
            -- holding three slid all three sideways to keep the group centred,
            -- and an icon that moves every time you loot is an icon you have to
            -- look for. Pinned to the panel's left edge, the first slot is
            -- always in the same place and the bar grows to the right.
            bar:ClearAllPoints()
            bar:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -ANCHOR_GAP)
            return true
        end
        -- Nothing to hang off yet. Fall through to the saved position, so the
        -- bar is somewhere findable rather than stacked in a corner until the
        -- Mythic+ panel turns up.
    end

    if cfg.point then
        ns.ApplyUIOffsets(bar, cfg.x or 0, cfg.y or 0)
        return true
    end

    -- Never moved. Centred low, over the action bars' usual latitude and clear
    -- of both trackers, which live up the right-hand side.
    bar:ClearAllPoints()
    bar:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    return false
end

function boons.ResetPosition()
    local block = Saved()
    if not block then return false end

    block.point, block.x, block.y, block.scale = nil, 0, 0, 1.0
    if bar then
        bar:SetScale(1.0)
        boons.RestorePosition()
    end
    ns.Print("boon bar position reset.")
    return true
end

function boons.SetScale(scale)
    local block = Saved()
    if not (bar and block) then return false end

    scale = ns.Snap(ns.Clamp(scale, ns.SCALE_MIN, ns.SCALE_MAX), 0.05)
    block.scale = scale

    if InCombatLockdown() then
        ns.RunWhenSafe(function()
            bar:SetScale(scale)
            boons.RestorePosition()
        end, "Boons:SetScale")
        return true, scale
    end

    bar:SetScale(scale)
    boons.RestorePosition()
    return true, scale
end

local function BarOnDragStart(self)
    if ns.IsLocked() then return end

    -- Anchored to the Mythic+ panel, so there is nowhere for a drag to put it.
    -- Said out loud rather than silently ignored: a frame that will not move
    -- and does not say why reads as a bug, and the way out is one checkbox.
    if boons.IsAnchored() then
        ns.Warn("the boon bar is anchored under the Mythic+ panel. Turn that off "
            .. "in |cFFC2C6D8/hp|r to place it yourself.")
        return
    end

    if InCombatLockdown() then
        ns.Warn("the boon bar does not move in combat - it will drag as soon as "
            .. "you are out of it.")
        return
    end
    self:StartMoving()
    self.moving = true
end

local function BarOnDragStop(self)
    if not self.moving then return end
    self.moving = nil
    pcall(self.StopMovingOrSizing, self)
    boons.SavePosition()
end

--------------------------------------------------------------------------------
-- Building
--
-- Once, at login, out of combat. Never again: a SecureActionButtonTemplate
-- button cannot be created, reparented or repositioned in combat, so a pool
-- that is grown on demand is a pool that fails at exactly the wrong moment.
--------------------------------------------------------------------------------

local function BuildButton(index, entry)
    local name = "HeroPanelBoonButton" .. index

    -- A plain Button when the client has no secure template to build on. The
    -- bar then shows what is in the bags and cannot fire any of it, which is
    -- worth having and is said out loud once, in ProbeCapabilities.
    local button
    if caps.secureButtons then
        button = CreateFrame("Button", name, bar, "SecureActionButtonTemplate")
    else
        button = CreateFrame("Button", name, bar)
    end

    -- "AnyUp" is what the action bar libraries on this client register, and it
    -- is what an override binding's synthesised click arrives as.
    if type(button.RegisterForClicks) == "function" then
        pcall(button.RegisterForClicks, button, "AnyUp")
    end
    SetSecureAttribute(button, "type", "")
    SetSecureAttribute(button, "item", "")

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    -- The client's icon art carries a border in the outer few pixels that reads
    -- as a second frame inside heroPanel's own. Trimmed, the way every icon
    -- addon on this client trims it.
    button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    button.border = button:CreateTexture(nil, "BACKGROUND")
    button.border:SetAllPoints(button)
    ns.SetTextureFile(button.border, ns.SOLID)
    button.border:SetVertexColor(ns.HexToRGB(ns.PALETTE.accentDeep, 0.9))

    -- The melee-only mark: four edges over the icon's own outer pixels.
    --
    -- Anchored to the button's corners rather than sized, so the ring follows
    -- the icon size slider without anything having to reposition it. Drawn on
    -- OVERLAY so it sits over the icon; the two pixels it covers are the ones
    -- the icon's texture coordinates already trim as the client's own border
    -- art, so nothing readable is lost.
    button.meleeMark = {}
    for _, edge in ipairs({ "top", "bottom", "left", "right" }) do
        local texture = button:CreateTexture(nil, "OVERLAY")
        ns.SetTextureFile(texture, ns.SOLID)
        texture:SetVertexColor(ns.HexToRGB(ns.PALETTE[MELEE_MARK_COLOUR]))
        texture:ClearAllPoints()

        if edge == "top" then
            texture:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
            texture:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
            texture:SetHeight(MELEE_MARK_WIDTH)
        elseif edge == "bottom" then
            texture:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
            texture:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
            texture:SetHeight(MELEE_MARK_WIDTH)
        elseif edge == "left" then
            texture:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
            texture:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
            texture:SetWidth(MELEE_MARK_WIDTH)
        else
            texture:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
            texture:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
            texture:SetWidth(MELEE_MARK_WIDTH)
        end

        texture:Hide()
        button.meleeMark[edge] = texture
    end

    -- The expiry sparks. Built at load with everything else and left hidden,
    -- because a texture created on the frame a boon starts expiring is a
    -- texture created in combat - allowed, unlike a secure button, but a
    -- needless allocation at the worst moment on the worst frame.
    --
    -- No points set here: PlaceSpark anchors them every frame while they run,
    -- and where they sit depends on the icon size, which the slider can change.
    button.glow = {}
    for i = 1, GLOW_SPARKS do
        local spark = button:CreateTexture(nil, "OVERLAY")
        ns.SetTextureFile(spark, ns.SOLID)
        spark:SetVertexColor(ns.HexToRGB(ns.PALETTE[GLOW_COLOUR]))
        spark:Hide()
        button.glow[i] = spark
    end
    button.glowPhase = 0

    -- The cycle key's "next up" mark: a bar across the bottom edge.
    --
    -- Anchored to the button's own corners so it tracks the icon size, and two
    -- pixels tall for the same reason the melee ring is - one pixel reads as
    -- the edge of the button at 32px.
    button.cycleMark = button:CreateTexture(nil, "OVERLAY")
    ns.SetTextureFile(button.cycleMark, ns.SOLID)
    button.cycleMark:SetVertexColor(ns.HexToRGB(ns.PALETTE.accentLight))
    button.cycleMark:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
    button.cycleMark:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    button.cycleMark:SetHeight(2)
    button.cycleMark:Hide()

    button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
    button.highlight:SetAllPoints(button)
    ns.SetTextureFile(button.highlight, ns.SOLID)
    button.highlight:SetVertexColor(ns.HexToRGB(ns.PALETTE.accentLight, ns.ALPHA.hoverButton))
    button.highlight:Hide()

    -- The swipe. Not every client of this vintage has the template, and a bar
    -- without a cooldown swipe is worth a great deal more than a bar that threw
    -- at login, so this is allowed to fail - SetCooldown checks for it.
    local gotCooldown, cooldown = pcall(CreateFrame, "Cooldown",
        name .. "Cooldown", button, "CooldownFrameTemplate")
    if gotCooldown and type(cooldown) == "table" then
        button.cooldown = cooldown
        pcall(cooldown.SetAllPoints, cooldown, button)
    end

    button.count = button:CreateFontString(nil, "OVERLAY")
    button.count:SetFont(ns.GetFontFile(), ns.GetFontSize(-2, "mplusBody"), "OUTLINE")
    button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
    button.count:SetTextColor(ns.HexToRGB(ns.PALETTE.bright))
    button.count:Hide()

    -- The bound key, top-left, opposite the stack count so the two never
    -- collide. A slot number would say the same thing less usefully: what a
    -- player wants off the icon is which key fires it, and in slot order the
    -- number moves as boons are looted anyway.
    button.hotkey = button:CreateFontString(nil, "OVERLAY")
    button.hotkey:SetFont(ns.GetFontFile(), ns.GetFontSize(-3, "mplusBody"), "OUTLINE")
    button.hotkey:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    button.hotkey:SetTextColor(ns.HexToRGB(ns.PALETTE.accentLight))
    button.hotkey:SetText("")

    -- The caption. Outside the icon rather than over it, because the two
    -- corners are already spoken for - the stack count and the bound key - and
    -- a word laid across the middle of the art hides the thing it is naming.
    --
    -- Built whether or not the captions are on, and left hidden. It is one
    -- FontString on a button that already carries a dozen regions, and creating
    -- it when the setting is ticked would mean creating it in combat on the one
    -- frame where that matters. Where it hangs is Layout's to say; it is
    -- anchored to the button, so it follows the icon without being placed.
    button.label = button:CreateFontString(nil, "OVERLAY")
    button.label:SetFont(ns.GetFontFile(), LabelFontSize(), "OUTLINE")
    button.label:SetJustifyH("CENTER")
    button.label:SetTextColor(ns.HexToRGB(ns.PALETTE[LABEL_COLOUR]))
    button.label:SetText(entry and ns.BoonData.LabelOf(entry) or "")
    button.label:Hide()

    button:SetScript("OnEnter", ButtonOnEnter)
    button:SetScript("OnLeave", ButtonOnLeave)

    -- HookScript rather than SetScript. SecureActionButtonTemplate installs its
    -- own OnClick and that is the one that actually uses the item; replacing it
    -- would leave a button that looks right and does nothing.
    button:HookScript("OnClick", function(self, click)
        -- Shift and left-click reports rather than uses. The secure attribute
        -- set in ApplySecure has already stopped the client using anything, so
        -- all that is left is to answer - and to return before the bookkeeping
        -- below, which would otherwise take a boon out of the local picture
        -- that is still very much in the bags.
        --
        -- Gated on a real left click. A keybind arrives here as BIND_CLICK, and
        -- a slot bound to a shift-modified key arrives with shift genuinely
        -- held - so without this, using that keybind would fire the boon *and*
        -- announce it. See the note on BIND_CLICK.
        if click == "LeftButton" and Config().reportDuration and IsShiftKeyDown()
           and self.itemID and owned[self.itemID] then
            local sent, detail = ReportDuration(self)
            if not sent then ns.Debug("boons: not reported - %s.", tostring(detail)) end
            return
        end

        -- A click that could not have used anything must not do the
        -- bookkeeping for one.
        --
        -- The attributes are written by ApplySecure, which is deferred out of
        -- combat - so a boon looted during a fight is drawn and hoverable with
        -- `type` still blank, and the client's own OnClick fires nothing. The
        -- hook ran regardless, and NoteUsed then took the boon out of `owned`
        -- and RefreshVisuals parked the button behind an inside-out hit rect:
        -- the first click blanked the icon and every click after it went
        -- through to the world, on a boon that was never spent and is still in
        -- the bags.
        --
        -- The cycler's PostClick has read `type` for this reason since it was
        -- written; this is the same test on the other path. It cannot move
        -- into NoteUsed, because the cycle key fires through its own hidden
        -- button and hands NoteUsed a visible one whose `type` is rightly
        -- blank.
        --
        -- Reading an attribute is not protected, so this answers in combat.
        local bound, kind = pcall(self.GetAttribute, self, "type")
        if not (bound and kind == "item") then return end

        NoteUsed(self)
    end)

    button.entry  = entry
    button.itemID = entry and entry.id or nil
    button.spare  = (entry == nil)

    if entry then
        local _, _, icon = GetSpellInfo(entry.id)
        ns.SetTextureFile(button.icon, icon or ns.BoonData.FALLBACK_ICON)
        byItem[entry.id] = button
    else
        ns.SetTextureFile(button.icon, ns.BoonData.FALLBACK_ICON)
    end

    button:Hide()
    return button
end

local function BuildBar()
    if bar then return bar end

    -- Never in combat.
    --
    -- Every button in the pool is a SecureActionButtonTemplate and the client
    -- refuses to create one under lockdown, so building here mid-fight is a
    -- block per button and a pool of nils behind them. This is not a
    -- theoretical path: PLAYER_LOGIN fires on /reload as well as on login, and
    -- /reload during a pull is how anybody testing a setting ends up on it.
    --
    -- Deferred rather than abandoned, and the follow-up work is deferred with
    -- it: a bar that exists but was never scaled, placed or filled is a bar
    -- sitting at 200x44 in the middle of the screen with nothing on it.
    if InCombatLockdown() then
        ns.Debug("boons: the bar cannot be built in combat; deferred.")
        ns.RunWhenSafe(function()
            if not BuildBar() then return end
            local block = Saved()
            if block then
                bar:SetScale(ns.Clamp(block.scale or 1, ns.SCALE_MIN, ns.SCALE_MAX))
            end
            boons.RestorePosition()
            boons.Refresh("bar built after combat")
        end, "Boons:build")
        return nil
    end

    -- Normally probed at login, before this runs. Asked for here as well
    -- because the options window can reach SetEnabled first if the store is
    -- ready and login is not, and a pool built with caps empty would be a pool
    -- of plain buttons for the rest of the session - and because the probe is
    -- skipped in combat, so a login that landed in one leaves it unanswered.
    if caps.secureButtons == nil then ProbeCapabilities() end

    bar = CreateFrame("Frame", "HeroPanelBoonBar", UIParent)
    bar:Hide()
    bar:SetWidth(200)
    bar:SetHeight(44)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:EnableMouse(true)
    bar:SetMovable(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", BarOnDragStart)
    bar:SetScript("OnDragStop", BarOnDragStop)

    -- The same chrome the two tracker panels use, painted from the Mythic+
    -- panel's own colours. The bar is a Mythic+ feature and reading as part of
    -- that panel is right; giving it a fourth set of background and border
    -- controls to keep in step by hand is not.
    ns.BuildPlateChrome(bar)
    ns.StylePlateChrome(bar, ns.PanelStyle("mplus"))

    bar.grip = ns.NewResizeGrip(bar, {
        label    = "boon bar",
        deferred = true,
        visible  = function() return not ns.IsLocked() end,
        get      = function() return Config().scale or 1 end,
        set      = function(scale) boons.SetScale(scale) end,
    })

    -- The compact in-combat tooltip is its own frame rather than GameTooltip,
    -- so it can be up while something else owns the real one. Allowed to fail
    -- for the same reason the cooldown is: without it, ButtonOnEnter falls
    -- through to the full tooltip, which is a worse experience and not a broken
    -- one.
    local gotTooltip, frame = pcall(CreateFrame, "GameTooltip",
        "HeroPanelBoonTooltip", UIParent, "GameTooltipTemplate")
    tooltip = (gotTooltip and type(frame) == "table" and type(frame.AddLine) == "function")
        and frame or nil

    -- The expiry scanner. A third tooltip, never shown and never anchored to
    -- anything visible, because reading an item's remaining lifetime means
    -- filling a tooltip with its text and looking at the lines - and doing that
    -- to either of the two tooltips a player can see would blank whatever they
    -- were reading at the time.
    local gotScanner, scan = pcall(CreateFrame, "GameTooltip",
        "HeroPanelBoonScanner", UIParent, "GameTooltipTemplate")
    scanner = (gotScanner and type(scan) == "table" and type(scan.SetBagItem) == "function")
        and scan or nil
    if not scanner then
        ns.Debug("boons: no scanning tooltip; expiry will be counted from when "
            .. "heroPanel first saw each boon.")
    end

    local index = 0
    for i = 1, #ns.BoonData.ORDER do
        index = index + 1
        buttons[index] = BuildButton(index, ns.BoonData.ORDER[i])
    end
    for _ = 1, SPARE_SLOTS do
        index = index + 1
        buttons[index] = BuildButton(index, nil)
    end

    BuildCycler()

    ticker       = ns.NewTicker(COOLDOWN_TICK, PollCooldowns)
    expiryTicker = ns.NewTicker(EXPIRY_TICK, ExpiryTick)

    -- The glow's own driver. Hidden until something is warning, which is most
    -- of the time - see the note on the expiry glow for why this is not one of
    -- ns.NewTicker's slots.
    glowDriver = CreateFrame("Frame", "HeroPanelBoonGlowDriver", UIParent)
    glowDriver:Hide()
    glowDriver:SetScript("OnUpdate", GlowOnUpdate)

    ns.Debug("boons: built %d button(s) (%d known, %d spare), cycling %s.",
        #buttons, #ns.BoonData.ORDER, SPARE_SLOTS,
        (cycler and cycler.snippet) and "in the restricted environment"
            or (cycler and "out of combat only" or "unavailable"))
    return bar
end

--------------------------------------------------------------------------------
-- Keybinding names
--
-- Set at file scope so they exist before the Key Bindings window is opened.
--
-- Five rows, named by slot rather than by boon. Naming them after the boons was
-- the first go and gave nineteen rows in a window nobody scrolls: you cannot
-- carry nineteen boons, and the four spares read as "Spare boon slot 1", which
-- says nothing about what pressing it would do. A slot is a position on the
-- bar, and "line boons up in the slots" makes those positions the boons you are
-- actually holding.
--------------------------------------------------------------------------------

_G.BINDING_HEADER_HEROPANEL = "heroPanel"

for i = 1, SLOT_COUNT do
    _G["BINDING_NAME_HEROPANEL_BOON" .. i] = string.format("Boon slot %d", i)
end

-- A sixth row, and the one most people will bind. Named for what it does
-- rather than for what it is - "Cycle boons" says the whole feature, where
-- "Boon cycle button" would say the implementation.
_G.BINDING_NAME_HEROPANEL_BOON_CYCLE = "Cycle boons"

--------------------------------------------------------------------------------
-- Bag events
--
-- Two paths, both live. C_Hook:RegisterBucket coalesces a burst of bag changes
-- into one callback with the events batched, and each event carries the bag,
-- slot and itemID - so a bag change that has nothing to do with boons costs a
-- loop over a handful of entries rather than a scan of five bags. That is the
-- fast path and it is the one that gets a looted boon onto the bar promptly.
--
-- Plain BAG_UPDATE runs behind it as a backstop, because the granular path can
-- fail silently. See the note on SubscribeBagEvents.
--
-- The handler runs securecall'd when the execution path is already insecure,
-- which is what the client's own boon UI does. It is not that anything below is
-- protected; it is that a bucket callback can arrive on a tainted path, and
-- work done on one taints what it touches. The buttons are secure frames, so
-- that matters here in a way it does not anywhere else in heroPanel.
--------------------------------------------------------------------------------

-- Where the itemID sits in a bucketed bag event's arguments.
--
--   BAG_ITEM_ADDED           bag, slot, itemID, count
--   BAG_ITEM_REMOVED         bag, slot, itemID, count
--   NEW_BAG_ITEM_ADDED       bag, slot, itemID, count
--   BAG_ITEM_COUNT_CHANGED   bag, slot, itemID, count, diff
--   BAG_ITEM_REPLACED        bag, slot, oldID, oldCount, newID, newCount
--
-- Four of the five put it third. The replacement carries two of them and either
-- one can be the boon - the old one when a boon was overwritten, the new one
-- when a boon landed on top of something else - so both places are read. The
-- bucket does not say which event a batch entry came from, which is why this is
-- positional rather than a lookup by name.
local BAG_EVENT_ITEM_SLOTS = { 3, 5 }

local function OnBagEvent(batch)
    -- Not every build hands the bucket a batch. Without one there is nothing to
    -- filter on, so rebuild and let RebuildOwned decide whether anything
    -- changed.
    if type(batch) ~= "table" then
        boons.Refresh("bag update")
        return
    end

    for i = 1, #batch do
        local event = batch[i]
        if type(event) == "table" then
            for j = 1, #BAG_EVENT_ITEM_SLOTS do
                if ClassifyItem(event[BAG_EVENT_ITEM_SLOTS[j]]) then
                    boons.Refresh("boon added or removed")
                    return
                end
            end
        end
    end
end

local function BagEventEntry(batch)
    if type(_G.issecure) == "function" and not _G.issecure()
       and type(_G.securecall) == "function" then
        _G.securecall(OnBagEvent, batch)
        return
    end
    OnBagEvent(batch)
end

-- Every granular bag event that can carry a boon.
--
-- The list used to be NEW_BAG_ITEM_ADDED, BAG_ITEM_REMOVED and
-- BAG_ITEM_COUNT_CHANGED, and that is why boons went missing off the bar. The
-- two that were absent are the two a looted boon most often arrives on:
--
--   BAG_ITEM_ADDED     sent for every item that lands in an empty slot.
--                      NEW_BAG_ITEM_ADDED is the *subset* of those the client
--                      could match back to an ITEM_PUSH, and it matches by icon
--                      texture rather than by item - so two boons that share an
--                      icon, which Skulking and Phasewalk do, can consume each
--                      other's pending push and the second one is announced on
--                      BAG_ITEM_ADDED alone.
--   BAG_ITEM_REPLACED  sent instead of either of the above when the slot was
--                      not empty. A boon landing on top of something else fires
--                      only this, so it was previously invisible to the bar.
--
-- Subscribing to the whole set costs nothing: OnBagEvent throws away anything
-- that is not a boon before it does any work.
local BAG_EVENTS = "BAG_ITEM_ADDED, NEW_BAG_ITEM_ADDED, BAG_ITEM_REMOVED, "
    .. "BAG_ITEM_REPLACED, BAG_ITEM_COUNT_CHANGED"

local function SubscribeBagEvents()
    local path = nil

    if caps.hook then
        -- pcall is not the safety net it looks like here. Called from an
        -- addon, C_Hook:RegisterBucket sees an insecure execution path and
        -- launders the registration through attributes on its own handler
        -- frame rather than performing it - so it returns having queued the
        -- work, and pcall reports success whether or not the registration ever
        -- landed. There is no return value to test either. That is the whole
        -- reason the stock route below is now installed alongside this one
        -- rather than only when this one visibly fails: a bucket that silently
        -- never registers used to leave the bar with no bag events at all, and
        -- nothing in the status output could tell that from a working one.
        local ok = pcall(function()
            _G.C_Hook:RegisterBucket(bar, BAG_EVENTS, 0.1, BagEventEntry)
        end)
        if ok then
            ns.Debug("boons: subscribed to C_Hook bag buckets.")
            path = "C_Hook"
        else
            ns.Debug("boons: C_Hook:RegisterBucket refused.")
        end
    end

    -- The stock route, always on. BAG_UPDATE says nothing about what changed,
    -- so every one of them costs a scan - which is why it is throttled hard and
    -- why the granular path above is still preferred for latency. As a backstop
    -- it is worth its price: it is the only thing that guarantees the bar
    -- cannot sit on a stale hand of boons for a whole key.
    --
    -- The delay is 0.3s and not the next frame on purpose. C_InventoryState
    -- rebuilds the cache this module reads on its own 0.2s BAG_UPDATE bucket,
    -- so a scan any sooner reads the bags as they were before the change.
    local queued = false
    ns:On("BAG_UPDATE", function()
        if queued then return end
        queued = true
        ns.After(0.3, function()
            queued = false
            boons.Refresh("bag update")
        end)
    end)

    return path and (path .. " + BAG_UPDATE") or "BAG_UPDATE"
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function boons.SetEnabled(value)
    local block = Saved()
    if not block then return false end

    block.enabled = value and true or false

    if block.enabled then
        BuildBar()
        boons.RestorePosition()
        if bar then bar:SetScale(ns.Clamp(block.scale or 1, ns.SCALE_MIN, ns.SCALE_MAX)) end
        boons.Refresh("enabled")
    elseif bar then
        -- Bindings go first. Leaving them installed would mean a key still
        -- firing a boon off a bar that is not on screen.
        if caps.overrideBinds and not InCombatLockdown() then
            pcall(_G.ClearOverrideBindings, bar)
        end
        ApplyVisibility()
    end

    return block.enabled
end

-- Called by the options window when a setting that changes the bar's shape is
-- touched. Split from Refresh because a colour or a font does not need the bags
-- re-read.
function boons.Restyle()
    if not bar then return end

    local file = ns.GetFontFile()
    for i = 1, #buttons do
        pcall(buttons[i].count.SetFont, buttons[i].count,
            file, ns.GetFontSize(-2, "mplusBody"), "OUTLINE")
        pcall(buttons[i].hotkey.SetFont, buttons[i].hotkey,
            file, ns.GetFontSize(-3, "mplusBody"), "OUTLINE")
        -- The caption's size is also the height of the band the layout leaves
        -- for it, so this one has to be set before Layout runs below rather
        -- than after - a font change would otherwise draw the new size into
        -- the old band until the next bag event.
        pcall(buttons[i].label.SetFont, buttons[i].label,
            file, LabelFontSize(), "OUTLINE")
    end

    if InCombatLockdown() then
        ns.StylePlateChrome(bar, ns.PanelStyle("mplus"))
        RefreshVisuals()
        QueueSecure("restyle")
        return
    end

    Layout()
    RefreshVisuals()
    ApplyVisibility()
end

function boons.GetBar()
    return bar
end

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

function boons.PrintStatus()
    if not boons.IsEnabled() then
        ns.Print("  |cFF8B8FA3boon bar off|r")
        return
    end

    local cfg = Config()
    ns.Print("  |cFF79C68Dboon bar on|r - %s, %d px icons, %s",
        cfg.orientation, Int(ns.Clamp(cfg.iconSize or 32, ICON_MIN, ICON_MAX)),
        cfg.mythicOnly and "Mythic dungeons only" or "always shown")
    ns.Print("    %d boon(s) in bags; bar is %s",
        ownedCount, (bar and bar:IsShown()) and "|cFF79C68Dshown|r" or "|cFF8B8FA3hidden|r")

    -- Why it is hidden, when it is. A bar that is away mid-key and a bar that
    -- is away in a city look identical in the line above, and the difference is
    -- the whole question - so the gate that closed says so, with the readings
    -- it closed on. This is the line that would have answered the boon bar
    -- going missing during a +15 without a second run.
    if bar and not bar:IsShown() then
        local instanceType, difficulty = InstanceState()
        if cfg.mythicOnly and not InMythicDungeon() then
            ns.Print("    |cFF8B8FA3hidden by \"only in Mythic dungeons\"|r - "
                .. "instance |cFFC2C6D8%s|r, difficulty |cFFC2C6D8%s|r",
                tostring(instanceType or "none"), tostring(difficulty or "unknown"))
        elseif cfg.hideEmpty and ownedCount == 0 then
            ns.Print("    |cFF8B8FA3hidden by \"hide when you have none\"|r")
        else
            ns.Print("    |cFF8B8FA3nothing is gating it - "
                .. "the show is waiting on the end of combat|r")
        end
    end

    ns.Print("    bag events: |cFFC2C6D8%s|r", tostring(boons.eventPath or "not subscribed"))
end

-- /hp boons - what the module resolved, and from where.
function boons.Dump()
    ns.Print("boon bar:")
    ns.Print("  %s, %d known boon(s), %d spare slot(s)",
        boons.IsEnabled() and "|cFF79C68Denabled|r" or "|cFF8B8FA3disabled|r",
        ns.BoonData.Count(), SPARE_SLOTS)
    ns.Print("  bags: |cFFC2C6D8%s|r, events: |cFFC2C6D8%s|r, keybinds: |cFFC2C6D8%s|r",
        caps.inventoryState and "C_InventoryState"
            or (caps.containerScan and "container scan" or "unavailable"),
        boons.eventPath or "not subscribed",
        caps.overrideBinds and "override bindings" or "unavailable")
    ns.Print("  in a Mythic dungeon: %s; bar %s; %s",
        InMythicDungeon() and "yes" or "no",
        (bar and bar:IsShown()) and "shown" or "hidden",
        boons.IsAnchored() and "|cFFC2C6D8anchored under the Mythic+ panel|r"
            or (Config().anchorMplus
                and "|cFF8B8FA3anchored, but the Mythic+ panel is not up|r"
                or "free-placed"))

    -- The two shape settings, reported together because they are the two that
    -- change what the bar looks like without changing what is on it - so "the
    -- bar is not where I left it" is answered from one line.
    do
        local perRow = RowLength()
        ns.Print("  captions: %s; layout: %s",
            Config().labels
                and ("|cFFC2C6D8" .. tostring(Config().labelAnchor or "above")
                     .. " each icon|r")
                or  "|cFF8B8FA3off|r",
            perRow and ("|cFFC2C6D8wrapping every " .. Int(perRow) .. "|r")
                or   "|cFF8B8FA3one row|r")
    end

    local warn = tonumber(Config().expiryWarn) or 0
    ns.Print("  expiry warning: %s; expiry read from |cFFC2C6D8%s|r",
        warn > 0 and ("|cFFC2C6D8" .. FormatSpan(warn) .. "|r") or "|cFF8B8FA3off|r",
        caps.itemDuration and "the client"
            or (scanner and "the item tooltip, else first sight" or "first sight"))
    ns.Print("  shift-click reports: %s",
        Config().reportDuration and "|cFF79C68Don|r" or "|cFF8B8FA3off|r")

    -- The two automatic lines, and - when the expiry one is on - which
    -- thresholds it would actually call. "It said nothing" is the whole of what
    -- ever goes wrong with these, and the answer is nearly always either the
    -- group or the gate, so both are on the line beside them.
    do
        local cfg      = Config()
        local wanted   = type(cfg.announceExpiryAt) == "table"
                         and cfg.announceExpiryAt or {}
        local at, list = {}, ns.BOON_ANNOUNCE_THRESHOLDS
        for i = 1, #list do
            if wanted[list[i].key] then at[#at + 1] = list[i].label end
        end

        ns.Print("  announces pickups: %s; announces expiry: %s",
            cfg.announceGain and "|cFF79C68Don|r" or "|cFF8B8FA3off|r",
            cfg.announceExpiry
                and (#at > 0
                     and ("|cFF79C68Don|r at |cFFC2C6D8" .. table.concat(at, ", ") .. "|r")
                     or  "|cFFFFAA00on, with no thresholds ticked|r")
                or  "|cFF8B8FA3off|r")
        ns.Print("    heard by: %s", InGroup()
            and ("|cFFC2C6D8" .. ReplyChannel() .. "|r")
            or  "|cFF8B8FA3nobody - you are not in a group|r")
    end

    -- Which boon each key would actually fire. The whole point of the slots is
    -- that the answer changes, so it has to be reportable.
    local slots = SlotButtons()
    for slot = 1, SLOT_COUNT do
        local button = slots[slot]
        local key    = GetBindingKey("HEROPANEL_BOON" .. slot)
        if key or button then
            ns.Print("  slot %d: %s%s", slot,
                (button and button.entry) and button.entry.name or "|cFF8B8FA3empty|r",
                key and (" - |cFFC2C6D8" .. key .. "|r") or " |cFF8B8FA3(no key bound)|r")
        end
    end

    -- The cycle key, and - the part worth reporting - whether it will keep
    -- advancing once a fight starts. That is the whole difference between the
    -- snippet path and the fallback, and it is invisible until it matters.
    do
        local key   = GetBindingKey("HEROPANEL_BOON_CYCLE")
        local next_ = CycleNextButton()
        ns.Print("  cycle: %s%s",
            key and ("|cFFC2C6D8" .. key .. "|r") or "|cFF8B8FA3no key bound|r",
            (cycler and cycler.snippet)
                and " - |cFF79C68Dadvances in combat|r"
                or  " - |cFF8B8FA3out of combat only|r")
        ns.Print("    next: %s",
            (next_ and next_.entry) and next_.entry.name or "|cFF8B8FA3nothing held|r")
    end

    if ownedCount == 0 then
        ns.Print("  |cFF8B8FA3no boons in your bags|r")
    else
        for itemID, record in pairs(owned) do
            local entry = ns.BoonData.BY_ID[itemID]
            local life  = RemainingLife(itemID)
            ns.Print("  |cFFC2C6D8%s|r (%d) x%d - bag %d slot %d, expires in %s",
                entry and entry.name or "unknown", Int(itemID), Int(record.count),
                Int(record.slots[1].bag), Int(record.slots[1].slot),
                life and FormatSpan(life) or "|cFF8B8FA3unknown|r")
        end
    end

    for i = 1, #unknownIDs do
        ns.Warn("  itemID %d is a boon heroPanel does not know about - "
            .. "worth adding to BoonData.lua.", unknownIDs[i])
    end
end

-- /hp boons expiry - every line of every held boon's tooltip, and what the
-- parser made of each one.
--
-- This exists because the expiry warning is built on a string nobody has read
-- yet. There is no API for an item's remaining lifetime, so the tooltip is the
-- only place the number is written down, and which line it is on and how it is
-- worded is a thing this client knows and heroPanel is guessing at. The
-- fallback - counting from when a boon was first seen - is correct for a boon
-- looted during the session, so the guess only has to be right to survive a
-- /reload mid-run.
--
-- Run it with boons in the bags and the answer is in front of you: if a line
-- carries the remaining time and reads "no", LineDuration wants widening.
function boons.DumpExpiry()
    if not scanner then
        ns.Print("boon expiry: |cFF8B8FA3no scanning tooltip on this client|r - "
            .. "expiry is counted from when heroPanel first saw each boon.")
        return
    end

    if ownedCount == 0 then
        ns.Print("boon expiry: |cFF8B8FA3no boons in your bags to read|r")
        return
    end

    ns.Print("boon expiry - raw tooltip lines:")

    for itemID, record in pairs(owned) do
        local entry = ns.BoonData.BY_ID[itemID]
        local place = record.slots[1]

        ns.Print("  |cFFC2C6D8%s|r - bag %d slot %d, heroPanel says %s",
            entry and entry.name or ("item " .. Int(itemID)),
            Int(place.bag), Int(place.slot),
            RemainingLife(itemID) and FormatSpan(RemainingLife(itemID)) or "unknown")

        scanner:SetOwner(UIParent, "ANCHOR_NONE")
        scanner:ClearLines()
        if pcall(scanner.SetBagItem, scanner, place.bag, place.slot) then
            local name  = scanner:GetName()
            local lines = 0
            local ok, count = pcall(scanner.NumLines, scanner)
            if ok then lines = tonumber(count) or 0 end

            for i = 1, lines do
                for _, side in ipairs({ "TextLeft", "TextRight" }) do
                    local fs = _G[name .. side .. i]
                    local text = fs and type(fs.GetText) == "function" and fs:GetText()
                    if text and text ~= "" then
                        local span = LineDuration(text)
                        ns.Print("    %d%s: %s |cFF8B8FA3[%s]|r", i,
                            side == "TextRight" and "R" or "", text,
                            span and (FormatSpan(span) .. " - read as a duration")
                                or "no")
                    end
                end
            end
        else
            ns.Print("    |cFF8B8FA3the tooltip refused that bag slot|r")
        end

        pcall(scanner.Hide, scanner)
    end
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

-- Registered defensively, the way Keys.lua registers its chat events: ns:On
-- hands the name straight to RegisterEvent, which throws on an event this
-- client does not have, and a throw at file scope would take the rest of the
-- file with it. PLAYER_DIFFICULTY_CHANGED is the one that is not on every
-- build.
local function Subscribe(event, fn)
    local ok, err = pcall(function() ns:On(event, fn) end)
    if not ok then ns.Debug("boons: could not register %s: %s", event, tostring(err)) end
    return ok
end

-- Ask the client to cache the item data for every known boon.
--
-- The tooltip for a boon you are *not* carrying is SetHyperlink("item:<id>"),
-- and a hyperlink to an item the client has never seen draws an empty box.
-- Item:Query is Ascension's own way of asking for that data ahead of being
-- asked for it, and the client's own boon UI calls it for the same reason.
-- Nothing depends on it working: ShowFullTooltip falls back to the compact
-- tooltip when nothing drew.
local function WarmItemCache()
    if type(_G.Item) ~= "table" or type(_G.Item.Query) ~= "function" then return end
    for i = 1, #ns.BoonData.ORDER do
        pcall(_G.Item.Query, _G.Item, ns.BoonData.ORDER[i].id)
    end
end

ns:On("PLAYER_LOGIN", function()
    ProbeCapabilities()
    WarmItemCache()

    -- Built whether or not the feature is on. Building it lazily on first
    -- enable would mean "turn the boon bar on" failing during a pull, since the
    -- pool cannot be created in combat - and an empty hidden frame costs
    -- nothing. BuildBar defers itself when this login landed in a fight, which
    -- is why everything below it is guarded on the bar rather than assuming it.
    BuildBar()

    local block = Saved()
    if block and bar then
        bar:SetScale(ns.Clamp(block.scale or 1, ns.SCALE_MIN, ns.SCALE_MAX))
    end
    boons.RestorePosition()

    boons.eventPath = SubscribeBagEvents()
    boons.Refresh("login")
end)

local function OnZoneOrDifficulty()
    if not bar then return end
    boons.Refresh("zone or difficulty changed")
end

Subscribe("PLAYER_ENTERING_WORLD", OnZoneOrDifficulty)
Subscribe("ZONE_CHANGED_NEW_AREA", OnZoneOrDifficulty)
Subscribe("PLAYER_DIFFICULTY_CHANGED", OnZoneOrDifficulty)

-- Re-read the player's keys when they change one, so a binding set in the Key
-- Bindings window takes effect without a reload.
Subscribe("UPDATE_BINDINGS", function()
    if not bar then return end
    if InCombatLockdown() then QueueSecure("bindings changed") else ApplyBindings() end
end)

-- The bar carries a resize grip, and the grip follows the global lock.
ns:On("HEROPANEL_LOCK_CHANGED", function()
    if bar and bar.grip then pcall(bar.grip.Sync, bar.grip) end
end)

-- The Mythic+ panel is built after heroPanel has booted - it is discovered by
-- Trackers.lua's poll rather than existing at login - so a bar anchored to it
-- has nothing to hang off until then. Re-anchor when it turns up.
ns:On("HEROPANEL_TRACKER_FOUND", function(key)
    if key ~= "mplus" or not bar then return end
    if not Config().anchorMplus then return end
    ns.RunWhenSafe(function() boons.RestorePosition() end, "Boons:anchor")
end)

-- Placement preview turning on or off changes both where an anchored bar hangs
-- and what it draws - the sample slots in Layout only exist while previewing.
-- Nothing else fires here outside a key, so without this the bar would sit on
-- its old layout for as long as the player is stood in a city placing things.
-- Placement preview turning on or off changes both where an anchored bar hangs
-- and what it draws - the sample slots in Layout only exist while previewing.
-- Nothing else fires here outside a key, so without this the bar would sit on
-- its old layout for as long as the player is stood in a city placing things.
--
-- Refreshed inline rather than deferred: Mplus fires this from its own redraw,
-- so the plate is already drawn or hidden and IsAnchored gets a straight answer.
ns:On("HEROPANEL_MPLUS_PREVIEW", function()
    if not (bar and Config().anchorMplus) then return end
    ns.RunWhenSafe(function() boons.Refresh("mplus preview toggled") end,
        "Boons:preview")
end)
