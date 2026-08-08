--[[--------------------------------------------------------------------------
    heroPanel - Trackers.lua

    Finds the two frames heroPanel cares about and keeps a small record for
    each one:

        watch  the default objective tracker (WatchFrame). WatchFrameHolder is
               preferred as the drag target when the client provides it.
        mplus  MythicPlusObjectiveTracker, supplied by Ascension_MythicPlus.
               It frequently does not exist yet at ADDON_LOADED, so it is
               polled rather than assumed.

    Also exposes ns.GetTrackerHeight, the collapse-aware height helper that
    later phases anchor their own chrome against.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- Tracker registry
--------------------------------------------------------------------------------

-- Candidate globals per tracker, most likely name first. The first one that
-- resolves to a real frame wins.
ns.trackers = {
    watch = {
        key         = "watch",
        label       = "Objective tracker",
        candidates  = { "WatchFrame" },
        -- Frame that actually gets dragged. Prefer the holder when it exists,
        -- because moving the holder moves the tracker without touching the
        -- protected frame's own anchors.
        moverFirst  = { "WatchFrameHolder", "WatchFrame" },
        protected   = true,
        frame       = nil,
        mover       = nil,
        found       = false,
        hooked      = false,
    },
    mplus = {
        key         = "mplus",
        label       = "Mythic+ tracker",
        candidates  = { "MythicPlusObjectiveTracker", "MythicPlusObjectiveTrackerFrame" },
        moverFirst  = { "MythicPlusObjectiveTracker", "MythicPlusObjectiveTrackerFrame" },
        protected   = false,
        frame       = nil,
        mover       = nil,
        found       = false,
        hooked      = false,
    },
}

ns.TRACKER_KEYS = { "watch", "mplus" }

local function IsFrame(object)
    return type(object) == "table"
       and type(object.GetObjectType) == "function"
       and type(object.SetPoint) == "function"
end

local function ResolveFirst(names)
    for i = 1, #names do
        local object = _G[names[i]]
        if IsFrame(object) then return object, names[i] end
    end
    return nil, nil
end

-- Look up a tracker record from a key ("watch"), a record, or a frame.
function ns.ResolveTracker(target)
    if type(target) == "string" then
        return ns.trackers[target]
    end
    if type(target) == "table" then
        if target.key and ns.trackers[target.key] == target then return target end
        for _, record in pairs(ns.trackers) do
            if record.frame == target or record.mover == target then return record end
        end
    end
    return nil
end

function ns.GetTrackerFrame(key)
    local record = ns.trackers[key]
    return record and record.frame or nil
end

-- The frame to move / scale for a tracker. Prefers the holder when present.
function ns.GetMoverFrame(key)
    local record = ns.trackers[key]
    return record and record.mover or nil
end

--------------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------------

local function DiscoverTracker(key)
    local record = ns.trackers[key]
    if not record or record.found then return record and record.found end

    local frame, frameName = ResolveFirst(record.candidates)
    if not frame then return false end

    local mover, moverName = ResolveFirst(record.moverFirst)

    record.frame     = frame
    record.frameName = frameName
    record.mover     = mover or frame
    record.moverName = moverName or frameName
    record.found     = true

    ns.Debug("found %s: frame=%s mover=%s", record.label, tostring(frameName), tostring(record.moverName))
    ns:Fire("HEROPANEL_TRACKER_FOUND", key, frame)
    return true
end
ns.DiscoverTracker = DiscoverTracker

-- Polling for trackers that arrive late. Backs off from every 0.5s to every
-- 2s and gives up after roughly a minute so a client without
-- Ascension_MythicPlus does not poll forever.
local POLL_MAX_ATTEMPTS = 40

local function PollForTracker(key, attempt)
    if ns.trackers[key] and ns.trackers[key].found then return end
    attempt = attempt or 1

    if DiscoverTracker(key) then return end

    if attempt >= POLL_MAX_ATTEMPTS then
        ns.Debug("gave up looking for %s after %d attempts.",
            ns.trackers[key] and ns.trackers[key].label or key, attempt)
        return
    end

    local delay = attempt < 10 and 0.5 or 2.0
    ns.After(delay, function() PollForTracker(key, attempt + 1) end)
end
ns.PollForTracker = PollForTracker

ns:On("ADDON_LOADED", function(loadedAddon)
    if loadedAddon == ADDON_NAME then
        -- WatchFrame is part of the base UI and is normally already there.
        if not DiscoverTracker("watch") then PollForTracker("watch", 1) end
        -- If Ascension_MythicPlus was loaded ahead of us its ADDON_LOADED has
        -- already been and gone, so look for its tracker directly.
        DiscoverTracker("mplus")
    elseif loadedAddon == "Ascension_MythicPlus" then
        ns.Debug("Ascension_MythicPlus loaded, looking for its tracker.")
        if not DiscoverTracker("mplus") then PollForTracker("mplus", 1) end
    end
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    -- The M+ tracker is often created on demand rather than at addon load, so
    -- take another look on every world entry (login, reload, zone-in).
    for i = 1, #ns.TRACKER_KEYS do
        local key = ns.TRACKER_KEYS[i]
        if not ns.trackers[key].found then PollForTracker(key, 1) end
    end
end)

--------------------------------------------------------------------------------
-- Collapse state
--------------------------------------------------------------------------------

-- Approximate header height used when a collapsed frame reports a height that
-- still includes its hidden body.
ns.HEADER_HEIGHT = 32

function ns.IsCollapsed(target)
    local record = ns.ResolveTracker(target)
    if not record then return false end

    -- Trust the frame's own flag when it has one; the WatchFrame collapse
    -- button sets this, and heroPanel must not fight it.
    local frame = record.frame
    if frame and frame.collapsed ~= nil then return frame.collapsed and true or false end

    local db = ns.db
    return db and db.collapsed and db.collapsed[record.key] and true or false
end

function ns.SetCollapsedState(target, collapsed)
    local record = ns.ResolveTracker(target)
    if not record or not ns.db then return false end
    ns.db.collapsed[record.key] = collapsed and true or false
    return true
end

--------------------------------------------------------------------------------
-- Height helper
--
-- ns.GetTrackerHeight(target) -> height, scaledHeight
--
--   target may be a key ("watch"), a tracker record, or either tracker frame.
--   Returns 0, 0 when the tracker is missing or hidden.
--   When collapsed, returns the header height rather than the frame's stale
--   full height, so callers can anchor to what is actually on screen.
--------------------------------------------------------------------------------

-- Fallback for frames that report a zero or nil height: measure the union of
-- the visible children instead.
local function MeasureVisibleChildren(frame)
    local top, bottom
    ns.WalkFrameTree(frame, function(object, info)
        if info.kind ~= "child" then return end
        if not (object.IsShown and object:IsShown()) then return false end
        local objTop, objBottom = object:GetTop(), object:GetBottom()
        if objTop and objBottom then
            if not top or objTop > top then top = objTop end
            if not bottom or objBottom < bottom then bottom = objBottom end
        end
    end, { maxDepth = 2, includeRegions = false })

    if top and bottom then return top - bottom end
    return 0
end

function ns.GetTrackerHeight(target)
    local record = ns.ResolveTracker(target)

    -- Allow a raw frame that is not one of our trackers, so later phases can
    -- reuse this for their own panels.
    local frame = record and record.frame or (IsFrame(target) and target or nil)
    if not frame then return 0, 0 end
    if frame.IsVisible and not frame:IsVisible() then return 0, 0 end

    local height
    if record and ns.IsCollapsed(record) then
        height = record.headerHeight or ns.HEADER_HEIGHT
        -- If the frame genuinely shrank on collapse, believe the smaller value.
        local actual = frame:GetHeight() or 0
        if actual > 0 and actual < height then height = actual end
    else
        height = frame:GetHeight() or 0
        if height <= 0 then height = MeasureVisibleChildren(frame) end
    end

    local scale = (frame.GetScale and frame:GetScale()) or 1
    return height, height * scale
end

--------------------------------------------------------------------------------
-- Status report
--------------------------------------------------------------------------------

function ns.PrintStatus()
    ns.Print("v%s - status", ns.version)
    for i = 1, #ns.TRACKER_KEYS do
        local record = ns.trackers[ns.TRACKER_KEYS[i]]
        if record.found then
            local saved = ns.db and ns.db.frame and ns.db.frame[record.key]
            local mode = ns.GetMode and ns.GetMode(record.key) or "own"

            ns.Print("  |cFF79C68D%s|r found (%s) - %s, scale %.1f%s",
                record.label,
                tostring(record.frameName),
                record.hooked and "|cFF79C68Dhooked|r" or "|cFFFFAA00not hooked|r",
                (saved and saved.scale) or 1,
                (saved and saved.point) and ", position saved" or ", no saved position")

            if mode == "yield" then
                ns.Print("    positioning: |cFFFFAA00yielded|r to another addon%s",
                    record.holderName and (" (" .. tostring(record.holderName) .. ")") or "")
            elseif mode == "holder" then
                ns.Print("    positioning: moving holder |cFFC2C6D8%s|r", tostring(record.holderName))
            else
                ns.Print("    positioning: heroPanel, moving |cFFC2C6D8%s|r",
                    tostring(record.moverName))
            end

            if record.holderName and mode == "own" then
                ns.Print("    another addon docks it into |cFF8B8FA3%s|r", tostring(record.holderName))
            end
        else
            ns.Print("  |cFF8B8FA3%s not found|r", record.label)
        end
    end
    ns.Print("  frames are |cFFC2C6D8%s|r, mode |cFFC2C6D8%s|r. Debug output is %s.",
        (ns.db and ns.db.frame.locked) and "locked" or "unlocked",
        (ns.db and ns.db.frame.ownership) or "auto",
        ns.DEBUG and "|cFF79C68DON|r" or "|cFF8B8FA3OFF|r")

    if ns.Skin and ns.Skin.PrintStatus then
        ns.Skin.PrintStatus()
    else
        -- Skin.lua threw while loading, so its half of the addon is simply not
        -- there. Worth naming: it looks identical to a skin that is switched off.
        ns.Print("  |cFFFFAA00skin module not loaded|r - check for a Lua error at login "
            .. "(|cFFC2C6D8/console scriptErrors 1|r, then /reload)")
    end
end
