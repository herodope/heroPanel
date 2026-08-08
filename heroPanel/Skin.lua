--[[--------------------------------------------------------------------------
    heroPanel - Skin.lua

    The panel behind the objective tracker: background plate, hairline border,
    approximated corner radius, and the header row (lock toggle, OBJECTIVES
    label, tracked-quest badge, collapse caret).

    Everything drawn here belongs to heroPanel. WatchFrame's own geometry is
    never touched:

      * the plate is a sibling of WatchFrame, anchored to it and sitting one
        frame level below, so it never intercepts a click meant for a quest
        line and never changes what the tracker does with its own children;
      * Blizzard's header chrome is faded out with SetAlpha, which is a region
        method and is neither protected nor destructive - Disable() puts the
        original alpha back;
      * the collapse caret is drawn over the *existing*
        WatchFrameCollapseExpandButton, which keeps working as it always did.
        heroPanel reads its collapse state, it does not drive it.

    Re-skinning is trigger-driven: shown, resized, WatchFrame_Update, collapse
    and expand. There is no per-frame work anywhere in this file; the one
    OnUpdate in play is the shared 10Hz hover ticker from Util.lua.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- Layout constants
--
-- Straight from the design handoff. Font sizes are relative to the configured
-- base size and live with ns.GetFontSize.
--------------------------------------------------------------------------------

local PANEL_MIN_WIDTH = 288
local HEADER_HEIGHT   = 30
local PAD_LEFT        = 14
local PAD_RIGHT       = 14
local PAD_BOTTOM      = 13
local HEADER_PAD_X    = 13
local DIVIDER_FADE    = 24    -- the divider fades out over this much at each end
local MAX_NOTCH       = 3     -- corner steps at the largest supported radius
local ICON_SIZE       = 12
local BADGE_HEIGHT    = 14
local BADGE_PAD_X     = 6
local HOVER_INTERVAL  = 0.1

-- Client textures used as glyphs, most preferred first. heroPanel ships no art,
-- and which of these exist varies between 3.3.5a builds, so each is a fallback
-- chain ending at a plain square - see ns.SetTextureFile.
local TEX_LOCKED   = { "Interface\\Buttons\\LockButton-Locked-Up",   "Interface\\Buttons\\UI-CheckBox-Check" }
local TEX_UNLOCKED = { "Interface\\Buttons\\LockButton-Unlocked-Up", "Interface\\Buttons\\UI-CheckBox-Check" }
local TEX_CARET    = { "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up", "Interface\\Buttons\\Arrow-Down-Up" }

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local skin = { enabled = false }
ns.Skin = skin

local plate                 -- the panel; every other region hangs off it
local header  = {}          -- our header row widgets
local blizz   = { alpha = {} }  -- Blizzard chrome we fade out, and its original alpha
local hoverTicker
local hooksInstalled  = false
local refreshQueued   = false
local hookedUpdate    = false
local lastBlockCount  = 0

function skin.GetPlate() return plate end
function skin.GetOverlay() return plate and plate.overlay or nil end

--------------------------------------------------------------------------------
-- Corner radius
--
-- 3.3.5a has no rounded corners and heroPanel ships no corner art, so the
-- radius is approximated by stepping the plate in at each corner: the
-- background is drawn as three rectangles (a full-width middle band plus two
-- bands inset horizontally) and the border as four 1px edges with a stepped
-- pixel run across each corner. At the default 8px radius that is a 2px
-- chamfer - not an arc, but it takes the hard point off the corner and reads
-- as "soft" at gameplay distance.
--------------------------------------------------------------------------------

local function NotchFor(radius)
    radius = tonumber(radius) or 0
    return math.max(0, math.min(MAX_NOTCH, math.floor(radius / 4 + 0.5)))
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function NewTexture(parent, layer)
    local texture = parent:CreateTexture(nil, layer or "ARTWORK")
    ns.SetTextureFile(texture, ns.SOLID)
    return texture
end

local function NewFontString(parent, layer)
    local fontString = parent:CreateFontString(nil, layer or "OVERLAY")
    fontString:SetFont(ns.GetFontFile(), ns.GetFontSize(0))
    return fontString
end

local function BuildPlate(watch)
    plate = CreateFrame("Frame", "HeroPanelWatchPlate", watch:GetParent() or UIParent)
    plate:Hide()
    plate:SetWidth(PANEL_MIN_WIDTH)
    plate:SetHeight(HEADER_HEIGHT)

    -- Background: middle band plus the two inset bands that make the chamfer.
    plate.bg = {
        main   = NewTexture(plate, "BACKGROUND"),
        top    = NewTexture(plate, "BACKGROUND"),
        bottom = NewTexture(plate, "BACKGROUND"),
    }

    -- A single dark contour just outside the border. The design asks for an
    -- ambient drop shadow; a soft one needs art heroPanel does not ship, so
    -- this is the cheap read of the same idea - it lifts the plate off a bright
    -- background without stacking layers.
    plate.shadow = {
        top    = NewTexture(plate, "BACKGROUND"),
        bottom = NewTexture(plate, "BACKGROUND"),
        left   = NewTexture(plate, "BACKGROUND"),
        right  = NewTexture(plate, "BACKGROUND"),
    }

    plate.edge = {
        top    = NewTexture(plate, "BORDER"),
        bottom = NewTexture(plate, "BORDER"),
        left   = NewTexture(plate, "BORDER"),
        right  = NewTexture(plate, "BORDER"),
    }

    plate.corner = {}
    for _, corner in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }) do
        plate.corner[corner] = {}
        for step = 1, MAX_NOTCH do
            local pixel = NewTexture(plate, "BORDER")
            pixel:SetWidth(1)
            pixel:SetHeight(1)
            pixel:Hide()
            plate.corner[corner][step] = pixel
        end
    end

    -- Divider under the header, fading out at both ends.
    plate.divider = {
        left  = NewTexture(plate, "BORDER"),
        mid   = NewTexture(plate, "BORDER"),
        right = NewTexture(plate, "BORDER"),
    }

    -- Glyphs that have to read on top of the hover tint but still underneath
    -- anything the tracker draws.
    plate.overlay = CreateFrame("Frame", nil, plate)
    plate.overlay:SetAllPoints(plate)

    ------------------------------------------------------------------
    -- Header row
    ------------------------------------------------------------------

    -- Click-to-collapse strip. Deliberately below WatchFrame's frame level so
    -- the real collapse button, and every quest line, keeps mouse priority.
    header.hit = CreateFrame("Frame", nil, plate)
    header.hit:EnableMouse(true)
    header.hit:SetHeight(HEADER_HEIGHT)

    header.lock = CreateFrame("Button", nil, plate)
    header.lock:SetWidth(ICON_SIZE + 4)
    header.lock:SetHeight(ICON_SIZE + 4)
    header.lockIcon = NewTexture(header.lock, "ARTWORK")
    header.lockIcon:SetWidth(ICON_SIZE)
    header.lockIcon:SetHeight(ICON_SIZE)
    header.lockIcon:SetPoint("CENTER")

    header.label     = NewFontString(plate)
    header.label:SetText("OBJECTIVES")

    header.badgeFill = NewTexture(plate, "BORDER")
    header.badgeFill:SetHeight(BADGE_HEIGHT)
    header.badgeText = NewFontString(plate)

    header.caretHover = NewTexture(plate, "BORDER")
    header.caretHover:SetWidth(20)
    header.caretHover:SetHeight(20)
    header.caretHover:Hide()

    header.caret = NewTexture(plate, "ARTWORK")
    header.caret:SetWidth(ICON_SIZE)
    header.caret:SetHeight(ICON_SIZE)
    ns.SetTextureFile(header.caret, TEX_CARET[1], TEX_CARET[2])

    return plate
