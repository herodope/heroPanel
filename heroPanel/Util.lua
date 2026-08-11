--[[--------------------------------------------------------------------------
    heroPanel - Util.lua

    Shared helpers: timers, combat-safe deferral, script hooking, colour
    parsing, and the throttled frame-tree scanner that later phases reuse for
    line styling and chest-tier maths.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- Timers
--
-- C_Timer.After exists on some 3.3.5a-derived clients and not on others, so
-- ns.After uses it when present and falls back to an OnUpdate queue otherwise.
-- Everything in the addon calls ns.After, never C_Timer directly.
--------------------------------------------------------------------------------

local pending = {}
local timerFrame

local function TimerOnUpdate(_, elapsed)
    local count = #pending
    if count == 0 then
        timerFrame:Hide()
        return
    end
    for i = count, 1, -1 do
        local entry = pending[i]
        entry.remaining = entry.remaining - elapsed
        if entry.remaining <= 0 then
            table.remove(pending, i)
            local ok, err = pcall(entry.fn)
            if not ok then ns.ReportError("timer", err) end
        end
    end
    if #pending == 0 then timerFrame:Hide() end
end

function ns.After(delay, fn)
    if type(fn) ~= "function" then return end
    delay = tonumber(delay) or 0

    -- Wrapped on both routes, so a fault in a deferred call is reported the same
    -- way whether or not the client has C_Timer. Most of the skin runs from
    -- here, and an unwrapped error would only reach the client's error handler,
    -- which is off by default on 3.3.5a.
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, function()
            local ok, err = pcall(fn)
            if not ok then ns.ReportError("timer", err) end
        end)
        return
    end

    if not timerFrame then
        timerFrame = CreateFrame("Frame", "HeroPanelTimerFrame")
        timerFrame:Hide()
        timerFrame:SetScript("OnUpdate", TimerOnUpdate)
    end
    table.insert(pending, { remaining = delay, fn = fn })
    timerFrame:Show()
end

--------------------------------------------------------------------------------
-- Combat-safe deferral
--
-- WatchFrame and its children are protected. SetPoint / Show / Hide /
-- SetMovable / SetScale / EnableMouse on a protected frame throw during
-- combat lockdown, so anything touching those goes through ns.RunWhenSafe.
--------------------------------------------------------------------------------

local combatQueue = {}

function ns.RunWhenSafe(fn, tag)
    if type(fn) ~= "function" then return end
    if not InCombatLockdown() then
        local ok, err = pcall(fn)
        if not ok then ns.ReportError("deferred call " .. tostring(tag), err) end
        return true
    end
    table.insert(combatQueue, { fn = fn, tag = tag })
    ns.Debug("deferred until combat ends: %s", tostring(tag or "unnamed"))
    return false
end

ns:On("PLAYER_REGEN_ENABLED", function()
    if #combatQueue == 0 then return end
    local queued = combatQueue
    combatQueue = {}
    ns.Debug("combat over, flushing %d deferred call(s).", #queued)
    for i = 1, #queued do
        local ok, err = pcall(queued[i].fn)
        if not ok then ns.ReportError("deferred call " .. tostring(queued[i].tag), err) end
    end
end)

--------------------------------------------------------------------------------
-- Script hooking
--
-- Never overwrite a script that already exists. HookScript when there is
-- something to hook, SetScript only when the slot is genuinely empty.
--------------------------------------------------------------------------------

-- Returns "hook" when an existing handler was extended, "set" when the slot was
-- empty, or false when the script could not be attached. The distinction
-- matters: a handler that was already there runs *before* ours and may have
-- moved the frame under us.
function ns.HookScript(frame, script, fn)
    if not frame or type(frame.GetScript) ~= "function" then return false end
    local ok, existing = pcall(frame.GetScript, frame, script)
    if not ok then return false end
    if existing then
        frame:HookScript(script, fn)
        return "hook"
    end
    frame:SetScript(script, fn)
    return "set"
end

--------------------------------------------------------------------------------
-- Throttled tickers
--
-- Same idea as the tree scanner below, for work that is not a tree walk: one
-- shared OnUpdate drives every active ticker off its own accumulator. Used by
-- the skin's hover watcher, which has to sample the cursor but must not do so
-- once per frame.
--------------------------------------------------------------------------------

local TICK_MIN_INTERVAL = 0.05

local activeTickers = {}
local tickDriver

local function TickDriverOnUpdate(_, elapsed)
    local anyActive = false
    for ticker in pairs(activeTickers) do
        anyActive = true
        ticker.accumulator = ticker.accumulator + elapsed
        if ticker.accumulator >= ticker.interval then
            ticker.accumulator = 0
            local ok, err = pcall(ticker.fn)
            if not ok then ns.ReportError("ticker", err) end
        end
    end
    if not anyActive then tickDriver:Hide() end
end

local tickerMethods = {}
local tickerMeta = { __index = tickerMethods }

function tickerMethods:Start()
    activeTickers[self] = true
    self.accumulator = self.interval
    tickDriver:Show()
    return self
end

function tickerMethods:Stop()
    activeTickers[self] = nil
    return self
end

function tickerMethods:IsRunning()
    return activeTickers[self] and true or false
end

function ns.NewTicker(interval, fn)
    if type(fn) ~= "function" then return nil end

    if not tickDriver then
        tickDriver = CreateFrame("Frame", "HeroPanelTickDriver")
        tickDriver:Hide()
        tickDriver:SetScript("OnUpdate", TickDriverOnUpdate)
    end

    return setmetatable({
        fn          = fn,
        interval    = math.max(tonumber(interval) or TICK_MIN_INTERVAL, TICK_MIN_INTERVAL),
        accumulator = 0,
    }, tickerMeta)
end

--------------------------------------------------------------------------------
-- Cursor hit testing
--
-- MouseIsOver is pure geometry - it does not need the frame to have the mouse
-- enabled, which is exactly what the skin's hover state wants: tinting a quest
-- block must never put a mouse-catching frame over Blizzard's clickable quest
-- lines. It is a FrameXML function rather than an API one, so fall back to the
-- same maths if a client does not ship it.
--------------------------------------------------------------------------------

function ns.MouseIsOver(frame)
    if not frame or not frame.GetLeft then return false end

    if type(_G.MouseIsOver) == "function" then
        local ok, result = pcall(_G.MouseIsOver, frame)
        if ok then return result and true or false end
    end

    local scale = frame:GetEffectiveScale()
    if not scale or scale == 0 then return false end

    local left, right   = frame:GetLeft(), frame:GetRight()
    local top, bottom   = frame:GetTop(), frame:GetBottom()
    if not (left and right and top and bottom) then return false end

    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale
    return x >= left and x <= right and y >= bottom and y <= top
end

--------------------------------------------------------------------------------
-- Texture files
--
-- heroPanel ships no art, so every glyph is a client texture. Which ones exist
-- varies between 3.3.5a builds, so paths are given as a candidate list and the
-- first one that loads wins.
--
-- Texture:SetTexture reports success on most clients of this vintage but not
-- all. Probe once against a texture that is certainly present: if the client
-- answers meaningfully, trust the return value; if it always answers nil,
-- believing it would reject every path, so take the first candidate on faith.
--------------------------------------------------------------------------------

ns.SOLID = "Interface\\Buttons\\WHITE8X8"

local reportsTextureResult

local function ClientReportsTextureResult()
    if reportsTextureResult == nil then
        local probeFrame = CreateFrame("Frame")
        local probe      = probeFrame:CreateTexture()
        reportsTextureResult = (probe:SetTexture(ns.SOLID) and true) or false
        probeFrame:Hide()
        ns.Debug("client %s texture load results.",
            reportsTextureResult and "reports" or "does not report")
    end
    return reportsTextureResult
end

-- ns.SetTextureFile(texture, "path", "fallback path", ...) -> path used
function ns.SetTextureFile(texture, ...)
    if not texture then return nil end
    local checked = ClientReportsTextureResult()

    for i = 1, select("#", ...) do
        local path = select(i, ...)
        if path then
            local ok, loaded = pcall(texture.SetTexture, texture, path)
            if ok and (loaded or not checked) then return path end
        end
    end

    pcall(texture.SetTexture, texture, ns.SOLID)
    return ns.SOLID
end

--------------------------------------------------------------------------------
-- Glyphs
--
-- heroPanel ships no art and the design fixes exact glyph colours, and client
-- textures cannot satisfy both. SetVertexColor multiplies: Blizzard's gold
-- padlock tinted #75798C comes out muted gold, not #75798C, which is why the
-- header's lock and caret read as gold squares however they were tinted.
-- Nothing in the client's icon set is neutral enough to tint cleanly, and which
-- paths exist varies between 3.3.5a builds anyway.
--
-- So glyphs are drawn from WHITE8X8 blocks on a small cell grid - the same
-- approximation the panel's chamfered corners use. White tints exactly, the
-- shapes stay crisp at the sizes the header needs, and there is no art to ship
-- and none to miss.
--
--     local glyph = ns.NewGlyph(parent, 12)
--     glyph:SetShape("caretDown")
--     glyph:SetColor(ns.HexToRGB("#75798C"))
--------------------------------------------------------------------------------

-- The shipped art, one 64x64 white alpha mask per shape, generated by
-- tools/glyphgen as both BLP and TGA. White tints exactly, so SetVertexColor
-- lands on the design's colour rather than multiplying into it, and the
-- client's own filtering keeps the shape smooth at the size the header needs.
-- The blocks below stay as the fallback for a client that reads neither, so
-- an unreadable file costs quality and not the glyph.
local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\media\\"

ns.GLYPH_ART = {
    caretUp   = { file = "caret" },
    caretDown = { file = "caret", flip = true },   -- the same chevron, flipped
    check     = { file = "check" },
    locked    = { file = "lock-closed" },
    unlocked  = { file = "lock-open" },

    -- The Mythic+ shapes. These were block glyphs first and read as exactly
    -- what the block note above warns about: a stopwatch and a crosshair are
    -- mostly circle, and a circle made of 2px blocks at 12 device pixels is a
    -- staircase. Rasterised as anti-aliased strokes they carry at that size.
    timer     = { file = "timer" },
    crosshair = { file = "crosshair" },
    ring      = { file = "ring" },
    ringDot   = { file = "ring-dot" },
}

-- Each shape is a list of cells: { column, row, columnSpan, rowSpan }, spans
-- defaulting to 1, row 0 at the top. The grid is only as wide and as tall as
-- the cells used and is scaled to fit whatever size the glyph is given, so a
-- shape is written once at whatever proportions read best.
ns.GLYPHS = {
    -- Chevrons on a 14 x 8 grid. The grid is fine on purpose: at header sizes
    -- the unit lands on about a pixel, so the arms read as crisp diagonals.
    -- A coarser grid - these were six cells across - gives blocks two or three
    -- pixels square, and a chevron made of those reads as Lego rather than as
    -- a stroke. Each cell is two rows tall to keep the arms from going faint.
    caretUp   = { {0,6,1,2}, {1,5,1,2}, {2,4,1,2}, {3,3,1,2}, {4,2,1,2}, {5,1,1,2}, {6,0,1,2},
                  {13,6,1,2}, {12,5,1,2}, {11,4,1,2}, {10,3,1,2}, {9,2,1,2}, {8,1,1,2}, {7,0,1,2} },
    caretDown = { {0,0,1,2}, {1,1,1,2}, {2,2,1,2}, {3,3,1,2}, {4,4,1,2}, {5,5,1,2}, {6,6,1,2},
                  {13,0,1,2}, {12,1,1,2}, {11,2,1,2}, {10,3,1,2}, {9,4,1,2}, {8,5,1,2}, {7,6,1,2} },

    -- Resize grip: a triangle of dots stepping into the bottom-right corner,
    -- which is the shape every window corner in every toolkit has used for
    -- thirty years and so needs no label. Dots rather than three diagonal
    -- strokes, because at 12px a stroke made of blocks is a staircase - see the
    -- note above the Mythic+ shapes.
    grip      = { {6,0},
                  {4,2}, {6,2},
                  {2,4}, {4,4}, {6,4},
                  {0,6}, {2,6}, {4,6}, {6,6} },

    -- Tick on a 16 x 12 grid: a short arm down and a long arm up, which is
    -- what separates a check from a V.
    check     = { {0,5,1,2}, {1,6,1,2}, {2,7,1,2}, {3,8,1,2}, {4,9,1,2}, {5,10,1,2},
                  {6,9,1,2}, {7,8,1,2}, {8,7,1,2}, {9,6,1,2}, {10,5,1,2},
                  {11,4,1,2}, {12,3,1,2}, {13,2,1,2}, {14,1,1,2}, {15,0,1,2} },

    -- Padlock: a shackle over a solid body. Unlocked opens the shackle's left
    -- side rather than drawing a different padlock, so the two states read as
    -- the same object.
    locked    = { {1,0,4,1}, {1,1}, {4,1}, {1,2}, {4,2}, {0,3,6,4} },
    unlocked  = { {1,0,4,1},         {4,1},        {4,2}, {0,3,6,4} },

    -- The Mythic+ panel's shapes. All circles, all on an 8x8 or 10x10 grid:
    -- a circle made of blocks needs its widest rows to be several cells long
    -- or it reads as a diamond, which is why the rows step 4-6-8 rather than
    -- 2-4-6-8.

    -- A hollow circle, one cell thick, which lands on about 1.5px at the 14px
    -- the boss rows use.
    ring      = { {2,0,4,1},
                  {1,1}, {6,1},
                  {0,2}, {7,2},
                  {0,3}, {7,3},
                  {0,4}, {7,4},
                  {0,5}, {7,5},
                  {1,6}, {6,6},
                  {2,7,4,1} },

    -- The ring with its centre filled: the boss currently being fought.
    ringDot   = { {2,0,4,1},
                  {1,1}, {6,1},
                  {0,2}, {7,2},
                  {0,3}, {3,3,2,2}, {7,3},
                  {0,4}, {7,4},
                  {0,5}, {7,5},
                  {1,6}, {6,6},
                  {2,7,4,1} },

    -- Stopwatch: a stem, a hollow body and a hand. The stem is what stops it
    -- reading as a plain ring next to the crosshair below.
    timer     = { {4,0,2,1},
                  {3,2,4,1},
                  {2,3}, {7,3},
                  {1,4}, {8,4},
                  {1,5}, {8,5},
                  {1,6}, {8,6},
                  {1,7}, {8,7},
                  {2,8}, {7,8},
                  {3,9,4,1},
                  {4,5,1,2} },

    -- Crosshair: a ring with four arms and a centre pip.
    crosshair = { {4,0,2,1},
                  {3,1,4,1},
                  {2,2}, {7,2},
                  {1,3}, {8,3},
                  {0,4,1,2}, {1,4}, {8,4}, {9,4,1,2},
                  {1,5}, {8,5},
                  {4,4,2,2},
                  {1,6}, {8,6},
                  {2,7}, {7,7},
                  {3,8,4,1},
                  {4,9,2,1} },
}

-- Glyph modes that pin one file rather than letting the chain choose. Two
-- different files can fail the same way on screen - a green square is what this
-- client draws for anything it resolves and then declines to decode - so
-- "which file is on screen" has to be answerable directly.
local FORCED_EXTENSION = {
    art = ".tga",   -- forced past the load test
    tga = ".tga",
}
ns.GLYPH_MODES = { "auto", "art", "tga", "blocks" }

local function Round(value)
    return math.floor(value + 0.5)
end

--------------------------------------------------------------------------------
-- Glyph outlines
--
-- The lock and the caret are drawn in a mid grey, which is the design's colour
-- and is fine over the panel's own background. It is not fine once a player
-- turns that background down: over a lit desert or a snowfield the grey lands
-- on top of a similar grey and the glyph stops being a shape at all. Colour on
-- its own cannot hold anything against a background heroPanel does not control,
-- which is the same problem the header text had - and text solves it with
-- SetShadowColor, which a texture does not have.
--
-- So an outlined glyph draws itself five times: four black copies offset by a
-- pixel in each direction on a lower draw layer, then the real one on top.
-- Four rather than eight, because at these sizes the diagonals add a fifth
-- again as many textures and nothing a player can see.
--
-- Drawing order comes from the layer, not from frame level, so all of this
-- stays inside the one glyph frame and every field callers already reach for -
-- glyph.art, glyph.parts, glyph.usingArt, glyph.artPath - stays exactly where
-- it was.
--------------------------------------------------------------------------------

local OUTLINE_OFFSETS = { { -1, 0 }, { 1, 0 }, { 0, 1 }, { 0, -1 } }

-- A shadow texture per offset, created on demand. Kept in a list beside
-- whatever it is shadowing so the two are placed together and can never drift.
local function GlyphShadowSet(glyph, owner, index)
    owner[index] = owner[index] or {}
    local set = owner[index]
    for i = 1, #OUTLINE_OFFSETS do
        if not set[i] then
            local texture = glyph:CreateTexture(nil, "BACKGROUND")
            ns.SetTextureFile(texture, ns.SOLID)
            texture:SetVertexColor(0, 0, 0, 1)
            set[i] = texture
        end
    end
    return set
end

local function HideShadows(owner, from)
    if not owner then return end
    for i = from or 1, #owner do
        local set = owner[i]
        if set then
            for j = 1, #set do set[j]:Hide() end
        end
    end
end

-- The flip flag is passed in rather than read back off the main texture:
-- Texture:GetTexCoord is not something to rely on across 3.3.5a builds, and
-- GlyphSetShape knows the answer already.
local function ShadowArt(glyph, path, flip)
    if not glyph.outlined then
        HideShadows(glyph.artShadows)
        return
    end

    local set = GlyphShadowSet(glyph, glyph.artShadows, 1)
    for i = 1, #set do
        local texture = set[i]
        local dx, dy  = OUTLINE_OFFSETS[i][1], OUTLINE_OFFSETS[i][2]
        pcall(texture.SetTexture, texture, path)
        if flip then texture:SetTexCoord(0, 1, 1, 0) else texture:SetTexCoord(0, 1, 0, 1) end
        texture:ClearAllPoints()
        texture:SetPoint("TOPLEFT", glyph, "TOPLEFT", dx, dy)
        texture:SetPoint("BOTTOMRIGHT", glyph, "BOTTOMRIGHT", dx, dy)
        texture:SetVertexColor(0, 0, 0, glyph.a or 1)
        texture:Show()
    end
end

local function ShadowPart(glyph, index, left, top, width, height)
    if not glyph.outlined then return end

    local set = GlyphShadowSet(glyph, glyph.partShadows, index)
    for i = 1, #set do
        local texture = set[i]
        local dx, dy  = OUTLINE_OFFSETS[i][1], OUTLINE_OFFSETS[i][2]
        texture:ClearAllPoints()
        texture:SetPoint("TOPLEFT", glyph, "TOPLEFT", left + dx, -top + dy)
        texture:SetWidth(width)
        texture:SetHeight(height)
        texture:SetVertexColor(0, 0, 0, glyph.a or 1)
        texture:Show()
    end
end

local GlyphSetColor

local function GlyphSetShape(glyph, name)
    local cells = ns.GLYPHS[name]
    if not cells or #cells == 0 then return false end
    glyph.shape = name

    -- Art first, blocks only if it did not load. "art" and "blocks" force one
    -- route: the two look very different and which one is live is not obvious
    -- from a screenshot, so being able to pin it is how a bad glyph gets
    -- diagnosed in one step instead of three.
    local mode = (ns.db and ns.db.glyph and ns.db.glyph.mode) or "auto"
    local art  = (mode ~= "blocks") and ns.GLYPH_ART[name] or nil

    local forced = FORCED_EXTENSION[mode]
    if art and forced then
        -- Forced: set it and believe it. ns.SetTextureFile would substitute a
        -- plain square on failure, which is the very thing being tested for.
        glyph.artPath = MEDIA .. art.file .. forced
        pcall(glyph.art.SetTexture, glyph.art, glyph.artPath)
        glyph.usingArt = true
        if art.flip then glyph.art:SetTexCoord(0, 1, 1, 0) else glyph.art:SetTexCoord(0, 1, 0, 1) end
        glyph.art:Show()
        for i = 1, #glyph.parts do glyph.parts[i]:Hide() end
        HideShadows(glyph.partShadows)
        ShadowArt(glyph, glyph.artPath, art.flip)
        GlyphSetColor(glyph, glyph.r, glyph.g, glyph.b, glyph.a)
        return true
    end

    if art then
        -- One spelling, deliberately. A candidate chain makes a failure
        -- ambiguous: when a glyph came out as the client's missing-texture
        -- green, the chain meant there was no way to say which file had
        -- produced it. One file per glyph, nothing to fall through to, and the
        -- failure is attributable.
        local used = ns.SetTextureFile(glyph.art, MEDIA .. art.file .. ".tga")
        if used ~= ns.SOLID then
            glyph.usingArt = true
            glyph.artPath  = used
            -- Flipping the caret vertically is what makes one chevron serve
            -- both directions, so there is one shape to draw and to keep.
            if art.flip then
                glyph.art:SetTexCoord(0, 1, 1, 0)
            else
                glyph.art:SetTexCoord(0, 1, 0, 1)
            end
            glyph.art:Show()
            for i = 1, #glyph.parts do glyph.parts[i]:Hide() end
            HideShadows(glyph.partShadows)
            ShadowArt(glyph, used, art.flip)
            GlyphSetColor(glyph, glyph.r, glyph.g, glyph.b, glyph.a)
            return true
        end
    end

    glyph.usingArt = false
    glyph.artPath  = nil
    glyph.art:Hide()
    HideShadows(glyph.artShadows)

    local columns, rows = 0, 0
    for i = 1, #cells do
        local cell = cells[i]
        columns = math.max(columns, cell[1] + (cell[3] or 1))
        rows    = math.max(rows,    cell[2] + (cell[4] or 1))
    end
    if columns == 0 or rows == 0 then return false end

    -- One unit for both axes, so the shape keeps its proportions, then centred
    -- in the glyph's box - a shape that is not square would sit in a corner.
    local size    = glyph.glyphSize
    local unit    = math.min(size / columns, size / rows)
    local originX = (size - columns * unit) / 2
    local originY = (size - rows    * unit) / 2

    for i = 1, #cells do
        local cell = cells[i]
        local part = glyph.parts[i]
        if not part then
            part = glyph:CreateTexture(nil, "ARTWORK")
            ns.SetTextureFile(part, ns.SOLID)
            glyph.parts[i] = part
        end

        -- Round each block's edges rather than its width and height, so blocks
        -- that share an edge meet exactly instead of leaving a seam or
        -- overlapping by a pixel.
        local left   = Round(originX + cell[1] * unit)
        local right  = Round(originX + (cell[1] + (cell[3] or 1)) * unit)
        local top    = Round(originY + cell[2] * unit)
        local bottom = Round(originY + (cell[2] + (cell[4] or 1)) * unit)

        local width  = math.max(1, right - left)
        local height = math.max(1, bottom - top)

        part:ClearAllPoints()
        part:SetPoint("TOPLEFT", glyph, "TOPLEFT", left, -top)
        part:SetWidth(width)
        part:SetHeight(height)
        part:Show()

        ShadowPart(glyph, i, left, top, width, height)
    end

    for i = #cells + 1, #glyph.parts do glyph.parts[i]:Hide() end
    HideShadows(glyph.partShadows, #cells + 1)

    -- A shape change rebuilds the blocks, and new ones start white.
    GlyphSetColor(glyph, glyph.r, glyph.g, glyph.b, glyph.a)
    return true
end

-- The outline never takes the colour, only the alpha: it is black by
-- definition, and it has to fade with the glyph it is behind or a glyph turned
-- down to nothing would leave four black copies of itself on screen.
local function ShadeOutline(owner, alpha)
    if not owner then return end
    for i = 1, #owner do
        local set = owner[i]
        if set then
            for j = 1, #set do set[j]:SetVertexColor(0, 0, 0, alpha) end
        end
    end
end

function GlyphSetColor(glyph, r, g, b, a)
    glyph.r, glyph.g, glyph.b, glyph.a = r or 1, g or 1, b or 1, a or 1
    if glyph.art then
        glyph.art:SetVertexColor(glyph.r, glyph.g, glyph.b, glyph.a)
    end
    for i = 1, #glyph.parts do
        glyph.parts[i]:SetVertexColor(glyph.r, glyph.g, glyph.b, glyph.a)
    end

    if glyph.outlined then
        ShadeOutline(glyph.artShadows, glyph.a)
        ShadeOutline(glyph.partShadows, glyph.a)
    end
end

local function GlyphSetGlyphSize(glyph, size)
    glyph.glyphSize = math.max(4, tonumber(size) or 12)
    glyph:SetWidth(glyph.glyphSize)
    glyph:SetHeight(glyph.glyphSize)
    if glyph.shape then GlyphSetShape(glyph, glyph.shape) end
end

-- Methods are attached as fields rather than through a metatable: a frame
-- brings its own, and replacing it is not something to do to a widget the
-- client owns.
--
-- outlined asks for the black surround described above. It is not the default:
-- most glyphs heroPanel draws sit on something it controls the colour of, and
-- four extra textures each is not free. The two that need it are the ones drawn
-- over the world - the header lock and the collapse caret.
function ns.NewGlyph(parent, size, outlined)
    local glyph = CreateFrame("Frame", nil, parent)
    glyph.parts = {}
    glyph.r, glyph.g, glyph.b, glyph.a = 1, 1, 1, 1

    glyph.outlined    = outlined and true or false
    glyph.artShadows  = {}
    glyph.partShadows = {}

    glyph.art = glyph:CreateTexture(nil, "ARTWORK")
    glyph.art:SetAllPoints(glyph)
    glyph.art:Hide()

    glyph.SetShape     = GlyphSetShape
    glyph.SetColor     = GlyphSetColor
    glyph.SetGlyphSize = GlyphSetGlyphSize

    GlyphSetGlyphSize(glyph, size)
    return glyph
end

--------------------------------------------------------------------------------
-- Fonts
--
-- ns.GetFontFile lives in Media.lua, which resolves HEROPANEL_DB.font.face
-- through LibSharedMedia and falls back to the client's own normal face. It is
-- defined there rather than here because the fallback, the validation probe and
-- the font list are one piece of reasoning and splitting them across two files
-- only made it possible for them to disagree.
--
-- Sizes stay here: they are arithmetic on the configured base and have nothing
-- to do with which file the glyphs come out of.
--------------------------------------------------------------------------------

-- ns.GetFontSize(delta, role) -> points
--
-- role is one of the keys in HEROPANEL_DB.font.size:
--
--   watchHeader   the quest tracker's "QUESTS" row and its badge
--   watchTitle    quest names
--   watchBody     objectives, descriptions and their counts
--   mplusHeader   the Mythic+ dungeon name and keystone level
--   mplusTimer    the Mythic+ clock, which is several times everything around
--                 it by design and so gets a control of its own
--   mplusBody     Mythic+ chest tiers, enemy forces and boss rows
--   options       the options window itself
--
-- Each one is the size that role is drawn at, in points, straight from the
-- store. This used to be a single base size with a per-panel multiplier over
-- it, and the arithmetic was the problem: a player setting 20 was setting a
-- number that then had the design's half-point steps and a percentage applied
-- to it, so what they set and what they saw were never the same figure.
--
-- delta is the small step the design puts on one string relative to the rest of
-- its role - the tracked-quest badge under the header beside it, a boss row
-- over the body of the Mythic+ panel. Those are proportions rather than
-- preferences, so they stay in the code and move with the role.
--
-- An unknown role falls back to the quest tracker's body size, which is the
-- closest thing heroPanel still has to a base.
function ns.GetFontSize(delta, role)
    local sizes = ns.db and ns.db.font and ns.db.font.size
    local size
    if type(sizes) == "table" then
        size = tonumber(sizes[role]) or tonumber(sizes.watchBody)
    end
    return math.max(6, (size or 12) + (delta or 0))
end

-- The range every font control offers. The old ceiling was 20 and the real
-- ceiling was lower still, because Lines.lua clamped a quest line to two points
-- over whatever the tracker had laid it out at - so a slider dragged from 16 to
-- 20 moved the header and the counts and left the quest text exactly where it
-- was. The clamp is gone and so is the reason for a tight range: text that
-- outgrows the panel is answered by dragging the panel's resize grip, which is
-- a thing the player can see happening.
ns.FONT_SIZE_MIN = 8
ns.FONT_SIZE_MAX = 30

--------------------------------------------------------------------------------
-- Text shadow
--
-- ns.ApplyTextShadow(fontString, key) puts the configured black outline on one
-- string, or takes it off. key is "watch" or "mplus"; force overrides the
-- setting and is what the two header strings pass, because those have carried a
-- shadow from the start and need one whatever the rest of the panel is doing -
-- they sit in the header band, which is the part of the panel most likely to be
-- over open sky.
--
-- SetShadowOffset is what a FontString has instead of the four-texture outline
-- ns.NewGlyph draws for a texture. It is one offset copy rather than a
-- surround, so it reads as a drop shadow at 1px and as an outline by 3, which
-- is why the size is offered rather than fixed.
--
-- Clearing it means both a zero offset and a zero alpha. Setting the offset
-- alone leaves a shadow drawn exactly under the glyph, which is not nothing -
-- it thickens the text - and setting the alpha alone leaves an offset behind
-- for the next thing that turns the shadow on.
--------------------------------------------------------------------------------

local SHADOW_ALPHA = 0.9

function ns.ApplyTextShadow(fontString, key, force)
    if not fontString or type(fontString.SetShadowOffset) ~= "function" then return end

    local saved = ns.db and ns.db.panel and ns.db.panel[key]
    local on    = force or (type(saved) == "table" and saved.textShadow)

    if not on then
        pcall(fontString.SetShadowColor, fontString, 0, 0, 0, 0)
        pcall(fontString.SetShadowOffset, fontString, 0, 0)
        return
    end

    local size = math.floor(ns.Clamp((type(saved) == "table" and saved.textShadowSize) or 1, 1, 3))
    pcall(fontString.SetShadowColor, fontString, 0, 0, 0, SHADOW_ALPHA)
    pcall(fontString.SetShadowOffset, fontString, size, -size)
end

--------------------------------------------------------------------------------
-- Colour helpers
--
-- The config stores colours as "#RRGGBB" strings; the WoW API wants 0-1 floats.
--------------------------------------------------------------------------------

function ns.HexToRGB(hex, alpha)
    if type(hex) ~= "string" then return 1, 1, 1, alpha or 1 end
    hex = string.gsub(hex, "^#", "")
    if #hex ~= 6 then return 1, 1, 1, alpha or 1 end
    local r = tonumber(string.sub(hex, 1, 2), 16) or 255
    local g = tonumber(string.sub(hex, 3, 4), 16) or 255
    local b = tonumber(string.sub(hex, 5, 6), 16) or 255
    return r / 255, g / 255, b / 255, alpha or 1
end

function ns.RGBToHex(r, g, b)
    return string.format("#%02X%02X%02X",
        math.floor((r or 0) * 255 + 0.5),
        math.floor((g or 0) * 255 + 0.5),
        math.floor((b or 0) * 255 + 0.5))
end

function ns.Clamp(value, minValue, maxValue)
    value = tonumber(value) or minValue
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

-- Round to a step, e.g. Snap(1.13, 0.1) -> 1.1
function ns.Snap(value, step)
    if not step or step == 0 then return value end
    return math.floor(value / step + 0.5) * step
end

--------------------------------------------------------------------------------
-- Frame-tree walking
--
-- ns.WalkFrameTree does one immediate pass over a frame's regions and child
-- frames. The callback receives (object, info) where info carries:
--     kind       "region" | "child"
--     depth      0 for the root's own regions/children
--     objectType the result of object:GetObjectType()
--     parent     the frame the object hangs off
--     root       the frame the walk started from
--
-- Returning false from the callback prunes recursion into that child.
--------------------------------------------------------------------------------

local DEFAULT_MAX_DEPTH = 6

local function Walk(frame, callback, opts, root, depth, seen)
    if not frame or depth > opts.maxDepth then return end
    if seen[frame] then return end
    seen[frame] = true

    if opts.includeRegions and frame.GetRegions then
        local ok, regions = pcall(function() return { frame:GetRegions() } end)
        if ok then
            for i = 1, #regions do
                local region = regions[i]
                if region then
                    local objectType = region.GetObjectType and region:GetObjectType() or nil
                    callback(region, {
                        kind       = "region",
                        depth      = depth,
                        objectType = objectType,
                        parent     = frame,
                        root       = root,
                    })
                end
            end
        end
    end

    if opts.includeChildren and frame.GetChildren then
        local ok, children = pcall(function() return { frame:GetChildren() } end)
        if ok then
            for i = 1, #children do
                local child = children[i]
                if child then
                    local objectType = child.GetObjectType and child:GetObjectType() or nil
                    local descend = callback(child, {
                        kind       = "child",
                        depth      = depth,
                        objectType = objectType,
                        parent     = frame,
                        root       = root,
                    })
                    if descend ~= false then
                        Walk(child, callback, opts, root, depth + 1, seen)
                    end
                end
            end
        end
    end
end

function ns.WalkFrameTree(frame, callback, options)
    if not frame or type(callback) ~= "function" then return false end
    options = options or {}
    local opts = {
        maxDepth        = options.maxDepth or DEFAULT_MAX_DEPTH,
        includeRegions  = options.includeRegions ~= false,
        includeChildren = options.includeChildren ~= false,
    }
    Walk(frame, callback, opts, frame, 0, {})
    return true
end

--------------------------------------------------------------------------------
-- Throttled frame-tree scanner
--
-- One shared OnUpdate driver runs every active scanner. Each scanner keeps its
-- own elapsed-time accumulator, so a scanner set to 0.1s does at most ~10
-- passes per second regardless of frame rate. Nothing runs per-frame.
--
--     local scanner = ns.NewTreeScanner(someFrame, function(object, info) ... end)
--     scanner:Start()          -- begin throttled scanning
--     scanner:ScanNow()        -- one immediate pass, ignores the throttle
--     scanner:SetInterval(0.2) -- 5 passes/sec instead of 10
--     scanner:Stop()
--------------------------------------------------------------------------------

local MIN_INTERVAL = 0.1   -- hard floor: ~10 scans/sec
local activeScanners = {}
local driver

local function DriverOnUpdate(_, elapsed)
    local anyActive = false
    for scanner in pairs(activeScanners) do
        anyActive = true
        scanner.accumulator = scanner.accumulator + elapsed
        if scanner.accumulator >= scanner.interval then
            scanner.accumulator = 0
            scanner:ScanNow()
        end
    end
    if not anyActive then driver:Hide() end
end

local scannerMethods = {}
local scannerMeta = { __index = scannerMethods }

function scannerMethods:SetFrame(frame)
    self.frame = frame
    return self
end

function scannerMethods:SetInterval(interval)
    self.interval = math.max(tonumber(interval) or MIN_INTERVAL, MIN_INTERVAL)
    return self
end

function scannerMethods:IsRunning()
    return activeScanners[self] and true or false
end

function scannerMethods:ScanNow()
    local frame = self.frame
    if not frame then return false end
    if self.requireVisible and frame.IsVisible and not frame:IsVisible() then return false end

    self.scanCount = self.scanCount + 1
    ns.WalkFrameTree(frame, self.callback, self.options)
    if self.onComplete then self.onComplete(self) end

    if self.once then self:Stop() end
    return true
end

function scannerMethods:Start()
    if not self.frame then return false end
    activeScanners[self] = true
    self.accumulator = self.interval   -- first pass on the next driver tick
    driver:Show()
    return true
end

function scannerMethods:Stop()
    activeScanners[self] = nil
    return self
end

-- ns.NewTreeScanner(frame, callback, options)
--   options.interval        seconds between passes (floored at 0.1)
--   options.maxDepth        recursion limit, default 6
--   options.includeRegions  default true
--   options.includeChildren default true
--   options.requireVisible  skip the pass when the frame is hidden, default true
--   options.once            stop after the first completed pass
--   options.onComplete      called with the scanner after each pass
function ns.NewTreeScanner(frame, callback, options)
    if type(callback) ~= "function" then return nil end
    options = options or {}

    if not driver then
        driver = CreateFrame("Frame", "HeroPanelScanDriver")
        driver:Hide()
        driver:SetScript("OnUpdate", DriverOnUpdate)
    end

    local scanner = setmetatable({
        frame          = frame,
        callback       = callback,
        options        = options,
        interval       = math.max(tonumber(options.interval) or MIN_INTERVAL, MIN_INTERVAL),
        accumulator    = 0,
        scanCount      = 0,
        requireVisible = options.requireVisible ~= false,
        once           = options.once and true or false,
        onComplete     = options.onComplete,
    }, scannerMeta)

    return scanner
end
