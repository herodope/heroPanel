--[[--------------------------------------------------------------------------
    heroPanel - Core.lua

    Namespace bootstrap, SavedVariables defaults, event plumbing and the
    debug-gated chat output. Loaded first; every other file registers into
    the tables created here.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

ns.name    = ADDON_NAME
ns.version = "0.1.0"

-- Public API surface. Later phases (options panel, skin) and other addons
-- talk to heroPanel through this table.
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
    enabled = true,
    debug   = false,

    frame = {
        locked = true,
        -- auto | own | holder | yield. See the ownership notes in Move.lua.
        ownership = "auto",
        watch  = { point = nil, x = 0, y = 0, scale = 1.0 },
        mplus  = { point = nil, x = 0, y = 0, scale = 1.0 },
    },

    collapsed = {
        watch = false,
        mplus = false,
    },

    bg = {
        color   = "#14161F",
        opacity = 1.0,
        texture = "flat",
    },

    border = {
        color = "#33364A",
        style = "hairline",
    },

    radius = 8,

    font = {
        -- Resolved through LibSharedMedia by Media.lua. This value is the one
        -- face 3.3.5a always has, and it is answered without asking the library
        -- so the default cannot depend on LSM being installed.
        face = "Friz Quadrata TT",
        -- 12, as the design's spec sheet has it.
        --
        -- This was 13 for a while, on the reasoning that objectives draw half a
        -- point under the base and 12 would therefore put them at 11.5 - under
        -- the tracker's own 12, so the skin would make its own text smaller than
        -- the text it replaced. That is true and it is still the trade, but the
        -- handoff fixes 12 as the default and the slider's marked default has to
        -- mean something. Anyone who wants the old behaviour sets 13 in the
        -- options panel and gets exactly it; Lines.lua's growth clamp is what
        -- bounds how far up this can usefully go.
        size = 12,

        -- Per-panel multipliers on that base. The three panels are different
        -- sizes and sit at different distances from where the player is
        -- looking, so one number for all of them made every change a
        -- compromise. 1.0 means "just the base", which is what every existing
        -- store gets when this key is filled in.
        scale = {
            watch   = 1.0,
            mplus   = 1.0,
            options = 1.0,
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
    },

    -- Where the options window was left. point = nil means "never moved", which
    -- centres it - deliberately away from where either tracker lives, so the
    -- config never opens on top of the frames it configures.
    options = { point = nil, x = 0, y = 0 },

    glyph = {
        -- auto | art | blocks. See the glyph notes in Util.lua; "auto" uses the
        -- shipped art when the client will load it and falls back to drawing
        -- the shapes from solids when it will not.
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
    headerLabel = "#9AA0B6",   -- "OBJECTIVES"
    icon        = "#75798C",   -- lock, caret
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
}

-- Alphas that go with the tokens above.
ns.ALPHA = {
    divider     = 0.12,
    badgeFill   = 0.07,
    hoverTint   = 0.08,
    hoverButton = 0.16,
}

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

function ns.InitDB()
    if type(HEROPANEL_DB) ~= "table" then HEROPANEL_DB = {} end
    ApplyDefaults(HEROPANEL_DB, ns.defaults)
    ns.db    = HEROPANEL_DB
    ns.DEBUG = HEROPANEL_DB.debug and true or false
    return ns.db
end

-- Reset the whole store back to defaults (used by the options panel later).
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
-- Phase 1 has no UI chrome, so lock/unlock and status live here. The options
-- panel replaces most of this later.
--------------------------------------------------------------------------------

local function PrintUsage()
    ns.Print("commands:")
    ns.Print("  |cFFC2C6D8/hp|r - open the options window (|cFF8B8FA3also Interface -> AddOns -> heroPanel|r)")
    ns.Print("  |cFFC2C6D8/hp help|r - this list")
    ns.Print("  |cFFC2C6D8/hp lock|r - lock both trackers in place")
    ns.Print("  |cFFC2C6D8/hp unlock|r - unlock both trackers for dragging")
    ns.Print("  |cFFC2C6D8/hp scale <watch|mplus> <0.5-1.5>|r - set tracker scale")
    ns.Print("  |cFFC2C6D8/hp reset [watch|mplus]|r - clear saved position and scale")
    ns.Print("  |cFFC2C6D8/hp mode <auto|own|holder|yield>|r - who positions the trackers")
    ns.Print("  |cFFC2C6D8/hp font <8-20>|r - set the base text size")
    ns.Print("  |cFFC2C6D8/hp fontface <name>|r - set the LibSharedMedia face by name")
    ns.Print("  |cFFC2C6D8/hp glyphs <auto|art|blocks>|r - where the lock and caret come from")
    ns.Print("  |cFFC2C6D8/hp skin [on|off]|r - skin the trackers, or hand them back to Blizzard")
    ns.Print("  |cFFC2C6D8/hp status|r - report which frames were found and hooked")
    ns.Print("  |cFFC2C6D8/hp dump|r - report the geometry the skin measured")
    ns.Print("  |cFFC2C6D8/hp mplus|r - report what the Mythic+ panel resolved, and from where")
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
            ns.Print("usage: /hp scale <watch|mplus> <0.5-1.5>")
        end
    elseif cmd == "reset" then
        ns.ResetPosition(rest ~= "" and rest or nil)
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
        else
            ns.Print("usage: /hp glyphs <auto|art|tga|blocks>  (currently |cFFC2C6D8%s|r)",
                (ns.db and ns.db.glyph and ns.db.glyph.mode) or "auto")
            ns.Print("  |cFF8B8FA3auto|r   - shipped art if the client loads it, drawn shapes if not")
            ns.Print("  |cFF8B8FA3art|r    - always the shipped art, even if it did not report loading")
            ns.Print("  |cFF8B8FA3tga|r    - force the .tga, to see that one file on its own")
            ns.Print("  |cFF8B8FA3blocks|r - always the drawn shapes")
        end
    elseif cmd == "font" then
        -- Kept alongside the options panel's slider rather than replaced by it.
        -- A changed default does not reach a store that already has the key -
        -- ApplyDefaults only fills in what is missing, by design - so this is
        -- also the quickest way to move a store written by an older build.
        local size = tonumber(rest)
        if ns.db and size and size >= 8 and size <= 20 then
            ns.db.font.size = size
            ns.Media.Apply("font size changed")
            if ns.Options then pcall(ns.Options.Sync) end
            ns.Print("font size set to |cFFC2C6D8%.1f|r.", size)
        else
            ns.Print("usage: /hp font <8-20>  (currently %.1f)",
                (ns.db and ns.db.font.size) or 12)
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
        local wanted
        if rest == "on" then wanted = true
        elseif rest == "off" then wanted = false
        else wanted = not (ns.db and ns.db.enabled) end

        if ns.Skin and ns.Skin.SetEnabled then
            ns.Skin.SetEnabled(wanted)
            -- The options window shows this as a pill and a toggle, so it has
            -- to follow the command as well as the other way round.
            if ns.Options then pcall(ns.Options.Sync) end
            ns.Print("skin %s.", wanted and "|cFF79C68Don|r" or "|cFF8B8FA3off - Blizzard's tracker restored|r")
        end
    elseif cmd == "status" then
        ns.PrintStatus()
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
        if ns.Mplus and ns.Mplus.Dump then
            ns.Mplus.Dump()
        else
            ns.Print("the Mythic+ module is not loaded.")
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