end

--------------------------------------------------------------------------------
-- Blizzard chrome
--
-- The tracker's own title and collapse-button art are faded out rather than
-- hidden: Show/Hide on a frame the game manages is exactly the kind of call
-- that gets refused in combat, and SetAlpha on a region is neither protected
-- nor something Blizzard's layout code reads back.
--------------------------------------------------------------------------------

local function FindCollapseButton(watch)
    local button = _G.WatchFrameCollapseExpandButton
    if button and button.GetObjectType and button:GetObjectType() == "Button" then return button end

    local found
    ns.WalkFrameTree(watch, function(object, info)
        if not found and info.objectType == "Button" then found = object end
        return false
    end, { maxDepth = 1, includeRegions = false })
    return found
end

local function FindTitleFontString(watch)
    local title = _G.WatchFrameTitle
    if title and title.GetObjectType and title:GetObjectType() == "FontString" then return title end

    -- No named title on this client. Accept an unnamed one only when the
    -- tracker has exactly one direct FontString, so heroPanel cannot end up
    -- fading out something it has not identified.
    local candidates = {}
    ns.WalkFrameTree(watch, function(object, info)
        if info.kind == "region" and info.objectType == "FontString" then
            table.insert(candidates, object)
        end
    end, { maxDepth = 0, includeChildren = false })

    if #candidates == 1 then return candidates[1] end
    return nil
