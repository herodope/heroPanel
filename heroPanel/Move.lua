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

-- The step was 0.1 while scale was only ever set from a slider and a slash
-- command. The resize grip drags it continuously, and ten stops across the
-- whole range is a panel that jumps rather than one that follows the cursor.
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.5, 1.5, 0.05
ns.SCALE_MIN, ns.SCALE_MAX = SCALE_MIN, SCALE_MAX

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

-- The frame heroPanel *scales*, which is never the holder.
--
-- This is not the same frame as the mover and it was, which made "scale the
-- quest tracker" slide it sideways instead of resizing it. A holder is a frame
-- the tracker is anchored *to*, not one it is parented to - ElvUI's
-- WatchFrameHolder is a child of UIParent that does
-- WatchFrame:SetPoint("TOP", WatchFrameHolder, "TOP") - so:
--
--   * scaling the holder cannot scale the tracker, because scale is inherited
--     through parentage and the tracker is not its child; and
--   * scaling the holder *does* move the tracker, because a wider holder has
--     its TOP - the anchor the tracker hangs off - further to the right.
--
-- So scale goes to the tracker itself and position keeps going to the mover.
-- The two are independent: scaling the tracker leaves the mover's geometry
-- untouched, and moving the holder leaves the tracker's scale alone. It also
-- makes Skin.lua's plate follow, since that reads the tracker's own scale.
--
-- With no holder in play these are the same frame and nothing changes.
local function ScaleTarget(key)
    local record = ns.trackers[key]
    if not record then return nil end
    return record.frame or record.mover
end
ns.GetScaleTarget = ScaleTarget

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

-- Exported for the options window, which is scalable now and so has the same
-- problem the trackers have: its saved position is a pair of offsets, and an
-- offset means a different distance once the frame it is measured in has been
-- scaled. Remembering where a window was left and putting it somewhere else on
-- the next login is the bug this exists to prevent, and there is no reason for
-- a second copy of the arithmetic to exist in order to have it twice.
ns.GetUIOffsets   = GetUIOffsets
ns.ApplyUIOffsets = ApplyUIOffsets

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

