--[[--------------------------------------------------------------------------
    heroPanel - Util.lua

    Shared helpers: timers, combat-safe deferral, script hooking, colour
    parsing, and the throttled frame-tree scanner that later phases reuse for
    line styling and chest-tier maths.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- Timers
--
-- C_Timer.After exists on some 3.3.5a-derived clients and not on others, so
-- ns.After uses it when present and falls back to an OnUpdate queue otherwise.
-- Everything in the addon calls ns.After, never C_Timer directly.
--------------------------------------------------------------------------------

local pending = {}
local timerFrame

local function TimerOnUpdate(_, elapsed)
    local count = #pending
    if count == 0 then
        timerFrame:Hide()
        return
    end
    for i = count, 1, -1 do
        local entry = pending[i]
        entry.remaining = entry.remaining - elapsed
        if entry.remaining <= 0 then
            table.remove(pending, i)
            local ok, err = pcall(entry.fn)
            if not ok then ns.Debug("timer error: %s", tostring(err)) end
        end
    end
    if #pending == 0 then timerFrame:Hide() end
end

function ns.After(delay, fn)
    if type(fn) ~= "function" then return end
    delay = tonumber(delay) or 0

    if C_Timer and C_Timer.After then
        C_Timer.After(delay, fn)
        return
    end

    if not timerFrame then
        timerFrame = CreateFrame("Frame", "HeroPanelTimerFrame")
        timerFrame:Hide()
        timerFrame:SetScript("OnUpdate", TimerOnUpdate)
    end
    table.insert(pending, { remaining = delay, fn = fn })
    timerFrame:Show()
end

--------------------------------------------------------------------------------
-- Combat-safe deferral
--
-- WatchFrame and its children are protected. SetPoint / Show / Hide /
-- SetMovable / SetScale / EnableMouse on a protected frame throw during
-- combat lockdown, so anything touching those goes through ns.RunWhenSafe.
--------------------------------------------------------------------------------

local combatQueue = {}

function ns.RunWhenSafe(fn, tag)
    if type(fn) ~= "function" then return end
    if not InCombatLockdown() then
        local ok, err = pcall(fn)
        if not ok then ns.Debug("deferred call error (%s): %s", tostring(tag), tostring(err)) end
        return true
    end
    table.insert(combatQueue, { fn = fn, tag = tag })
    ns.Debug("deferred until combat ends: %s", tostring(tag or "unnamed"))
    return false
end

ns:On("PLAYER_REGEN_ENABLED", function()
    if #combatQueue == 0 then return end
    local queued = combatQueue
    combatQueue = {}
    ns.Debug("combat over, flushing %d deferred call(s).", #queued)
    for i = 1, #queued do
        local ok, err = pcall(queued[i].fn)
        if not ok then ns.Debug("deferred call error (%s): %s", tostring(queued[i].tag), tostring(err)) end
    end
end)

--------------------------------------------------------------------------------
-- Script hooking
--
-- Never overwrite a script that already exists. HookScript when there is
-- something to hook, SetScript only when the slot is genuinely empty.
--------------------------------------------------------------------------------

function ns.HookScript(frame, script, fn)
    if not frame or type(frame.GetScript) ~= "function" then return false end
    local ok, existing = pcall(frame.GetScript, frame, script)
    if not ok then return false end
    if existing then
        frame:HookScript(script, fn)
    else
        frame:SetScript(script, fn)
    end
    return true
end

--------------------------------------------------------------------------------
-- Colour helpers
--
-- The config stores colours as "#RRGGBB" strings; the WoW API wants 0-1 floats.
--------------------------------------------------------------------------------

function ns.HexToRGB(hex, alpha)
    if type(hex) ~= "string" then return 1, 1, 1, alpha or 1 end
    hex = string.gsub(hex, "^#", "")
    if #hex ~= 6 then return 1, 1, 1, alpha or 1 end
    local r = tonumber(string.sub(hex, 1, 2), 16) or 255
    local g = tonumber(string.sub(hex, 3, 4), 16) or 255
    local b = tonumber(string.sub(hex, 5, 6), 16) or 255
    return r / 255, g / 255, b / 255, alpha or 1
end

function ns.RGBToHex(r, g, b)
    return string.format("#%02X%02X%02X",
        math.floor((r or 0) * 255 + 0.5),
        math.floor((g or 0) * 255 + 0.5),
        math.floor((b or 0) * 255 + 0.5))
end

function ns.Clamp(value, minValue, maxValue)
    value = tonumber(value) or minValue
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

-- Round to a step, e.g. Snap(1.13, 0.1) -> 1.1
function ns.Snap(value, step)
    if not step or step == 0 then return value end
    return math.floor(value / step + 0.5) * step
end

--------------------------------------------------------------------------------
-- Frame-tree walking
--
-- ns.WalkFrameTree does one immediate pass over a frame's regions and child
-- frames. The callback receives (object, info) where info carries:
--     kind       "region" | "child"
--     depth      0 for the root's own regions/children
--     objectType the result of object:GetObjectType()
--     parent     the frame the object hangs off
--     root       the frame the walk started from
--
-- Returning false from the callback prunes recursion into that child.
--------------------------------------------------------------------------------

local DEFAULT_MAX_DEPTH = 6

local function Walk(frame, callback, opts, root, depth, seen)
    if not frame or depth > opts.maxDepth then return end
    if seen[frame] then return end
    seen[frame] = true

    if opts.includeRegions and frame.GetRegions then
        local ok, regions = pcall(function() return { frame:GetRegions() } end)
        if ok then
            for i = 1, #regions do
                local region = regions[i]
                if region then
                    local objectType = region.GetObjectType and region:GetObjectType() or nil
                    callback(region, {
                        kind       = "region",
                        depth      = depth,
                        objectType = objectType,
                        parent     = frame,
                        root       = root,
                    })
                end
            end
        end
    end

    if opts.includeChildren and frame.GetChildren then
        local ok, children = pcall(function() return { frame:GetChildren() } end)
        if ok then
            for i = 1, #children do
                local child = children[i]
                if child then
                    local objectType = child.GetObjectType and child:GetObjectType() or nil
                    local descend = callback(child, {
                        kind       = "child",
                        depth      = depth,
                        objectType = objectType,
                        parent     = frame,
                        root       = root,
                    })
                    if descend ~= false then
                        Walk(child, callback, opts, root, depth + 1, seen)
                    end
                end
            end
        end
    end
end

function ns.WalkFrameTree(frame, callback, options)
    if not frame or type(callback) ~= "function" then return false end
    options = options or {}
    local opts = {
        maxDepth        = options.maxDepth or DEFAULT_MAX_DEPTH,
        includeRegions  = options.includeRegions ~= false,
        includeChildren = options.includeChildren ~= false,
    }
    Walk(frame, callback, opts, frame, 0, {})
    return true
end

--------------------------------------------------------------------------------
-- Throttled frame-tree scanner
--
-- One shared OnUpdate driver runs every active scanner. Each scanner keeps its
-- own elapsed-time accumulator, so a scanner set to 0.1s does at most ~10
-- passes per second regardless of frame rate. Nothing runs per-frame.
--
--     local scanner = ns.NewTreeScanner(someFrame, function(object, info) ... end)
--     scanner:Start()          -- begin throttled scanning
--     scanner:ScanNow()        -- one immediate pass, ignores the throttle
--     scanner:SetInterval(0.2) -- 5 passes/sec instead of 10
--     scanner:Stop()
--------------------------------------------------------------------------------

local MIN_INTERVAL = 0.1   -- hard floor: ~10 scans/sec
local activeScanners = {}
local driver

local function DriverOnUpdate(_, elapsed)
    local anyActive = false
    for scanner in pairs(activeScanners) do
        anyActive = true
        scanner.accumulator = scanner.accumulator + elapsed
        if scanner.accumulator >= scanner.interval then
            scanner.accumulator = 0
            scanner:ScanNow()
        end
    end
    if not anyActive then driver:Hide() end
end

local scannerMethods = {}
local scannerMeta = { __index = scannerMethods }

function scannerMethods:SetFrame(frame)
    self.frame = frame
    return self
end

function scannerMethods:SetInterval(interval)
    self.interval = math.max(tonumber(interval) or MIN_INTERVAL, MIN_INTERVAL)
    return self
end

function scannerMethods:IsRunning()
    return activeScanners[self] and true or false
end

function scannerMethods:ScanNow()
    local frame = self.frame
    if not frame then return false end
    if self.requireVisible and frame.IsVisible and not frame:IsVisible() then return false end

    self.scanCount = self.scanCount + 1
    ns.WalkFrameTree(frame, self.callback, self.options)
    if self.onComplete then self.onComplete(self) end

    if self.once then self:Stop() end
    return true
end

function scannerMethods:Start()
    if not self.frame then return false end
    activeScanners[self] = true
    self.accumulator = self.interval   -- first pass on the next driver tick
    driver:Show()
    return true
end

function scannerMethods:Stop()
    activeScanners[self] = nil
    return self
end

-- ns.NewTreeScanner(frame, callback, options)
--   options.interval        seconds between passes (floored at 0.1)
--   options.maxDepth        recursion limit, default 6
--   options.includeRegions  default true
--   options.includeChildren default true
--   options.requireVisible  skip the pass when the frame is hidden, default true
--   options.once            stop after the first completed pass
--   options.onComplete      called with the scanner after each pass
function ns.NewTreeScanner(frame, callback, options)
    if type(callback) ~= "function" then return nil end
    options = options or {}

    if not driver then
        driver = CreateFrame("Frame", "HeroPanelScanDriver")
        driver:Hide()
        driver:SetScript("OnUpdate", DriverOnUpdate)
    end

    local scanner = setmetatable({
        frame          = frame,
        callback       = callback,
        options        = options,
        interval       = math.max(tonumber(options.interval) or MIN_INTERVAL, MIN_INTERVAL),
        accumulator    = 0,
        scanCount      = 0,
        requireVisible = options.requireVisible ~= false,
        once           = options.once and true or false,
        onComplete     = options.onComplete,
    }, scannerMeta)

    return scanner
end