end

local function EachButtonTexture(button, fn)
    if not button then return end
    local getters = { "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }
    for i = 1, #getters do
        local getter = button[getters[i]]
        if type(getter) == "function" then
            local ok, texture = pcall(getter, button)
            if ok and texture then fn(texture) end
        end
    end
end

local function FadeRegion(region)
    if not region or blizz.alpha[region] ~= nil then return end
    blizz.alpha[region] = region:GetAlpha() or 1
    region:SetAlpha(0)
end

local function HideBlizzardChrome()
    FadeRegion(blizz.title)
    EachButtonTexture(blizz.collapse, FadeRegion)
end

local function RestoreBlizzardChrome()
    for region, alpha in pairs(blizz.alpha) do
        pcall(region.SetAlpha, region, alpha)
    end
    wipe(blizz.alpha)
end

--------------------------------------------------------------------------------
-- Styling
--
-- Reads the config and paints. Split out from layout so a colour change from
-- the options panel does not have to re-measure the tracker, and so the
-- per-trigger refresh stays as cheap as possible.
--------------------------------------------------------------------------------

local function StylePlate()
    if not plate then return end

    local db     = ns.db
    local notch  = NotchFor(db.radius)
    local br, bg, bb = ns.HexToRGB(db.bg.color)
    local opacity    = ns.Clamp(db.bg.opacity, 0, 1)
    local er, eg, eb = ns.HexToRGB(db.border.color)

    if db.bg.texture and db.bg.texture ~= "flat" then
        ns.Debug("backdrop texture '%s' is not implemented; drawing flat.", tostring(db.bg.texture))
    end

    -- Background bands.
    local main = plate.bg.main
    main:ClearAllPoints()
    main:SetPoint("TOPLEFT", plate, "TOPLEFT", 0, -notch)
    main:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", 0, notch)

    local top = plate.bg.top
    top:ClearAllPoints()
    top:SetPoint("TOPLEFT", plate, "TOPLEFT", notch, 0)
    top:SetPoint("BOTTOMRIGHT", plate, "TOPRIGHT", -notch, -notch)

    local bottom = plate.bg.bottom
    bottom:ClearAllPoints()
    bottom:SetPoint("TOPLEFT", plate, "BOTTOMLEFT", notch, notch)
    bottom:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -notch, 0)

    for _, texture in pairs(plate.bg) do
        texture:SetVertexColor(br, bg, bb, opacity)
        texture:Show()
    end

    -- Border. "inset" is accepted but drawn as a hairline until Phase 4 gives
    -- the options panel something to switch between.
    local style = db.border.style or "hairline"
    if style ~= "hairline" and style ~= "none" then
        ns.Debug("border style '%s' drawn as hairline.", tostring(style))
    end
    local showBorder = (style ~= "none")

    local edge = plate.edge
    edge.top:ClearAllPoints()
    edge.top:SetPoint("TOPLEFT", plate, "TOPLEFT", notch, 0)
    edge.top:SetPoint("TOPRIGHT", plate, "TOPRIGHT", -notch, 0)
    edge.top:SetHeight(1)

    edge.bottom:ClearAllPoints()
    edge.bottom:SetPoint("BOTTOMLEFT", plate, "BOTTOMLEFT", notch, 0)
    edge.bottom:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -notch, 0)
    edge.bottom:SetHeight(1)

    edge.left:ClearAllPoints()
    edge.left:SetPoint("TOPLEFT", plate, "TOPLEFT", 0, -notch)
    edge.left:SetPoint("BOTTOMLEFT", plate, "BOTTOMLEFT", 0, notch)
    edge.left:SetWidth(1)

    edge.right:ClearAllPoints()
    edge.right:SetPoint("TOPRIGHT", plate, "TOPRIGHT", 0, -notch)
    edge.right:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", 0, notch)
    edge.right:SetWidth(1)

    for _, texture in pairs(edge) do
        texture:SetVertexColor(er, eg, eb, 1)
        if showBorder then texture:Show() else texture:Hide() end
    end

    -- The stepped corner run, one pixel per step along the diagonal.
    for corner, pixels in pairs(plate.corner) do
        for step = 1, MAX_NOTCH do
            local pixel = pixels[step]
            pixel:ClearAllPoints()
            if showBorder and step <= notch then
                local along = step - 1
                local away  = notch - step
                if corner == "TOPLEFT" then
                    pixel:SetPoint("TOPLEFT", plate, "TOPLEFT", along, -away)
                elseif corner == "TOPRIGHT" then
                    pixel:SetPoint("TOPRIGHT", plate, "TOPRIGHT", -along, -away)
                elseif corner == "BOTTOMLEFT" then
                    pixel:SetPoint("BOTTOMLEFT", plate, "BOTTOMLEFT", along, away)
                else
                    pixel:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -along, away)
                end
                pixel:SetVertexColor(er, eg, eb, 1)
                pixel:Show()
            else
                pixel:Hide()
            end
        end
    end

    -- Contour, one pixel outside the border.
    local shadow = plate.shadow
    shadow.top:ClearAllPoints()
    shadow.top:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", notch, 0)
    shadow.top:SetPoint("BOTTOMRIGHT", plate, "TOPRIGHT", -notch, 0)
    shadow.top:SetHeight(1)

    shadow.bottom:ClearAllPoints()
    shadow.bottom:SetPoint("TOPLEFT", plate, "BOTTOMLEFT", notch, 0)
    shadow.bottom:SetPoint("TOPRIGHT", plate, "BOTTOMRIGHT", -notch, 0)
    shadow.bottom:SetHeight(1)

    shadow.left:ClearAllPoints()
    shadow.left:SetPoint("TOPRIGHT", plate, "TOPLEFT", 0, -notch)
    shadow.left:SetPoint("BOTTOMRIGHT", plate, "BOTTOMLEFT", 0, notch)
    shadow.left:SetWidth(1)

    shadow.right:ClearAllPoints()
    shadow.right:SetPoint("TOPLEFT", plate, "TOPRIGHT", 0, -notch)
    shadow.right:SetPoint("BOTTOMLEFT", plate, "BOTTOMRIGHT", 0, notch)
    shadow.right:SetWidth(1)

    for _, texture in pairs(shadow) do
        texture:SetVertexColor(0, 0, 0, showBorder and 0.45 or 0)
    end

    ------------------------------------------------------------------
    -- Header row
    ------------------------------------------------------------------

    local hr, hg, hb = ns.HexToRGB(ns.PALETTE.hairline)
    local divider = plate.divider

    divider.left:ClearAllPoints()
    divider.left:SetPoint("TOPLEFT", plate, "TOPLEFT", 1, -HEADER_HEIGHT)
    divider.left:SetWidth(DIVIDER_FADE)
    divider.left:SetHeight(1)
    divider.left:SetGradientAlpha("HORIZONTAL", hr, hg, hb, 0, hr, hg, hb, ns.ALPHA.divider)

    divider.right:ClearAllPoints()
    divider.right:SetPoint("TOPRIGHT", plate, "TOPRIGHT", -1, -HEADER_HEIGHT)
    divider.right:SetWidth(DIVIDER_FADE)
    divider.right:SetHeight(1)
    divider.right:SetGradientAlpha("HORIZONTAL", hr, hg, hb, ns.ALPHA.divider, hr, hg, hb, 0)

    divider.mid:ClearAllPoints()
    divider.mid:SetPoint("TOPLEFT", divider.left, "TOPRIGHT", 0, 0)
    divider.mid:SetPoint("TOPRIGHT", divider.right, "TOPLEFT", 0, 0)
    divider.mid:SetHeight(1)
    divider.mid:SetVertexColor(hr, hg, hb, ns.ALPHA.divider)

    header.hit:ClearAllPoints()
    header.hit:SetPoint("TOPLEFT", plate, "TOPLEFT", 0, 0)
    header.hit:SetPoint("TOPRIGHT", plate, "TOPRIGHT", 0, 0)

    header.lock:ClearAllPoints()
    header.lock:SetPoint("LEFT", plate, "TOPLEFT", HEADER_PAD_X, -HEADER_HEIGHT / 2)

    local ir, ig, ib = ns.HexToRGB(ns.PALETTE.icon)
    header.lockIcon:SetVertexColor(ir, ig, ib, 1)
    header.caret:SetVertexColor(ir, ig, ib, 1)

    local lr, lg, lb = ns.HexToRGB(ns.PALETTE.headerLabel)
    header.label:SetFont(ns.GetFontFile(), ns.GetFontSize(-0.5))
    header.label:SetTextColor(lr, lg, lb, 1)
    header.label:ClearAllPoints()
    header.label:SetPoint("LEFT", header.lock, "RIGHT", 8, 0)

    local mr, mg, mb = ns.HexToRGB(ns.PALETTE.muted)
    header.badgeText:SetFont(ns.GetFontFile(), ns.GetFontSize(-2.5))
    header.badgeText:SetTextColor(mr, mg, mb, 1)
    header.badgeText:ClearAllPoints()
    header.badgeText:SetPoint("LEFT", header.label, "RIGHT", 8 + BADGE_PAD_X, 0)

    header.badgeFill:ClearAllPoints()
    header.badgeFill:SetPoint("LEFT", header.badgeText, "LEFT", -BADGE_PAD_X, 0)
    header.badgeFill:SetVertexColor(hr, hg, hb, ns.ALPHA.badgeFill)

    local ar, ag, ab = ns.HexToRGB(ns.PALETTE.accent)
    header.caretHover:SetVertexColor(ar, ag, ab, ns.ALPHA.hoverButton)

    -- The caret rides on the real collapse button when there is one, so the
    -- glyph the player clicks is the glyph heroPanel drew.
    header.caret:ClearAllPoints()
    header.caretHover:ClearAllPoints()
    if blizz.collapse then
        header.caret:SetPoint("CENTER", blizz.collapse, "CENTER", 0, 0)
    else
        header.caret:SetPoint("RIGHT", plate, "TOPRIGHT", -HEADER_PAD_X, -HEADER_HEIGHT / 2)
    end
    header.caretHover:SetPoint("CENTER", header.caret, "CENTER", 0, 0)
