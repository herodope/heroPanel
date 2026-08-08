--[[--------------------------------------------------------------------------
    heroPanel - Move.lua

    Move / lock / rescale for both trackers.

    Safety rules this file exists to enforce:
      * WatchFrame is protected. SetPoint, Show, Hide, SetMovable, SetScale and
        EnableMouse on it are only ever called through ns.RunWhenSafe, which
        defers to PLAYER_REGEN_ENABLED while the player is in combat.
      * Scripts are attached with ns.HookScript, which hooks rather than
        replaces anything the game already installed.
      * Blizzard's UIParent layout manager is told to stop managing WatchFrame
        the first time the user actually saves a position, so the game does not
        drag it back on the next layout pass.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.5, 1.5, 0.1

--------------------------------------------------------------------------------
-- Saved geometry access
--------------------------------------------------------------------------------

local function GetSaved(key)
    if not ns.db then return nil end
    ns.db.frame[key] = ns.db.frame[key] or { x = 0, y = 0, scale = 1.0 }
    return ns.db.frame[key]
end

function ns.IsLocked()
    return not ns.db or ns.db.frame.locked ~= false
end

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

-- Blizzard re-anchors WatchFrame from UIParent_ManageFramePositions. Once the
-- user has moved it, take it out of that table so our anchor sticks.
local function ReleaseFromUIParent(frameName)
    if not frameName then return end
    local managed = _G.UIPARENT_MANAGED_FRAME_POSITIONS
    if managed and managed[frameName] then
        ns.savedManagedPositions = ns.savedManagedPositions or {}
        ns.savedManagedPositions[frameName] = managed[frameName]
        managed[frameName] = nil
        ns.Debug("released %s from UIParent frame management.", frameName)
    end
end

function ns.SavePosition(key)
    local record = ns.trackers[key]
    local frame  = record and record.mover
    local saved  = GetSaved(key)
    if not frame or not saved then return false end

    local point, _, _, x, y = frame:GetPoint(1)
    if not point then return false end

    saved.point = point
    saved.x     = x or 0
    saved.y     = y or 0

    ReleaseFromUIParent(record.moverName)
    ns.Debug("saved %s position: %s %.0f, %.0f", key, point, saved.x, saved.y)
    return true
end

function ns.RestorePosition(key)
    local record = ns.trackers[key]
    local frame  = record and record.mover
    local saved  = GetSaved(key)
    if not frame or not saved or not saved.point then return false end

    return ns.RunWhenSafe(function()
        ReleaseFromUIParent(record.moverName)
        frame:ClearAllPoints()
        frame:SetPoint(saved.point, UIParent, saved.point, saved.x or 0, saved.y or 0)
        ns.Debug("restored %s position: %s %.0f, %.0f", key, saved.point, saved.x or 0, saved.y or 0)
    end, "RestorePosition:" .. key)
end

-- Clear the saved anchor (and scale) and hand the frame back to the game.
function ns.ResetPosition(key)
    local keys = key and { key } or ns.TRACKER_KEYS
    for i = 1, #keys do
        local record = ns.trackers[keys[i]]
        if record then
            local saved = GetSaved(record.key)
            saved.point, saved.x, saved.y, saved.scale = nil, 0, 0, 1.0

            local managed = _G.UIPARENT_MANAGED_FRAME_POSITIONS
            local stashed = ns.savedManagedPositions and ns.savedManagedPositions[record.moverName]
            if managed and stashed then
                managed[record.moverName] = stashed
                ns.savedManagedPositions[record.moverName] = nil
            end

            if record.mover then
                local frame = record.mover
                ns.RunWhenSafe(function() frame:SetScale(1.0) end, "ResetScale:" .. record.key)
            end
            ns.Print("%s reset. Reload the UI to put it back where the game wants it.", record.label)
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- Scale
--------------------------------------------------------------------------------

function ns.SetScale(key, scale)
    local record = ns.trackers[key]
    local frame  = record and record.mover
    local saved  = GetSaved(key)
    if not frame or not saved then return false end

    scale = ns.Snap(ns.Clamp(scale, SCALE_MIN, SCALE_MAX), SCALE_STEP)
    saved.scale = scale

    ns.RunWhenSafe(function() frame:SetScale(scale) end, "SetScale:" .. key)
    return true, scale
end

function ns.RestoreScale(key)
    local saved = GetSaved(key)
    local frame = ns.GetMoverFrame(key)
    if not frame or not saved then return false end
    local scale = ns.Clamp(saved.scale or 1.0, SCALE_MIN, SCALE_MAX)
    return ns.RunWhenSafe(function() frame:SetScale(scale) end, "RestoreScale:" .. key)
end

--------------------------------------------------------------------------------
-- Drag / mousewheel wiring
--
-- Scripts are attached exactly once per frame. Lock state is applied by
-- toggling movability and drag registration, not by rewiring scripts.
--------------------------------------------------------------------------------

local function OnDragStart(frame)
    local record = ns.ResolveTracker(frame)
    if not record or ns.IsLocked() then return end
    if InCombatLockdown() and record.protected then return end
    frame:StartMoving()
    record.isMoving = true
end

local function OnDragStop(frame)
    local record = ns.ResolveTracker(frame)
    if not record or not record.isMoving then return end
    frame:StopMovingOrSizing()
    record.isMoving = false
    ns.SavePosition(record.key)
end

local function OnMouseWheel(frame, delta)
    if not IsControlKeyDown() then return end
    local record = ns.ResolveTracker(frame)
    if not record then return end

    local saved   = GetSaved(record.key)
    local current = saved and saved.scale or frame:GetScale() or 1
    local target  = current + (delta > 0 and SCALE_STEP or -SCALE_STEP)

    local ok, applied = ns.SetScale(record.key, target)
    if ok then ns.Debug("%s scale -> %.1f", record.key, applied) end
end

-- Apply the current lock state to one tracker. Everything here touches
-- protected methods, so it all goes through RunWhenSafe.
local function ApplyLockState(key)
    local record = ns.trackers[key]
    local frame  = record and record.mover
    if not frame then return false end

    local locked = ns.IsLocked()
    return ns.RunWhenSafe(function()
        if locked then
            frame:RegisterForDrag()
            frame:SetMovable(false)
            -- Only give the mouse back if we were the ones who took it.
            if record.mouseEnabledByUs then
                frame:EnableMouse(false)
                record.mouseEnabledByUs = nil
            end
        else
            frame:SetMovable(true)
            frame:SetClampedToScreen(true)
            if frame.IsMouseEnabled and not frame:IsMouseEnabled() then
                frame:EnableMouse(true)
                record.mouseEnabledByUs = true
            end
            frame:RegisterForDrag("LeftButton")
        end
    end, "ApplyLockState:" .. key)
end
ns.ApplyLockState = ApplyLockState

local function HookTracker(key)
    local record = ns.trackers[key]
    if not record or not record.found or record.hooked then return false end

    local frame = record.mover
    if not frame then return false end

    ns.HookScript(frame, "OnDragStart", OnDragStart)
    ns.HookScript(frame, "OnDragStop",  OnDragStop)

    -- Ctrl+Scroll to rescale. Mousewheel input does not enable mouse clicks,
    -- so this is safe to leave on while the frame is locked.
    if frame.EnableMouseWheel then
        ns.RunWhenSafe(function() frame:EnableMouseWheel(true) end, "EnableMouseWheel:" .. key)
        ns.HookScript(frame, "OnMouseWheel", OnMouseWheel)
    end

    -- Re-assert our geometry whenever the frame comes back into view; the game
    -- and other addons both like to reposition trackers on show.
    ns.HookScript(frame, "OnShow", function()
        ns.RestorePosition(key)
        ns.RestoreScale(key)
    end)

    record.hooked = true
    ns.Debug("hooked %s (%s).", record.label, tostring(record.moverName))

    ApplyLockState(key)
    ns.RestorePosition(key)
    ns.RestoreScale(key)
    return true
end
ns.HookTracker = HookTracker

--------------------------------------------------------------------------------
-- Public lock API
--------------------------------------------------------------------------------

-- HeroPanel:ToggleLock(trackerKey)
--
-- Flips HEROPANEL_DB.frame.locked. The lock is a single global flag, so the
-- new state is applied to every discovered tracker; trackerKey selects which
-- frame gets reported and is applied first.
function ns:ToggleLock(trackerKey)
    return ns.SetLocked(not ns.IsLocked(), trackerKey)
end

function ns.SetLocked(locked, trackerKey)
    if not ns.db then return false end
    ns.db.frame.locked = locked and true or false

    if trackerKey and ns.trackers[trackerKey] then ApplyLockState(trackerKey) end
    for i = 1, #ns.TRACKER_KEYS do
        local key = ns.TRACKER_KEYS[i]
        if key ~= trackerKey then ApplyLockState(key) end
    end

    ns:Fire("HEROPANEL_LOCK_CHANGED", ns.db.frame.locked)

    if ns.db.frame.locked then
        ns.Print("trackers |cFFC2C6D8locked|r.")
    else
        ns.Print("trackers |cFF79C68Dunlocked|r - drag with the left mouse button, Ctrl+Scroll to resize.")
    end

    if InCombatLockdown() then
        ns.Warn("in combat - the change applies to the objective tracker when you leave combat.")
    end
    return true
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

ns:On("HEROPANEL_TRACKER_FOUND", function(key)
    -- Saved geometry has to exist before the frame is hooked. In practice the
    -- store is ready long before any tracker is found, but a tracker that
    -- turns up first must not be dropped on the floor.
    if not ns.db then ns.InitDB() end
    HookTracker(key)
end)

ns:On("PLAYER_LOGIN", function()
    for i = 1, #ns.TRACKER_KEYS do
        local key = ns.TRACKER_KEYS[i]
        if ns.trackers[key].found then HookTracker(key) end
    end
end)
