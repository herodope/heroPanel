--[[--------------------------------------------------------------------------
    heroPanel - Plate.lua

    The panel chrome both trackers sit on: background plate, hairline border,
    the stepped approximation of a corner radius, and the contour that stands
    in for an ambient shadow.

    This started life inside Skin.lua and was pulled out when the Mythic+ panel
    needed the same treatment. Copying it would have meant two plates that are
    only identical until someone edits one of them, and "the same background,
    border and radius as the quest tracker" is a requirement rather than a
    coincidence - so there is one implementation and both callers use it.

    A plate is any frame. ns.BuildPlateChrome adds the textures; ns.StylePlateChrome
    paints and positions them from the current config. Neither knows anything
    about headers, rows or trackers: what goes *on* the plate belongs to the
    caller.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

-- Corner steps at the largest supported radius.
ns.MAX_NOTCH = 3

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

function ns.NotchFor(radius)
    radius = tonumber(radius) or 0
    return math.max(0, math.min(ns.MAX_NOTCH, math.floor(radius / 4 + 0.5)))
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function NewTexture(parent, layer)
    local texture = parent:CreateTexture(nil, layer or "ARTWORK")
    ns.SetTextureFile(texture, ns.SOLID)
    return texture
end
ns.NewPlateTexture = NewTexture

-- Adds the chrome to an existing frame. Safe to call once per plate; the
-- textures are kept on the frame itself so a caller can reach them if it has
-- to, but nothing outside this file is expected to.
function ns.BuildPlateChrome(plate)
    if not plate or plate.bg then return plate end

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
        for step = 1, ns.MAX_NOTCH do
            local pixel = NewTexture(plate, "BORDER")
            pixel:SetWidth(1)
            pixel:SetHeight(1)
            pixel:Hide()
            plate.corner[corner][step] = pixel
        end
    end

    return plate
end

--------------------------------------------------------------------------------
-- Painting
--
-- Reads the config and paints. Split from layout so a colour change from the
-- options panel does not have to re-measure anything.
--------------------------------------------------------------------------------

function ns.StylePlateChrome(plate)
    if not (plate and plate.bg) then return end

    local db     = ns.db
    local notch  = ns.NotchFor(db.radius)
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
        for step = 1, ns.MAX_NOTCH do
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
end

--------------------------------------------------------------------------------
-- Gradient bars
--
-- The design's bars are three-stop gradients and SetGradientAlpha takes two
-- stops, so a bar is drawn as two textures meeting at the middle stop. The
-- fill is sized by fraction rather than anchored to both ends, because a
-- partially filled bar has no right-hand anchor to use.
--
--     local bar = ns.NewGradientBar(parent, "BORDER")
--     bar:SetStops("#5D5294", "#9184D9", "#B5ABFC")   -- mid may be nil
--     bar:Layout(width, height, fraction)
--------------------------------------------------------------------------------

local barMethods = {}

function barMethods:SetStops(from, mid, to)
    self.from, self.mid, self.to = from, mid, to
end

-- fraction is clamped to 0..1. A bar at zero hides both halves rather than
-- drawing a one-pixel sliver, which is what a width of zero comes out as.
function barMethods:Layout(width, height, fraction)
    fraction = ns.Clamp(fraction or 0, 0, 1)
    local filled = width * fraction

    if filled <= 0 then
        self.left:Hide()
        self.right:Hide()
        return 0
    end

    local r1, g1, b1 = ns.HexToRGB(self.from)
    local r3, g3, b3 = ns.HexToRGB(self.to)
    local r2, g2, b2 = r3, g3, b3
    if self.mid then r2, g2, b2 = ns.HexToRGB(self.mid) end

    -- Two halves of the *filled* portion, so the gradient always runs its full
    -- range across whatever is drawn. Running it across the track instead would
    -- mean a nearly empty bar showed only the darkest stop.
    local half = filled / 2

    self.left:ClearAllPoints()
    self.left:SetPoint("TOPLEFT", self.track, "TOPLEFT", 0, 0)
    self.left:SetWidth(math.max(1, half))
    self.left:SetHeight(height)
    self.left:SetGradientAlpha("HORIZONTAL", r1, g1, b1, 1, r2, g2, b2, 1)
    self.left:Show()

    self.right:ClearAllPoints()
    self.right:SetPoint("TOPLEFT", self.left, "TOPRIGHT", 0, 0)
    self.right:SetWidth(math.max(1, filled - half))
    self.right:SetHeight(height)
    self.right:SetGradientAlpha("HORIZONTAL", r2, g2, b2, 1, r3, g3, b3, 1)
    self.right:Show()

    return filled
end

function ns.NewGradientBar(parent, layer)
    local bar = {
        track = ns.NewPlateTexture(parent, layer or "BORDER"),
        left  = ns.NewPlateTexture(parent, "ARTWORK"),
        right = ns.NewPlateTexture(parent, "ARTWORK"),
    }
    for name, fn in pairs(barMethods) do bar[name] = fn end
    return bar
end