end
skin.Restyle = StylePlate

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

-- How much of the tracker's own top edge is header rather than quest lines.
-- Our header row overlays that space instead of adding to it, so the skinned
-- panel is the same height as the frame it is skinning.
local function NativeHeaderHeight(watch)
    local top = watch:GetTop()
    if not top then return 0 end

    local lowest
    local button = blizz.collapse
    if button and button:IsShown() and button:GetBottom() then
        lowest = button:GetBottom()
    end
    local title = blizz.title
    if title and title:IsShown() and title:GetBottom() then
        lowest = lowest and math.min(lowest, title:GetBottom()) or title:GetBottom()
    end
    if not lowest then return 0 end

    local height = top - lowest
    if height < 0 or height > HEADER_HEIGHT + 18 then return 0 end
    return height
end

-- contentBottom is the bottom edge of the lowest line the skin styled, measured
-- by Lines.Apply. The tracker's own height is the space it has been given to
-- draw in rather than the space it is using, so the plate is sized from what is
-- actually on screen and only falls back to the frame when there is nothing to
-- measure.
local function LayoutPlate(watch, contentBottom)
    local collapsed = ns.IsCollapsed("watch")
    ns.SetCollapsedState("watch", collapsed)

    -- Another addon may have re-parented the tracker since the plate was built.
    -- Following it keeps the two in one scale chain, which is what lets line
    -- measurements be used directly as offsets on our own frames.
    local parent = watch:GetParent() or UIParent
    if plate:GetParent() ~= parent then plate:SetParent(parent) end
    plate:SetScale(watch:GetScale() or 1)

    -- Two levels below the tracker, not one: the hover tint has to sit above
    -- the plate's background and still below every line the tracker draws, and
    -- that needs a level of its own between them.
    --
    -- The lock button is the one thing that goes above the tracker. It has to
    -- take its own clicks even while the tracker itself is mouse-enabled for
    -- dragging, and it only covers the header's top-left corner. The collapse
    -- strip stays below, so an unlocked tracker drags from the header instead.
    local level = watch:GetFrameLevel() or 2
    local base  = math.max(0, level - 2)
    plate:SetFrameStrata(watch:GetFrameStrata())
    plate:SetFrameLevel(base)
    plate.overlay:SetFrameLevel(base + 2)
    header.hit:SetFrameLevel(base + 1)
    header.lock:SetFrameLevel(base + 3)

    local nativeHeader = NativeHeaderHeight(watch)
    local headerHeight = ns.db.header.show and HEADER_HEIGHT or 0
    local extraTop     = math.max(0, headerHeight - nativeHeader)
    local minHeight    = math.max(headerHeight, nativeHeader) + 4

    -- The panel is as wide as the tracker plus its padding, so the header's
    -- caret still lands on the tracker's own collapse button. The design width
    -- is the floor for a tracker that has not reported a usable width yet.
    local trackerWidth = watch:GetWidth() or 0
    local width = trackerWidth > 60 and (trackerWidth + PAD_LEFT + PAD_RIGHT) or PANEL_MIN_WIDTH

    local top    = watch:GetTop()
    local height = minHeight
    if not collapsed and contentBottom and top then
        height = (top + extraTop) - contentBottom + PAD_BOTTOM
    end

    plate:ClearAllPoints()
    plate:SetPoint("TOPLEFT", watch, "TOPLEFT", -PAD_LEFT, extraTop)
    plate:SetWidth(width)
    plate:SetHeight(math.max(minHeight, height))

    return collapsed
