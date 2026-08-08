--[[--------------------------------------------------------------------------
    heroPanel - Lines.lua

    Text styling for the objective tracker, and the hover state that goes with
    it.

    The one rule this file exists to keep: the tracker's lines are pooled and
    laid out by the game, so heroPanel recolours and refonts them and does
    nothing else. No line is re-anchored, resized, reparented, shown or hidden,
    and no script is attached to one. In particular:

      * fonts are only ever made smaller, never larger. The tracker measures
        each line and places the next one before heroPanel sees it, so growing
        a line would wrap it into its neighbour - and fixing that would mean
        moving lines, which is exactly what must not happen here.
      * the objective counter is highlighted by wrapping it in a colour escape.
        Escape sequences draw nothing and measure nothing, so the line is the
        same width afterwards as the width the tracker laid out.
      * hover is a tint on heroPanel's own frames, sitting a frame level below
        the tracker. Nothing heroPanel draws can take a click away from a quest
        line, and nothing moves on hover.

    Everything changed here is remembered, so Restore() gives the player
    Blizzard's tracker back exactly as it was.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local lines = {}
ns.Lines = lines

--------------------------------------------------------------------------------
-- Layout constants
--------------------------------------------------------------------------------

local BLOCK_INSET   = 7    -- how far the hover tint extends left of the text
local BLOCK_PAD_TOP = 5
local BLOCK_PAD_BOT = 5
local BLOCK_RIGHT   = 8    -- gap between the tint and the panel's right edge
local STRIP_WIDTH   = 2    -- accent strip on the hovered block's left edge
local CHECK_SIZE    = 11
local DASH_MAX_W    = 16   -- widest a FontString can be and still be a dash

local TEX_CHECK = { "Interface\\Buttons\\UI-CheckBox-Check", "Interface\\RaidFrame\\ReadyCheck-Ready" }

--------------------------------------------------------------------------------
-- State
--
-- originals / decorated / dashAlpha are keyed by the tracker's own regions and
-- are what Restore() replays. They are never cleared while the skin is on: a
-- pooled line that is reused keeps the same original font, and re-reading it
-- after heroPanel has already styled it would record our own values as
-- Blizzard's.
--------------------------------------------------------------------------------

local originals = {}   -- FontString -> { path, size, flags, r, g, b, a }
local decorated = {}   -- FontString -> { raw, shown }
local dashAlpha = {}   -- FontString -> original alpha

local blocks    = {}   -- quest blocks built by the last Apply
local wrappers  = {}   -- pool of hover frames
local glyphs    = {}   -- pool of completed-objective check marks
local hovered

--------------------------------------------------------------------------------
-- Reading the tracker's lines
--------------------------------------------------------------------------------

local function IsFontString(object)
    return type(object) == "table"
       and type(object.GetObjectType) == "function"
       and object:GetObjectType() == "FontString"
end

-- A tracker line is a frame carrying a label FontString and, for objectives, a
-- leading dash. WatchFrame names them line.text / line.dash; when a client does
-- not, fall back to picking the widest string as the label and a narrow one
-- beside it as the dash.
local function ResolveLineStrings(frame)
    if IsFontString(frame.text) then
        return frame.text, IsFontString(frame.dash) and frame.dash or nil
    end

    local ok, regions = pcall(function() return { frame:GetRegions() } end)
    if not ok then return nil end

    local strings = {}
    for i = 1, #regions do
        local region = regions[i]
        if IsFontString(region) and region:IsShown() then
            local text = region:GetText()
            if text and text ~= "" then table.insert(strings, region) end
        end
    end
    if #strings == 0 then return nil end

    local label = strings[1]
    for i = 2, #strings do
        if (strings[i]:GetStringWidth() or 0) > (label:GetStringWidth() or 0) then
            label = strings[i]
        end
    end

    local dash
    for i = 1, #strings do
        local candidate = strings[i]
        if candidate ~= label and (candidate:GetStringWidth() or 0) <= DASH_MAX_W then
            dash = candidate
            break
        end
    end

    return label, dash
end

-- The text as Blizzard set it, with heroPanel's own counter highlight taken
-- back off so a second pass cannot decorate an already decorated string.
local function RawText(fontString)
    local current = fontString:GetText() or ""
    local record  = decorated[fontString]
    if record and record.shown == current then return record.raw end
    return current
end

local function Collect(watch)
    local found = {}

    ns.WalkFrameTree(watch, function(object, info)
        if not (object.IsShown and object:IsShown()) then return false end

        local label, dash = ResolveLineStrings(object)
        if label and label:IsShown() then
            local raw = RawText(label)
            local top = label:GetTop()
            if raw ~= "" and top then
                table.insert(found, {
                    frame = object,
                    label = label,
                    dash  = dash,
                    raw   = raw,
                    top   = top,
                    left  = label:GetLeft() or 0,
                })
            end
        end
    end, { maxDepth = 3, includeRegions = false })

    table.sort(found, function(a, b)
        if a.top == b.top then return a.left < b.left end
        return a.top > b.top
    end)

    return found
end

--------------------------------------------------------------------------------
-- Classification
--
-- Three signals, in order of how much they can be trusted:
--   1. a shown dash - the tracker only gives those to objective lines;
--   2. a "done/total" counter in the text;
--   3. indentation relative to the leftmost line, which is what a title is.
-- Any one of them makes a line an objective; a line with none is a quest title.
--------------------------------------------------------------------------------

local COUNTER = "(%d+)%s*/%s*(%d+)"

local function Classify(line, minLeft)
    local done, total = string.match(line.raw, COUNTER)
    local hasDash     = line.dash and line.dash:IsShown() and (line.dash:GetText() or "") ~= ""
    local indented    = line.left > minLeft + 3

    if not (hasDash or done or indented) then return "title" end

    if done then
        done, total = tonumber(done), tonumber(total)
        if total and total > 0 and done >= total then return "done" end
        return "counter"
    end

    return "text"
end

--------------------------------------------------------------------------------
-- Styling
--------------------------------------------------------------------------------

local function Remember(fontString)
    local original = originals[fontString]
    if original then return original end

    local path, size, flags = fontString:GetFont()
    local r, g, b, a = fontString:GetTextColor()
    original = { path = path, size = size, flags = flags, r = r, g = g, b = b, a = a }
    originals[fontString] = original
    return original
end

local function SetLineFont(fontString, wanted)
    local original = Remember(fontString)
    local path = ns.GetFontFile()
    if not path then return end

    local size = wanted
    if original.size and original.size > 0 and size > original.size then size = original.size end
    pcall(fontString.SetFont, fontString, path, size, original.flags)
end

local function ClearDecoration(fontString)
    local record = decorated[fontString]
    if not record then return end
    decorated[fontString] = nil
    if fontString:GetText() == record.shown then fontString:SetText(record.raw) end
end

-- Counters read as their own value, not as part of the sentence, so they get
-- the brighter colour. The design right-aligns them; that would mean giving the
-- number its own anchored region on a pooled line, so the colour carries the
-- distinction here and the alignment stays Blizzard's.
local function DecorateCounter(fontString, raw)
    local hex = string.gsub(ns.PALETTE.count, "^#", "")
    local text, replaced = string.gsub(raw, "(%d+%s*/%s*%d+)", "|cFF" .. hex .. "%1|r", 1)

    if replaced == 0 then
        ClearDecoration(fontString)
        return
    end

    decorated[fontString] = { raw = raw, shown = text }
    fontString:SetText(text)
end

local function FadeDash(dash)
    if not dash then return end
    if dashAlpha[dash] == nil then dashAlpha[dash] = dash:GetAlpha() or 1 end
    dash:SetAlpha(0)
end

local function ShowDash(dash, r, g, b)
    if not dash then return end
    if dashAlpha[dash] ~= nil then
        dash:SetAlpha(dashAlpha[dash])
        dashAlpha[dash] = nil
    end
    Remember(dash)
    dash:SetTextColor(r, g, b, 1)
end

--------------------------------------------------------------------------------
-- Check marks
--
-- A completed objective gets a leading check where its dash was. The dash is
-- faded rather than retexted, because its width is part of the line's layout.
--------------------------------------------------------------------------------

local function GetGlyph(index)
    local glyph = glyphs[index]
    if glyph then return glyph end

    local overlay = ns.Skin.GetOverlay()
    if not overlay then return nil end

    glyph = overlay:CreateTexture(nil, "ARTWORK")
    glyph:SetWidth(CHECK_SIZE)
    glyph:SetHeight(CHECK_SIZE)
    ns.SetTextureFile(glyph, TEX_CHECK[1], TEX_CHECK[2])
    glyphs[index] = glyph
    return glyph
end

local function PlaceGlyph(index, line, r, g, b)
    local glyph = GetGlyph(index)
    if not glyph then return end

    glyph:ClearAllPoints()
    if line.dash then
        glyph:SetPoint("CENTER", line.dash, "CENTER", 0, 0)
    else
        glyph:SetPoint("RIGHT", line.label, "LEFT", -2, 0)
    end
    glyph:SetVertexColor(r, g, b, 1)
    glyph:Show()
end

--------------------------------------------------------------------------------
-- Hover wrappers
--
-- One frame per quest block, carrying the 8% accent tint and the 2px accent
-- strip. They keep OnEnter / OnLeave scripts so the hover state lives where
-- you would expect it, but the mouse is deliberately left disabled and the
-- scripts are called by the skin's hover ticker instead: a mouse-enabled frame
-- here would sit on top of the tracker's clickable quest titles.
--------------------------------------------------------------------------------

local function GetWrapper(index)
    local wrapper = wrappers[index]
    if wrapper then return wrapper end

    local plate = ns.Skin.GetPlate()
    if not plate then return nil end

    wrapper = CreateFrame("Frame", nil, plate)
    wrapper:SetFrameLevel(plate:GetFrameLevel() + 1)
    wrapper:Hide()

    wrapper.tint = wrapper:CreateTexture(nil, "BACKGROUND")
    ns.SetTextureFile(wrapper.tint, ns.SOLID)
    wrapper.tint:SetAllPoints(wrapper)
    wrapper.tint:Hide()

    wrapper.strip = wrapper:CreateTexture(nil, "BORDER")
    ns.SetTextureFile(wrapper.strip, ns.SOLID)
    wrapper.strip:SetPoint("TOPLEFT", wrapper, "TOPLEFT", 0, 0)
    wrapper.strip:SetPoint("BOTTOMLEFT", wrapper, "BOTTOMLEFT", 0, 0)
    wrapper.strip:SetWidth(STRIP_WIDTH)
    wrapper.strip:Hide()

    wrapper:SetScript("OnEnter", function(self)
        self.tint:Show()
        self.strip:Show()
    end)
    wrapper:SetScript("OnLeave", function(self)
        self.tint:Hide()
        self.strip:Hide()
    end)

    wrappers[index] = wrapper
    return wrapper
end

local function LayoutWrapper(index, block)
    local plate = ns.Skin.GetPlate()
    local wrapper = GetWrapper(index)
    if not (plate and wrapper) then return nil end

    local first = block.lines[1].label
    local last  = block.lines[#block.lines].label

    local top, bottom = first:GetTop(), last:GetBottom()
    local left, right = first:GetLeft(), plate:GetRight()
    if not (top and bottom and left and right) then
        wrapper:Hide()
        return nil
    end

    local width  = right - left + BLOCK_INSET - BLOCK_RIGHT
    local height = top - bottom + BLOCK_PAD_TOP + BLOCK_PAD_BOT
    if width < 40 or height < 8 then
        wrapper:Hide()
        return nil
    end

    local ar, ag, ab = ns.HexToRGB(ns.PALETTE.accent)
    wrapper.tint:SetVertexColor(ar, ag, ab, ns.ALPHA.hoverTint)
    wrapper.strip:SetVertexColor(ar, ag, ab, 1)

    wrapper:ClearAllPoints()
    wrapper:SetPoint("TOPLEFT", first, "TOPLEFT", -BLOCK_INSET, BLOCK_PAD_TOP)
    wrapper:SetWidth(width)
    wrapper:SetHeight(height)
    wrapper:SetFrameLevel(plate:GetFrameLevel() + 1)
    wrapper:Show()

    return wrapper
end

--------------------------------------------------------------------------------
-- Apply
--
-- Called from the skin's coalesced refresh, never on a timer. Returns the
-- number of quest blocks found - which is what the header badge falls back to
-- when the client has no quest-watch API - and the bottom edge of the lowest
-- line, which is how the skin knows how tall the panel has to be.
--------------------------------------------------------------------------------

local function HideFrom(pool, first)
    for i = first, #pool do
        if pool[i] then pool[i]:Hide() end
    end
end

function lines.Apply(watch)
    watch = watch or ns.GetTrackerFrame("watch")
    if not watch or not ns.Skin.GetPlate() then return 0 end

    local db      = ns.db
    local found   = Collect(watch)
    local minLeft = nil
    for i = 1, #found do
        if not minLeft or found[i].left < minLeft then minLeft = found[i].left end
    end
    minLeft = minLeft or 0

    local titleSize = ns.GetFontSize(0.5)
    local lineSize  = ns.GetFontSize(-0.5)

    local tr, tg, tb = ns.HexToRGB(db.text.title)
    local nr, ng, nb = ns.HexToRGB(db.text.normal)
    local dr, dg, dbb = ns.HexToRGB(db.text.done)
    local mr, mg, mb = ns.HexToRGB(ns.PALETTE.muted)

    wipe(blocks)
    local glyphCount   = 0
    local contentBottom
    local current

    for i = 1, #found do
        local line = found[i]
        local kind = Classify(line, minLeft)
        local label = line.label
        Remember(label)

        local bottom = label:GetBottom()
        if bottom and (not contentBottom or bottom < contentBottom) then contentBottom = bottom end

        if kind == "title" then
            SetLineFont(label, titleSize)
            label:SetTextColor(tr, tg, tb, 1)
            ClearDecoration(label)

            current = { lines = { line } }
            table.insert(blocks, current)
        else
            SetLineFont(label, lineSize)

            if kind == "done" then
                label:SetTextColor(dr, dg, dbb, 1)
                ClearDecoration(label)
                FadeDash(line.dash)
                glyphCount = glyphCount + 1
                PlaceGlyph(glyphCount, line, dr, dg, dbb)
            else
                label:SetTextColor(nr, ng, nb, 1)
                ShowDash(line.dash, mr, mg, mb)
                if kind == "counter" then
                    DecorateCounter(label, line.raw)
                else
                    ClearDecoration(label)
                end
            end

            -- An objective before any title belongs to no block; it is still
            -- styled, it just does not get a hover region of its own.
            if current then table.insert(current.lines, line) end
        end
    end

    HideFrom(glyphs, glyphCount + 1)

    for i = 1, #blocks do
        blocks[i].wrapper = LayoutWrapper(i, blocks[i])
    end
    HideFrom(wrappers, #blocks + 1)

    -- A block the hover was sitting on may not exist any more.
    if hovered and not hovered.wrapper then hovered = nil end

    return #blocks, contentBottom
end

--------------------------------------------------------------------------------
-- Hover state
--------------------------------------------------------------------------------

local function CallScript(wrapper, script)
    if not wrapper then return end
    local fn = wrapper:GetScript(script)
    if fn then pcall(fn, wrapper) end
end

local function SetHovered(block)
    if block == hovered then return end
    if hovered then CallScript(hovered.wrapper, "OnLeave") end
    hovered = block
    if hovered then CallScript(hovered.wrapper, "OnEnter") end
end

function lines.UpdateHover()
    local target
    for i = 1, #blocks do
        local block = blocks[i]
        if block.wrapper and block.wrapper:IsVisible() and ns.MouseIsOver(block.wrapper) then
            target = block
            break
        end
    end
    SetHovered(target)
end

function lines.ClearHover()
    SetHovered(nil)
end

function lines.ClearBlocks()
    SetHovered(nil)
    wipe(blocks)
    HideFrom(wrappers, 1)
    HideFrom(glyphs, 1)
end

--------------------------------------------------------------------------------
-- Restore
--
-- Puts every line back the way the tracker had it. Blizzard would restore the
-- fonts and colours itself on its next update anyway, but not the counter
-- highlight, and "eventually" is not the same as "now".
--------------------------------------------------------------------------------

function lines.Restore()
    lines.ClearBlocks()

    for fontString, record in pairs(decorated) do
        if fontString:GetText() == record.shown then fontString:SetText(record.raw) end
    end
    wipe(decorated)

    for dash, alpha in pairs(dashAlpha) do
        pcall(dash.SetAlpha, dash, alpha)
    end
    wipe(dashAlpha)

    for fontString, original in pairs(originals) do
        if original.path and original.size then
            pcall(fontString.SetFont, fontString, original.path, original.size, original.flags)
        end
        if original.r then
            pcall(fontString.SetTextColor, fontString, original.r, original.g, original.b, original.a or 1)
        end
    end
    wipe(originals)
end
