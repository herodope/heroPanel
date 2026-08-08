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
        face = "Friz Quadrata TT",
        size = 12,
    },

    text = {
        title  = "#E7C67C",
        normal = "#C2C6D8",
        done   = "#79C68D",
    },

    header = {
        show = true,
    },
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
        if not ok then ns.Debug("handler error on %s: %s", tostring(event), tostring(err)) end
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
    ns.Print("  |cFFC2C6D8/hp lock|r - lock both trackers in place")
    ns.Print("  |cFFC2C6D8/hp unlock|r - unlock both trackers for dragging")
    ns.Print("  |cFFC2C6D8/hp scale <watch|mplus> <0.5-1.5>|r - set tracker scale")
    ns.Print("  |cFFC2C6D8/hp reset [watch|mplus]|r - clear saved position and scale")
    ns.Print("  |cFFC2C6D8/hp mode <auto|own|holder|yield>|r - who positions the trackers")
    ns.Print("  |cFFC2C6D8/hp status|r - report which frames were found and hooked")
    ns.Print("  |cFFC2C6D8/hp debug|r - toggle debug output (currently %s)",
        ns.DEBUG and "|cFF79C68DON|r" or "|cFF8B8FA3OFF|r")
end

SLASH_HEROPANEL1 = "/hp"
SLASH_HEROPANEL2 = "/heropanel"

SlashCmdList["HEROPANEL"] = function(input)
    input = string.lower(string.gsub(input or "", "^%s*(.-)%s*$", "%1"))
    local cmd, rest = string.match(input, "^(%S*)%s*(.-)$")

    if cmd == "lock" then
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
    elseif cmd == "status" then
        ns.PrintStatus()
    elseif cmd == "debug" then
        ns.DEBUG = not ns.DEBUG
        if ns.db then ns.db.debug = ns.DEBUG end
        ns.Print("debug output %s.", ns.DEBUG and "|cFF79C68DON|r" or "|cFF8B8FA3OFF|r")
    else
        PrintUsage()
    end
end