end

--------------------------------------------------------------------------------
-- Header contents
--------------------------------------------------------------------------------

local function TrackedQuestCount()
    if type(_G.GetNumQuestWatches) == "function" then
        local ok, count = pcall(_G.GetNumQuestWatches)
        if ok and count then return count end
    end
    -- No API for it on this client: fall back to what is actually drawn.
    return lastBlockCount
end

local function UpdateHeader()
    if not plate then return end

    local locked = ns.IsLocked()
    ns.SetTextureFile(header.lockIcon,
        locked and TEX_LOCKED[1] or TEX_UNLOCKED[1],
        locked and TEX_LOCKED[2] or TEX_UNLOCKED[2])

    -- The base caret art points down, which is the collapsed state; flipping it
    -- vertically gives the expanded one.
    if ns.IsCollapsed("watch") then
        header.caret:SetTexCoord(0, 1, 0, 1)
    else
        header.caret:SetTexCoord(0, 1, 1, 0)
    end

    local count = TrackedQuestCount()
    header.badgeText:SetText(tostring(count))
    header.badgeFill:SetWidth((header.badgeText:GetStringWidth() or 6) + BADGE_PAD_X * 2)

    -- Turning heroPanel's header off has to give the tracker's own header back,
    -- otherwise there is nothing left to collapse the panel with.
    if ns.db.header.show then
        HideBlizzardChrome()
    else
        RestoreBlizzardChrome()
    end

    if ns.db.header.show then
        header.hit:Show()
        header.lock:Show()
        header.label:Show()
        header.badgeFill:Show()
        header.badgeText:Show()
        header.caret:Show()
        for _, texture in pairs(plate.divider) do texture:Show() end
    else
        header.hit:Hide()
        header.lock:Hide()
        header.label:Hide()
        header.badgeFill:Hide()
        header.badgeText:Hide()
        header.caret:Hide()
        header.caretHover:Hide()
        for _, texture in pairs(plate.divider) do texture:Hide() end
    end
