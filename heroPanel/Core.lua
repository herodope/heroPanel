--[[--------------------------------------------------------------------------
    heroPanel - Core.lua

    Namespace bootstrap, SavedVariables defaults, event plumbing and the
    debug-gated chat output. Loaded first; every other file registers into
    the tables created here.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

ns.name    = ADDON_NAME
ns.version = "0.2.4"

-- Public API surface. Every other file in the addon registers into this table,
-- and it is what another addon would talk to heroPanel through.
_G.HeroPanel = ns

--------------------------------------------------------------------------------
-- Debug flag
--
-- OFF by default. Mirrors HEROPANEL_DB.debug once SavedVariables are loaded.
-- Debug output is chat/addon-state only - never file system information.
--------------------------------------------------------------------------------

ns.DEBUG = false

local PREFIX     = "|cFF9184D9heroPanel:|r "
local PREFIX_WARN = "|cFFFFAA00heroPanel:|r "

-- Always-on user-facing output. Used sparingly (conflict warning, slash replies).
function ns.Print(msg, ...)
    if select("#", ...) > 0 then msg = string.format(msg, ...) end
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

function ns.Warn(msg, ...)
    if select("#", ...) > 0 then msg = string.format(msg, ...) end
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX_WARN .. tostring(msg))
end

-- Debug output. Silent unless ns.DEBUG is true.
function ns.Debug(msg, ...)
    if not ns.DEBUG then return end
    if select("#", ...) > 0 then msg = string.format(msg, ...) end
    DEFAULT_CHAT_FRAME:AddMessage("|cFF5D5294heroPanel dbg:|r " .. tostring(msg))
end

-- Errors are reported whether or not debug output is on.
--
-- heroPanel pcalls everything that runs off an event, a timer or a hook, so one
-- fault cannot take the addon down with it. The cost of that is silence: an
-- error inside a pcall produces no client error either, so a broken addon looks
-- exactly like an addon that decided to do nothing. Reporting is capped at one
-- message per distinct error so a fault on a repeating event cannot flood chat.
local reportedErrors = {}
local reportedHint   = false

function ns.ReportError(context, err)
    local key = tostring(context) .. "\0" .. tostring(err)
    if reportedErrors[key] then return end
    reportedErrors[key] = true

    ns.Warn("error in %s: %s", tostring(context), tostring(err))
    if not reportedHint then
        reportedHint = true
        ns.Warn("that is a bug. |cFFC2C6D8/hp status|r shows what heroPanel did manage to set up.")
    end
end

--------------------------------------------------------------------------------
-- SavedVariables defaults
--
-- Keys left nil on purpose (frame.<tracker>.point) mean "no user position
-- saved yet - leave the frame where the game put it".
--------------------------------------------------------------------------------

ns.defaults = {
    debug   = false,

    -- Which panels heroPanel skins. One flag each, because they are separate
    -- modules over separate frames: a single `enabled` came first and made it
    -- impossible to hand one panel back without the others.
    --
    -- None of them is a master. "/hp skin on|off" still sets all three, because
    -- that command is the escape hatch and an escape hatch that only frees part
    -- of the UI is not one.
    --
    -- The dungeon panel has a flag here and no block in `panel` below: which
    -- panels are drawn is a different question from what they look like.
    skin = {
        watch   = true,
        mplus   = true,
        dungeon = true,
    },

    frame = {
        locked = true,
        -- auto | own | holder | yield. See the ownership notes in Move.lua.
        ownership = "auto",
        watch   = { point = nil, x = 0, y = 0, scale = 1.0 },
        mplus   = { point = nil, x = 0, y = 0, scale = 1.0 },
        -- The dungeon panel has a position of its own even though it is drawn
        -- from the Mythic+ panel's settings. They are two frames and only one
        -- of them is ever on screen, so sharing a position would look tidy and
        -- would mean neither could be placed while the other was up.
        dungeon = { point = nil, x = 0, y = 0, scale = 1.0 },
    },

    collapsed = {
        watch   = false,
        mplus   = false,
        dungeon = false,
    },

    -- Panel chrome, one block per tracker. One global set covered both once,
    -- which forced a compromise: the Mythic+ panel is a dense block of numbers
    -- that wants something solid behind it, and the quest tracker is a column of
    -- lines a player often wants nearly transparent over the world.
    --
    -- The backdrop texture stays global, below: it is one piece of art, and two
    -- panels drawn from different ones would read as two addons.
    --
    -- There is deliberately no `dungeon` block. The dungeon panel is the
    -- Mythic+ panel with the keystone taken out of it, and it reads
    -- ns.PanelStyle("mplus") and the mplus font roles directly - so the two
    -- cannot be set to disagree, and there is no second copy of these keys to
    -- keep matched. See the header of Dungeon.lua.
    panel = {
        -- The options window's own background, and only that.
        --
        -- The rest of its chrome stays a design token: its border, its corner
        -- and its shadow are what make it read as a dialog over the UI rather
        -- than as a third tracker, and none of them is worth a control. The
        -- background is different because it is the one thing a player looks
        -- at for as long as the window is open.
        options = {
            bgColor = "#161826",
        },
        watch = {
            bgColor     = "#14161F",
            bgOpacity   = 1.0,
            borderColor = "#33364A",
            -- Alpha 0 and border style "none" both turn off every edge
            -- heroPanel draws, and nothing in the options window sets this to 0
            -- any more: the border swatch row's "Transparent" entry was a second
            -- way to say what the style's None already said. The key stays
            -- because Plate.lua reads it.
            borderAlpha = 1.0,
            borderStyle = "hairline",
            -- Square, and not configurable. There are no rounded corners on
            -- 3.3.5a and heroPanel ships no corner art, so this can only ever be
            -- a chamfer of nought to three pixels stepped into the plate, which
            -- is not visible at gameplay distance. The key stays because
            -- Plate.lua reads it and real corner art would make it mean
            -- something again.
            radius      = 0,

            -- A black outline behind every string this panel draws.
            --
            -- Off by default, because the design's colours were chosen against
            -- a solid background and an outline on text that does not need one
            -- only makes it muddy. It earns its place the moment the background
            -- opacity comes down: the panel then reads over whatever the world
            -- is doing behind it, and colour on its own cannot hold text
            -- against a background heroPanel does not control.
            --
            -- The two header strings have carried a one-pixel shadow from the
            -- start for exactly that reason. This is the same idea offered to
            -- the rest of the panel and made adjustable, because how much of it
            -- is wanted depends entirely on how transparent the panel was made.
            textShadow     = false,
            -- 1 is the drop shadow alone; 2 and 3 add the font's OUTLINE and
            -- THICKOUTLINE flags. See ns.ApplyTextShadow.
            textShadowSize = 1,
        },
        mplus = {
            bgColor     = "#14161F",
            bgOpacity   = 1.0,
            borderColor = "#33364A",
            borderAlpha = 1.0,
            borderStyle = "hairline",
            radius      = 0,
            textShadow     = false,
            textShadowSize = 1,
        },
    },

    -- Getting the quest tracker out of the way on its own.
    --
    -- Both of these fade the tracker and then hide it, because neither call is
    -- enough alone. SetAlpha is not protected and lands whatever else is
    -- happening, which is what makes the tracker disappear on time - "hide in
    -- combat" has to take effect at the exact moment lockdown begins, and Hide
    -- is one of the calls the client refuses there. Hide is what makes the
    -- region click-through, so it goes through ns.RunWhenSafe and lands as soon
    -- as the client allows. See the auto-hide notes in Skin.lua.
    autoHide = {
        combat = false,
        mythic = false,
    },

    -- ...and the other answer to the same question. Rather than taking the
    -- quest tracker off the screen for the length of a key, this hangs it off
    -- the bottom of the Mythic+ panel and gives it back its own position when
    -- the run ends - which is what somebody who still wants to read their
    -- objectives in there is asking for. See the anchor notes in Skin.lua.
    --
    -- Off by default: it moves a frame the player placed themselves, and a
    -- setting that does that before being asked is one they go looking for the
    -- way to undo.
    questAnchor = {
        mplus = false,
    },

    bg = {
        texture = "flat",
    },

    -- Party key checks. See Keys.lua.
    --
    -- On by default. It is the whole of what that module does, it costs
    -- nothing until somebody types one of eight short words in party chat, and
    -- a feature that ships switched off is a feature nobody knows is there.
    keys = {
        respond = true,
    },

    -- The Mythic+ boon bar. See Boons.lua.
    --
    -- Off by default, which is the opposite of the call made for key checks
    -- just above, and for the opposite reason. Key checks cost nothing until
    -- somebody types two characters; this puts a bar of fifteen icons on screen
    -- the moment it is installed, and it only means anything inside a Mythic
    -- keystone run. A feature that rearranges somebody's UI before they have
    -- asked for it is one they turn off by uninstalling the addon.
    --
    -- There is no lock of its own. The bar obeys the single global
    -- frame.locked, the same flag the padlock in the options header and
    -- /hp lock set - two locks would be two things to check when a frame will
    -- not move.
    boons = {
        enabled     = false,
        orientation = "horizontal",
        iconSize    = 32,

        -- A word beside each icon saying what the boon does - "Dmg", "Crit",
        -- "AP/SP" - from BoonData's label column.
        --
        -- Off by default, because the bar's own claim is that you aim at a
        -- position rather than read it, and fifteen captions is a bar you read.
        -- It is on offer because that claim only holds once the positions have
        -- been learned, and the run where you are still learning them is the
        -- run where a caption is worth most.
        --
        -- Above rather than below, and the bottom edge is why: the cycle key's
        -- "next up" mark is a bar drawn across it, and the stack count sits in
        -- the corner beside that. A caption underneath lands directly under
        -- both and the three read as one smudge. The top edge carries only the
        -- bound key, in the opposite corner. Either side is one click away.
        labels      = false,
        labelAnchor = "above",

        -- Wrap the bar into rows instead of one long strip. Nineteen icons at
        -- the default size is about seven hundred pixels of screen, which is a
        -- third of a 1920 monitor laid across the middle of it.
        --
        -- rowSize is where the wrap falls, and it is a length rather than a
        -- number of rows - see the note in Boons.lua on why "split into two"
        -- has no sensible answer for a bar shorter than twice the split. Eight
        -- is a little over half the fifteen known boons, so the default lands
        -- as the two rows this was asked for.
        splitRows   = false,
        rowSize     = 8,

        -- Exactly the check the client's own boon UI makes: a party instance
        -- at dungeon difficulty 3. Off means "always show", which is how the
        -- bar gets positioned somewhere other than mid-run.
        mythicOnly  = true,

        -- Both off, because the bar's value is that a boon is always in the
        -- same place. Compacting it moves everything every time a boon is
        -- looted, which is a bar you have to read rather than aim at.
        hideUnowned = false,
        hideEmpty   = false,

        -- Piercing and Adaptation do nothing for a caster, so they can be
        -- marked with a border in a colour nothing else on the bar uses.
        --
        -- Shelved, and off. The feature has no row in the options window and
        -- Boons.lua gates the border off whatever this says - see
        -- MELEE_MARK_SHELVED there. The key is kept so a store round-trips
        -- unchanged and so bringing the feature back is one line rather than a
        -- migration.
        markMelee   = false,

        -- Hang the bar off the bottom of the Mythic+ panel instead of leaving
        -- it wherever it was dragged. Off by default, because it moves a frame
        -- the player has already placed, and because it does nothing at all
        -- when the Mythic+ panel is not on screen.
        anchorMplus = false,

        -- Line the boons you are actually carrying up at the front of the bar,
        -- so the five keybind slots always point at something usable. Off by
        -- default: it reorders the bar as boons are looted and used, and the
        -- bar's other virtue is that a given boon is always in the same place.
        slotOrder   = false,

        -- The full client description in place of heroPanel's one-line
        -- summary. See the note on the summaries in BoonData.lua - three of the
        -- fifteen live strings are wrong, which is why this is not the default.
        rawTooltip  = false,

        -- How many seconds before a boon rots in the bags its icon starts to
        -- glow. 0 is off, and off is the default for the same reason marking
        -- melee boons is: an animation nobody asked for, running on a bar in
        -- the middle of a timed run, is a thing to be opted into.
        --
        -- The values the options window offers are 0, 30, 60 and 120. Stored as
        -- a number rather than a name because it is a threshold and the code
        -- compares it against a remaining time.
        expiryWarn  = 0,

        -- Shift and left-click a boon to say how long it has left in party chat
        -- instead of using it. Off by default: it puts a line in somebody else's
        -- chat window, and a click that used to fire a boon quietly changing
        -- what it does is not something to do to a player who has not asked.
        reportDuration = false,

        point = nil, x = 0, y = 0, scale = 1.0,
    },

    font = {
        -- Resolved through LibSharedMedia by Media.lua. This value is the one
        -- face 3.3.5a always has, and it is answered without asking the library
        -- so the default cannot depend on LSM being installed.
        face = "Friz Quadrata TT",

        -- Absolute point sizes, one per text role. A single base size plus a
        -- per-panel multiplier came first and was dropped: the number a player
        -- set was never the number on screen, and every role inside a panel
        -- moved together.
        --
        -- These are what they say they are: the size that role is drawn at.
        -- The small steps the design puts on one string relative to the rest of
        -- its role - the tracked-quest badge sitting under the header beside
        -- it, a boss row over the body of the Mythic+ panel - stay in the code
        -- as deltas, because they are proportions rather than preferences.
        size = {
            watchHeader = 16,   -- "QUESTS" and the tracked-quest badge
            watchTitle  = 14,   -- quest names
            watchBody   = 12,   -- objectives, descriptions and their counts

            -- The Mythic+ panel splits the same way the quest tracker does,
            -- and for the same reason: one number moved the whole panel, so
            -- making the boss rows readable also made the timer take a third
            -- of the panel. The timer gets its own control because it is the
            -- one element that is deliberately several times everything else.
            mplusHeader = 14,   -- dungeon name and keystone level
            mplusTimer  = 20,   -- the clock
            mplusBody   = 14,   -- chest tiers, enemy forces, boss rows

            options     = 16,   -- this options window
        },
    },

    text = {
        title  = "#E7C67C",
        normal = "#C2C6D8",
        done   = "#79C68D",
    },

    header = {
        -- The quest tracker's header row. The Mythic+ panel's header is not
        -- covered by this: it carries the dungeon name, the keystone level, the
        -- affix icons and that panel's own lock button, and turning all four off
        -- from a control labelled "show header" would be a surprise rather than
        -- a setting. The options panel labels it "Show quest header" for the
        -- same reason.
        show = true,

        -- Nothing tracked, nothing drawn.
        --
        -- With no quests being followed the tracker is an empty column, and the
        -- skin over it is a header reading "QUESTS 0" and a plate around
        -- nothing - chrome that exists only to say there is nothing to say. Off
        -- by default, because a panel that vanishes is a panel a player has to
        -- learn is coming back, and that is a choice rather than a default.
        --
        -- It takes the whole skin with it, not just the header row: hiding the
        -- header alone would leave a bare plate, which reads as the skin having
        -- half failed.
        hideEmpty = false,

        -- Draw the header row only while the cursor is over the panel.
        --
        -- Off by default. The header is where the lock, the quest count and the
        -- collapse caret live, so it is chrome rather than content - and once a
        -- tracker has been arranged and locked, none of the three is needed on
        -- screen while you are reading the quest under it. It stays off by
        -- default all the same, because a control that is invisible until
        -- hovered is one a player has to already know is there.
        --
        -- This fades the row rather than removing it, so the band keeps its
        -- height and the quest lines do not jump the moment the cursor leaves.
        mouseover = false,
    },

    -- Where the options window was left, and how big it was left. point = nil
    -- means "never moved", which centres it - deliberately away from where
    -- either tracker lives, so the config never opens on top of the frames it
    -- configures. x and y are in UIParent's space rather than the window's own,
    -- because the window is scalable and an offset in its own units means a
    -- different place on screen at a different scale.
    -- ...and which of its groups are folded away. Every one of them starts
    -- open, so a store written before the headings became switches opens the
    -- window it always opened. See the section notes in Options.lua.
    options = {
        point = nil, x = 0, y = 0, scale = 1.0,
        sections = { global = true, watch = true, mplus = true, boons = true },
    },

    glyph = {
        -- auto | art | tga | blocks. See the glyph notes in Util.lua; "auto"
        -- uses the shipped art when the client will load it and falls back to
        -- drawing the shapes from solids when it will not.
        mode = "auto",
    },
}

--------------------------------------------------------------------------------
-- Design tokens
--
-- Colours the design fixes but the options panel does not expose. The
-- configurable subset lives in ns.defaults above and is read from ns.db; these
-- are literals on purpose, so a token used in two files cannot drift.
--------------------------------------------------------------------------------

ns.PALETTE = {
    -- The header row reads over whatever the world is doing behind it, because
    -- the panel's opacity is the player's to set and the design's own values
    -- were picked against a solid #14161F. These two are lifted well above the
    -- design's #9AA0B6 and #8B8FA3, and Skin.lua gives both a black shadow -
    -- colour on its own cannot hold text against a background heroPanel does
    -- not control.
    headerLabel = "#DDE1F0",   -- "QUESTS"
    headerCount = "#F3F5FE",   -- the number beside it
    icon        = "#9AA0B6",   -- lock, caret - a step up from the design's #75798C
    muted       = "#8B8FA3",   -- count badge, leading dash
    count       = "#E9E9ED",   -- objective counters
    accent      = "#9184D9",   -- hover tint, left strip
    accentLight = "#B5ABFC",   -- hovered caret, keystone level
    hairline    = "#E9E9ED",   -- divider / badge fill, used at low alpha

    -- Mythic+ panel.
    accentDeep  = "#5D5294",   -- gradient start, heroPanel mark
    bright      = "#F3F5FE",   -- dungeon name, timer, threshold ticks
    chest       = "#ECCE82",   -- highest eligible chest tier
    chestTime   = "#C9A95F",   -- the tier's remaining window
    forces      = "#CFD3E5",   -- "Enemy Forces" label

    -- The boon bar's expiry glow. Warm and outside the rest of the palette on
    -- purpose: gold is already spoken for on that bar - it is the melee-only
    -- mark - and a warning drawn in a colour that means something else is a
    -- warning that has to be read rather than noticed. Nothing else in
    -- heroPanel is this colour, which is the whole point of it.
    expiry      = "#E2724F",   -- boon about to rot in your bags
}

-- Alphas that go with the tokens above.
ns.ALPHA = {
    divider     = 0.12,
    badgeFill   = 0.07,
    hoverTint   = 0.08,
    hoverButton = 0.16,
}

-- Whether one panel's skin is switched on. key is "watch", "mplus" or "dungeon".
--
-- Defended rather than indexed straight, because it is read from boot paths
-- that run before the store has been filled in - a tracker can be discovered
-- before ADDON_LOADED has been seen - and an unfilled store must read as "off"
-- rather than throw.
function ns.SkinEnabled(key)
    local flags = ns.db and ns.db.skin
    if type(flags) ~= "table" then return false end
    return flags[key] and true or false
end

-- Recursively fill missing keys from the defaults tree without clobbering
-- anything the user has already changed.
local function ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            ApplyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end
ns.ApplyDefaults = ApplyDefaults

--------------------------------------------------------------------------------
-- Schema version
--
-- The shape the store is written in. Store.lua carries a store from an older
-- shape up to this one; nothing is discarded on a mismatch.
--
-- The number is a stamp. Its absolute value means nothing - all that matters is
-- that it differs from the last build whose shape was different, and that it
-- only ever goes up. Bump it whenever a key changes meaning or shape, and leave
-- it alone when only a default moves: a changed default reaching an existing
-- store is what ApplyDefaults deliberately does not do, and is not a shape
-- change.
--
-- Bumping it is cheap now. Reconciliation keeps every value that still fits the
-- new shape whether or not anybody wrote a migration step, so the bump costs
-- only the values whose shape genuinely changed. Write a step in
-- Store.MIGRATIONS for the ones reconciliation cannot work out on its own - a
-- key renamed, a key split in two, a value that kept its type and changed its
-- meaning.
--------------------------------------------------------------------------------

local DB_VERSION = 7

-- Published so the harness can assert against the stamp rather than against a
-- copy of the number, which went stale every time this moved.
ns.DB_VERSION = DB_VERSION

function ns.InitDB()
    if type(HEROPANEL_DB) ~= "table" then HEROPANEL_DB = {} end

    -- Store.lua is a file like any other and a file can fail to load. Without
    -- it there is no reconciliation and no chain, but there is still an addon:
    -- defaults over whatever is in the store is what every login did before any
    -- of this existed, and it is a great deal better than no settings at all.
    if not (ns.Store and ns.Store.Prepare) then
        ApplyDefaults(HEROPANEL_DB, ns.defaults)
        HEROPANEL_DB.dbVersion = DB_VERSION
        ns.db    = HEROPANEL_DB
        ns.DEBUG = HEROPANEL_DB.debug and true or false
        ns.Warn("the store module is not loaded - your settings are being read "
            .. "as-is and not checked. Look for a Lua error at login.")
        return ns.db
    end

    -- Store.Prepare returns the table to use rather than editing in place: the
    -- migration chain runs on a copy, so on a shape change this is a different
    -- table from the one that went in.
    local report
    HEROPANEL_DB, report = ns.Store.Prepare(HEROPANEL_DB, DB_VERSION, ns.defaults)

    ns.db    = HEROPANEL_DB
    ns.DEBUG = HEROPANEL_DB.debug and true or false

    -- Announced after ns.DEBUG is set, so the debug-level detail in the report
    -- is not silenced by a flag that is about to be turned on.
    ns.Store.Announce(report)
    return ns.db
end

-- Reset the whole store back to defaults. Used by the options window's Reset.
function ns.ResetDB()
    HEROPANEL_DB = {}
    return ns.InitDB()
end

--------------------------------------------------------------------------------
-- Event plumbing
--
-- One frame for the whole addon. Modules subscribe with ns:On(event, fn);
-- ADDON_LOADED subscribers get the loaded addon name as their first argument.
-- Handlers fire in registration order, which is file order in the .toc, so
-- Core's own bookkeeping always runs first.
--------------------------------------------------------------------------------

local handlers = {}

-- Internal (non-Blizzard) events heroPanel fires itself. Registering one of
-- these must not be forwarded to RegisterEvent.
local INTERNAL_EVENTS = {
    HEROPANEL_READY        = true,   -- ()          DB ready, addon booted
    HEROPANEL_TRACKER_FOUND = true,  -- (key, frame) a tracker frame appeared
    HEROPANEL_LOCK_CHANGED = true,   -- (locked)    lock state flipped
}
ns.INTERNAL_EVENTS = INTERNAL_EVENTS

local eventFrame = CreateFrame("Frame", "HeroPanelEventFrame")
ns.eventFrame = eventFrame

function ns:On(event, fn)
    if type(fn) ~= "function" then return end
    if not handlers[event] then
        handlers[event] = {}
        if not INTERNAL_EVENTS[event] then
            eventFrame:RegisterEvent(event)
        end
    end
    table.insert(handlers[event], fn)
end

function ns:Fire(event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        -- pcall so one broken handler cannot take down the rest of the addon.
        local ok, err = pcall(list[i], ...)
        if not ok then ns.ReportError("handler for " .. tostring(event), err) end
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    ns:Fire(event, ...)
end)

--------------------------------------------------------------------------------
-- Blocked calls
--
-- The client fires ADDON_ACTION_BLOCKED (and ADDON_ACTION_FORBIDDEN, for the
-- calls addons may never make at all) when it refuses a protected call and
-- blames an addon by name. Both carry the addon and the function it was
-- refused, and both are the only moment at which any of that is knowable.
--
-- This exists because it was not being captured. A blocked call is reported to
-- the player as a taint error whose stack is whatever debugstack happened to be
-- holding - usually a FrameXML template with no relation to what actually
-- tripped - so a bug report arrives naming heroPanel and nothing else. What is
-- recorded here is the part the taint error throws away: the function name, and
-- whether the addon was still starting up when it happened.
--
-- Two fields carry most of the diagnostic weight:
--
--   combat  whether the client was in lockdown. A block out of combat is a
--           different bug from a block during one - the first is a call that is
--           never allowed, the second is one that only had to wait.
--   booted  whether heroPanel had finished starting. A block before boot points
--           at the login path, which is the one that runs whether or not the
--           player asked for anything; /reload during a fight is how a player
--           ends up on it mid-combat.
--
-- Reporting is capped the way ns.ReportError caps: one chat line per distinct
-- function, counted after that, so a block on a repeating event cannot flood.
-- The stack is kept but never printed unprompted - it is long, and it is only
-- worth reading once the function name has failed to settle the question.
--------------------------------------------------------------------------------

-- Enough to see a pattern in, few enough to print into chat unpaged.
local BLOCKED_KEEP = 5

-- Newest last. Read by /hp status.
ns.blockedCalls = {}

local blockedSeen = {}

local function RecordBlockedCall(event, addon, func)
    -- Blocks are broadcast for every addon on the machine; this one only
    -- speaks for its own. Another addon's block is that addon's bug, and a
    -- heroPanel status report claiming it is a report that sends someone to
    -- the wrong place.
    if addon ~= ADDON_NAME then return end

    func = tostring(func or "UNKNOWN")

    local existing = blockedSeen[func]
    if existing then
        existing.count = existing.count + 1
        return
    end

    -- debugstack rather than the stack the taint error shows, because this runs
    -- at the moment of the refusal rather than whenever the error was drawn.
    -- Level 2 skips this function itself. It is still not guaranteed to name
    -- heroPanel code - a call blocked inside secure code has no frame of ours
    -- on the stack at all - but when it does, it names the line.
    local ok, stack = pcall(debugstack, 2, 8, 8)

    -- Both of these are pcall'd against the client rather than assumed. This
    -- handler runs at the one moment the information exists and there is no
    -- second chance at it, so a client missing either call has to cost the
    -- record a field rather than the whole thing.
    local stamped, stamp = pcall(date, "%H:%M:%S")

    local record = {
        event  = event,
        func   = func,
        count  = 1,
        combat = InCombatLockdown() and true or false,
        booted = ns.booted and true or false,
        when   = stamped and stamp or nil,
        stack  = ok and stack or nil,
    }

    blockedSeen[func] = record
    table.insert(ns.blockedCalls, record)
    if #ns.blockedCalls > BLOCKED_KEEP then table.remove(ns.blockedCalls, 1) end

    ns.Warn("the client refused a protected call: |cFFC2C6D8%s|r (%s, %s). "
        .. "That is a bug - |cFFC2C6D8/hp status|r reports it.",
        func,
        record.combat and "in combat" or "out of combat",
        record.booted and "after login" or "still starting up")
end

ns:On("ADDON_ACTION_BLOCKED", function(addon, func)
    RecordBlockedCall("ADDON_ACTION_BLOCKED", addon, func)
end)

ns:On("ADDON_ACTION_FORBIDDEN", function(addon, func)
    RecordBlockedCall("ADDON_ACTION_FORBIDDEN", addon, func)
end)

-- Printed by /hp status. Silent when there is nothing to say, so the common
-- case - no blocked calls at all - costs the report one line of nothing.
function ns.PrintBlockedCalls()
    if #ns.blockedCalls == 0 then
        ns.Print("  no protected calls were refused this session.")
        return
    end

    ns.Print("  |cFFFFAA00%d protected call(s) refused|r - this is what to report:",
        #ns.blockedCalls)

    for i = 1, #ns.blockedCalls do
        local record = ns.blockedCalls[i]
        ns.Print("    %s |cFFC2C6D8%s|r - %s, %s%s",
            record.when or "--:--:--",
            record.func,
            record.combat and "in combat" or "out of combat",
            record.booted and "after login" or "|cFFFFAA00still starting up|r",
            record.count > 1 and string.format(" (x%d)", record.count) or "")

        -- One frame of it. The whole stack is on the record for anyone who
        -- asks for it in a debug session; eight lines per block would bury the
        -- rest of the status report.
        if ns.DEBUG and record.stack then
            -- string.char(10) rather than an escape in the pattern: this file
            -- is read and edited far more often than it is run, and a lone
            -- backslash in a string literal is the thing an editor, a diff or a
            -- copy-paste is most likely to quietly eat.
            local newline = string.char(10)
            local stop    = string.find(record.stack, newline, 1, true)
            local first   = stop and string.sub(record.stack, 1, stop - 1) or record.stack
            if first and first ~= "" then
                ns.Print("      |cFF8B8FA3%s|r", first)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------

ns.booted = false

ns:On("ADDON_LOADED", function(loadedAddon)
    if loadedAddon == ADDON_NAME then
        ns.InitDB()
        ns.booted = true
        ns.Debug("SavedVariables loaded, defaults applied.")
        ns:Fire("HEROPANEL_READY")
    end
end)

ns:On("PLAYER_LOGIN", function()
    -- Belt and braces: if for any reason ADDON_LOADED was missed, make sure
    -- the store exists before anything reads ns.db.
    if not ns.db then ns.InitDB() end
end)

--------------------------------------------------------------------------------
-- Slash commands
--
-- Everything the options window offers is settable from here too, and the
-- diagnostics are here only: dump, probe, frame, texture and mplus print reports
-- rather than change anything, which is not what a settings window is for.
--------------------------------------------------------------------------------

local function PrintUsage()
    ns.Print("commands:")
    ns.Print("  |cFFC2C6D8/hp|r - open the options window (|cFF8B8FA3also Interface -> AddOns -> heroPanel|r)")
    ns.Print("  |cFFC2C6D8/hp help|r - this list")
    ns.Print("  |cFFC2C6D8/hp lock|r - lock both trackers in place")
    ns.Print("  |cFFC2C6D8/hp unlock|r - unlock both trackers for dragging")
    ns.Print("  |cFFC2C6D8/hp scale <watch|mplus|dungeon> <0.5-1.5>|r - set tracker scale "
        .. "(|cFF8B8FA3or unlock and drag the grip in a panel's bottom-right corner|r)")
    ns.Print("  |cFFC2C6D8/hp reset [watch|mplus|dungeon|boons]|r - clear saved position and scale")
    ns.Print("  |cFFC2C6D8/hp mode <auto|own|holder|yield>|r - who positions the trackers")
    ns.Print("  |cFFC2C6D8/hp font <8-30>|r - set every text size at once")
    ns.Print("  |cFFC2C6D8/hp fontface <name>|r - set the LibSharedMedia face by name")
    ns.Print("  |cFFC2C6D8/hp glyphs <auto|art|tga|blocks>|r - where the lock and caret come from")
    ns.Print("  |cFFC2C6D8/hp skin [on|off]|r - skin both trackers, or hand them both back "
        .. "(|cFF8B8FA3one at a time in the options window|r)")
    ns.Print("  |cFFC2C6D8/hp keys [on|off]|r - answer !keys / ?keys in group chat by "
        .. "linking your keystone (|cFF8B8FA3no argument links it now|r)")
    ns.Print("  |cFFC2C6D8/hp boons [on|off|expiry]|r - the Mythic+ boon bar "
        .. "(|cFF8B8FA3no argument reports what it resolved; expiry dumps the "
        .. "tooltip lines the warning reads|r)")
    ns.Print("  |cFFC2C6D8/hp status|r - report which frames were found and hooked")
    ns.Print("  |cFFC2C6D8/hp store|r - report what this login did to your saved settings")
    ns.Print("  |cFFC2C6D8/hp dump|r - report the geometry the skin measured")
    ns.Print("  |cFFC2C6D8/hp mplus [preview]|r - report what the Mythic+ panel resolved "
        .. "(|cFF8B8FA3preview draws it outside a key so you can place it|r)")
    ns.Print("  |cFFC2C6D8/hp dungeon [preview]|r - the same for the dungeon panel "
        .. "(|cFF8B8FA3Normal, Heroic and Mythic 0|r)")
    ns.Print("  |cFFC2C6D8/hp probe [all]|r - report what else draws inside the panel; |cFF8B8FA3all|r adds heroPanel's own")
    ns.Print("  |cFFC2C6D8/hp frame <name>|r - everything about one named frame (use the name /framestack gives)")
    ns.Print("  |cFFC2C6D8/hp texture <path>|r - put any texture in the caret's slot, untinted (no path resets)")
    ns.Print("  |cFFC2C6D8/hp debug|r - toggle debug output (currently %s)",
        ns.DEBUG and "|cFF79C68DON|r" or "|cFF8B8FA3OFF|r")
end

SLASH_HEROPANEL1 = "/hp"
SLASH_HEROPANEL2 = "/heropanel"

SlashCmdList["HEROPANEL"] = function(input)
    -- Only the command word is lowercased. The argument is kept as typed,
    -- because one of them is a texture path and Interface\AddOns\... does not
    -- survive being folded to lower case.
    input = string.gsub(input or "", "^%s*(.-)%s*$", "%1")
    local cmd, rawRest = string.match(input, "^(%S*)%s*(.-)$")
    cmd = string.lower(cmd)
    local rest = string.lower(rawRest)

    -- A bare /hp opens the options window; that is what the design puts on the
    -- command and what a player who has not read the list will type. The full
    -- list moved to /hp help, and an unrecognised word still prints it.
    if cmd == "" or cmd == "config" or cmd == "options" then
        if ns.Options then
            ns.Options.Toggle()
        else
            ns.Print("the options module is not loaded - check for a Lua error at login "
                .. "(|cFFC2C6D8/console scriptErrors 1|r, then /reload). |cFFC2C6D8/hp help|r still works.")
        end
    elseif cmd == "help" then
        PrintUsage()
    elseif cmd == "lock" then
        ns.SetLocked(true)
    elseif cmd == "unlock" then
        ns.SetLocked(false)
    elseif cmd == "scale" then
        local key, value = string.match(rest, "^(%S+)%s+([%d%.]+)$")
        if key and value and ns.SetScale(key, tonumber(value)) then
            ns.Print("%s scale set to %.1f.", key, tonumber(value))
        else
            ns.Print("usage: /hp scale <watch|mplus|dungeon> <0.5-1.5>")
        end
    elseif cmd == "reset" then
        -- The boon bar is not one of ns.trackers - it is a frame heroPanel
        -- creates rather than one it finds - so ns.ResetPosition would look it
        -- up, find nothing and say nothing. Answered here so both spellings
        -- work: /hp reset boons and /hp boons reset.
        if rest == "boons" then
            if ns.Boons then ns.Boons.ResetPosition() else ns.Print("the boon bar module is not loaded.") end
        else
            ns.ResetPosition(rest ~= "" and rest or nil)
        end
    elseif cmd == "mode" then
        local mode, which = string.match(rest, "^(%S+)%s*(%S*)$")
        if mode and ns.SetOwnership(mode, which ~= "" and which or nil) then
            ns.Print("positioning mode set to |cFFC2C6D8%s|r.%s", mode,
                mode == "auto" and " heroPanel will adapt if another addon contends." or "")
            ns.ReapplyGeometry()
        else
            ns.Print("usage: /hp mode <auto|own|holder|yield>")
            ns.Print("  |cFF8B8FA3auto|r   - take over, then cooperate if another addon contends")
            ns.Print("  |cFF8B8FA3own|r    - always position the trackers yourself")
            ns.Print("  |cFF8B8FA3holder|r - move the other addon's holder frame instead")
            ns.Print("  |cFF8B8FA3yield|r  - never position; skin only")
        end
    elseif cmd == "glyphs" then
        local valid = false
        for i = 1, #(ns.GLYPH_MODES or {}) do
            if ns.GLYPH_MODES[i] == rest then valid = true end
        end

        if ns.db and valid then
            -- Defended, and answered before the work rather than after it.
            -- ns.db.glyph is missing on a store written by a build that did not
            -- have it, and indexing that throws - which on this client means the
            -- command does nothing at all and says nothing either, because
            -- script errors are off by default. A slash command must always
            -- reply.
            if type(ns.db.glyph) ~= "table" then ns.db.glyph = {} end
            ns.db.glyph.mode = rest
            ns.Print("glyphs: |cFFC2C6D8%s|r.", rest)
            if ns.Skin then
                pcall(ns.Skin.Restyle)
                pcall(ns.Skin.Refresh, "glyph mode changed")
            end
            if ns.Mplus then
                pcall(ns.Mplus.Restyle)
                pcall(ns.Mplus.Refresh, "glyph mode changed")
            end
            if ns.Dungeon then
                pcall(ns.Dungeon.Restyle)
                pcall(ns.Dungeon.Refresh, "glyph mode changed")
            end
        else
            ns.Print("usage: /hp glyphs <auto|art|tga|blocks>  (currently |cFFC2C6D8%s|r)",
                (ns.db and ns.db.glyph and ns.db.glyph.mode) or "auto")
            ns.Print("  |cFF8B8FA3auto|r   - shipped art if the client loads it, drawn shapes if not")
            ns.Print("  |cFF8B8FA3art|r    - always the shipped art, even if it did not report loading")
            ns.Print("  |cFF8B8FA3tga|r    - force the .tga, to see that one file on its own")
            ns.Print("  |cFF8B8FA3blocks|r - always the drawn shapes")
        end
    elseif cmd == "font" then
        -- One number for every role, which is the only thing a single argument
        -- can sensibly mean now that there are seven of them. The per-role sizes
        -- are the options window's job; this is the blunt instrument for
        -- putting the whole skin back to a legible size in one line.
        local size = tonumber(rest)
        if ns.db and size and size >= ns.FONT_SIZE_MIN and size <= ns.FONT_SIZE_MAX then
            for role in pairs(ns.db.font.size) do
                ns.db.font.size[role] = size
            end
            ns.Media.Apply("font size changed")
            if ns.Options then pcall(ns.Options.Sync) end
            ns.Print("every font size set to |cFFC2C6D8%d|r.", size)
        else
            ns.Print("usage: /hp font <%d-%d> - sets every role at once "
                .. "(|cFF8B8FA3/hp|r sets them individually)",
                ns.FONT_SIZE_MIN, ns.FONT_SIZE_MAX)
            if ns.db then
                ns.Print("  quests: header %d, name %d, description %d",
                    ns.GetFontSize(0, "watchHeader"), ns.GetFontSize(0, "watchTitle"),
                    ns.GetFontSize(0, "watchBody"))
                ns.Print("  Mythic+: header %d, timer %d, body %d; this window %d",
                    ns.GetFontSize(0, "mplusHeader"), ns.GetFontSize(0, "mplusTimer"),
                    ns.GetFontSize(0, "mplusBody"), ns.GetFontSize(0, "options"))
            end
        end
    elseif cmd == "fontface" then
        -- The face is chosen from the options panel's dropdown, which previews
        -- each one. This is here for the case the dropdown cannot answer: a
        -- face registered by an addon that loads after everything, or a name
        -- with a character that is awkward to click past.
        if ns.db and rawRest ~= "" then
            ns.db.font.face = rawRest
            ns.Media.Apply("font face changed")
            if ns.Options then pcall(ns.Options.Sync) end
            ns.Print("font face set to |cFFC2C6D8%s|r, drawing from |cFF8B8FA3%s|r.",
                rawRest, tostring(ns.GetFontFile()))
        else
            local faces = ns.Media.ListFonts()
            ns.Print("usage: /hp fontface <name>  (currently |cFFC2C6D8%s|r)",
                (ns.db and ns.db.font.face) or ns.DEFAULT_FONT_FACE)
            ns.Print("  %d face(s) registered with LibSharedMedia.", #faces)
        end
    elseif cmd == "skin" then
        -- Every panel, always. They are separate settings in the options
        -- window; this command is the escape hatch, and one that frees part of
        -- the UI is not one. A bare /hp skin toggles on "is anything skinned",
        -- so a partly-on state turns fully off first rather than fully on.
        local wanted
        if rest == "on" then wanted = true
        elseif rest == "off" then wanted = false
        else
            wanted = not (ns.SkinEnabled("watch") or ns.SkinEnabled("mplus")
                          or ns.SkinEnabled("dungeon"))
        end

        if ns.SetSkinEnabled then
            ns.SetSkinEnabled(nil, wanted)
            -- The options window shows this as a pill and three toggles, so it
            -- has to follow the command as well as the other way round.
            if ns.Options then pcall(ns.Options.Sync) end
            ns.Print("skin %s.", wanted and "|cFF79C68Don|r"
                or "|cFF8B8FA3off - Blizzard's and Ascension's trackers restored|r")
        end
    elseif cmd == "keys" then
        -- A bare /hp keys links your key now. That is what somebody typing the
        -- command wants: the reason to reach for it is that the group is asking
        -- and nothing has appeared, and toggling a setting does not answer them.
        -- It bypasses the throttle, since posting by hand is a decision that the
        -- last answer was not good enough.
        if not ns.Keys then
            ns.Print("the key-check module is not loaded.")
        elseif rest == "on" or rest == "off" then
            ns.Keys.SetEnabled(rest == "on")
            if ns.Options then pcall(ns.Options.Sync) end
            ns.Print("party key checks %s.", rest == "on"
                and "|cFF79C68Don|r" or "|cFF8B8FA3off|r")
        elseif rest ~= "" then
            ns.Print("usage: /hp keys [on|off]  (no argument links your keystone now)")
        else
            local sent, detail = ns.Keys.Announce(true)
            if sent and detail then
                ns.Print("linked %s.", tostring(detail))
            elseif sent then
                ns.Print("no keystone in your bags - said so.")
            else
                ns.Print("could not answer: %s.", tostring(detail))
            end
        end
    elseif cmd == "boons" then
        -- A bare /hp boons reports rather than toggles, which is the opposite
        -- of what /hp keys does with no argument. The two are different kinds
        -- of thing: linking your key is an action worth having on a bare
        -- command, and turning a bar on and off by accident is not.
        if not ns.Boons then
            ns.Print("the boon bar module is not loaded.")
        elseif rest == "on" or rest == "off" then
            ns.Boons.SetEnabled(rest == "on")
            if ns.Options then pcall(ns.Options.Sync) end
            ns.Print("boon bar %s.", rest == "on" and "|cFF79C68Don|r" or "|cFF8B8FA3off|r")
        elseif rest == "reset" then
            ns.Boons.ResetPosition()
        elseif rest == "expiry" then
            -- The one diagnostic that cannot be answered from the code. How
            -- long a boon has left is only written down in its tooltip, and
            -- which line that is on is this client's business - so this prints
            -- the lines and what the parser made of each, which is the whole of
            -- what is needed to fix a warning that fires at the wrong time.
            ns.Boons.DumpExpiry()
        elseif rest ~= "" then
            ns.Print("usage: /hp boons [on|off|reset|expiry]  "
                .. "(no argument reports what it resolved)")
        else
            ns.Boons.Dump()
        end
    elseif cmd == "status" then
        ns.PrintStatus()
    elseif cmd == "store" then
        if ns.Store then
            ns.Store.PrintReport()
        else
            ns.Print("the store module is not loaded.")
        end
    elseif cmd == "dump" then
        if ns.Skin and ns.Skin.Dump then
            ns.Skin.Dump()
        else
            ns.Print("the skin module is not loaded.")
        end
    elseif cmd == "frame" then
        if ns.Skin and ns.Skin.DescribeFrame then
            ns.Skin.DescribeFrame(rawRest)
        else
            ns.Print("the skin module is not loaded.")
        end
    elseif cmd == "texture" then
        if ns.Skin and ns.Skin.TestTexture then
            ns.Skin.TestTexture(rawRest)
        else
            ns.Print("the skin module is not loaded.")
        end
    elseif cmd == "mplus" then
        -- A bare /hp mplus reports, the way /hp boons does, and for the same
        -- reason: it is a diagnostic and turning a panel on by accident is not
        -- what a diagnostic should do.
        if not (ns.Mplus and ns.Mplus.Dump) then
            ns.Print("the Mythic+ module is not loaded.")
        elseif rest == "preview" then
            -- The switch is also in the options window. It is here as well
            -- because placing a panel means dragging it, and the options window
            -- is a 300px rectangle sitting in the middle of the screen you are
            -- trying to drag it across.
            ns.Mplus.SetPreview(not ns.Mplus.IsPreview())
            if ns.Options then pcall(ns.Options.Sync) end
        elseif rest ~= "" then
            ns.Print("usage: /hp mplus [preview]  (no argument reports what it resolved)")
        else
            ns.Mplus.Dump()
        end
    elseif cmd == "dungeon" then
        -- Same shape as /hp mplus above, and for the same reasons: a bare call
        -- reports rather than switches anything on, and the preview is here as
        -- well as in the options window because placing a panel means dragging
        -- it across the screen the options window is sitting in the middle of.
        if not (ns.Dungeon and ns.Dungeon.Dump) then
            ns.Print("the dungeon module is not loaded.")
        elseif rest == "preview" then
            ns.Dungeon.SetPreview(not ns.Dungeon.IsPreview())
            if ns.Options then pcall(ns.Options.Sync) end
        elseif rest ~= "" then
            ns.Print("usage: /hp dungeon [preview]  (no argument reports what it resolved)")
        else
            ns.Dungeon.Dump()
        end
    elseif cmd == "probe" then
        if ns.Skin and ns.Skin.Probe then
            ns.Skin.Probe(rest == "all")
        else
            ns.Print("the skin module is not loaded.")
        end
    elseif cmd == "debug" then
        ns.DEBUG = not ns.DEBUG
        if ns.db then ns.db.debug = ns.DEBUG end
        ns.Print("debug output %s.", ns.DEBUG and "|cFF79C68DON|r" or "|cFF8B8FA3OFF|r")
    else
        PrintUsage()
    end
end
