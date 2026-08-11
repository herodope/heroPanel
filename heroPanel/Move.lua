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
      * No other addon's SavedVariables are read or written, ever.

    Ownership
    ---------
    heroPanel is not always the only addon that wants to place these frames.
    Rather than assume, each tracker resolves an ownership mode:

      own     heroPanel anchors the tracker to UIParent itself. Used when
              nothing else contends for the frame.
      holder  another addon docks the tracker into a holder frame of its own.
              heroPanel leaves the tracker alone and moves that holder instead,
              so both addons stay happy.
      yield   another addon owns the frame and no usable holder was found.
              heroPanel stops positioning it - the other addon's mover places
              it, and heroPanel still skins it.

    "auto" (the default) starts at own and degrades own -> holder -> yield as
    contention is detected. The holder is discovered by observation, not by
    hardcoding another addon's frame names, so this works for any addon that
    behaves this way rather than only the ones known today.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.5, 1.5, 0.1

-- Bumped when the meaning of the stored geometry changes. Anything older is
-- dropped rather than misinterpreted.
local GEOMETRY_VERSION = 2

ns.OWNERSHIP_MODES = { auto = true, own = true, holder = true, yield = true }

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
-- Ownership
--------------------------------------------------------------------------------

-- The mode actually in force for a tracker. An explicit setting always wins;
-- "auto" uses whatever the degrade cascade has settled on so far.
function ns.GetMode(key)
    local record = ns.trackers[key]
    if not record then return "own" end

    local configured = ns.db and ns.db.frame.ownership or "auto"
    if configured ~= "auto" and ns.OWNERSHIP_MODES[configured] then return configured end

    return record.mode or "own"
end

function ns.SetOwnership(mode, key)
    if not ns.OWNERSHIP_MODES[mode] then return false end
    if ns.db then ns.db.frame.ownership = mode end

    local keys = key and { key } or ns.TRACKER_KEYS
    for i = 1, #keys do
        local record = ns.trackers[keys[i]]
        if record then
            record.mode = (mode ~= "auto") and mode or "own"
            ns.ClearFightState(record.key)
        end
    end
    return true
end

-- The frame heroPanel moves for a tracker, which is not always the tracker.
local function ActiveMover(key)
    local record = ns.trackers[key]
    if not record then return nil end
    if ns.GetMode(key) == "holder" and record.holderFrame then return record.holderFrame end
    return record.mover
end
ns.GetActiveMover = ActiveMover

local function ActiveMoverName(key)
    local record = ns.trackers[key]
    if not record then return nil end
    if ns.GetMode(key) == "holder" and record.holderFrame then return record.holderName end
    return record.moverName
end

--------------------------------------------------------------------------------
-- Coordinate helpers
--
-- SetPoint offsets are measured in the moved frame's own coordinate space, so
-- they change meaning when the frame is rescaled. Offsets are therefore stored
-- in UIParent space and converted on the way in and out.
--------------------------------------------------------------------------------

local function GetUIOffsets(frame)
    if not frame then return nil end
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

-- True while heroPanel is the one moving a frame, so the anchor hooks can tell
-- our own changes apart from everyone else's.
local applying = {}

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

function ns.SavePosition(key)
    if ns.GetMode(key) == "yield" then return false end

    local record = ns.trackers[key]
    local frame  = ActiveMover(key)
    local saved  = GetSaved(key)
    if not frame or not saved then return false end

    local x, y = GetUIOffsets(frame)
    if not x then return false end

    saved.point = "TOPLEFT"
    saved.x     = x
    saved.y     = y
    saved.v     = GEOMETRY_VERSION

    ReleaseFromUIParent(ActiveMoverName(key))

    -- Re-anchor to the canonical point, so what is on screen and what is in the
    -- store cannot drift apart. If combat started mid-drag this waits, which is
    -- safe: the stored offsets already describe where the frame is.
    ns.RunWhenSafe(function()
        applying[key] = true
        ApplyUIOffsets(frame, x, y)
        applying[key] = nil
    end, "Normalize:" .. key)

    ns.Debug("saved %s position: %.0f, %.0f (moving %s)", key, x, y, tostring(ActiveMoverName(key)))
    return true
end

