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
-- Wider than the design's 14 on purpose. The tracker's quest titles start flush
-- against the panel's content edge, so a quest's status icon has nowhere to go
-- on the left without either overlapping the title or being shrunk to the point
-- of illegibility. This margin is what it sits in.
local PAD_LEFT        = 34
local PAD_RIGHT       = 14
local PAD_BOTTOM      = 13
local HEADER_PAD_X    = 13
local DIVIDER_FADE    = 24    -- the divider fades out over this much at each end
local MAX_NOTCH       = 3     -- corner steps at the largest supported radius
local ICON_SIZE       = 12
-- The caret is a chevron: wide and shallow, so it needs a little more box than
-- a lock to carry the same weight on screen - but only a little.
local CARET_SIZE      = 13
local BADGE_HEIGHT    = 14
local BADGE_PAD_X     = 6
local HOVER_INTERVAL  = 0.1

-- The tracker's own header band, measured down from its top edge. The fallback
-- is a constant rather than zero on purpose: a band that measures as nothing
-- whenever the collapse button is briefly unmeasurable moves heroPanel's whole
-- header row by 30px, which is the difference between the design and two
-- headers stacked on top of each other.
local HEADER_BAND_FALLBACK = 22
local HEADER_BAND_MAX      = HEADER_HEIGHT + 18

-- Frame levels only run down to zero and are only comparable inside a strata,
-- so "a couple of levels below the tracker" silently stops working on a client
-- that puts the tracker at level 1. A strata step has no floor.
local STRATA_BELOW = {
    TOOLTIP           = "FULLSCREEN_DIALOG",
    FULLSCREEN_DIALOG = "FULLSCREEN",
    FULLSCREEN        = "DIALOG",
    DIALOG            = "HIGH",
    HIGH              = "MEDIUM",
    MEDIUM            = "LOW",
    LOW               = "BACKGROUND",
    BACKGROUND        = "BACKGROUND",
}

-- Glyphs are drawn from solids by ns.NewGlyph rather than taken from client
-- art. The design fixes their colours and a tint cannot reach those from
-- Blizzard's coloured icons - see the glyph notes in Util.lua.

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
local lastContentBottom     -- what the last line walk measured, for /hp dump

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
    header.lockIcon = ns.NewGlyph(header.lock, ICON_SIZE)
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

    header.caret = ns.NewGlyph(plate, CARET_SIZE)

    return plate
end

--------------------------------------------------------------------------------
-- Blizzard chrome
--
-- heroPanel's header row replaces the tracker's own, so everything the tracker
-- draws in that band has to go - not just the title FontString and the collapse
-- button's art. Fading only those two left this client's header title and its
-- header art on screen underneath ours.
--
-- Which regions make up the header differs between builds and between addon
-- stacks, and the string on screen is not reliably the one a name lookup finds,
-- so the band is cleared by *geometry* rather than by name: every region the
-- tracker or one of its direct children draws inside the band is faded, and its
-- original alpha is kept so Disable() puts all of them back.
--
-- Fading, not hiding: Show/Hide on a frame the game manages is exactly the kind
-- of call that gets refused in combat, and SetAlpha on a region is neither
-- protected nor something Blizzard's layout code reads back.
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

-- The original alpha is recorded once; the fade itself is re-applied every
-- time. A region heroPanel has already seen can be shown again by the tracker's
-- next update, and an early return on "we know this one" would leave it there.
local function FadeRegion(region)
    if not region or type(region.SetAlpha) ~= "function" then return end
    if blizz.alpha[region] == nil then
        local ok, alpha = pcall(region.GetAlpha, region)
        blizz.alpha[region] = (ok and alpha) or 1
    end
    pcall(region.SetAlpha, region, 0)
end

-- Bottom edge of the tracker's header band, in screen coordinates.
--
-- The band is the union of the header widgets that can be measured, so it
-- covers everything the tracker's header draws: the collapse button is the one
-- widget every build of this tracker has, and the title extends the band
-- downwards when it sits lower. HEADER_BAND_MAX caps how far that can run, and
-- anything unreasonable falls back to the constant rather than to zero - a band
-- of zero moves heroPanel's whole header row, see HEADER_BAND_FALLBACK.
local function HeaderBandBottom(watch)
    local top = watch and watch:GetTop()
    if not top then return nil end

    local bottom
    local button = blizz.collapse
    if button and button:IsShown() and button:GetBottom() then
        bottom = button:GetBottom()
    end
    local title = blizz.title
    if title and title:IsShown() and title:GetBottom() then
        bottom = bottom and math.min(bottom, title:GetBottom()) or title:GetBottom()
    end

    if not bottom or bottom >= top or (top - bottom) > HEADER_BAND_MAX then
        bottom = top - HEADER_BAND_FALLBACK
    end
    return bottom
end