end

--------------------------------------------------------------------------------
-- Refresh
--
-- Every trigger funnels through here and is coalesced onto the next frame, so
-- a burst of events - which is what a quest turn-in looks like - costs one
-- pass, not one per event.
--------------------------------------------------------------------------------

local function Refresh(reason)
    if refreshQueued then return end
    refreshQueued = true

    ns.After(0, function()
        refreshQueued = false
        if not skin.enabled or not plate then return end

        local watch = ns.GetTrackerFrame("watch")
        if not watch then return end

        if not watch:IsVisible() then
            plate:Hide()
            if ns.Lines then ns.Lines.ClearHover() end
            return
        end

        -- First pass anchors the plate and gives it a header-sized height, so
        -- the lines have something to measure against; the second sizes it to
        -- what those lines turned out to be. Both happen before the frame is
        -- drawn, so nothing flickers.
        local collapsed = LayoutPlate(watch, nil)
        plate:Show()

        if ns.Lines then
            if collapsed then
                ns.Lines.ClearBlocks()
            else
                local count, contentBottom = ns.Lines.Apply(watch)
                lastBlockCount = count or 0
                LayoutPlate(watch, contentBottom)
            end
        end

        -- After the lines, so a client with no quest-watch API can still put
        -- the number of blocks it just drew in the badge.
        UpdateHeader()

        ns.Debug("skin refreshed (%s).", tostring(reason))
    end)