-- Trackers whose scale another addon has been seen to hold, so the warning is
-- said once rather than on every notch of a grip drag.
local scaleHeldWarned = {}

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

            -- Scale comes off the tracker and user-placed comes off the mover,
            -- because that is where each of them was put.
            local target = ScaleTarget(record.key)
            local frame  = record.mover
            if target or frame then
                ns.RunWhenSafe(function()
                    if target then target:SetScale(1.0) end
                    if frame and frame.SetUserPlaced then
                        pcall(frame.SetUserPlaced, frame, false)
                    end
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
-- Set from /hp scale and from the options window's sliders, which call this
-- same function so the two cannot disagree. There is deliberately no mousewheel
-- binding on the tracker frames.
--------------------------------------------------------------------------------

function ns.SetScale(key, scale)
    local target = ScaleTarget(key)
    local mover  = ActiveMover(key)
    local saved  = GetSaved(key)
    if not target or not saved then return false end

    scale = ns.Snap(ns.Clamp(scale, SCALE_MIN, SCALE_MAX), SCALE_STEP)
    saved.scale = scale

    ns.RunWhenSafe(function()
        target:SetScale(scale)

        -- Did it stick?
        --
        -- Another addon can hold a frame's scale the same way one can hold its
        -- anchor - MoveAnything hooks SetScale on the widget metatable and
        -- rescales straight back to its own number. The anchor hooks below
        -- notice that happening to a position and degrade the mode for it;
        -- nothing was ever watching the scale, so the resize grip simply did
        -- nothing and said nothing, which reads as heroPanel being broken.
        --
        -- Read back rather than hooked, because a hook would fire on our own
        -- call and on every other addon's, and telling those apart is the
        -- problem this avoids entirely: what matters is only whether the number
        -- we asked for is the number the frame ended up with.
        local ok, actual = pcall(target.GetScale, target)
        if ok and actual and math.abs(actual - scale) > 0.001 then
            if not scaleHeldWarned[key] then
                scaleHeldWarned[key] = true
                ns.Warn("another addon is controlling the %s's size - heroPanel asked "
                    .. "for %.2f and it came back %.2f. Use that addon's own controls, "
                    .. "or release the frame there.",
                    string.lower(ns.trackers[key] and ns.trackers[key].label or key),
                    scale, actual)
            end
            ns.Debug("%s scale rejected: asked %.2f, got %.2f", key, scale, actual)
        else
            scaleHeldWarned[key] = nil
        end

        -- Re-pin the mover's top-left corner. Offsets are stored in UIParent
        -- space and converted using the mover's own effective scale, so this
        -- only actually changes anything when the mover and the scaled frame
        -- are the same object - which is the no-holder case. It is run either
        -- way because it costs nothing and getting it wrong is a frame that
        -- creeps every time it is rescaled.
        if mover and saved.point and ns.GetMode(key) ~= "yield" then
            applying[key] = true
            ApplyUIOffsets(mover, saved.x or 0, saved.y or 0)
            applying[key] = nil
        end
    end, "SetScale:" .. key)
    return true, scale
end

-- Yield means yield, and that has to include the scale.
--
-- This used to re-assert heroPanel's scale whatever the mode was, and it runs
-- from the tracker's OnShow - so a player who had explicitly handed the frame
-- to another addon still got heroPanel writing SetScale to it every time the
-- tracker was shown. Against MoveAnything, which locks scale and puts its own
-- number straight back, that is an endless silent argument over a frame the
-- player already said was not ours. Position has always been gated here; scale
-- was simply missed.
function ns.RestoreScale(key)
    if ns.GetMode(key) == "yield" then return false end

    local target = ScaleTarget(key)
    local saved  = GetSaved(key)
    if not target or not saved then return false end
    local scale = ns.Clamp(saved.scale or 1.0, SCALE_MIN, SCALE_MAX)
    return ns.RunWhenSafe(function() target:SetScale(scale) end, "RestoreScale:" .. key)
end

--------------------------------------------------------------------------------
-- The resize grip
--
-- A handle in the bottom-right corner of a panel. Dragging it scales that panel.
--
-- This replaces the percentage sliders the options window used to carry, and it
-- is not only a nicer control. A slider asks the player to guess a number and
-- then look away from it to see what the number did; a grip is the corner of
-- the thing being resized, and it moves with the cursor.
--
-- It sets *scale*, not size. 3.3.5a has StartSizing, and pointing it at the
-- objective tracker would be wrong twice: the frame is protected, and its width
-- is Blizzard's to decide - the tracker lays its own lines out and re-measures
-- them. Scale is the lever that makes the whole panel bigger without heroPanel
-- having an opinion about where any line goes, which is the rule the rest of
-- the addon is built on. It is the right lever for the options window too, for
-- a different reason: that window is a column of absolutely-placed rows 440
-- units wide, so widening the frame would leave every control where it was.
--
-- Three panels use this and they do not all want the same wiring, so the
-- reading and writing of the scale is passed in:
--
--   opts.get      current scale
--   opts.set      apply a new one
--   opts.visible  when the grip should be on screen; omitted means always
--   opts.label    what to call this panel in a message
--   opts.deferred true if opts.set may be refused in combat, so the player is
--                 told once rather than left wondering
--
-- All three panels pass the lock state as `visible`, because a grip is a piece
-- of edit-mode furniture and leaving it on a panel someone has finished
-- arranging is one more thing drawn over their game for no reason. The options
-- window was always-on for a while, on the grounds that the lock governs the
-- trackers rather than it - which is true, and still read as the third panel
-- having missed the memo.
--------------------------------------------------------------------------------

local GRIP_SIZE  = 14
local GRIP_INSET = 3

-- Every grip built, so one lock change reaches all of them without each panel
-- having to subscribe for itself.
local grips = {}

local function GripStop(grip)
    if not grip.drag then return end
    grip.drag = nil
    grip:SetScript("OnUpdate", nil)
    -- The options window shows the same numbers in its status line, and a
    -- drag that ends without telling it leaves it a scale behind.
    if ns.Options and ns.Options.IsShown and ns.Options.IsShown() then
        pcall(ns.Options.Sync)
    end
end

-- Distance from the panel's top-left corner to a point, along the diagonal the
-- grip is dragged on. Horizontal and vertical reach are added rather than
-- measured as a hypotenuse: the sum responds to a drag along either axis alone,
-- which is what a player who grabs the corner and pulls straight down expects,
-- and a hypotenuse barely moves for that.
--
-- Everything here is in screen pixels. The panel's own units change meaning as
-- it is scaled, which is the one coordinate space a rescale must not be
-- measured in.
local function GripReach(drag, x, y)
    return (x - drag.ax) + (drag.ay - y)
end

local function GripUpdate(grip)
    local drag = grip.drag
    if not drag then return end

    -- A release outside the grip never reaches its OnMouseUp, so the button
    -- state is what actually ends the drag.
    if type(_G.IsMouseButtonDown) == "function" and not _G.IsMouseButtonDown("LeftButton") then
        GripStop(grip)
        return
    end

    local x, y  = GetCursorPosition()
    local reach = math.max(1, GripReach(drag, x, y))
    local wanted = ns.Snap(ns.Clamp(drag.scale * reach / drag.reach, SCALE_MIN, SCALE_MAX), SCALE_STEP)

    -- Only on a change of the snapped value. Setting a tracker's scale is a
    -- protected call, so pushing one per frame would queue a few hundred of
    -- them at the first pull inside a fight.
    if wanted == drag.applied then return end
    drag.applied = wanted
    grip.set(wanted)
end

local function GripStart(grip)
    if not grip:CanResize() then return end

    local plate = grip:GetParent()
    local scale = plate and plate:GetEffectiveScale()
    local left, top = plate and plate:GetLeft(), plate and plate:GetTop()
    if not (left and top and scale and scale > 0) then return end

    local x, y = GetCursorPosition()
    local drag = { ax = left * scale, ay = top * scale }
    drag.reach = GripReach(drag, x, y)
    -- Grabbing the corner of a panel with no extent to speak of would make the
    -- first pixel of movement a huge multiplier.
    if drag.reach < 20 then return end

    drag.scale   = tonumber(grip.get()) or 1
    drag.applied = drag.scale
    grip.drag    = drag

    if grip.deferred and InCombatLockdown() then
        ns.Warn("the game refuses to rescale the %s in combat - drag it now and the "
            .. "new size lands the moment you leave combat.", grip.label)
    end

    grip:SetScript("OnUpdate", GripUpdate)
end

-- ns.NewResizeGrip(plate, opts) -> grip
--
-- The panel owns the grip; Move.lua owns what it does. Each panel calls this
-- once at build time and then only ever calls grip:Raise from its layout pass.
function ns.NewResizeGrip(plate, opts)
    opts = opts or {}

    local grip = CreateFrame("Button", nil, plate)
    grip:SetWidth(GRIP_SIZE)
    grip:SetHeight(GRIP_SIZE)
    grip:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -GRIP_INSET, GRIP_INSET)
    grip:EnableMouse(true)
    grip:Hide()

    grip.label    = opts.label or "panel"
    grip.get      = opts.get
    grip.set      = opts.set
    grip.visible  = opts.visible
    grip.deferred = opts.deferred and true or false

    grip.glyph = ns.NewGlyph(grip, GRIP_SIZE - 2)
    grip.glyph:SetPoint("CENTER")
    grip.glyph:SetShape("grip")
    grip.glyph:SetColor(ns.HexToRGB(ns.PALETTE.icon))

    grip:SetScript("OnMouseDown", function(self) GripStart(self) end)
    grip:SetScript("OnMouseUp",   function(self) GripStop(self) end)
    grip:SetScript("OnHide",      function(self) GripStop(self) end)

    grip:SetScript("OnEnter", function(self)
        self.glyph:SetColor(ns.HexToRGB(ns.PALETTE.accentLight))
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Drag to resize", 1, 1, 1)
        if self.visible then
            GameTooltip:AddLine("Lock the trackers to put this away.", 0.6, 0.6, 0.7, true)
        end
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function(self)
        self.glyph:SetColor(ns.HexToRGB(ns.PALETTE.icon))
        GameTooltip:Hide()
    end)

    function grip:CanResize()
        return type(self.get) == "function" and type(self.set) == "function"
           and (not self.visible or self.visible())
    end

    -- Shown by whatever condition the panel handed over, never by the panel
    -- itself. A panel deciding this for itself is how the grips and the lock
    -- ended up able to disagree about whether the trackers were unlocked.
    function grip:Sync()
        if self.visible and not self.visible() then self:Hide() else self:Show() end
    end

    -- The plate deliberately sits a strata below the tracker so it can never
    -- take a click meant for a quest line. The grip is the one part of it that
    -- has to take its own clicks, and an unlocked tracker is mouse-enabled over
    -- the whole of its own rectangle - so it is raised the same way the header's
    -- lock button is, from the tracker's own strata and level.
    function grip:Raise(strata, level)
        if strata then self:SetFrameStrata(strata) end
        self:SetFrameLevel((level or self:GetFrameLevel()) + 1)
    end

    table.insert(grips, grip)
    grip:Sync()
    return grip
