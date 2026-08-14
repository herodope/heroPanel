--[[--------------------------------------------------------------------------
    heroPanel - Boons.lua

    The Mythic+ boon bar.

    Mythic keystone dungeons on Conquest of Azeroth have Boon Crystals. Clicking
    one hands everybody in line of sight a random "Mythical Boon: X" consumable
    that buffs the whole party for about thirty seconds. They are bind-on-pickup,
    they expire after about three minutes (Bloodlust, eight), they share a
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
        cooldown swipes - is not protected and runs immediately, in combat or
        out. Secure work - binding a button to a bag slot, laying the bar out,
        installing keybinds - is guarded by InCombatLockdown() and deferred
        through ns.RunWhenSafe, which flushes on PLAYER_REGEN_ENABLED.

    A boon looted in the middle of a fight therefore lights up straight away and
    becomes clickable when the fight ends. That is a real limitation and it is
    the one the client's own implementation shipped with.

    TODO: the proper fix is to move the binding into the restricted environment
    with SecureHandlerStateTemplate and RegisterStateDriver, so the attribute is
    set by secure code the client trusts in combat. That is a bigger piece of
    work than v1 wants, and doing it badly is worse than deferring, because the
    failure mode is taint rather than a boon that lights up late.
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

-- How far below the Mythic+ panel the bar hangs when it is anchored to it.
local ANCHOR_GAP = 6

-- Keybind slots. Five, because five is more boons than anybody is holding at
-- once and fifteen rows in the Key Bindings window is a list nobody reads.
local SLOT_COUNT = 5

--------------------------------------------------------------------------------
-- Config
--
-- Read through here rather than indexed straight off ns.db, because this module
-- runs from events that can fire before the store exists - a login where
-- PLAYER_ENTERING_WORLD beats ADDON_LOADED is unusual and not impossible - and
-- an unfilled store must read as "off" rather than throw.
--------------------------------------------------------------------------------

local DEFAULT_CONFIG = {
    enabled     = false,
    orientation = "horizontal",
    iconSize    = 32,
    mythicOnly  = true,
    hideUnowned = false,
    hideEmpty   = false,
    markMelee   = false,
    anchorMplus = false,
    slotOrder   = false,
    rawTooltip  = false,
    scale       = 1.0,
    x           = 0,
    y           = 0,
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
    local ok, probe = pcall(CreateFrame, "Button", nil, UIParent, "SecureActionButtonTemplate")
    caps.secureButtons = ok and type(probe) == "table"
                         and type(probe.SetAttribute) == "function"
    if ok and type(probe) == "table" and probe.Hide then pcall(probe.Hide, probe) end

    caps.itemCooldown  = type(_G.GetItemCooldown) == "function"
    caps.spellDesc     = type(_G.C_Spell) == "table"
                         and type(_G.C_Spell.GetSpellDescription) == "function"
    caps.overrideBinds = type(_G.SetOverrideBindingClick) == "function"
                         and type(_G.ClearOverrideBindings) == "function"

    ns.Debug("boons: bag path %s, events %s, cooldowns %s, clickable %s, keybinds %s.",
        caps.inventoryState and "C_InventoryState" or
            (caps.containerScan and "container scan" or "none"),
        caps.hook and "C_Hook buckets" or "BAG_UPDATE",
        caps.itemCooldown and "yes" or "no",
        caps.secureButtons and "yes" or "no",
        caps.overrideBinds and "yes" or "no")

    if not caps.secureButtons then
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

local function RebuildOwned()
    owned, ownedCount = {}, 0

    if caps.inventoryState then
        ScanInventoryState()
    elseif caps.containerScan then
        ScanContainers()
    end

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
-- Visuals
--
-- Everything in here is safe in combat: SetAlpha, SetDesaturated,
-- SetVertexColor, texture swaps, font strings and cooldown frames are all
-- unprotected. This is what runs when a boon is looted or used mid-fight, and
-- it is the whole of what can run then.
--------------------------------------------------------------------------------

local function RefreshVisuals()
    if not bar then return end
    local cfg = Config()

    for i = 1, #buttons do
        local button = buttons[i]
        local record = button.itemID and owned[button.itemID]
        local entry  = button.entry

        button.icon:SetDesaturated(not record)

        local alpha = record and 1 or UNOWNED_ALPHA
        button.icon:SetAlpha(alpha)
        button.border:SetAlpha(record and 1 or 0.5)

        -- The mark is a property of the boon rather than of what is in the
        -- bags, so it is drawn on an unowned melee boon too - faded with the
        -- icon it is around, or it would be the brightest thing on a button
        -- that is otherwise greyed out.
        local marked = cfg.markMelee and entry and entry.melee and button.itemID ~= nil
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
end

--------------------------------------------------------------------------------
-- Visibility
--
-- The default is exactly the check the client's own UI makes: a party instance
-- at dungeon difficulty 3. "Show only in Mythic dungeons" off turns that check
-- into nothing, which is how the bar gets positioned somewhere other than
-- mid-run.
--
-- IsInInstance returns 1 rather than true on this client, so it is tested for
-- truth rather than compared - a build that returns a boolean must not turn the
-- bar off.
--------------------------------------------------------------------------------

local function InMythicDungeon()
    if type(_G.IsInInstance) ~= "function" then return false end

    local ok, inInstance, instanceType = pcall(_G.IsInInstance)
    if not ok or not inInstance or inInstance == 0 then return false end
    if instanceType ~= "party" then return false end

    if type(_G.GetDungeonDifficulty) ~= "function" then return false end
    local gotDifficulty, difficulty = pcall(_G.GetDungeonDifficulty)
    return gotDifficulty and difficulty == 3
end

local function ShouldShow()
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
local function ApplyVisibility()
    if not bar then return end

    local show = ShouldShow()
    bar:SetAlpha(show and 1 or 0)

    if InCombatLockdown() then
        QueueSecure("visibility")
    elseif show then
        bar:Show()
    else
        bar:Hide()
    end

    if ticker then
        if show and not ticker:IsRunning() then
            ticker:Start()
        elseif not show and ticker:IsRunning() then
            ticker:Stop()
        end
    end
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
--------------------------------------------------------------------------------

local function BarOrder()
    if not Config().slotOrder then return buttons end

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

    if Config().slotOrder then
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
--------------------------------------------------------------------------------

local function Layout()
    if not bar or InCombatLockdown() then return end

    local cfg        = Config()
    local size       = ns.Clamp(cfg.iconSize or 32, ICON_MIN, ICON_MAX)
    local vertical   = (cfg.orientation == "vertical")
    local hideUnowned = cfg.hideUnowned and true or false
    local slotOrder  = cfg.slotOrder and true or false

    local order = BarOrder()
    local offset, lastGroup, placed = BAR_PAD, nil, 0

    for i = 1, #order do
        local button  = order[i]
        local visible = button.itemID ~= nil
            and (not hideUnowned or owned[button.itemID] ~= nil)

        button:SetWidth(size)
        button:SetHeight(size)

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
            if lastGroup and group ~= lastGroup then offset = offset + GROUP_GAP end
            lastGroup = group

            button:ClearAllPoints()
            if vertical then
                button:SetPoint("TOPLEFT", bar, "TOPLEFT", BAR_PAD, -offset)
            else
                button:SetPoint("TOPLEFT", bar, "TOPLEFT", offset, -BAR_PAD)
            end
            button:Show()

            offset = offset + size + ICON_GAP
            placed = placed + 1
        else
            button:Hide()
        end
    end

    -- The trailing gap belongs to a button that is not there.
    if placed > 0 then offset = offset - ICON_GAP end
    local extent = offset + BAR_PAD
    local thickness = size + BAR_PAD * 2

    -- A bar with nothing in it still needs a rectangle, or the drag handle and
    -- the resize grip have nothing to sit on. This is what "hide unowned" plus
    -- an empty bag comes out as, and it is reachable on purpose: the player can
    -- still find and move the bar.
    if placed == 0 then extent = size + BAR_PAD * 2 end

    if vertical then
        bar:SetWidth(thickness)
        bar:SetHeight(extent)
    else
        bar:SetWidth(extent)
        bar:SetHeight(thickness)
    end

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
                        button:GetName(), "LeftButton")
                end
                if key2 then
                    pcall(_G.SetOverrideBindingClick, bar, true, key2,
                        button:GetName(), "LeftButton")
                end
            end
        end
    end
end

-- Reached from Bindings.xml when a bound key fires without an override behind
-- it, which means the bar is off. Public because the XML calls it by name.
function boons.BindingFallback(index)
    if boons.IsEnabled() then
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
            end

            if itemID then byItem[itemID] = button end
        end
    end
end

function ApplySecure(reason)
    if not bar or InCombatLockdown() then return end

    AssignSpares()

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
    end

    Layout()
    -- After the layout, because anchoring to the Mythic+ panel puts the bar's
    -- TOP against that panel's BOTTOM and the bar's height is what Layout has
    -- just decided.
    boons.RestorePosition()
    ApplyBindings()

    local show = ShouldShow()
    if show then bar:Show() else bar:Hide() end
    bar:SetAlpha(show and 1 or 0)

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
            bar:ClearAllPoints()
            bar:SetPoint("TOP", anchor, "BOTTOM", 0, -ANCHOR_GAP)
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

    button:SetScript("OnEnter", ButtonOnEnter)
    button:SetScript("OnLeave", ButtonOnLeave)

    -- HookScript rather than SetScript. SecureActionButtonTemplate installs its
    -- own OnClick and that is the one that actually uses the item; replacing it
    -- would leave a button that looks right and does nothing.
    button:HookScript("OnClick", function(self)
        local record = self.itemID and owned[self.itemID]
        if not record then return end

        if caps.itemCooldown then
            local ok, start, duration, enable = pcall(_G.GetItemCooldown, self.itemID)
            -- A boon that is already on cooldown was not used, so there is
            -- nothing to propagate and nothing to take out of the bags. The
            -- 0.01 window is the reference's: a cooldown that started this
            -- instant is the one this click just caused.
            if ok and duration and duration > 0 and (GetTime() - (start or 0)) >= 0.01 then
                return
            end
            if ok then PropagateCooldown(start, duration, enable) end
        end

        -- Taken out of the local picture without waiting for the bag event, so
        -- the icon goes grey on the click rather than a tenth of a second
        -- later. The next rebuild is authoritative either way, so being wrong
        -- here costs one refresh and not a stuck button.
        if #record.slots <= 1 then
            owned[self.itemID] = nil
            ownedCount = math.max(0, ownedCount - 1)
        else
            table.remove(record.slots, 1)
            record.count = math.max(1, record.count - 1)
        end

        RefreshVisuals()

        -- Deliberately not a full Refresh. That would re-read the bags, and the
        -- server has not taken the boon out of them yet - so the icon would
        -- light straight back up and go out again a tenth of a second later
        -- when the bag event lands. QueueSecure runs inline when the player is
        -- not fighting, so the button is unbound now either way.
        QueueSecure("boon used")
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

    -- Normally probed at login, before this runs. Asked for here as well
    -- because the options window can reach SetEnabled first if the store is
    -- ready and login is not, and a pool built with caps empty would be a pool
    -- of plain buttons for the rest of the session.
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

    local index = 0
    for i = 1, #ns.BoonData.ORDER do
        index = index + 1
        buttons[index] = BuildButton(index, ns.BoonData.ORDER[i])
    end
    for _ = 1, SPARE_SLOTS do
        index = index + 1
        buttons[index] = BuildButton(index, nil)
    end

    ticker = ns.NewTicker(COOLDOWN_TICK, PollCooldowns)

    ns.Debug("boons: built %d button(s) (%d known, %d spare).",
        #buttons, #ns.BoonData.ORDER, SPARE_SLOTS)
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

--------------------------------------------------------------------------------
-- Bag events
--
-- The Ascension path first. C_Hook:RegisterBucket coalesces a burst of bag
-- changes into one callback with the events batched, and NEW_BAG_ITEM_ADDED /
-- BAG_ITEM_REMOVED carry the bag, slot, itemID and count - so a bag change that
-- has nothing to do with boons costs a loop over a handful of entries rather
-- than a scan of five bags.
--
-- The handler runs securecall'd when the execution path is already insecure,
-- which is what the client's own boon UI does. It is not that anything below is
-- protected; it is that a bucket callback can arrive on a tainted path, and
-- work done on one taints what it touches. The buttons are secure frames, so
-- that matters here in a way it does not anywhere else in heroPanel.
--------------------------------------------------------------------------------

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
        local itemID = type(event) == "table" and event[3] or nil
        if ClassifyItem(itemID) then
            boons.Refresh("boon added or removed")
            return
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

local function SubscribeBagEvents()
    if caps.hook then
        local ok = pcall(function()
            _G.C_Hook:RegisterBucket(bar,
                "NEW_BAG_ITEM_ADDED, BAG_ITEM_REMOVED, BAG_ITEM_COUNT_CHANGED",
                0.1, BagEventEntry)
        end)
        if ok then
            ns.Debug("boons: subscribed to C_Hook bag buckets.")
            return "C_Hook"
        end
        ns.Debug("boons: C_Hook:RegisterBucket refused; falling back to BAG_UPDATE.")
    end

    -- The stock route. BAG_UPDATE says nothing about what changed, so every one
    -- of them costs a scan - which is why it is the fallback and not the
    -- default. Throttled onto the next frame so moving a stack around a bag
    -- does not scan five times.
    local queued = false
    ns:On("BAG_UPDATE", function()
        if queued then return end
        queued = true
        ns.After(0.1, function()
            queued = false
            boons.Refresh("bag update")
        end)
    end)
    return "BAG_UPDATE"
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

    if ownedCount == 0 then
        ns.Print("  |cFF8B8FA3no boons in your bags|r")
    else
        for itemID, record in pairs(owned) do
            local entry = ns.BoonData.BY_ID[itemID]
            ns.Print("  |cFFC2C6D8%s|r (%d) x%d - bag %d slot %d",
                entry and entry.name or "unknown", Int(itemID), Int(record.count),
                Int(record.slots[1].bag), Int(record.slots[1].slot))
        end
    end

    for i = 1, #unknownIDs do
        ns.Warn("  itemID %d is a boon heroPanel does not know about - "
            .. "worth adding to BoonData.lua.", unknownIDs[i])
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

    -- Built whether or not the feature is on. The pool cannot be created in
    -- combat, so building it lazily on first enable would mean "turn the boon
    -- bar on" failing during a pull - and an empty hidden frame costs nothing.
    BuildBar()

    local block = Saved()
    if block then
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