end
skin.Refresh = Refresh

--------------------------------------------------------------------------------
-- Collapse
--
-- The tracker already knows how to collapse itself. heroPanel clicks the
-- button the game provides rather than driving WatchFrame's state directly,
-- which keeps the whole thing out of protected territory. Out of combat only:
-- a collapse in combat is the game's call to refuse, not ours to force.
--------------------------------------------------------------------------------

function skin.ToggleCollapse()
    if InCombatLockdown() then
        ns.Warn("can't collapse the objective tracker in combat - the game protects it.")
        return false
    end

    local button = blizz.collapse
    if button and button:IsShown() and type(button.Click) == "function" then
        local ok = pcall(button.Click, button)
        if ok then
            Refresh("collapse toggled")
            return true
        end
    end

    local watch = ns.GetTrackerFrame("watch")
    if not watch then return false end

    local collapsed = ns.IsCollapsed("watch")
    local fn = collapsed and _G.WatchFrame_Expand or _G.WatchFrame_Collapse
    if type(fn) ~= "function" then return false end

    pcall(fn, watch)
    Refresh("collapse toggled")
    return true
end

--------------------------------------------------------------------------------
-- Hover
--
-- Sampled at 10Hz off the shared ticker rather than by enabling the mouse on
-- our own frames. A mouse-enabled overlay would sit between the player and the
-- tracker's clickable quest lines; MouseIsOver only reads geometry, so nothing
-- heroPanel draws can swallow a click.
--------------------------------------------------------------------------------

local function HoverTick()
    if not skin.enabled or not plate or not plate:IsVisible() then return end

    if not ns.MouseIsOver(plate) then
        header.caretHover:Hide()
        if ns.Lines then ns.Lines.ClearHover() end
        return
    end

    local overCollapse = ns.db.header.show
        and ((blizz.collapse and blizz.collapse:IsShown() and ns.MouseIsOver(blizz.collapse))
             or ns.MouseIsOver(header.hit))
    if overCollapse then header.caretHover:Show() else header.caretHover:Hide() end

    if ns.Lines then ns.Lines.UpdateHover() end
end

--------------------------------------------------------------------------------
-- Hooks
--
-- Installed once. Frame scripts go through ns.HookScript so nothing the game
-- or another addon installed is replaced; globals go through hooksecurefunc.
--------------------------------------------------------------------------------

local function InstallHooks(watch)
    if hooksInstalled then return end
    hooksInstalled = true

    ns.HookScript(watch, "OnShow", function() Refresh("shown") end)
    ns.HookScript(watch, "OnHide", function()
        if plate then plate:Hide() end
        if ns.Lines then ns.Lines.ClearHover() end
    end)
    ns.HookScript(watch, "OnSizeChanged", function() Refresh("resized") end)

    if type(_G.WatchFrame_Update) == "function" then
        hooksecurefunc("WatchFrame_Update", function() Refresh("tracker updated") end)
        hookedUpdate = true
    end
    if type(_G.WatchFrame_Collapse) == "function" then
        hooksecurefunc("WatchFrame_Collapse", function() Refresh("collapsed") end)
    end
    if type(_G.WatchFrame_Expand) == "function" then
        hooksecurefunc("WatchFrame_Expand", function() Refresh("expanded") end)
    end

    -- Without WatchFrame_Update there is no callback for "the tracker's
    -- contents changed", so fall back to the events that cause it.
    if not hookedUpdate then
        ns:On("QUEST_LOG_UPDATE", function() Refresh("quest log") end)
        ns.Debug("WatchFrame_Update not found; refreshing from QUEST_LOG_UPDATE instead.")
    end

    header.hit:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then skin.ToggleCollapse() end
    end)

    header.lock:SetScript("OnClick", function()
        ns:ToggleLock("watch")
    end)
    header.lock:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ns.IsLocked() and "Unlock to move the tracker" or "Lock the tracker", 1, 1, 1)
        GameTooltip:Show()
    end)
    header.lock:SetScript("OnLeave", function() GameTooltip:Hide() end)

    ns.Debug("skin hooks installed (WatchFrame_Update %s).", hookedUpdate and "hooked" or "absent")
end