-- Lines.lua needs the same band to keep the tracker's header title out of its
-- quest-line walk, and there must be exactly one definition of where it is.
function skin.HeaderBandBottom(watch)
    return HeaderBandBottom(watch or ns.GetTrackerFrame("watch"))
end

-- The band is a strip of screen, so what belongs to it is what is drawn through
-- it - not what happens to start inside it.
--
-- Testing the top edge alone missed the tracker's own background art, which
-- overhangs the frame's top edge and runs the height of the panel: its top was
-- *above* the tracker, so a top-inside-the-band test threw it out for being too
-- high, and it is the root's own region, so the header-frame promotion skipped
-- it as well. Two guards, each excluding it for a different reason.
--
-- Overlap does not widen this as much as it looks. Quest lines are drawn below
-- the band and are only a line tall, so none of them reaches into it; what
-- overlap adds is exactly the large art that spans the header, which is chrome
-- by definition - heroPanel draws its own background over that space.
local function OverlapsBand(region, bandBottom, bandTop)
    local top, bottom = region:GetTop(), region:GetBottom()
    if not (top and bottom) then return false end
    return top > bandBottom and bottom < bandTop
end

-- Deliberately the same reach as Lines.Collect's walk. The two have to agree:
-- anything the line walk can pick up and mistake for a quest title is something
-- this has to be able to fade, and a header nested one frame deeper than the
-- fade could see is exactly how the tracker's own title ended up both visible
-- and styled as a quest. The geometry test is what keeps the extra depth safe -
-- quest lines are drawn below the band, not inside it.
local BAND_DEPTH = 3

local function EachRegion(frame, fn)
    if not (frame and frame.GetRegions) then return end
    local ok, regions = pcall(function() return { frame:GetRegions() } end)
    if not ok then return end
    for i = 1, #regions do
        if regions[i] then fn(regions[i]) end
    end
end

local function FadeHeaderBand(watch)
    if not watch then return end

    local top        = watch:GetTop()
    local bandBottom = HeaderBandBottom(watch)
    if not (top and bandBottom) then return end

    blizz.bandBottom  = bandBottom
    blizz.bandCount   = 0
    blizz.headerCount = 0
    blizz.headerFrames = blizz.headerFrames or {}
    wipe(blizz.headerFrames)

    ns.WalkFrameTree(watch, function(region, info)
        if info.kind ~= "region" then return end
        if info.objectType ~= "FontString" and info.objectType ~= "Texture" then return end
        if not (region.IsShown and region:IsShown()) then return end
        if not OverlapsBand(region, bandBottom, top) then return end

        blizz.bandCount = blizz.bandCount + 1
        FadeRegion(region)

        -- A frame that draws inside the band is a header frame, and the rest of
        -- what it draws is header too - the divider art under this tracker's
        -- title hangs a few pixels below the band and survived a purely
        -- geometric pass. Quest lines never draw inside the band, so nothing
        -- that carries quest text can be promoted this way, and only the owning
        -- frame's own regions are taken, never its children's.
        --
        -- The tracker itself is excluded: it is the root of everything, and
        -- "all of WatchFrame's regions" is a different and much larger claim.
        local owner = info.parent
        if owner and owner ~= watch and not blizz.headerFrames[owner] then
            blizz.headerFrames[owner] = true
            blizz.headerCount = blizz.headerCount + 1
        end
    end, { maxDepth = BAND_DEPTH, includeRegions = true })

    for owner in pairs(blizz.headerFrames) do
        EachRegion(owner, FadeRegion)
    end

    -- A button's textures are regions of the button and are covered above, but
    -- only while the button is shown and measurable. This is the belt-and-braces
    -- pass for the one widget heroPanel draws over itself.
    EachButtonTexture(blizz.collapse, FadeRegion)
end

local function RestoreBlizzardChrome()
    for region, alpha in pairs(blizz.alpha) do
        pcall(region.SetAlpha, region, alpha)
    end
    wipe(blizz.alpha)
    blizz.bandCount   = 0
    blizz.headerCount = 0
    if blizz.headerFrames then wipe(blizz.headerFrames) end
end

--------------------------------------------------------------------------------
-- Styling
--
-- Reads the config and paints. Split out from layout so a colour change from
-- the options panel does not have to re-measure the tracker, and so the
-- per-trigger refresh stays as cheap as possible.
--------------------------------------------------------------------------------

-- The caret belongs to heroPanel's header row, so it is placed against the
-- panel: centred in the row, HEADER_PAD_X in from the right, mirroring the lock
-- on the left. That is where the design puts it.
--
-- It used to ride Blizzard's collapse button instead, on the reasoning that the
-- glyph the player clicks should be the glyph heroPanel drew. That put it
-- wherever the tracker happened to keep its button - on this client seven
-- pixels below the row's centre, hard against the divider and reading as though
-- it had slipped into the body. The reasoning was wrong anyway: the header's
-- click strip spans the whole row and collapses on click, and the tracker's own
-- button still takes its own clicks underneath, so both work wherever the
-- glyph is drawn.
local function AnchorCaret()
    if not plate then return end

    header.caret:ClearAllPoints()
    header.caret:SetPoint("RIGHT", plate, "TOPRIGHT", -HEADER_PAD_X, -HEADER_HEIGHT / 2)

    header.caretHover:ClearAllPoints()
    header.caretHover:SetPoint("CENTER", header.caret, "CENTER", 0, 0)