function ns.RestorePosition(key)
    if ns.GetMode(key) == "yield" then return false end

    local frame = ActiveMover(key)
    local saved = GetSaved(key)
    if not frame or not saved or not saved.point then return false end

    return ns.RunWhenSafe(function()
        ReleaseFromUIParent(ActiveMoverName(key))
        applying[key] = true
        ApplyUIOffsets(frame, saved.x or 0, saved.y or 0)
        applying[key] = nil
        ns.Debug("restored %s position: %.0f, %.0f", key, saved.x or 0, saved.y or 0)
    end, "RestorePosition:" .. key)
end

--------------------------------------------------------------------------------
-- Contention handling
--
-- If another addon owns the same frame, correcting it every time it moves is an
-- endless tug-of-war that flickers and burns CPU for no benefit. Count the
-- corrections; past a threshold, step down a mode rather than keep fighting.
--------------------------------------------------------------------------------

local FIGHT_LIMIT, FIGHT_WINDOW = 8, 3

local fightCounts  = {}
local fightGivenUp = {}

-- own -> holder (if one was observed) -> yield
local function DegradeMode(key)
    local record = ns.trackers[key]
    if not record then return end

    local configured = ns.db and ns.db.frame.ownership or "auto"
    if configured ~= "auto" then
        -- The user asked for this mode explicitly. Say it is not working rather
        -- than quietly overriding the choice.
        ns.Warn("another addon keeps re-anchoring the %s and heroPanel is set to "
            .. "'%s'. Stopping corrections - try /hp mode auto.",
            string.lower(record.label), configured)
        record.mode = "yield"
        return
    end

    local current = record.mode or "own"

    if current == "own" and record.holderFrame then
        record.mode = "holder"
        ns.Print("another addon docks the %s into |cFFC2C6D8%s|r. heroPanel will move "
            .. "that holder instead, so both can coexist.",
            string.lower(record.label), tostring(record.holderName))
        fightCounts[key], fightGivenUp[key] = nil, nil
        ns.RestorePosition(key)
        return
    end

    record.mode = "yield"
    ns.Warn("another addon owns the %s, so heroPanel has stopped positioning it - "
        .. "use that addon's mover to place it. Skinning still applies. "
        .. "Force heroPanel to take over with /hp mode own.",
        string.lower(record.label))
end

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
    DegradeMode(key)
    return false
end

-- Called when the user expresses fresh intent (a drag, an unlock, a reset), so
-- one bad stretch does not disable correction for the rest of the session.
function ns.ClearFightState(key)
    if key then
        fightCounts[key], fightGivenUp[key] = nil, nil
    else
        fightCounts, fightGivenUp = {}, {}
    end
end
local ClearFightState = ns.ClearFightState

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
            if record and record.hooked and saved and saved.point
               and ns.GetMode(key) ~= "yield" and AllowCorrection(key) then
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
            record.mode = nil

            local managed = _G.UIPARENT_MANAGED_FRAME_POSITIONS
            local stashed = ns.savedManagedPositions and ns.savedManagedPositions[record.moverName]
            if managed and stashed then
                managed[record.moverName] = stashed
                ns.savedManagedPositions[record.moverName] = nil
            end

            local frame = record.mover
            if frame then
                ns.RunWhenSafe(function()
                    frame:SetScale(1.0)
                    if frame.SetUserPlaced then pcall(frame.SetUserPlaced, frame, false) end
                end, "Reset:" .. record.key)
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
    local frame = ActiveMover(key)
    local saved = GetSaved(key)
    if not frame or not saved then return false end

    scale = ns.Snap(ns.Clamp(scale, SCALE_MIN, SCALE_MAX), SCALE_STEP)
    saved.scale = scale

    ns.RunWhenSafe(function()
        frame:SetScale(scale)
        -- Offsets are stored in UIParent space, so re-apply to keep the frame's
        -- top-left corner pinned where the user put it.
        if saved.point and ns.GetMode(key) ~= "yield" then
            applying[key] = true
            ApplyUIOffsets(frame, saved.x or 0, saved.y or 0)
            applying[key] = nil
        end
    end, "SetScale:" .. key)
    return true, scale
end

function ns.RestoreScale(key)
    local frame = ActiveMover(key)
    local saved = GetSaved(key)
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