--------------------------------------------------------------------------------
-- Enable / disable
--
-- HEROPANEL_DB.enabled = false must give the player Blizzard's tracker back,
-- not just hide heroPanel's own chrome, so Disable undoes everything the skin
-- changed: fonts, colours, faded regions and rewritten counters.
--------------------------------------------------------------------------------

-- Returns false plus a reason, so a caller can say why the skin is not there
-- rather than leaving the player looking at an unchanged tracker.
function skin.Enable()
    if not ns.db then return false, "SavedVariables are not loaded yet" end

    local watch = ns.GetTrackerFrame("watch")
    if not watch then return false, "the objective tracker has not been found" end

    if not plate then
        blizz.collapse = FindCollapseButton(watch)
        blizz.title    = FindTitleFontString(watch)
        BuildPlate(watch)
        InstallHooks(watch)
        ns.Debug("skin built (collapse button %s, title %s).",
            blizz.collapse and "found" or "not found",
            blizz.title and "found" or "not found")
    end

    skin.enabled = true
    HideBlizzardChrome()
    StylePlate()

    if not hoverTicker then hoverTicker = ns.NewTicker(HOVER_INTERVAL, HoverTick) end
    hoverTicker:Start()

    Refresh("enabled")
    return true
end

function skin.Disable()
    skin.enabled = false

    if hoverTicker then hoverTicker:Stop() end
    if ns.Lines then ns.Lines.Restore() end

    RestoreBlizzardChrome()
    if plate then plate:Hide() end
    return true
end

-- The single entry point for the config flag, so nothing else has to remember
-- to write HEROPANEL_DB.enabled and call the right half.
function skin.SetEnabled(enabled)
    if not ns.db then return false end
    ns.db.enabled = enabled and true or false

    if ns.db.enabled then
        if not skin.Enable() then
            ns.Debug("skin enabled but the objective tracker is not available yet.")
        end
    else
        skin.Disable()
    end
    return ns.db.enabled
end

--------------------------------------------------------------------------------
-- Status
--
-- What /hp status reports about the skin. A panel that is built but not visible
-- and a panel that was never built are the same thing on screen and completely
-- different problems, so say which one it is.
--------------------------------------------------------------------------------

function skin.PrintStatus()
    if not ns.db then return end

    ns.Print("  skin is |cFFC2C6D8%s|r", ns.db.enabled and "on" or "off")

    if not plate then
        ns.Print("    |cFFFFAA00panel not built|r - the tracker was not available when the skin ran")
        return
    end

    local watch = ns.GetTrackerFrame("watch")
    ns.Print("    panel %s, %.0f x %.0f, level %.0f",
        plate:IsVisible() and "|cFF79C68Dvisible|r" or "|cFFFFAA00not visible|r",
        plate:GetWidth() or 0, plate:GetHeight() or 0, plate:GetFrameLevel() or 0)

    if watch then
        ns.Print("    tracker %s, %s, %.0f quest block(s) styled",
            watch:IsVisible() and "visible" or "|cFFFFAA00hidden|r",
            ns.IsCollapsed("watch") and "collapsed" or "expanded",
            lastBlockCount)
    end

    ns.Print("    header chrome: collapse button %s, title %s",
        blizz.collapse and "found" or "|cFFFFAA00not found|r",
        blizz.title and "found" or "|cFFFFAA00not found|r")
    ns.Print("    glyphs: lock |cFF8B8FA3%s|r, caret |cFF8B8FA3%s|r",
        tostring(header.lockIcon and header.lockIcon:GetTexture()),
        tostring(header.caret and header.caret:GetTexture()))
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

ns:On("HEROPANEL_TRACKER_FOUND", function(key)
    if key ~= "watch" then return end
    if not ns.db then ns.InitDB() end
    if ns.db.enabled then skin.Enable() end
end)

ns:On("HEROPANEL_LOCK_CHANGED", function()
    if skin.enabled then UpdateHeader() end
end)

ns:On("PLAYER_LOGIN", function()
    if ns.db and ns.db.enabled and not skin.enabled then
        local ok, reason = skin.Enable()
        -- By login the tracker exists on any client heroPanel can skin, so a
        -- failure here is worth saying out loud rather than logging quietly.
        if not ok then ns.Warn("the skin was not applied: %s.", tostring(reason)) end
    end
    Refresh("login")
end)

ns:On("PLAYER_ENTERING_WORLD", function() Refresh("entering world") end)
ns:On("QUEST_WATCH_UPDATE", function() Refresh("quest watch") end)