end

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
    header.lockIcon:SetColor(ir, ig, ib, 1)
    header.caret:SetColor(ir, ig, ib, 1)

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

    AnchorCaret()
end
skin.Restyle = StylePlate

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

-- How much of the tracker's own top edge is header rather than quest lines.
-- Our header row overlays that space instead of adding to it, so the skinned
-- panel is the same height as the frame it is skinning.
local function NativeHeaderHeight(watch)
    local top        = watch:GetTop()
    local bandBottom = HeaderBandBottom(watch)
    if not (top and bandBottom) then return HEADER_BAND_FALLBACK end
    return top - bandBottom
end

-- contentBottom is the bottom edge of the lowest line the skin styled, measured
-- by Lines.Apply. The tracker's own height is the space it has been given to
-- draw in rather than the space it is using, so the plate is sized from what is
-- actually on screen and only falls back to the frame when there is nothing to
-- measure.
local function LayoutPlate(watch, contentBottom)
    -- Another addon may have re-parented the tracker since the plate was built.
    -- Following it keeps the two in one scale chain, which is what lets line
    -- measurements be used directly as offsets on our own frames.
    local parent = watch:GetParent() or UIParent
    if plate:GetParent() ~= parent then plate:SetParent(parent) end
    plate:SetScale(watch:GetScale() or 1)

    -- The plate goes a strata below the tracker rather than a couple of frame
    -- levels below it. Levels bottom out at zero and only compare inside one
    -- strata, so on a client that puts the tracker at level 1 - which is what
    -- this one does - "two below" clamped to zero and the overlay, two levels up
    -- from that, came out *above* the tracker and drew heroPanel's check marks
    -- over Blizzard's text. A strata step has no floor, so the plate, the hover
    -- tint and the glyphs stay behind the tracker whatever level it picks.
    --
    -- The lock button is the one thing that goes above the tracker. It has to
    -- take its own clicks even while the tracker itself is mouse-enabled for
    -- dragging, and it only covers the header's top-left corner. The collapse
    -- strip stays below, so an unlocked tracker drags from the header instead.
    local strata = watch:GetFrameStrata() or "LOW"
    local level  = watch:GetFrameLevel() or 1
    plate:SetFrameStrata(STRATA_BELOW[strata] or "BACKGROUND")
    plate:SetFrameLevel(1)
    header.hit:SetFrameLevel(2)
    plate.overlay:SetFrameLevel(3)

    header.lock:SetFrameStrata(strata)
    header.lock:SetFrameLevel(level + 1)

    local nativeHeader = NativeHeaderHeight(watch)
    local headerHeight = ns.db.header.show and HEADER_HEIGHT or 0
    local extraTop     = math.max(0, headerHeight - nativeHeader)
    local minHeight    = math.max(headerHeight, nativeHeader) + 4

    -- The panel is as wide as the tracker plus its padding, so the header's
    -- caret still lands on the tracker's own collapse button. The design width
    -- is the floor for a tracker that has not reported a usable width yet.
    local trackerWidth = watch:GetWidth() or 0
    local width = trackerWidth > 60 and (trackerWidth + PAD_LEFT + PAD_RIGHT) or PANEL_MIN_WIDTH

    -- No content measured means nothing is drawn below the header, whether
    -- because the tracker is collapsed or because it is empty. Either way the
    -- panel is a header.
    local top    = watch:GetTop()
    local height = minHeight
    if contentBottom and top then
        height = (top + extraTop) - contentBottom + PAD_BOTTOM
    end

    plate:ClearAllPoints()
    plate:SetPoint("TOPLEFT", watch, "TOPLEFT", -PAD_LEFT, extraTop)
    plate:SetWidth(width)
    plate:SetHeight(math.max(minHeight, height))
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