local function OnDragStart(frame)
    local record = ns.ResolveTracker(frame)
    if not record or ns.IsLocked() then return end

    if ns.GetMode(record.key) == "yield" then
        ns.Warn("another addon is positioning the %s - use its mover, or run "
            .. "/hp mode own to let heroPanel take over.", string.lower(record.label))
        return
    end

    -- Both trackers stay draggable in combat, which is when you are most
    -- likely to want to move one.
    --
    -- WatchFrame is protected, and this used to refuse a drag in combat on
    -- that basis. It turns out not to be needed: StartMoving / StopMovingOrSizing
    -- on the tracker are not among the calls the 3.3.5a client refuses under
    -- lockdown, and dragging an unlocked tracker through a Mythic+ boss fight
    -- produced no taint. The refusal cost the one case the feature is for, so
    -- it is gone. The deferral in ns.RunWhenSafe still guards the calls that
    -- genuinely are protected - SetPoint, Show, Hide, SetScale, EnableMouse.

    -- In holder mode the frame under the cursor is the tracker, but the frame
    -- that actually moves is the holder it is docked into.
    local mover = ActiveMover(record.key)
    if not mover then return end

    local x, y = GetUIOffsets(mover)
    ns.Debug("drag start %s at %.0f, %.0f (moving %s)",
        record.key, x or -1, y or -1, tostring(ActiveMoverName(record.key)))
    ClearFightState(record.key)   -- a fresh drag is fresh intent

    mover:SetMovable(true)
    mover:StartMoving()
    record.movingFrame = mover
end

local function OnDragStop(frame)
    local record = ns.ResolveTracker(frame)
    if not record or not record.movingFrame then return end

    local mover = record.movingFrame
    record.movingFrame = nil

    -- Combat can start mid-drag, which blocks the stop on a protected frame.
    if not pcall(mover.StopMovingOrSizing, mover) then
        ns.Debug("could not stop moving %s.", record.key)
        return
    end

    local x, y = GetUIOffsets(mover)
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

--------------------------------------------------------------------------------
-- Holder discovery
--
-- When another addon re-anchors a tracker, whatever it anchors the tracker to
-- is that addon's holder. Remembering it by observation means heroPanel can
-- cooperate with any addon that works this way, without knowing its name in
-- advance or reading its saved variables.
--------------------------------------------------------------------------------

local function NameOf(object)
    if type(object) ~= "table" then return tostring(object) end
    local ok, objectName = pcall(object.GetName, object)
    return (ok and objectName) or "unnamed"
end

-- Forward declaration: adopting a holder installs the same anchor hooks on it.
local InstallAnchorHooks

local function NoteHolder(key, candidate)
    if type(candidate) ~= "table" or candidate == UIParent then return end
    if type(candidate.SetPoint) ~= "function" then return end

    local record = ns.trackers[key]
    if not record or candidate == record.frame or candidate == record.mover then return end
    if record.holderFrame == candidate then return end

    local candidateName = NameOf(candidate)
    record.holderFrame = candidate
    record.holderName  = candidateName
    ns.Debug("%s holder observed: %s", key, candidateName)

    -- An addon that docks the tracker into a holder of its own is not really
    -- competing - it has told us where it wants the tracker to live. Move the
    -- holder and the tracker comes with it. Adopt immediately rather than
    -- waiting for the contention detector: a tug-of-war is not a prerequisite
    -- for cooperating, and fighting first only makes the frame flicker.
    --
    -- Only named holders are adopted. An unnamed frame is recorded for
    -- reference but is too weak a signal to hand positioning over to.
    local configured = ns.db and ns.db.frame.ownership or "auto"
    if configured ~= "auto" then return end
    if record.mode == "holder" or record.mode == "yield" then return end
    if not candidateName or candidateName == "unnamed" then return end

    record.mode = "holder"
    ns.ClearFightState(key)
    InstallAnchorHooks(key, candidate, "holder")

    ns.Print("the %s is docked into |cFFC2C6D8%s|r by another addon. heroPanel will "
        .. "move that holder instead, so both can coexist.",
        string.lower(record.label), candidateName)

    ns.RestoreScale(key)
    ns.RestorePosition(key)
end