end

function ns.SyncResizeGrips()
    for i = 1, #grips do pcall(grips[i].Sync, grips[i]) end
end

ns:On("HEROPANEL_LOCK_CHANGED", ns.SyncResizeGrips)

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
    -- WatchFrame is protected and a drag was refused in combat on that basis
    -- once, needlessly: StartMoving / StopMovingOrSizing are not among the calls
    -- the 3.3.5a client refuses under lockdown, and dragging an unlocked tracker
    -- through a boss fight produced no taint. ns.RunWhenSafe still guards the
    -- calls that genuinely are protected - SetPoint, Show, Hide, SetScale,
    -- EnableMouse.

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

-- Apply the current lock state to one tracker.
--
-- Pushing the whole job through ns.RunWhenSafe came first and meant unlocking
-- during a fight did nothing until the fight was over, which is exactly when you
-- notice the tracker is in the way. So the work is split by what each call
-- actually needs:
--
--   * SetMovable and RegisterForDrag are done once, at hook time, and left
--     alone. Registering for drag does not by itself let anything move: every
--     drag goes through OnDragStart, which checks the lock first. Whether the
--     tracker can be dragged is therefore a flag heroPanel reads, not a piece
--     of frame state it has to rewrite mid-combat.
--   * EnableMouse is the one genuinely protected call left, and it is only
--     needed when the frame does not already have the mouse. That is a state
--     the frame usually reaches the first time it is unlocked out of combat and
--     then keeps, so unlocking in combat normally has nothing left to do.
--
-- What remains is deferred, and the caller is told whether anything was.
-- Returns true when the state is fully live now.
local function ApplyLockState(key)
    local record = ns.trackers[key]
    local frame  = record and record.mover
    if not frame then return false end

    local locked = ns.IsLocked()

    if not locked then
        -- Clamping is not protected and is worth having on before a drag.
        pcall(frame.SetClampedToScreen, frame, true)

        if frame.IsMouseEnabled and not frame:IsMouseEnabled() then
            -- The only thing here that can be refused.
            return ns.RunWhenSafe(function()
                frame:EnableMouse(true)
                record.mouseEnabledByUs = true
            end, "ApplyLockState:" .. key)
        end
        return true
    end

    -- Locking deliberately leaves the mouse on.
    --
    -- Turning it off again is what made unlocking mid-fight do nothing: the mouse
    -- has to be on before the frame can be dragged, EnableMouse is refused under
    -- lockdown, and locking is the state you are in when a fight starts.
    --
    -- The cost is that the tracker's rectangle stops being click-through once
    -- it has been unlocked once in a session - you cannot target something
    -- behind it. That is the trade: click-through in a rectangle you chose to
    -- put the tracker in, against being able to move it out of the way when it
    -- is actually in the way. Nothing else changes, because none of heroPanel's
    -- own overlays ever take the mouse.
    --
    -- mouseEnabledByUs is still recorded, so /hp skin off can hand a frame back
    -- exactly as it was found.
    return true