local function UpdateHeader(watch)
    if not plate then return end

    local locked = ns.IsLocked()
    header.lockIcon:SetShape(locked and "locked" or "unlocked")

    -- Caret up when the tracker is expanded, down when it is collapsed: it
    -- points at what a click would do. Left alone while /hp texture is holding
    -- a test texture there, or the next refresh would wipe the test out.
    if not skin.textureTest then
        header.caret:SetShape(ns.IsCollapsed("watch") and "caretDown" or "caretUp")
    end

    local count = TrackedQuestCount()
    header.badgeText:SetText(tostring(count))
    header.badgeFill:SetWidth((header.badgeText:GetStringWidth() or 6) + BADGE_PAD_X * 2)

    -- Turning heroPanel's header off has to give the tracker's own header back,
    -- otherwise there is nothing left to collapse the panel with.
    if ns.db.header.show then
        FadeHeaderBand(watch)
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

        -- Both are cached at build time, and both can be absent then: the
        -- tracker is sometimes found before it has drawn its own header. Look
        -- again while either is missing rather than skinning around a hole for
        -- the rest of the session.
        if not blizz.collapse then blizz.collapse = FindCollapseButton(watch) end
        if not blizz.title    then blizz.title    = FindTitleFontString(watch) end
        AnchorCaret()

        -- First pass anchors the plate and gives it a header-sized height, so
        -- the lines have something to measure against; the second sizes it to
        -- what those lines turned out to be. Both happen before the frame is
        -- drawn, so nothing flickers.
        LayoutPlate(watch, nil)
        plate:Show()

        if ns.Lines then
            -- The walk always runs. Whether the tracker is collapsed is decided
            -- by what it finds, not by asking the frame first: a client that
            -- leaves its collapsed flag set would otherwise stop the skin from
            -- ever looking at the lines it is meant to be styling.
            local count, contentBottom = ns.Lines.Apply(watch)
            lastBlockCount, lastContentBottom = count or 0, contentBottom

            local collapsed = (contentBottom == nil)
            ns.SetMeasuredCollapsed("watch", collapsed)
            ns.SetCollapsedState("watch", collapsed)
            if collapsed then ns.Lines.ClearBlocks() end

            LayoutPlate(watch, contentBottom)
        end

        -- After the lines, so a client with no quest-watch API can still put
        -- the number of blocks it just drew in the badge.
        UpdateHeader(watch)

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
    FadeHeaderBand(watch)
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

    -- "title found" on its own was misleading: it says a FontString was
    -- located, not that it is the one on screen. The faded count is the honest
    -- answer to "is Blizzard's header gone" - zero means it is still there
    -- whatever the name lookup managed to find.
    ns.Print("    header chrome: collapse button %s, title %s, %s region(s) faded",
        blizz.collapse and "found" or "|cFFFFAA00not found|r",
        blizz.title and "found" or "|cFFFFAA00not found|r",
        (blizz.bandCount or 0) > 0
            and string.format("|cFF79C68D%.0f|r", blizz.bandCount)
            or "|cFFFFAA000|r")
    -- Which route the glyphs took is the first question when they look wrong,
    -- and *which file* is the second. Two different files fail the same way on
    -- screen - this client draws green for anything it resolves and will not
    -- decode - so "shipped art" on its own says nothing about which one is
    -- being looked at.
    ns.Print("    glyphs: lock |cFF8B8FA3%s|r, caret |cFF8B8FA3%s|r, mode |cFFC2C6D8%s|r",
        tostring(header.lockIcon and header.lockIcon.shape),
        tostring(header.caret and header.caret.shape),
        (ns.db.glyph and ns.db.glyph.mode) or "auto")

    if header.caret and header.caret.usingArt then
        ns.Print("      drawn from |cFF79C68Dshipped art|r: |cFF8B8FA3%s|r",
            tostring(header.caret.artPath))
        ns.Print("      |cFF8B8FA3a green square here means the client resolved that file "
            .. "and would not decode it|r")
    else
        ns.Print("      drawn from |cFFFFAA00solid blocks|r - no art file was accepted")
    end
end

--------------------------------------------------------------------------------
-- Geometry dump
--
-- /hp dump. The panel is sized from what the tracker's lines measure, so when
-- it comes out the wrong size the question is always "what did the walk
-- actually find, and where does the client think it is". Guessing at that from
-- a screenshot does not work, especially with another skin in play.
--------------------------------------------------------------------------------

local function Describe(frame, label)
    if not frame then
        ns.Print("  %s: |cFFFFAA00missing|r", label)
        return
    end

    local parent = frame:GetParent()
    local parentName = parent and (parent:GetName() or "unnamed") or "none"

    ns.Print("  %s: %s, parent %s, level %.0f, strata %s",
        label,
        frame:IsVisible() and "visible" or "|cFFFFAA00not visible|r",
        tostring(parentName),
        frame:GetFrameLevel() or 0,
        tostring(frame:GetFrameStrata()))
    ns.Print("    top %s bottom %s left %s right %s, %s x %s",
        tostring(frame:GetTop() and string.format("%.0f", frame:GetTop())),
        tostring(frame:GetBottom() and string.format("%.0f", frame:GetBottom())),
        tostring(frame:GetLeft() and string.format("%.0f", frame:GetLeft())),
        tostring(frame:GetRight() and string.format("%.0f", frame:GetRight())),
        tostring(frame:GetWidth() and string.format("%.0f", frame:GetWidth())),
        tostring(frame:GetHeight() and string.format("%.0f", frame:GetHeight())))
    ns.Print("    scale %.2f, effective %.2f",
        frame:GetScale() or 1, frame:GetEffectiveScale() or 1)
