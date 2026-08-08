--[[--------------------------------------------------------------------------
    heroPanel - Move.lua

    Move / lock / rescale for both trackers.

    Safety rules this file exists to enforce:
      * WatchFrame is protected. SetPoint, Show, Hide, SetMovable, SetScale and
        EnableMouse on it are only ever called through ns.RunWhenSafe, which
        defers to PLAYER_REGEN_ENABLED while the player is in combat.
      * Scripts are attached with ns.HookScript, which hooks rather than
        replaces anything the game already installed.
      * Global functions are extended with hooksecurefunc, never overwritten.

    Holding a position on WatchFrame takes three separate measures, because on
    a 3.3.5a client the game re-anchors it from more than one place:
      1. it is removed from UIPARENT_MANAGED_FRAME_POSITIONS,
      2. UIParent_ManageFramePositions is hooked so our anchor is re-applied
         after any full layout pass,
      3. the frame's own SetPoint is hooked, so an anchor change from anywhere
         else - including client code we cannot see - is corrected on the next
         frame.
    Positions are stored as UIParent-space offsets from TOPLEFT rather than
    whatever anchor the frame happened to be using, so restoring is exact and
    survives a scale change.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.5, 1.5, 0.1

-- Bumped when the meaning of the stored geometry changes. Anything older is
-- dropped rather than misinterpreted.
local GEOMETRY_VERSION = 2

--------------------------------------------------------------------------------
-- Saved geometry access
--------------------------------------------------------------------------------

local function GetSaved(key)
    if not ns.db then return nil end
    local saved = ns.db.frame[key]
    if type(saved) ~= "table" then
        saved = { x = 0, y = 0, scale = 1.0 }
        ns.db.frame[key] = saved
    end

    -- Geometry written by an earlier version stored whatever anchor point the
    -- frame happened to have, which is not reproducible. Discard it.
    if saved.point and saved.v ~= GEOMETRY_VERSION then
        ns.Debug("dropping %s position saved by an older version.", key)
        saved.point, saved.x, saved.y, saved.v = nil, 0, 0, nil
    end

    return saved
end

function ns.IsLocked()
    return not ns.db or ns.db.frame.locked ~= false
end

--------------------------------------------------------------------------------
-- Coordinate helpers
--
-- SetPoint offsets are measured in the moved frame's own coordinate space, so
-- they change meaning when the frame is rescaled. Offsets are therefore stored
-- in UIParent space and converted on the way in and out.
--------------------------------------------------------------------------------

local function GetUIOffsets(frame)
    local frameScale = frame:GetEffectiveScale()
    local uiScale    = UIParent:GetEffectiveScale()
    if not frameScale or frameScale == 0 or not uiScale or uiScale == 0 then return nil end

    local left, top = frame:GetLeft(), frame:GetTop()
    if not left or not top then return nil end

    local x = (left * frameScale - UIParent:GetLeft() * uiScale) / uiScale
    local y = (top  * frameScale - UIParent:GetTop()  * uiScale) / uiScale
    return x, y
end

local function ApplyUIOffsets(frame, x, y)
    local frameScale = frame:GetEffectiveScale()
    local uiScale    = UIParent:GetEffectiveScale()
    if not frameScale or frameScale == 0 then return false end

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x * uiScale / frameScale, y * uiScale / frameScale)

    -- Tells the client the frame is where the player wants it. Blizzard's
    -- layout code skips user-placed frames, so this is what stops the tracker
    -- being dragged back to its docked spot on the next layout pass.
    if frame.SetUserPlaced and frame.IsUserPlaced and not frame:IsUserPlaced() then
        pcall(frame.SetUserPlaced, frame, true)
    end
    return true
end

--------------------------------------------------------------------------------
-- Anchor ownership
--------------------------------------------------------------------------------

-- Take the frame out of Blizzard's layout manager so a full layout pass stops
-- trying to place it. The previous entry is stashed so /hp reset can undo it.
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

-- True while heroPanel is the one moving a frame, so the SetPoint hook can
-- tell our own anchor changes apart from everyone else's.
local applying = {}

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

function ns.SavePosition(key)
    local record = ns.trackers[key]
    local frame  = record and record.mover
    local saved  = GetSaved(key)
    if not frame or not saved then return false end

    local x, y = GetUIOffsets(frame)
    if not x then return false end

    saved.point = "TOPLEFT"
    saved.x     = x
    saved.y     = y
    saved.v     = GEOMETRY_VERSION

    ReleaseFromUIParent(record.moverName)

    -- Re-anchor to the canonical point, so what is on screen and what is in the
    -- store cannot drift apart. If combat started mid-drag this waits, which is
    -- safe: the stored offsets already describe where the frame is.
    ns.RunWhenSafe(function()
        applying[key] = true
        ApplyUIOffsets(frame, x, y)
        applying[key] = nil
    end, "Normalize:" .. key)

    ns.Debug("saved %s position: %.0f, %.0f", key, x, y)
    return true
end

function ns.RestorePosition(key)
    local record = ns.trackers[key]
    local frame  = record and record.mover
    local saved  = GetSaved(key)
    if not frame or not saved or not saved.point then return false end

    return ns.RunWhenSafe(function()
        ReleaseFromUIParent(record.moverName)
        applying[key] = true
        ApplyUIOffsets(frame, saved.x or 0, saved.y or 0)
        applying[key] = nil
        ns.Debug("restored %s position: %.0f, %.0f", key, saved.x or 0, saved.y or 0)
    end, "RestorePosition:" .. key)
end

--------------------------------------------------------------------------------
-- Fight detection
--
-- If another addon owns the same frame, correcting it every time it moves is an
-- endless tug-of-war that flickers and burns CPU for no benefit. Count the
-- corrections; past a threshold, stop, say so once, and leave the frame alone.
--------------------------------------------------------------------------------

local FIGHT_LIMIT, FIGHT_WINDOW = 8, 3

local fightCounts = {}
local fightGivenUp = {}

local function AllowCorrection(key)
    if fightGivenUp[key] then return false end

    local now   = GetTime()
    local count = fightCounts[key]
    if not count or (now - count.start) > FIGHT_WINDOW then
        fightCounts[key] = { start = now, n = 1 }
        return true
    end

    count.n = count.n + 1
    if count.n <= FIGHT_LIMIT then return true end

    fightGivenUp[key] = true
    local record = ns.trackers[key]
    ns.Warn("another addon keeps re-anchoring the %s, so heroPanel has stopped "
        .. "correcting it. Disable that addon's objective tracker module to let "
        .. "heroPanel position it, or run /hp reset.",
        record and string.lower(record.label) or key)
    return false
end

-- Called when the user expresses fresh intent (a drag, an unlock, a reset), so
-- one bad stretch does not disable correction for the rest of the session.
local function ClearFightState(key)
    if key then
        fightCounts[key], fightGivenUp[key] = nil, nil
    else
        fightCounts, fightGivenUp = {}, {}
    end
end
ns.ClearFightState = ClearFightState

-- Re-apply every saved anchor after something else has laid the screen out.
-- Coalesced onto the next frame so a burst of layout calls costs one pass.
local reapplyQueued = false

local function ReapplyGeometry()
    if reapplyQueued then return end
    reapplyQueued = true
    ns.After(0, function()
        reapplyQueued = false
        for i = 1, #ns.TRACKER_KEYS do
            local key    = ns.TRACKER_KEYS[i]
            local record = ns.trackers[key]
            local saved  = GetSaved(key)
            if record and record.hooked and saved and saved.point and AllowCorrection(key) then
                ns.RestorePosition(key)
            end
        end
    end)
end
ns.ReapplyGeometry = ReapplyGeometry

-- Clear the saved anchor (and scale) and hand the frame back to the game.
function ns.ResetPosition(key)
    local keys = key and { key } or ns.TRACKER_KEYS
    for i = 1, #keys do
        local record = ns.trackers[keys[i]]
        if record then
            local saved = GetSaved(record.key)
            saved.point, saved.x, saved.y, saved.scale, saved.v = nil, 0, 0, 1.0, nil
            ClearFightState(record.key)

            if record.mover and record.mover.SetUserPlaced then
                local frame = record.mover
                ns.RunWhenSafe(function() pcall(frame.SetUserPlaced, frame, false) end,
                    "ClearUserPlaced:" .. record.key)
            end

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
--
-- Scale is set from /hp scale and, from Phase 4, the options panel. There is
-- deliberately no mousewheel binding on the tracker frames.
--------------------------------------------------------------------------------

function ns.SetScale(key, scale)
    local record = ns.trackers[key]
    local frame  = record and record.mover
    local saved  = GetSaved(key)
    if not frame or not saved then return false end

    scale = ns.Snap(ns.Clamp(scale, SCALE_MIN, SCALE_MAX), SCALE_STEP)
    saved.scale = scale

    ns.RunWhenSafe(function()
        frame:SetScale(scale)
        -- Offsets are stored in UIParent space, so re-apply to keep the frame's
        -- top-left corner pinned where the user put it.
        if saved.point then
            applying[key] = true
            ApplyUIOffsets(frame, saved.x or 0, saved.y or 0)
            applying[key] = nil
        end
    end, "SetScale:" .. key)
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
-- Drag wiring
--
-- Scripts are attached exactly once per frame. Lock state is applied by
-- toggling movability and drag registration, not by rewiring scripts.
--------------------------------------------------------------------------------

-- A drag cannot be deferred and replayed once combat ends, so an attempt made
-- in combat is simply refused. Warned once per combat so repeated attempts do
-- not spam chat.
local combatMoveWarned = false

local function OnDragStart(frame)
    local record = ns.ResolveTracker(frame)
    if not record or ns.IsLocked() then return end

    -- Only the game's own tracker is protected. Addon-owned frames such as the
    -- Mythic+ tracker stay draggable in combat, which is when you are most
    -- likely to want to move one.
    if record.protected and InCombatLockdown() then
        if not combatMoveWarned then
            combatMoveWarned = true
            ns.Warn("can't move the %s in combat - the game protects it. Try again out of combat.",
                string.lower(record.label))
        end
        return
    end

    local x, y = GetUIOffsets(frame)
    ns.Debug("drag start %s at %.0f, %.0f", record.key, x or -1, y or -1)
    ClearFightState(record.key)   -- a fresh drag is fresh intent
    frame:StartMoving()
    record.isMoving = true
end

ns:On("PLAYER_REGEN_ENABLED", function() combatMoveWarned = false end)

local function OnDragStop(frame)
    local record = ns.ResolveTracker(frame)
    if not record or not record.isMoving then return end
    record.isMoving = false
    -- Combat can start mid-drag, which blocks the stop on a protected frame.
    if not pcall(frame.StopMovingOrSizing, frame) then
        ns.Debug("could not stop moving %s.", record.key)
        return
    end
    local x, y = GetUIOffsets(frame)
    ns.Debug("drag stop %s, frame now at %.0f, %.0f", record.key, x or -1, y or -1)
    ns.SavePosition(record.key)
end

-- Apply the current lock state to one tracker. Everything here touches
-- protected methods, so it all goes through RunWhenSafe.
local function ApplyLockState(key)
    local record = ns.trackers[key]
    local frame  = record and record.mover
    if not frame then return false end

    local locked = ns.IsLocked()
    return ns.RunWhenSafe(function()
        -- Movable stays on in both states. It is what makes SetUserPlaced legal,
        -- and it does not by itself let the player drag anything - that needs
        -- RegisterForDrag, which is what the lock actually controls.
        frame:SetMovable(true)

        if locked then
            frame:RegisterForDrag()
            -- Only give the mouse back if we were the ones who took it.
            if record.mouseEnabledByUs then
                frame:EnableMouse(false)
                record.mouseEnabledByUs = nil
            end
        else
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

    -- "hook" here means the frame already had a handler of its own, which runs
    -- before ours and may reposition the frame under us. Worth knowing about.
    local startMode = ns.HookScript(frame, "OnDragStart", OnDragStart)
    local stopMode  = ns.HookScript(frame, "OnDragStop",  OnDragStop)
    ns.Debug("%s drag scripts: OnDragStart=%s OnDragStop=%s (%s = pre-existing handler)",
        key, tostring(startMode), tostring(stopMode), "hook")

    -- Re-assert our geometry whenever the frame comes back into view; the game
    -- and other addons both like to reposition trackers on show.
    ns.HookScript(frame, "OnShow", function()
        ns.RestoreScale(key)
        ns.RestorePosition(key)
    end)

    -- Anything that re-anchors this frame - a layout pass, the client's own
    -- tracker code, another addon - is corrected on the next frame.
    if not record.anchorHooksInstalled then
        record.anchorHooksInstalled = true

        local function NameOf(object)
            if type(object) ~= "table" then return tostring(object) end
            local ok, objectName = pcall(object.GetName, object)
            return (ok and objectName) or "unnamed"
        end

        local function ExternalAnchor(how, detail)
            if applying[key] then return end
            local saved = GetSaved(key)
            if not (saved and saved.point) then return end
            ns.Debug("%s re-anchored via %s %s", key, how, detail or "")
            ReapplyGeometry()
        end

        -- SetPoint is the obvious route, but not the only one: SetAllPoints
        -- repositions a frame without ever calling SetPoint, and reparenting
        -- moves it along with its new parent. Watch all three.
        hooksecurefunc(frame, "SetPoint", function(_, point, relativeTo, relPoint, ox, oy)
            ExternalAnchor("SetPoint", string.format("(%s -> %s %s at %s, %s)",
                tostring(point), NameOf(relativeTo), tostring(relPoint), tostring(ox), tostring(oy)))
        end)

        hooksecurefunc(frame, "SetAllPoints", function(_, relativeTo)
            ExternalAnchor("SetAllPoints", "(" .. NameOf(relativeTo) .. ")")
        end)

        hooksecurefunc(frame, "SetParent", function(_, parent)
            ns.Debug("%s reparented to %s", key, NameOf(parent))
            ExternalAnchor("SetParent", "(" .. NameOf(parent) .. ")")
        end)
    end

    record.hooked = true
    ns.Debug("hooked %s (%s).", record.label, tostring(record.moverName))

    ApplyLockState(key)
    -- Scale first: position offsets are converted using the current scale.
    ns.RestoreScale(key)
    ns.RestorePosition(key)
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
-- frame gets applied first.
function ns:ToggleLock(trackerKey)
    return ns.SetLocked(not ns.IsLocked(), trackerKey)
end

function ns.SetLocked(locked, trackerKey)
    if not ns.db then return false end
    ns.db.frame.locked = locked and true or false
    ClearFightState()   -- the user is actively repositioning; try again

    if trackerKey and ns.trackers[trackerKey] then ApplyLockState(trackerKey) end
    for i = 1, #ns.TRACKER_KEYS do
        local key = ns.TRACKER_KEYS[i]
        if key ~= trackerKey then ApplyLockState(key) end
    end

    ns:Fire("HEROPANEL_LOCK_CHANGED", ns.db.frame.locked)

    if ns.db.frame.locked then
        ns.Print("trackers |cFFC2C6D8locked|r.")
    else
        ns.Print("trackers |cFF79C68Dunlocked|r - drag with the left mouse button.")
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

    -- A full layout pass re-places every frame the game thinks it owns, and it
    -- runs well after login. Re-apply ours afterwards rather than fighting it.
    if type(_G.UIParent_ManageFramePositions) == "function" then
        hooksecurefunc("UIParent_ManageFramePositions", function()
            ns.Debug("layout pass ran.")
            ReapplyGeometry()
        end)
        ns.Debug("hooked UIParent_ManageFramePositions.")
    end
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    -- Zoning triggers a layout pass of its own.
    ReapplyGeometry()
end)