--------------------------------------------------------------------------------
-- Anchor hooks
--
-- Installed on the tracker itself, and on any holder heroPanel adopts. The two
-- roles behave differently:
--
--   tracker  watch for holders. Correct re-anchors only while heroPanel is the
--            one placing this frame - in holder mode the tracker's own anchor
--            belongs to the other addon and must be left alone, which is what
--            stops the two addons fighting.
--   holder   this is heroPanel's move target, so re-anchors are corrected.
--
-- The set of frames hooked is tracked separately from the tracker records, so
-- a frame is never double-hooked.
--------------------------------------------------------------------------------

local anchorHookedFrames = {}

function InstallAnchorHooks(key, frame, role)
    if not frame or anchorHookedFrames[frame] then return false end
    anchorHookedFrames[frame] = true

    -- A contended frame can be re-anchored many times a second. Log the first
    -- few so the cause is identifiable, then go quiet rather than flooding chat.
    local LOG_LIMIT, logged = 3, 0

    local function ExternalAnchor(how, candidate, detail)
        if applying[key] then return end

        if role == "tracker" then
            NoteHolder(key, candidate)
            -- Once a holder is in play the other addon owns this frame's
            -- anchor. Correcting it here is exactly the tug-of-war to avoid.
            if ns.GetMode(key) == "holder" then return end
        end

        if ns.GetMode(key) == "yield" then return end

        local saved = GetSaved(key)
        if not (saved and saved.point) then return end

        if logged < LOG_LIMIT then
            logged = logged + 1
            ns.Debug("%s %s re-anchored via %s %s%s", key, role, how, detail or "",
                logged == LOG_LIMIT and " (further re-anchors not logged)" or "")
        end
        ReapplyGeometry()
    end

    -- SetPoint is the obvious route, but not the only one: SetAllPoints
    -- repositions a frame without ever calling SetPoint, and reparenting moves
    -- it along with its new parent. Watch all three.
    hooksecurefunc(frame, "SetPoint", function(_, point, relativeTo, relPoint, ox, oy)
        ExternalAnchor("SetPoint", relativeTo, string.format("(%s -> %s %s at %s, %s)",
            tostring(point), NameOf(relativeTo), tostring(relPoint), tostring(ox), tostring(oy)))
    end)

    hooksecurefunc(frame, "SetAllPoints", function(_, relativeTo)
        ExternalAnchor("SetAllPoints", relativeTo, "(" .. NameOf(relativeTo) .. ")")
    end)

    hooksecurefunc(frame, "SetParent", function(_, parent)
        ExternalAnchor("SetParent", parent, "(" .. NameOf(parent) .. ")")
    end)

    ns.Debug("anchor hooks installed on %s (%s, role %s)", NameOf(frame), key, role)
    return true
end

--------------------------------------------------------------------------------
-- Hooking
--------------------------------------------------------------------------------

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

    InstallAnchorHooks(key, frame, "tracker")

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

-- A holder is often created after heroPanel resolved its move target, because
-- addons load in whatever order the client picks. Re-check the known candidate
-- names once everything has loaded rather than waiting to observe a re-anchor.
function ns.RecheckHolders()
    for i = 1, #ns.TRACKER_KEYS do
        local key    = ns.TRACKER_KEYS[i]
        local record = ns.trackers[key]
        if record and record.found and not record.holderFrame and record.moverFirst then
            for c = 1, #record.moverFirst do
                local candidate = _G[record.moverFirst[c]]
                if candidate and candidate ~= record.mover then
                    NoteHolder(key, candidate)
                    break
                end
            end
        end
    end
end

ns:On("PLAYER_LOGIN", function()
    for i = 1, #ns.TRACKER_KEYS do
        local key = ns.TRACKER_KEYS[i]
        if ns.trackers[key].found then HookTracker(key) end
    end
    ns.RecheckHolders()

    -- A full layout pass re-places every frame the game thinks it owns, and it
    -- runs well after login. Re-apply ours afterwards rather than fighting it.
    if type(_G.UIParent_ManageFramePositions) == "function" then
        hooksecurefunc("UIParent_ManageFramePositions", ReapplyGeometry)
        ns.Debug("hooked UIParent_ManageFramePositions.")
    end
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    -- Zoning triggers a layout pass of its own.
    ns.RecheckHolders()
    ReapplyGeometry()
end)