end

-- Who else is drawing here.
--
-- The walk starts at WatchFrame, so anything another addon parents somewhere
-- else is invisible to it - including, potentially, the header drawn over ours.
-- Reporting the text around the tracker with the frame that owns it names the
-- culprit outright. It uses the holder heroPanel already observed in Phase 1
-- rather than any hardcoded frame name, so this works for whichever addon it
-- turns out to be.
local NEIGHBOUR_LIMIT = 20

-- What a region is, in one column: the text for a FontString, the tail of the
-- texture path for a Texture. The tail rather than the head because the leading
-- "Interface\\..." is the same on every path and the filename is what names it.
local function RegionSummary(region, objectType)
    if objectType == "FontString" then
        local ok, text = pcall(region.GetText, region)
        return string.format("\"%s\"", string.sub((ok and text) or "", 1, 26))
    end
    local ok, path = pcall(region.GetTexture, region)
    if ok and path then
        path = tostring(path)
        return string.sub(path, math.max(1, #path - 29))
    end
    return "-"
end

local function DescribeChain(frame, label)
    if not frame then return end
    local names, guard, current = {}, 0, frame
    while current and guard < 8 do
        table.insert(names, (current.GetName and current:GetName()) or "unnamed")
        current = current.GetParent and current:GetParent() or nil
        guard = guard + 1
    end
    ns.Print("  %s chain: %s", label, table.concat(names, " < "))
end

local function DumpNeighbourhood()
    local record = ns.trackers and ns.trackers.watch
    if not record or not record.frame then return end

    local roots, seen = {}, {}
    local function AddRoot(frame)
        if frame and frame ~= UIParent and not seen[frame] then
            seen[frame] = true
            table.insert(roots, frame)
        end
    end
    AddRoot(record.holderFrame)
    AddRoot(record.frame:GetParent())

    if #roots == 0 then
        ns.Print("  nothing else owns the tracker - it hangs straight off UIParent")
        return
    end

    for i = 1, #roots do
        local root = roots[i]
        ns.Print("  text drawn under |cFFC2C6D8%s|r:",
            tostring((root.GetName and root:GetName()) or "unnamed"))

        -- Textures as well as text. Reporting only FontStrings answered "who
        -- drew this header" and stayed silent about art, which is the half that
        -- actually went missing.
        local count = 0
        ns.WalkFrameTree(root, function(object, info)
            if info.kind ~= "region" then return end
            local isText = info.objectType == "FontString"
            if not isText and info.objectType ~= "Texture" then return end
            if isText and (object:GetText() or "") == "" then return end

            count = count + 1
            if count > NEIGHBOUR_LIMIT then return false end
            ns.Print("    d%.0f %s %s: %s", info.depth,
                tostring((info.parent.GetName and info.parent:GetName()) or "unnamed"),
                isText and "text" or "art ",
                RegionSummary(object, info.objectType))
        end, { maxDepth = 4 })

        if count == 0 then ns.Print("    none") end
    end
end

-- What the tracker actually draws in its header band, and whether heroPanel
-- got hold of it.
--
-- This is the half of the picture the rest of the dump was missing. The skin
-- fades chrome it identifies by name, the name lookup can land on a FontString
-- that is not the one on screen, and from the outside "faded the wrong string"
-- and "did not fade anything" look identical - two headers on top of each
-- other. Listing the band region by region, with the owner that draws it and
-- whether heroPanel has its alpha, says which.
local CHROME_LIMIT = 24

local function DumpChrome(watch)
    local top = watch and watch:GetTop()
    if not top then
        ns.Print("  |cFFFFAA00header band: no top edge to measure from|r")
        return
    end

    local bandBottom = HeaderBandBottom(watch)
    ns.Print("  header band: top %.0f bottom %.0f (%.0f tall), %.0f in band, %.0f header frame(s)",
        top, bandBottom or top, top - (bandBottom or top),
        blizz.bandCount or 0, blizz.headerCount or 0)

    -- Regions outside the band are listed too when their owner draws inside it.
    -- That is the whole point of the promotion: art anchored a few pixels below
    -- the band is still header art, and the only way to see whether heroPanel
    -- reached it is to print it next to the band it did not fall in.
    local count = 0
    ns.WalkFrameTree(watch, function(region, info)
        if info.kind ~= "region" then return end
        if info.objectType ~= "FontString" and info.objectType ~= "Texture" then return end

        local owner    = info.parent
        local promoted = owner and blizz.headerFrames and blizz.headerFrames[owner]
        local inBand   = bandBottom and OverlapsBand(region, bandBottom, top)
        if not (inBand or promoted) then return end

        count = count + 1
        if count > CHROME_LIMIT then return end

        ns.Print("    d%.0f %s %s %s a%.2f %s %s %s",
            info.depth,
            tostring((owner and owner.GetName and owner:GetName()) or "unnamed"),
            info.objectType == "FontString" and "text" or "art ",
            (region.IsShown and region:IsShown()) and "shown" or "|cFF8B8FA3hidden|r",
            (region.GetAlpha and region:GetAlpha()) or 1,
            inBand and "band" or "|cFF8B8FA3below|r",
            blizz.alpha[region] ~= nil and "|cFF79C68Dfaded|r" or "|cFFFFAA00left alone|r",
            RegionSummary(region, info.objectType))
    end, { maxDepth = BAND_DEPTH, includeRegions = true })

    if count == 0 then
        ns.Print("    |cFFFFAA00nothing in the band|r - the tracker's header is drawn elsewhere")
    elseif count > CHROME_LIMIT then
        ns.Print("    ... and %.0f more", count - CHROME_LIMIT)
    end
end

function skin.Dump()
    local watch = ns.GetTrackerFrame("watch")
    ns.Print("geometry dump")

    Describe(watch, "WatchFrame")
    Describe(plate, "panel")
    Describe(blizz.collapse, "collapse button")

    if watch then
        local native = NativeHeaderHeight(watch)
        ns.Print("  native header %.0f, our header %.0f, extra top %.0f, collapsed %s",
            native, ns.db.header.show and HEADER_HEIGHT or 0,
            math.max(0, (ns.db.header.show and HEADER_HEIGHT or 0) - native),
            tostring(ns.IsCollapsed("watch")))
    end

    ns.Print("  last line walk: %s, %.0f block(s)",
        lastContentBottom
            and string.format("content bottom %.0f", lastContentBottom)
            or "|cFFFFAA00nothing measured|r",
        lastBlockCount)

    DumpChrome(watch)

    DescribeChain(watch, "tracker")
    DescribeChain(plate, "panel")

    if ns.Lines and ns.Lines.Dump then ns.Lines.Dump() end

    DumpNeighbourhood()
end

--------------------------------------------------------------------------------
-- Texture test
--
-- /hp texture <path>. Puts an arbitrary texture in the caret's slot, untinted.
--
-- Everything about heroPanel's own glyph files can be checked from outside the
-- game and has been: the header and footer are byte-identical to textures this
-- client demonstrably loads, and the pixel data round-trips through an
-- independent decoder. That leaves two possibilities which no amount of
-- staring at the file can separate - the file is wrong in some way that does
-- not show up in its bytes, or the file is fine and heroPanel is doing
-- something to it that no other addon does.
--
-- Pointing the same slot at a texture that is known to work answers that in one
-- step. Untinted on purpose: a green square multiplied by the glyph colour is
-- not obviously green, and this test is only useful if its failure is
-- unmistakable.
--------------------------------------------------------------------------------

function skin.TestTexture(path)
    if not (plate and header.caret) then
        ns.Print("the panel is not built yet.")
        return false
    end

    if not path or path == "" then
        skin.textureTest = nil
        UpdateHeader(ns.GetTrackerFrame("watch"))
        StylePlate()
        ns.Print("caret glyph restored.")
        return true
    end

    skin.textureTest = path

    local caret = header.caret
    for i = 1, #caret.parts do caret.parts[i]:Hide() end
    caret.usingArt = true
    caret.artPath  = path
    caret.art:SetTexCoord(0, 1, 0, 1)

    local ok, loaded = pcall(caret.art.SetTexture, caret.art, path)
    caret.art:SetVertexColor(1, 1, 1, 1)
    caret.art:Show()

    ns.Print("caret texture: |cFF8B8FA3%s|r", path)
    ns.Print("  SetTexture returned |cFFC2C6D8%s|r; the glyph is untinted, so green means "
        .. "the client would not decode it", tostring(ok and loaded))
    return true
end

--------------------------------------------------------------------------------
-- One frame, by name
--
-- /hp frame <name>. Everything known about a single named frame.
--
-- The wide reports have repeatedly failed at this: they sort by position and
-- truncate, so the one object being chased falls off the end, and a listing
-- that buries its answer reads as though it answered. When /framestack has
-- already named the frame, the remaining question is narrow - where is it,
-- is it drawn, what is it parented to - and that deserves a narrow tool.
--------------------------------------------------------------------------------

function skin.DescribeFrame(name)
    if not name or name == "" then
        ns.Print("usage: /hp frame <FrameName>  (the name /framestack reports)")
        return
    end

    local frame = _G[name]
    if type(frame) ~= "table" or type(frame.GetObjectType) ~= "function" then
        ns.Print("|cFFFFAA00no frame called|r |cFFC2C6D8%s|r", tostring(name))
        return
    end

    ns.Print("frame |cFFC2C6D8%s|r (%s)", name, tostring(frame:GetObjectType()))

    local shown   = frame.IsShown and frame:IsShown()
    local visible = frame.IsVisible and frame:IsVisible()
    ns.Print("  shown %s, visible %s, alpha %.2f, strata %s, level %.0f",
        shown and "|cFF79C68Dyes|r" or "|cFFFFAA00no|r",
        visible and "|cFF79C68Dyes|r" or "|cFFFFAA00no|r",
        (frame.GetAlpha and frame:GetAlpha()) or 1,
        tostring(frame.GetFrameStrata and frame:GetFrameStrata()),
        (frame.GetFrameLevel and frame:GetFrameLevel()) or 0)

    local left, right = frame:GetLeft(), frame:GetRight()
    local top, bottom = frame:GetTop(), frame:GetBottom()
    if left and right and top and bottom then
        ns.Print("  x %.0f..%.0f, y %.0f..%.0f, %.0f x %.0f, effective scale %.2f",
            left, right, bottom, top, right - left, top - bottom,
            (frame.GetEffectiveScale and frame:GetEffectiveScale()) or 1)

        -- Screen pixels as well as UI units, because /framestack reports the
        -- cursor in pixels and everything here is in UI units. Comparing the
        -- two by hand is exactly where this went wrong.
        local scale = (frame.GetEffectiveScale and frame:GetEffectiveScale()) or 1
        ns.Print("  on screen: x %.0f..%.0f, y %.0f..%.0f pixels",
            left * scale, right * scale, bottom * scale, top * scale)
    else
        ns.Print("  |cFFFFAA00no rectangle - the frame has no resolvable anchors|r")
    end

    if plate then
        local panelLeft, panelRight = plate:GetLeft(), plate:GetRight()
        if panelLeft and panelRight then
            ns.Print("  panel x %.0f..%.0f, on screen %.0f..%.0f pixels",
                panelLeft, panelRight,
                panelLeft * plate:GetEffectiveScale(), panelRight * plate:GetEffectiveScale())
        end
    end

    local names, guard, current = {}, 0, frame:GetParent()
    while current and guard < 8 do
        table.insert(names, (current.GetName and current:GetName()) or "unnamed")
        current = current.GetParent and current:GetParent() or nil
        guard = guard + 1
    end
    ns.Print("  parents: %s", #names > 0 and table.concat(names, " < ") or "none")

    local points = (frame.GetNumPoints and frame:GetNumPoints()) or 0
    for i = 1, points do
        local point, relTo, relPoint, x, y = frame:GetPoint(i)
        ns.Print("  anchor %.0f: %s to %s %s at %.0f, %.0f", i,
            tostring(point),
            tostring((relTo and relTo.GetName and relTo:GetName()) or relTo or "nil"),
            tostring(relPoint), x or 0, y or 0)
    end
    if points == 0 then ns.Print("  |cFFFFAA00no anchors|r") end
end

--------------------------------------------------------------------------------
-- Probe
--
-- /hp probe. Everything drawn inside the panel's rectangle, whoever owns it.
--
-- The band dump answers "did heroPanel get hold of the header", and it answers
-- it well. It cannot answer "then what is this", because it only looks where
-- chrome is already expected: at regions inside the band, and at the frames
-- that draw there. Art anchored anywhere else - on the tracker itself, on a
-- frame that draws nothing in the band, on another addon's frame entirely - is
-- invisible to it, and guessing which of those it is has now been wrong.
--
-- So this searches the panel's rectangle rather than the frame hierarchy, and
-- reports every region overlapping it with the frame that owns it, its draw
-- layer, its alpha and its texture path. heroPanel's own regions are marked
-- rather than skipped, because "that streak is ours" is an answer too.
--------------------------------------------------------------------------------

local PROBE_LIMIT  = 40
local PROBE_DEPTH  = 4
-- Frames visited before giving up, so a probe of a busy UIParent cannot hang
-- the client. The tracker and its holder are walked before UIParent, so a
-- budget hit costs the least likely candidates rather than the most likely
-- ones - but it does mean the listing is incomplete, which is why it says so.
local PROBE_BUDGET = 50000

local function Overlaps(region, rect)
    local left, right  = region:GetLeft(), region:GetRight()
    local top, bottom  = region:GetTop(), region:GetBottom()
    if not (left and right and top and bottom) then return false end
    return left < rect.right and right > rect.left
       and bottom < rect.top and top > rect.bottom
end

local function IsOurs(frame)
    local guard = 0
    while frame and guard < 8 do
        if frame == plate then return true end
        frame = frame.GetParent and frame:GetParent() or nil
        guard = guard + 1
    end
    return false
end

function skin.Probe(includeOurs)
    if not plate then
        ns.Print("the panel is not built yet - nothing to probe.")
        return
    end

    local rect = {
        left   = plate:GetLeft(),   right  = plate:GetRight(),
        top    = plate:GetTop(),    bottom = plate:GetBottom(),
    }
    if not (rect.left and rect.right and rect.top and rect.bottom) then
        ns.Print("the panel has no rectangle to probe.")
        return
    end

    local panelWidth  = plate:GetWidth() or 0
    local panelHeight = plate:GetHeight() or 0
    ns.Print("probe: %.0f x %.0f panel at %.0f, %.0f (shown regions only)",
        panelWidth, panelHeight, rect.left, rect.top)

    -- The tracker, whatever holder it was docked into, and the frame it hangs
    -- off. The last one is what catches art that belongs to neither heroPanel
    -- nor the tracker.
    local record = ns.trackers and ns.trackers.watch
    local roots, rooted = {}, {}
    local function AddRoot(frame)
        if frame and not rooted[frame] then
            rooted[frame] = true
            table.insert(roots, frame)
        end
    end
    AddRoot(record and record.frame)
    AddRoot(record and record.holderFrame)
    AddRoot(record and record.frame and record.frame:GetParent())

    local found, seen, visited = {}, {}, 0
    for i = 1, #roots do
        ns.WalkFrameTree(roots[i], function(object, info)
            visited = visited + 1
            if visited > PROBE_BUDGET then return false end
            if info.kind ~= "region" then return end
            if info.objectType ~= "FontString" and info.objectType ~= "Texture" then return end
            if seen[object] or not Overlaps(object, rect) then return end

            -- Hidden regions, and art far larger than the panel, are noise.
            -- A first pass without these filters returned 154 regions, most of
            -- them full-screen backgrounds belonging to frames that were not
            -- even shown, and the one thing being looked for fell past the
            -- listing limit. A diagnostic that buries its answer is worse than
            -- none, because it looks like it answered.
            if not (object.IsShown and object:IsShown()) then return end
            local width, height = object:GetWidth() or 0, object:GetHeight() or 0
            if width > panelWidth * 2 and height > panelHeight * 2 then return end

            seen[object] = true
            table.insert(found, { region = object, info = info })
        end, { maxDepth = PROBE_DEPTH, includeRegions = true })
    end

    -- Top down, which is how the panel is read.
    table.sort(found, function(a, b)
        local aTop, bTop = a.region:GetTop() or 0, b.region:GetTop() or 0
        if aTop == bTop then return (a.region:GetLeft() or 0) < (b.region:GetLeft() or 0) end
        return aTop > bTop
    end)

    -- heroPanel's own regions are the majority and they are the least
    -- interesting: the panel is made of solid blocks, and the glyphs alone are
    -- dozens of them. Left in by default they would fill the listing before it
    -- reached whatever is being looked for. They are counted, not dropped, and
    -- "/hp probe all" puts them back for when the answer is "that is ours".
    local mine, shown = 0, 0
    ns.Print("  %.0f region(s) overlap the panel, from %.0f root(s), %.0f frame(s) visited%s",
        #found, #roots, visited, visited > PROBE_BUDGET and " |cFFFFAA00(budget hit)|r" or "")

    for i = 1, #found do
        local region = found[i].region
        local info   = found[i].info
        local owner  = info.parent
        local ours   = IsOurs(owner)

        if ours then mine = mine + 1 end

        if (includeOurs or not ours) and shown < PROBE_LIMIT then
            shown = shown + 1

            local layer = "?"
            local ok, drawLayer = pcall(region.GetDrawLayer, region)
            if ok and drawLayer then layer = tostring(drawLayer) end

            ns.Print("    %s d%.0f %s %s %s %s a%.2f top %.0f left %.0f %.0fx%.0f %s",
                ours and "|cFF9184D9ours|r" or "|cFFC2C6D8them|r",
                info.depth,
                tostring((owner and owner.GetName and owner:GetName()) or "unnamed"),
                info.objectType == "FontString" and "text" or "art ",
                layer,
                (region.IsShown and region:IsShown()) and "shown" or "|cFF8B8FA3hidden|r",
                (region.GetAlpha and region:GetAlpha()) or 1,
                region:GetTop() or 0, region:GetLeft() or 0,
                region:GetWidth() or 0, region:GetHeight() or 0,
                RegionSummary(region, info.objectType))
        end
    end

    local listable = includeOurs and #found or (#found - mine)
    if listable > shown then
        ns.Print("    ... and %.0f more", listable - shown)
    end
    if not includeOurs and mine > 0 then
        ns.Print("    %.0f of heroPanel's own region(s) not listed - |cFFC2C6D8/hp probe all|r to include them", mine)
    end
    if listable == 0 then
        ns.Print("    |cFFFFAA00nothing but heroPanel draws inside the panel|r")
    end
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
    if skin.enabled then UpdateHeader(ns.GetTrackerFrame("watch")) end
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
-- Anchoring the tracker's own children is protected, so the line pass skips it
-- in combat. This is how it catches up rather than waiting for a quest to
-- change.
ns:On("PLAYER_REGEN_ENABLED", function() Refresh("combat ended") end)
ns:On("QUEST_WATCH_UPDATE", function() Refresh("quest watch") end)
