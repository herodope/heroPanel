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
local COUNTER_RIGHT = 14   -- gap between the right-aligned count and the panel

-- The check is drawn from solids by ns.NewGlyph. Blizzard's tick textures are
-- yellow and green respectively, and the design wants the completed-objective
-- colour exactly - a tint multiplies, so coloured art cannot get there.

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
local moved     = {}   -- object -> { points, width, height } for art tucked back in

local blocks    = {}   -- quest blocks built by the last Apply
local wrappers  = {}   -- pool of hover frames
local glyphs    = {}   -- pool of completed-objective check marks
local counters  = {}   -- pool of right-aligned count FontStrings
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

-- Everything the tracker draws inside its own header band belongs to its
-- header, not to a quest. Without this test the header title comes back as a
-- quest line and Classify has no way to tell: it carries no dash, no counter,
-- and it sits at the tracker's left edge, which is precisely the shape of a
-- quest title. It would take a phantom quest block with it, colour the string
-- heroPanel is meant to be hiding, and - worse - set the leftmost edge that
-- every real line's indentation is judged against.
local function Collect(watch)
    local found      = {}
    local bandBottom = ns.Skin.HeaderBandBottom and ns.Skin.HeaderBandBottom(watch)

    ns.WalkFrameTree(watch, function(object, info)
        if not (object.IsShown and object:IsShown()) then return false end

        local label, dash = ResolveLineStrings(object)
        if label and label:IsShown() then
            local raw = RawText(label)
            local top = label:GetTop()
            if top and bandBottom and top >= bandBottom then return end

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

-- COUNTER captures the two halves, for deciding whether an objective is done.
-- COUNTER_TEXT matches the same thing as one piece, for when the counter is
-- wanted as it was written rather than as two numbers.
local COUNTER      = "(%d+)%s*/%s*(%d+)"
local COUNTER_TEXT = "%d+%s*/%s*%d+"

-- A dash counts only when it is shown *and* has something in it. The tracker
-- keeps an empty dash FontString on lines that do not have one, so testing
-- IsShown alone calls every line an objective.
local function HasDash(line)
    return (line.dash and line.dash:IsShown() and (line.dash:GetText() or "") ~= "") and true or false
end

local function Classify(line, minLeft)
    local done, total = string.match(line.raw, COUNTER)
    local hasDash     = HasDash(line)
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

-- How far a line may grow past the size the tracker laid it out at.
--
-- Lines used to be clamped to the tracker's own size and never allowed to grow
-- at all. The reason still holds - the tracker measures each line and places
-- the next one before heroPanel sees it, so a bigger font cannot ask for more
-- room - but the clamp also meant the objective size, half a point under the
-- base, could only ever come out *smaller* than Blizzard's. The skin was making
-- its own text harder to read than the text it replaced.
--
-- So growth is allowed, and bounded. This client lays lines out on a 14px pitch
-- with a 12px font, so a couple of points fits in the gap the tracker already
-- left; open-ended growth would run lines into each other, and no amount of
-- configuration should be able to do that.
local FONT_GROW_MAX = 2

local function SetLineFont(fontString, wanted)
    local original = Remember(fontString)
    local path = ns.GetFontFile()
    if not path then return end

    local size = wanted
    if original.size and original.size > 0 then
        local ceiling = original.size + FONT_GROW_MAX
        if size > ceiling then size = ceiling end
    end
    pcall(fontString.SetFont, fontString, path, size, original.flags)
end

local function ClearDecoration(fontString)
    local record = decorated[fontString]
    if not record then return end
    decorated[fontString] = nil
    if fontString:GetText() == record.shown then fontString:SetText(record.raw) end
end

-- The inline highlight: the count keeps its place in the sentence and only
-- takes the brighter colour. This is the fallback now that the count gets its
-- own right-aligned region, for when there is no panel to align it against.
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

-- Art the tracker hangs off a quest line: the turn-in question mark and its
-- icon border, and whatever else a given build puts there.
--
-- It is anchored to the line's own text, so it sits wherever the title's length
-- puts it - which is outside the panel, because the panel's left edge is inset
-- from the tracker's and the icon hangs off the *left* of the text. Fading it
-- was the first answer and it was the wrong one twice over: it loses a cue the
-- player wants, and it did not even work, because on this client the icon is
-- one level further out than a scan of the line's own regions reaches.
--
-- So it is moved back inside instead, against the panel's right edge on its own
-- row. Both possibilities are covered without naming either - the line's own
-- Textures and the frames the line parents - and the test is geometric: only
-- something icon-sized that is actually sticking out gets touched, and
-- something already inside is left exactly where the tracker put it.
--
-- Every original anchor and size is remembered, so Restore puts it all back.
local ICON_MAX   = 40   -- biggest a thing can be and still be treated as an icon
-- Gap between a tucked icon and the panel's inner edge, and the margin the
-- containment test allows. Measuring and tucking against the same figure is
-- what keeps a tucked icon settled: it lands just inside the boundary, so the
-- next pass reads it as already inside and leaves it alone.
local ICON_MARGIN = 4

local function SaveGeometry(object)
    if moved[object] then return true end

    local ok, count = pcall(object.GetNumPoints, object)
    if not ok or not count or count == 0 then return false end

    local points = {}
    for i = 1, count do
        local point, relTo, relPoint, x, y = object:GetPoint(i)
        if not point then return false end
        points[i] = { point, relTo, relPoint, x, y }
    end

    moved[object] = {
        points = points,
        width  = object:GetWidth(),
        height = object:GetHeight(),
    }
    return true
end

-- Why an object was or was not tucked, as one word.
--
-- Split out from the move itself so /hp dump can report the same decision the
-- skin actually took. Three attempts at this icon were wrong about where it
-- lived, and each one looked from the outside exactly like the one before -
-- nothing moved. A verdict per candidate says which test rejected it instead
-- of leaving that to be guessed at again.
-- Everything here is compared in screen pixels, never in UI units.
--
-- The tracker's line container carries a scale of its own, so a quest POI
-- button sits at effective 0.64 while the panel is at 0.71. Comparing their
-- GetLeft values directly compares two different coordinate spaces: the button
-- read as 1741 against a panel spanning 1582..1916 and was called "already
-- inside", while on screen it was ten pixels off the panel's left edge. Two
-- numbers being in the same units is not something to assume.
--
-- Regions report an effective scale of 1 whatever their parent does, so they
-- take the scale of the frame that draws them.
local function EffectiveScale(object)
    local objectType = object.GetObjectType and object:GetObjectType()
    if objectType ~= "Texture" and objectType ~= "FontString" then
        return (object.GetEffectiveScale and object:GetEffectiveScale()) or 1
    end
    local parent = object.GetParent and object:GetParent()
    return (parent and parent.GetEffectiveScale and parent:GetEffectiveScale()) or 1
end

local function ScreenRect(object)
    local scale = EffectiveScale(object)
    if not scale or scale <= 0 then return nil end

    local left, right = object:GetLeft(), object:GetRight()
    local top, bottom = object:GetTop(), object:GetBottom()
    if not (left and right and top and bottom) then return nil end

    return left * scale, right * scale, top * scale, bottom * scale, scale
end

local function TuckVerdict(object, plate)
    if not object then return "missing" end

    -- Drawn, not merely shown. IsShown reports an object's own flag and says
    -- nothing about its parents, so a region inside a hidden frame reads as
    -- shown while nothing of it reaches the screen. Believing it moved a
    -- tracker icon that was never visible in the first place.
    if object.IsVisible then
        if not object:IsVisible() then return "not drawn" end
    elseif object.IsShown then
        if not object:IsShown() then return "not drawn" end
    else
        return "no geometry"
    end

    if not object.GetLeft then return "no geometry" end

    local left, right, top, bottom, scale = ScreenRect(object)
    local panelLeft, panelRight, panelTop, _, panelScale = ScreenRect(plate)
    if not (left and panelLeft) then return "unmeasured" end

    -- Sizes in the object's own units, which is what ICON_MAX is written in.
    local width  = (right - left) / scale
    local height = (top - bottom) / scale
    if width <= 0 or height <= 0 then return "empty" end
    if width > ICON_MAX or height > ICON_MAX then
        return string.format("too big %.0fx%.0f", width, height)
    end

    local margin = ICON_MARGIN * panelScale
    if left >= panelLeft + margin and right <= panelRight - margin then
        return "already inside"
    end

    return "outside", left, top, width, height, scale, panelLeft, panelRight, panelTop, panelScale
end

local function TuckIntoPanel(object, plate)
    local verdict, _, top, width, height, scale,
          panelLeft, _, panelTop, panelScale = TuckVerdict(object, plate)
    if verdict ~= "outside" then return verdict end
    if not SaveGeometry(object) then return "no anchor to restore" end

    -- Size before anchors. Something anchored by two corners loses its size the
    -- moment its points are cleared, and this is about to be given one anchor.
    pcall(object.SetWidth, object, width)
    pcall(object.SetHeight, object, height)

    -- Into the panel's left margin, beside the quest title rather than away
    -- across the panel from it. That margin exists for this: the tracker's
    -- titles start flush against the content edge, so PAD_LEFT is widened to
    -- make room here.
    --
    -- SetPoint offsets are read in the object's own scale while the anchor it
    -- is measured from is the panel's, so both sides are worked out in screen
    -- pixels and only converted back at the end.
    local targetLeft = panelLeft + ICON_MARGIN * panelScale
    object:ClearAllPoints()
    object:SetPoint("TOPLEFT", plate, "TOPLEFT",
        (targetLeft - panelLeft) / scale,
        (top - panelTop) / scale)
    return "moved"
end

-- Walks the tracker's whole subtree rather than named levels of it.
--
-- Two narrower versions of this missed the icon twice. It is not a region of
-- the quest line, and it is not a child of the tracker either: on this client
-- it is a quest POI button - poiWatchFrameLines<n>_<n> - parented to the line
-- container, so it sits a level below both places that were being searched.
-- Guessing which level a given build keeps it at is how this went wrong, so
-- the walk covers the subtree and lets the geometry decide.
--
-- FontStrings are never moved: the tracker's text belongs where the tracker
-- put it, and this is only ever about art that has been anchored out of frame.
local TUCK_DEPTH = 3

local function TuckStrayArt(watch)
    local plate = ns.Skin.GetPlate()
    if not (watch and plate) then return end

    -- Anchoring a child of the tracker is a protected call. Out of combat only;
    -- the skin refreshes when combat ends, so it catches up on its own.
    if InCombatLockdown() then return end

    ns.WalkFrameTree(watch, function(object, info)
        if info.objectType == "FontString" then return end
        TuckIntoPanel(object, plate)
    end, { maxDepth = TUCK_DEPTH, includeRegions = true })
end

-- What the tuck walk saw, and what it decided about each thing it saw.
local TUCK_DUMP_LIMIT = 26

function lines.DumpTuck()
    local watch = ns.GetTrackerFrame("watch")
    local plate = ns.Skin.GetPlate()
    if not (watch and plate) then return end

    ns.Print("  tuck walk (depth %.0f, panel %.0f..%.0f):",
        TUCK_DEPTH, plate:GetLeft() or 0, plate:GetRight() or 0)

    local count, listed = 0, 0
    ns.WalkFrameTree(watch, function(object, info)
        if info.objectType == "FontString" then return end
        count = count + 1

        local verdict = TuckVerdict(object, plate)
        local name = (object.GetName and object:GetName()) or nil

        -- Anything named, and anything heroPanel has moved, is always listed.
        -- Filtering on the verdict alone suppressed exactly the object whose
        -- verdict was wanted: a named frame that came back "already inside" or
        -- "hidden" is the interesting case, because it is the one that explains
        -- why nothing happened. Only unnamed clutter is dropped.
        if moved[object] then
            verdict = "|cFF79C68Dtucked|r, now " .. verdict
        elseif not name and (verdict == "already inside" or verdict == "not drawn") then
            return
        end
        if listed >= TUCK_DUMP_LIMIT then return end
        listed = listed + 1

        ns.Print("    d%.0f %s %s %.0fx%.0f at %.0f..%.0f: |cFFC2C6D8%s|r",
            info.depth,
            tostring(name or "unnamed"),
            tostring(info.objectType),
            object.GetWidth and object:GetWidth() or 0,
            object.GetHeight and object:GetHeight() or 0,
            (object.GetLeft and object:GetLeft()) or 0,
            (object.GetRight and object:GetRight()) or 0,
            tostring(verdict))
    end, { maxDepth = TUCK_DEPTH, includeRegions = true })

    ns.Print("    %.0f object(s) visited, %.0f interesting, %.0f currently moved",
        count, listed, (function() local n = 0 for _ in pairs(moved) do n = n + 1 end return n end)())
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
-- Right-aligned counts
--
-- The design puts the count against the panel's right edge, away from the
-- label. It arrives inside the line's single FontString, and on this client as
-- a *prefix* - "0/1 General Drakkisath slain" - so there is no way to align it
-- without taking it out of that string and drawing it in a region of our own.
--
-- Doing that stays inside the rule this file exists to keep. No line is moved,
-- resized or reparented; one string gets shorter. That direction is the safe
-- one: the tracker measured and placed the line at its full length, so a
-- shorter string cannot wrap into its neighbour, and it is remembered like any
-- other decoration so Restore puts the whole sentence back.
--
-- If there is no panel to align against, the count keeps its place in the
-- sentence and only takes the brighter colour, which is what the skin did
-- before. Losing the alignment is a worse outcome than losing the count.
--------------------------------------------------------------------------------

local function SplitCounter(raw)
    local count = string.match(raw, COUNTER_TEXT)
    if not count then return nil, nil end

    local label = string.gsub(raw, COUNTER_TEXT, "", 1)
    label = string.gsub(label, "^%s*[%-:]?%s*", "")   -- separator the count left behind
    label = string.gsub(label, "%s*[%-:]%s*$", "")
    label = string.gsub(label, "^%s+", "")
    label = string.gsub(label, "%s+$", "")

    -- A line that is nothing but a count has no label to right-align away
    -- from, and blanking it would lose the objective entirely.
    if label == "" then return nil, nil end
    return label, count
end

local function GetCounter(index)
    local counter = counters[index]
    if counter then return counter end

    local overlay = ns.Skin.GetOverlay()
    if not overlay then return nil end

    counter = overlay:CreateFontString(nil, "OVERLAY")
    counters[index] = counter
    return counter
end

-- Returns the number of counters placed so far, so the caller can pool them.
local function StyleCounter(placed, line, fontString, r, g, b)
    local label, count = SplitCounter(line.raw)
    if not label then
        ClearDecoration(fontString)
        return placed
    end

    local plate    = ns.Skin.GetPlate()
    local counter  = GetCounter(placed + 1)
    local lineTop  = fontString:GetTop()
    local plateTop = plate and plate:GetTop()

    if not (counter and plate and lineTop and plateTop) then
        DecorateCounter(fontString, line.raw)
        return placed
    end

    decorated[fontString] = { raw = line.raw, shown = label }
    fontString:SetText(label)

    counter:SetFont(ns.GetFontFile(), ns.GetFontSize(-0.5))
    counter:SetText(count)
    counter:SetTextColor(r, g, b, 1)

    -- The plate and the tracker share a scale chain, so the line's measured top
    -- is usable directly as an offset on our own frame.
    counter:ClearAllPoints()
    counter:SetPoint("TOPRIGHT", plate, "TOPRIGHT", -COUNTER_RIGHT, lineTop - plateTop)
    counter:Show()

    return placed + 1
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

    glyph = ns.NewGlyph(overlay, CHECK_SIZE)
    glyph:SetShape("check")
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
    glyph:SetColor(r, g, b, 1)
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

    local cr, cg, cb = ns.HexToRGB(ns.PALETTE.count)

    wipe(blocks)
    local glyphCount   = 0
    local counterCount = 0
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
                FadeDash(line.dash)
                glyphCount = glyphCount + 1
                PlaceGlyph(glyphCount, line, dr, dg, dbb)
                -- A completed count reads in the done colour, not the count
                -- highlight: the whole line is the thing that is finished.
                counterCount = StyleCounter(counterCount, line, label, dr, dg, dbb)
            else
                label:SetTextColor(nr, ng, nb, 1)
                ShowDash(line.dash, mr, mg, mb)
                if kind == "counter" then
                    counterCount = StyleCounter(counterCount, line, label, cr, cg, cb)
                else
                    ClearDecoration(label)
                end
            end

            -- An objective before any title belongs to no block; it is still
            -- styled, it just does not get a hover region of its own.
            if current then table.insert(current.lines, line) end
        end
    end

    -- Once, over the whole subtree, after the lines have been placed. The size
    -- test is what keeps this off everything else the tracker owns: its line
    -- container and background art are far larger than an icon, and its
    -- collapse button is already inside the panel.
    TuckStrayArt(watch)

    HideFrom(glyphs, glyphCount + 1)
    HideFrom(counters, counterCount + 1)

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
    HideFrom(counters, 1)
end

--------------------------------------------------------------------------------
-- Dump
--
-- What the walk resolved, and when it resolved nothing, what it actually
-- visited. The second half is the interesting one: a tracker whose lines are
-- hidden or live somewhere else looks, from the outside, exactly like a walk
-- that is broken.
--------------------------------------------------------------------------------

local DUMP_LIMIT = 24

function lines.Dump()
    local watch = ns.GetTrackerFrame("watch")
    if not watch then return end

    local found = Collect(watch)
    local minLeft
    for i = 1, #found do
        if not minLeft or found[i].left < minLeft then minLeft = found[i].left end
    end
    minLeft = minLeft or 0

    lines.DumpTuck()

    ns.Print("  walk resolved %.0f line(s)%s", #found, #found > 0 and ":" or "")
    for i = 1, math.min(#found, DUMP_LIMIT) do
        local line = found[i]
        -- The dash column has to answer the same question Classify asks, or a
        -- line reported as "dash yes" but classified as a title reads as a bug
        -- in the classifier when it is an empty dash FontString.
        ns.Print("    %.0f |cFFC2C6D8%s|r top %.0f left %.0f dash %s: %s",
            i, Classify(line, minLeft), line.top, line.left,
            HasDash(line) and "yes" or "no",
            string.sub(line.raw, 1, 42))
    end

    if #found > 0 then return end

    ns.Print("  |cFFFFAA00nothing resolved|r - frames the walk visited:")
    local count = 0
    ns.WalkFrameTree(watch, function(object, info)
        count = count + 1
        if count > DUMP_LIMIT then return false end

        local shown, empty = 0, 0
        local ok, regions = pcall(function() return { object:GetRegions() } end)
        if ok then
            for r = 1, #regions do
                local region = regions[r]
                if region.GetObjectType and region:GetObjectType() == "FontString" then
                    if region:IsShown() and (region:GetText() or "") ~= "" then
                        shown = shown + 1
                    else
                        empty = empty + 1
                    end
                end
            end
        end

        ns.Print("    d%.0f %s %s - %.0f text, %.0f empty",
            info.depth,
            tostring((object.GetName and object:GetName()) or "unnamed"),
            (object.IsShown and object:IsShown()) and "shown" or "|cFFFFAA00hidden|r",
            shown, empty)
    end, { maxDepth = 3, includeRegions = false })

    if count == 0 then ns.Print("    |cFFFFAA00the tracker has no child frames at all|r") end
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

    -- Anchors and sizes of anything tucked back inside the panel. Skipped in
    -- combat rather than forced: these are the tracker's own children.
    if not InCombatLockdown() then
        for object, saved in pairs(moved) do
            pcall(function()
                object:ClearAllPoints()
                if saved.width  then object:SetWidth(saved.width) end
                if saved.height then object:SetHeight(saved.height) end
                for i = 1, #saved.points do
                    local point = saved.points[i]
                    object:SetPoint(point[1], point[2], point[3], point[4], point[5])
                end
            end)
        end
        wipe(moved)
    end

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