end
ns.ApplyLockState = ApplyLockState

-- Done once per tracker, at hook time, out of combat. Neither of these needs
-- redoing when the lock flips - see the note above.
local function EnableDragging(frame)
    if not frame then return end
    -- Movable is what makes SetUserPlaced legal, and it does not by itself let
    -- the player drag anything.
    pcall(frame.SetMovable, frame, true)
    pcall(frame.RegisterForDrag, frame, "LeftButton")
end

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

    -- Never one of heroPanel's own frames.
    --
    -- This whole function is about noticing that *another* addon has docked the
    -- tracker somewhere. A heroPanel frame in that position is not another
    -- addon cooperating - it is heroPanel's own panel, and adopting it would be
    -- heroPanel deciding it had lost an argument with itself and handing
    -- positioning to a frame it positions.
    --
    -- It is reachable: the Mythic+ placement preview anchors the tracker to its
    -- own plate for two statements to convert a dragged position into offsets
    -- without doing scale arithmetic by hand, and the SetPoint hook that calls
    -- this fires on that anchor before the next line can undo it. Guarded here
    -- rather than there, because "heroPanel's frames are not holders" is true
    -- of every caller and not just that one.
    if type(candidateName) == "string"
       and string.sub(candidateName, 1, 9) == "HeroPanel" then
        return
    end
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

    EnableDragging(frame)
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

    local live = true
    if trackerKey and ns.trackers[trackerKey] then
        live = ApplyLockState(trackerKey) and live
    end
    for i = 1, #ns.TRACKER_KEYS do
        local key = ns.TRACKER_KEYS[i]
        if key ~= trackerKey then live = ApplyLockState(key) and live end
    end

    ns:Fire("HEROPANEL_LOCK_CHANGED", ns.db.frame.locked)

    if ns.db.frame.locked then
        ns.Print("trackers |cFFC2C6D8locked|r.")
    else
        ns.Print("trackers |cFF79C68Dunlocked|r - drag with the left mouse button.")
    end

    -- Only warn when something was actually deferred. Being in combat is not by
    -- itself a reason to say the change has not taken: unlocking mid-fight
    -- normally has nothing protected left to do, and warning anyway told the
    -- player their tracker was stuck when it was in fact draggable.
    if not live then
        ns.Warn("the objective tracker needs the mouse turned on, which the game "
            .. "refuses in combat - it will be draggable the moment you leave combat.")
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
