-- Minimal 3.3.5a-shaped mock of the WoW client, enough to boot heroPanel and
-- drive the skin. Not a client emulator: a smoke test.

local ADDON = os.getenv("HP_ADDON") or "../../heroPanel/"
local MINIMAL = os.getenv("HP_MINIMAL") ~= nil

local failures = {}
local log = {}
local function note(msg) table.insert(log, msg) end
local function fail(msg) table.insert(failures, msg) end

--------------------------------------------------------------------------------
-- Object model
--------------------------------------------------------------------------------

local methods = {}
local meta = { __index = methods }

local function new(kind, name, parent)
    local o = setmetatable({
        __kind = kind, __name = name, __parent = parent,
        __points = {}, __scripts = {}, __regions = {}, __children = {},
        __shown = true, __alpha = 1, __scale = 1, __mouse = false,
        __events = {},
    }, meta)
    if name then _G[name] = o end
    if parent and parent.__children then table.insert(parent.__children, o) end
    return o
end

function methods:GetObjectType() return self.__kind end
function methods:GetName() return self.__name end
function methods:GetParent() return self.__parent end
function methods:SetParent(p) self.__parent = p end
function methods:Show() self.__shown = true end
function methods:Hide() self.__shown = false end
function methods:IsShown() return self.__shown end
function methods:IsVisible()
    if not self.__shown then return false end
    local p = self.__parent
    while p do
        if not p.__shown then return false end
        p = p.__parent
    end
    return true
end
function methods:SetAlpha(a) self.__alpha = a end
function methods:GetAlpha() return self.__alpha end
function methods:SetScale(s) self.__scale = s end
function methods:GetScale() return self.__scale end
function methods:GetEffectiveScale()
    local s, p = self.__scale, self.__parent
    while p do s = s * (p.__scale or 1); p = p.__parent end
    return s
end
function methods:SetFrameStrata(s) self.__strata = s end
function methods:GetFrameStrata() return self.__strata or "MEDIUM" end
function methods:SetFrameLevel(l) self.__level = l end
function methods:GetFrameLevel() return self.__level or 1 end
function methods:EnableMouse(v) self.__mouse = v end
function methods:IsMouseEnabled() return self.__mouse end
function methods:SetMovable(v) self.__movable = v end
function methods:StartMoving() end
function methods:StopMovingOrSizing() end
function methods:RegisterForDrag() end
function methods:RegisterForClicks() end
function methods:SetClampedToScreen() end
function methods:SetUserPlaced(v) self.__userPlaced = v end
function methods:IsUserPlaced() return self.__userPlaced end
function methods:RegisterEvent(e) self.__events[e] = true end
function methods:UnregisterEvent(e) self.__events[e] = nil end
function methods:IsEnabled() return true end
function methods:SetHitRectInsets() end
function methods:SetTexCoord(...) self.__texCoord = { ... } end
function methods:SetTexture(path) self.__texture = path; return true end
function methods:GetTexture() return self.__texture end
function methods:SetVertexColor(r, g, b, a) self.__color = { r, g, b, a } end
function methods:SetGradientAlpha(...) self.__gradient = { ... } end
function methods:SetBlendMode() end
function methods:SetDrawLayer() end

function methods:SetScript(s, fn) self.__scripts[s] = fn end
function methods:GetScript(s) return self.__scripts[s] end
function methods:HookScript(s, fn)
    local existing = self.__scripts[s]
    self.__scripts[s] = function(...)
        if existing then existing(...) end
        fn(...)
    end
end

function methods:CreateTexture(name, layer)
    local t = new("Texture", name, self)
    t.__layer = layer
    table.insert(self.__regions, t)
    return t
end

function methods:CreateFontString(name, layer)
    local f = new("FontString", name, self)
    f.__layer = layer
    f.__text = ""
    f.__font = { "Fonts\\FRIZQT__.TTF", 12, "" }
    f.__textColor = { 1, 1, 1, 1 }
    table.insert(self.__regions, f)
    return f
end

function methods:GetRegions() return unpack_regions(self) end
function methods:GetChildren() return unpack_children(self) end

function unpack_regions(self) return table.unpack(self.__regions) end
function unpack_children(self) return table.unpack(self.__children) end

-- FontString
function methods:SetFont(path, size, flags)
    if not path or not size then error("SetFont with nil path/size", 2) end
    self.__font = { path, size, flags }
    return true
end
function methods:GetFont()
    local f = self.__font or { "Fonts\\FRIZQT__.TTF", 12, "" }
    return f[1], f[2], f[3]
end
function methods:SetText(t) self.__text = t end
function methods:GetText() return self.__text end
function methods:SetTextColor(r, g, b, a) self.__textColor = { r, g, b, a } end
function methods:GetTextColor()
    local c = self.__textColor or { 1, 1, 1, 1 }
    return c[1], c[2], c[3], c[4]
end
function methods:GetStringWidth()
    local visible = string.gsub(self.__text or "", "|c%x%x%x%x%x%x%x%x", "")
    visible = string.gsub(visible, "|r", "")
    return #visible * 5
end
function methods:SetJustifyH() end
function methods:SetWordWrap() end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

function methods:SetWidth(w) self.__width = w end
function methods:SetHeight(h) self.__height = h end
function methods:ClearAllPoints() self.__points = {} end
function methods:SetPoint(point, a, b, c, d)
    local relTo, relPoint, x, y
    if type(a) == "table" then
        relTo, relPoint, x, y = a, b, c, d
        if type(b) == "number" then relPoint, x, y = point, b, c end
    elseif type(a) == "string" then
        relTo, relPoint, x, y = self.__parent, a, b, c
    else
        relTo, relPoint, x, y = self.__parent, point, a, b
    end
    table.insert(self.__points, {
        point = point, relTo = relTo, relPoint = relPoint or point,
        x = x or 0, y = y or 0,
    })
end
function methods:SetAllPoints(other)
    other = other or self.__parent
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", other, "TOPLEFT", 0, 0)
    self:SetPoint("BOTTOMRIGHT", other, "BOTTOMRIGHT", 0, 0)
end

local function anchorPoint(rect, point)
    if not rect then return nil, nil end
    local cx = (rect.left + rect.right) / 2
    local cy = (rect.top + rect.bottom) / 2
    local x, y = cx, cy
    if string.find(point, "LEFT")   then x = rect.left   end
    if string.find(point, "RIGHT")  then x = rect.right  end
    if string.find(point, "TOP")    then y = rect.top    end
    if string.find(point, "BOTTOM") then y = rect.bottom end
    return x, y
end

local resolving = {}

local function rectOf(obj, depth)
    if not obj then return nil end
    if obj.__rect then return obj.__rect end
    if resolving[obj] or (depth or 0) > 12 then return nil end
    resolving[obj] = true

    local left, right, top, bottom
    for _, p in ipairs(obj.__points) do
        local target = rectOf(p.relTo, (depth or 0) + 1)
        local ax, ay = anchorPoint(target, p.relPoint)
        if ax then
            local px, py = ax + p.x, ay + p.y
            if string.find(p.point, "LEFT")   then left   = px end
            if string.find(p.point, "RIGHT")  then right  = px end
            if string.find(p.point, "TOP")    then top    = py end
            if string.find(p.point, "BOTTOM") then bottom = py end
            if p.point == "CENTER" then
                local w, h = obj.__width or 0, obj.__height or 0
                left, right, top, bottom = px - w / 2, px + w / 2, py + h / 2, py - h / 2
            end
            if p.point == "LEFT" or p.point == "RIGHT" then
                local h = obj.__height or 0
                if not top then top, bottom = py + h / 2, py - h / 2 end
            end
        end
    end

    if left and not right and obj.__width then right = left + obj.__width end
    if right and not left and obj.__width then left = right - obj.__width end
    if top and not bottom and obj.__height then bottom = top - obj.__height end
    if bottom and not top and obj.__height then top = bottom + obj.__height end

    resolving[obj] = nil
    if not (left and right and top and bottom) then return nil end
    return { left = left, right = right, top = top, bottom = bottom }
end

function methods:GetLeft()   local r = rectOf(self); return r and r.left end
function methods:GetRight()  local r = rectOf(self); return r and r.right end
function methods:GetTop()    local r = rectOf(self); return r and r.top end
function methods:GetBottom() local r = rectOf(self); return r and r.bottom end
function methods:GetWidth()
    if self.__width then return self.__width end
    local r = rectOf(self); return r and (r.right - r.left) or 0
end
function methods:GetHeight()
    if self.__height then return self.__height end
    local r = rectOf(self); return r and (r.top - r.bottom) or 0
end

--------------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------------

function methods:GetNormalTexture() return self.__normal end
function methods:GetPushedTexture() return self.__pushed end
function methods:GetHighlightTexture() return self.__highlight end
function methods:GetDisabledTexture() return nil end
function methods:Click()
    local fn = self.__scripts.OnClick
    if fn then fn(self, "LeftButton") end
end

--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------

_G = _ENV or _G

local frames = {}

function CreateFrame(kind, name, parent, template)
    local f = new(kind, name, parent or UIParent)
    if kind == "Button" then
        f.__normal    = f:CreateTexture()
        f.__highlight = f:CreateTexture()
    end
    table.insert(frames, f)
    return f
end

UIParent = new("Frame", "UIParent", nil)
UIParent.__rect = { left = 0, right = 1600, top = 900, bottom = 0 }

DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) note(msg) end }

GameTooltip = new("Frame", "GameTooltip", UIParent)
GameTooltip.SetOwner = function() end
GameTooltip.AddLine  = function() end

GameFontNormal = new("Font", "GameFontNormal", nil)
GameFontNormal.__font = { "Fonts\\FRIZQT__.TTF", 12, "" }

UIPARENT_MANAGED_FRAME_POSITIONS = { WatchFrame = {} }
function UIParent_ManageFramePositions() end

local combat = false
function InCombatLockdown() return combat end

local now = 0
function GetTime() return now end

local cursorX, cursorY = -1000, -1000
function GetCursorPosition() return cursorX, cursorY end

function wipe(t) for k in pairs(t) do t[k] = nil end return t end

SlashCmdList = {}

function IsAddOnLoaded() return false end
function GetAddOnInfo() return nil, nil, nil, false, false end

local questWatches = 3
if not MINIMAL then
    function GetNumQuestWatches() return questWatches end
end

function hooksecurefunc(a, b, c)
    local target, key, fn
    if type(a) == "table" then target, key, fn = a, b, c else target, key, fn = _G, a, b end
    local original = target[key]
    if type(original) ~= "function" then error("hooksecurefunc on a non-function: " .. tostring(key), 2) end
    target[key] = function(...)
        local r = { original(...) }
        fn(...)
        return table.unpack(r)
    end
end

--------------------------------------------------------------------------------
-- The tracker
--------------------------------------------------------------------------------

WatchFrame = new("Frame", "WatchFrame", UIParent)
WatchFrame.__level = 2
-- Deliberately far taller than its contents: the real frame is given a region
-- to draw in, not sized to what it drew.
WatchFrame.__rect = { left = 1000, right = 1204, top = 800, bottom = 300 }

local trackerLines = {}
local collapseBtn = new("Button", MINIMAL and nil or "WatchFrameCollapseExpandButton", WatchFrame)
WatchFrameCollapseExpandButton = collapseBtn
collapseBtn.__level = 3
collapseBtn.__rect = { left = 1186, right = 1202, top = 800, bottom = 784 }
collapseBtn.__normal    = collapseBtn:CreateTexture()
collapseBtn.__highlight = collapseBtn:CreateTexture()
collapseBtn:SetScript("OnClick", function()
    WatchFrame.collapsed = not WatchFrame.collapsed
    for _, line in ipairs(trackerLines) do
        if WatchFrame.collapsed then line:Hide() else line:Show() end
    end
end)
if MINIMAL then WatchFrameCollapseExpandButton = nil end

local titleFS = WatchFrame:CreateFontString(MINIMAL and nil or "WatchFrameTitle", "ARTWORK")
titleFS:SetText("Objectives")
titleFS.__rect = { left = 1002, right = 1060, top = 800, bottom = 786 }

-- A second header, drawn on a child frame rather than on WatchFrame itself.
--
-- This is the shape the live client turned out to have, and the one the mock
-- was missing: the string actually on screen is not the one a WatchFrameTitle
-- lookup finds, and it is a region of a child, so a name lookup misses it and a
-- regions-of-the-root scan never sees it either. Two things went wrong because
-- of that - the header stayed visible under heroPanel's own, and the line walk
-- picked the string up as a quest title, because a title is exactly what it
-- looks like: no dash, no counter, at the tracker's left edge.
--
-- Left unnamed on purpose. Nothing may key off the name.
local nativeHeader = new("Frame", nil, WatchFrame)
nativeHeader.__level = 3
nativeHeader.__rect = { left = 1000, right = 1204, top = 800, bottom = 784 }

local nativeHeaderArt = nativeHeader:CreateTexture(nil, "ARTWORK")
nativeHeaderArt.__rect = { left = 1000, right = 1204, top = 800, bottom = 796 }

local nativeHeaderText = nativeHeader:CreateFontString(nil, "ARTWORK")
nativeHeaderText:SetText("Objectives (1)")
nativeHeaderText.__rect = { left = 1002, right = 1080, top = 796, bottom = 784 }

-- The header's divider art, anchored a few pixels *below* the band. Geometry
-- alone never reaches it, which is how it survived on the live client and left
-- a gold streak across the panel. It is header art all the same, and the only
-- thing that says so is that its owner draws inside the band.
local nativeHeaderDivider = nativeHeader:CreateTexture(nil, "ARTWORK")
nativeHeaderDivider.__rect = { left = 1000, right = 1204, top = 782, bottom = 780 }

local WatchFrameLines = new("Frame", "WatchFrameLines", WatchFrame)
WatchFrameLines.__level = 3
WatchFrameLines.__rect = { left = 1000, right = 1204, top = 780, bottom = 300 }

local lineDefs = {
    { text = "Wolves at the Gate",        dash = nil,  top = 770, left = 1010 },
    { text = "Dire wolves slain: 6/8",    dash = "- ", top = 754, left = 1020 },
    { text = "Alpha wolf slain: 0/1",     dash = "- ", top = 740, left = 1020 },
    { text = "Supplies for the Front",    dash = nil,  top = 720, left = 1010 },
    { text = "Iron ore collected: 12/12", dash = "- ", top = 704, left = 1020 },
    { text = "A Cure for the Ailing",     dash = nil,  top = 684, left = 1010 },
    { text = "Deliver the tonic to Marla", dash = "- ", top = 668, left = 1020 },
}

for i, def in ipairs(lineDefs) do
    local line = new("Frame", "WatchFrameLine" .. i, WatchFrameLines)
    line.__level = 4
    line.__rect = { left = def.left, right = 1200, top = def.top, bottom = def.top - 12 }

    local dash = line:CreateFontString(nil, "ARTWORK")
    dash:SetText(def.dash or "")
    dash.__rect = { left = def.left, right = def.left + 8, top = def.top, bottom = def.top - 12 }
    if not def.dash then dash:Hide() end

    local text = line:CreateFontString(nil, "ARTWORK")
    text:SetText(def.text)
    text.__rect = { left = def.left + (def.dash and 10 or 0), right = 1190,
                    top = def.top, bottom = def.top - 12 }
    text.__font = { "Fonts\\FRIZQT__.TTF", def.dash and 12 or 13, "" }

    -- A client that does not expose these parent keys is exactly what the
    -- fallback resolver in Lines.lua is for.
    if not MINIMAL then line.dash, line.text = dash, text end
    line.__dash, line.__text = dash, text

    trackerLines[i] = line
end

function _WatchFrame_Update()
    local collapsed = WatchFrame.collapsed
    for _, line in ipairs(trackerLines) do
        if collapsed then line:Hide() else line:Show() end
    end
end

if not MINIMAL then
    WatchFrame_Update = _WatchFrame_Update
    function WatchFrame_Collapse(frame) frame.collapsed = true;  _WatchFrame_Update() end
    function WatchFrame_Expand(frame)   frame.collapsed = false; _WatchFrame_Update() end
end

--------------------------------------------------------------------------------
-- Event / OnUpdate driving
--------------------------------------------------------------------------------

local function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.__events[event] and f.__scripts.OnEvent then
            f.__scripts.OnEvent(f, event, ...)
        end
    end
end

local function tick(seconds)
    now = now + (seconds or 0.05)
    for _, f in ipairs(frames) do
        if f.__scripts.OnUpdate and f:IsShown() then
            f.__scripts.OnUpdate(f, seconds or 0.05)
        end
    end
end

--------------------------------------------------------------------------------
-- Boot heroPanel
--------------------------------------------------------------------------------

local ns = {}
local files = { "Core.lua", "Util.lua", "Trackers.lua", "Move.lua", "Skin.lua", "Lines.lua", "Compat.lua" }
for _, file in ipairs(files) do
    local chunk, err = loadfile(ADDON .. file)
    if not chunk then error("load " .. file .. ": " .. tostring(err)) end
    chunk("heroPanel", ns)
end

HEROPANEL_DB = { debug = true }

fire("ADDON_LOADED", "heroPanel")
tick(); tick()
fire("PLAYER_LOGIN")
tick(); tick()
fire("PLAYER_ENTERING_WORLD")
tick(); tick(); tick()

--------------------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------------------

local function check(condition, message)
    if not condition then fail(message) end
end

for _, line in ipairs(log) do
    -- the deliberate one below is the point of the reporter test
    if string.find(line, "error", 1, true)
       and not string.find(line, "HEROPANEL_TEST_EXPLODE", 1, true) then
        fail("runtime: " .. line)
    end
end

local plate = HeroPanelWatchPlate
check(plate ~= nil, "plate was never created")

if plate then
    check(plate:IsShown(), "plate is not shown")
    check(plate:GetWidth() == 204 + 28, "plate width follows the tracker: got " .. tostring(plate:GetWidth()))

    -- Content runs from y=770 down to y=656; the plate must be sized to that,
    -- not to WatchFrame's 500px drawing region.
    local height = plate:GetHeight()
    check(height > 100 and height < 200, "plate height should track content, got " .. tostring(height))

    -- Behind the tracker is a strata step, not frame-level arithmetic. Levels
    -- bottom out at zero and only compare inside one strata, so subtracting a
    -- couple from the tracker's level silently stopped working on the live
    -- client, which puts WatchFrame at level 1.
    check(plate:GetFrameStrata() == "LOW",
        "plate should sit a strata below the tracker's MEDIUM, got " .. tostring(plate:GetFrameStrata()))
end

-- Blizzard chrome faded, not hidden
check(titleFS:GetAlpha() == 0, "Blizzard title should be faded out")
check(titleFS:IsShown(), "Blizzard title should not be hidden, only faded")
check(collapseBtn.__normal:GetAlpha() == 0, "collapse button art should be faded")

-- ...and the header the tracker draws on a child frame, which is the one that
-- was left on screen underneath heroPanel's own. Neither region is named, so
-- this only passes if the band is being cleared by geometry.
check(nativeHeaderText:GetAlpha() == 0,
    "the tracker's own header text should be faded, got " .. tostring(nativeHeaderText:GetAlpha()))
check(nativeHeaderArt:GetAlpha() == 0,
    "the tracker's own header art should be faded, got " .. tostring(nativeHeaderArt:GetAlpha()))
check(nativeHeaderText:IsShown(), "header text should be faded, not hidden")
check(nativeHeaderDivider:GetAlpha() == 0,
    "header divider art below the band should be faded through its owner, got "
    .. tostring(nativeHeaderDivider:GetAlpha()))

-- Line styling
local function colourOf(fontString)
    local r, g, b = fontString:GetTextColor()
    return string.format("%02X%02X%02X",
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

check(colourOf(trackerLines[1].__text) == "E7C67C", "quest title should be gold, got " .. colourOf(trackerLines[1].__text))
check(colourOf(trackerLines[2].__text) == "C2C6D8", "objective should be normal, got " .. colourOf(trackerLines[2].__text))
check(colourOf(trackerLines[5].__text) == "79C68D", "completed objective should be green, got " .. colourOf(trackerLines[5].__text))
check(colourOf(trackerLines[7].__text) == "C2C6D8", "text objective should be normal, got " .. colourOf(trackerLines[7].__text))

check(string.find(trackerLines[2].__text:GetText(), "|cFFE9E9ED6/8|r", 1, true) ~= nil,
    "counter should be highlighted, got " .. tostring(trackerLines[2].__text:GetText()))
check(trackerLines[5].__text:GetText() == "Iron ore collected: 12/12",
    "completed line should not be recoloured inline, got " .. tostring(trackerLines[5].__text:GetText()))
check(trackerLines[5].__dash:GetAlpha() == 0, "completed objective's dash should be faded for the check glyph")
check(trackerLines[7].__dash:GetAlpha() == 1, "text objective keeps its dash")

-- The tracker's own header text must not come back from the line walk as a
-- quest title. In minimal mode the badge below counts blocks, so a phantom
-- block shows up there too; this says outright which mistake was made.
check(colourOf(nativeHeaderText) ~= "E7C67C",
    "the tracker's header text was styled as a quest title by the line walk")

-- Fonts never grow past what the tracker measured
local _, titleSize = trackerLines[1].__text:GetFont()
local _, lineSize  = trackerLines[2].__text:GetFont()
check(titleSize <= 13, "title font must not exceed the original 13, got " .. tostring(titleSize))
check(lineSize == 11.5, "objective font should be 11.5, got " .. tostring(lineSize))

-- Header badge
local badge
for _, region in ipairs(plate and plate.__regions or {}) do
    if region.__kind == "FontString" and region:GetText() == "3" then badge = region end
end
check(badge ~= nil, "count badge should read 3")

--------------------------------------------------------------------------------
-- Glyphs
--
-- Drawn from solids rather than client art because SetVertexColor multiplies:
-- Blizzard's gold padlock tinted #75798C comes out muted gold, not #75798C,
-- which is what put gold squares in the header. Three things have to hold - a
-- shape fills the box it is given, never spills out of it, and comes out the
-- exact colour asked for. The last one is the entire reason for not using art,
-- so it is the one worth asserting hardest.
--------------------------------------------------------------------------------

local hp = HeroPanel

local glyphHost = new("Frame", nil, UIParent)
glyphHost.__rect = { left = 500, right = 600, top = 500, bottom = 400 }

local glyph = hp.NewGlyph(glyphHost, 12)
check(glyph ~= nil, "NewGlyph returned nothing")
glyph:SetPoint("TOPLEFT", glyphHost, "TOPLEFT", 0, 0)

local shapeNames = {}
for name in pairs(hp.GLYPHS) do table.insert(shapeNames, name) end
table.sort(shapeNames)
check(#shapeNames >= 5, "expected the full glyph set, got " .. tostring(#shapeNames))

for _, name in ipairs(shapeNames) do
    check(glyph:SetShape(name) ~= false, "SetShape rejected " .. name)

    local boxLeft, boxRight = glyph:GetLeft(), glyph:GetRight()
    local boxTop, boxBottom = glyph:GetTop(), glyph:GetBottom()

    local shown, minLeft, maxRight, maxTop, minBottom = 0
    for _, part in ipairs(glyph.parts) do
        if part:IsShown() then
            shown = shown + 1
            local l, r = part:GetLeft(), part:GetRight()
            local t, b = part:GetTop(), part:GetBottom()

            check(l >= boxLeft - 0.01 and r <= boxRight + 0.01
              and t <= boxTop + 0.01 and b >= boxBottom - 0.01,
                name .. " spills outside its box")
            check(r - l >= 1 and t - b >= 1, name .. " has a block thinner than a pixel")

            minLeft   = math.min(minLeft   or l, l)
            maxRight  = math.max(maxRight  or r, r)
            maxTop    = math.max(maxTop    or t, t)
            minBottom = math.min(minBottom or b, b)
        end
    end

    check(shown == #hp.GLYPHS[name],
        name .. " drew " .. tostring(shown) .. " of " .. tostring(#hp.GLYPHS[name]) .. " blocks")

    -- The grid scales to fit, so the longer axis must reach the full 12px.
    -- A shape rendering at a few pixels inside a 12px box is what getting the
    -- unit maths wrong looks like, and it would pass every other check here.
    local reach = math.max(maxRight - minLeft, maxTop - minBottom)
    check(reach >= 11.99, name .. " does not fill its box, longest axis " .. tostring(reach))
end

-- Colour is exact, and survives a shape change: SetShape builds blocks it has
-- not built before, and a new block starts white. This is the check the whole
-- approach exists for - a tint over Blizzard's art could never assert it.
local function glyphHex(part)
    local c = part.__color or {}
    return string.format("%02X%02X%02X",
        math.floor((c[1] or 1) * 255 + 0.5),
        math.floor((c[2] or 1) * 255 + 0.5),
        math.floor((c[3] or 1) * 255 + 0.5))
end

glyph:SetShape("caretUp")
glyph:SetColor(hp.HexToRGB("#75798C"))
check(glyphHex(glyph.parts[1]) == "75798C",
    "glyph colour should be exact, got " .. glyphHex(glyph.parts[1]))

-- "locked" has more blocks than "caretUp", so the last one is built by this
-- call and has never been coloured before.
glyph:SetShape("locked")
local lastBlock = glyph.parts[#hp.GLYPHS.locked]
check(#hp.GLYPHS.locked > #hp.GLYPHS.caretUp, "the shape swap must add blocks to be a test")
check(glyphHex(lastBlock) == "75798C",
    "a block built by a shape change should take the glyph's colour, got " .. glyphHex(lastBlock))

--------------------------------------------------------------------------------
-- Hover
--------------------------------------------------------------------------------

local firstBlockLine = trackerLines[2].__text
cursorX = (firstBlockLine:GetLeft() + 5) * UIParent:GetEffectiveScale()
cursorY = (firstBlockLine:GetTop() - 2) * UIParent:GetEffectiveScale()
tick(0.2)

local tinted = 0
for _, f in ipairs(frames) do
    if f.tint and f.tint:IsShown() then tinted = tinted + 1 end
end
check(tinted == 1, "exactly one quest block should be tinted on hover, got " .. tinted)

cursorX, cursorY = -1000, -1000
tick(0.2)
tinted = 0
for _, f in ipairs(frames) do
    if f.tint and f.tint:IsShown() then tinted = tinted + 1 end
end
check(tinted == 0, "hover tint should clear when the cursor leaves, got " .. tinted)

--------------------------------------------------------------------------------
-- Collapse
--------------------------------------------------------------------------------

local expandedHeight = plate:GetHeight()
ns.Skin.ToggleCollapse()
tick(); tick()

check(WatchFrame.collapsed == true, "collapse should have gone through the tracker's own button")
check(plate:GetHeight() < expandedHeight, "collapsed plate should be header-height")

ns.Skin.ToggleCollapse()
tick(); tick()
check(WatchFrame.collapsed == false, "expand should have gone through the tracker's own button")
check(math.abs(plate:GetHeight() - expandedHeight) < 1, "expanding should restore the plate height")

-- ...and refuses in combat rather than touching a protected frame
combat = true
local before = WatchFrame.collapsed
ns.Skin.ToggleCollapse()
check(WatchFrame.collapsed == before, "collapse must be refused in combat")
combat = false

--------------------------------------------------------------------------------
-- Disable restores Blizzard's tracker
--------------------------------------------------------------------------------

ns.Skin.SetEnabled(false)
tick(); tick()

check(HEROPANEL_DB.enabled == false, "the flag should be stored")
check(plate:IsShown() == false, "plate should be hidden when the skin is off")
check(titleFS:GetAlpha() == 1, "Blizzard title should be back")
check(collapseBtn.__normal:GetAlpha() == 1, "collapse button art should be back")
check(trackerLines[2].__text:GetText() == "Dire wolves slain: 6/8",
    "counter highlight should be removed, got " .. tostring(trackerLines[2].__text:GetText()))
check(colourOf(trackerLines[1].__text) == "FFFFFF", "title colour should be restored, got " .. colourOf(trackerLines[1].__text))
local _, restored = trackerLines[1].__text:GetFont()
check(restored == 13, "title font size should be restored, got " .. tostring(restored))
check(trackerLines[5].__dash:GetAlpha() == 1, "faded dash should be restored")

-- ...and re-enabling works from a clean slate
ns.Skin.SetEnabled(true)
tick(); tick(); tick()
check(plate:IsShown(), "plate should come back when the skin is re-enabled")
check(colourOf(trackerLines[1].__text) == "E7C67C", "re-enabling should re-skin the title")

--------------------------------------------------------------------------------
-- Header off, and the border / radius variants
--------------------------------------------------------------------------------

HEROPANEL_DB.header.show = false
ns.Skin.Restyle()
ns.Skin.Refresh("test")
tick(); tick()

check(titleFS:GetAlpha() == 1, "turning the header off must give Blizzard's header back")
check(collapseBtn.__normal:GetAlpha() == 1, "turning the header off must give the collapse art back")
check(plate.divider.mid:IsShown() == false, "divider should be hidden with the header")

HEROPANEL_DB.header.show = true
HEROPANEL_DB.border.style = "none"
HEROPANEL_DB.radius = 0
HEROPANEL_DB.bg.opacity = 0.5
ns.Skin.Restyle()
ns.Skin.Refresh("test")
tick(); tick()

check(titleFS:GetAlpha() == 0, "header back on should fade Blizzard's title again")
check(plate.edge.top:IsShown() == false, "border style 'none' should hide the edges")
for _, pixels in pairs(plate.corner) do
    for _, pixel in ipairs(pixels) do
        check(pixel:IsShown() == false, "corner steps should be hidden with no border")
    end
end
check(plate.bg.main.__color[4] == 0.5, "background opacity should be applied")

HEROPANEL_DB.border.style = "hairline"
HEROPANEL_DB.radius = 8
ns.Skin.Restyle()
local notched = 0
for _, pixels in pairs(plate.corner) do
    for _, pixel in ipairs(pixels) do
        if pixel:IsShown() then notched = notched + 1 end
    end
end
check(notched == 8, "an 8px radius should be a 2px step at each of the four corners, got " .. notched)

--------------------------------------------------------------------------------
-- A stuck collapsed flag
--
-- Observed in the wild: the client leaves WatchFrame.collapsed set while the
-- tracker is plainly expanded with quest lines on screen. Trusting the flag
-- made the skin skip the line walk entirely - nothing styled, nothing
-- measured, and a panel collapsed to header height around visible text. What
-- is drawn has to win.
--------------------------------------------------------------------------------

WatchFrame.collapsed = true
for _, line in ipairs(trackerLines) do line:Show() end
ns.Skin.Refresh("stuck flag")
tick(); tick()

check(plate:GetHeight() > 100,
    "a stuck collapsed flag must not shrink the panel around visible lines, got "
    .. tostring(plate:GetHeight()))
check(colourOf(trackerLines[1].__text) == "E7C67C",
    "lines must still be styled when the collapsed flag is stuck, got " .. colourOf(trackerLines[1].__text))
check(ns.IsCollapsed("watch") == false,
    "the measurement should override the frame's flag")

WatchFrame.collapsed = false
ns.Skin.Refresh("cleared")
tick(); tick()

--------------------------------------------------------------------------------
-- Diagnostics
--
-- /hp status has to survive being run when the skin is broken, which is the
-- only time anybody runs it.
--------------------------------------------------------------------------------

local before = #log
SlashCmdList["HEROPANEL"]("status")
check(#log > before, "/hp status should print something")

local reported = table.concat(log, "\n", before + 1)
check(string.find(reported, "skin is", 1, true) ~= nil, "/hp status should report the skin state")
check(string.find(reported, "quest block", 1, true) ~= nil, "/hp status should report styled blocks")

before = #log
SlashCmdList["HEROPANEL"]("dump")
local dumped = table.concat(log, "\n", before + 1)
check(string.find(dumped, "WatchFrame", 1, true) ~= nil, "/hp dump should describe the tracker")
check(string.find(dumped, "walk resolved 7 line", 1, true) ~= nil,
    "/hp dump should list the resolved lines, got:\n" .. dumped)

-- The branch that matters when something is wrong: another addon has taken the
-- display over and the tracker's own lines are hidden. The dump has to say what
-- it visited, not just that it found nothing.
for _, line in ipairs(trackerLines) do line:Hide() end
before = #log
SlashCmdList["HEROPANEL"]("dump")
local blind = table.concat(log, "\n", before + 1)
check(string.find(blind, "nothing resolved", 1, true) ~= nil,
    "/hp dump should say when the walk resolved nothing")
check(string.find(blind, "hidden", 1, true) ~= nil,
    "/hp dump should report the hidden frames it visited, got:\n" .. blind)
for _, line in ipairs(trackerLines) do line:Show() end

-- Another addon docks the tracker into a holder of its own and draws a header
-- there. The walk starts at WatchFrame so it cannot see that; the dump has to
-- name it anyway.
local holder = new("Frame", "SomeOtherAddonHolder", UIParent)
holder.__rect = { left = 1000, right = 1204, top = 810, bottom = 300 }
local otherHeader = new("Frame", "SomeOtherAddonTrackerHeader", holder)
otherHeader.__rect = { left = 1000, right = 1204, top = 810, bottom = 794 }
local otherText = otherHeader:CreateFontString(nil, "ARTWORK")
otherText:SetText("Objectives (1)")
ns.trackers.watch.holderFrame = holder

before = #log
SlashCmdList["HEROPANEL"]("dump")
local neighbours = table.concat(log, "\n", before + 1)
check(string.find(neighbours, "SomeOtherAddonHolder", 1, true) ~= nil,
    "/hp dump should name the holder")
check(string.find(neighbours, "Objectives %(1%)") ~= nil,
    "/hp dump should find text another addon draws around the tracker, got:\n" .. neighbours)
check(string.find(neighbours, "SomeOtherAddonTrackerHeader", 1, true) ~= nil,
    "/hp dump should name the frame that owns that text")
ns.trackers.watch.holderFrame = nil

-- An error anywhere in the addon must reach the player, not just the debug log.
ns.DEBUG = false
local exploded = false
ns:On("HEROPANEL_TEST_EXPLODE", function() exploded = true; error("boom") end)
before = #log
ns:Fire("HEROPANEL_TEST_EXPLODE")
check(exploded, "the test handler should have run")
local loud = table.concat(log, "\n", before + 1)
check(string.find(loud, "boom", 1, true) ~= nil, "a handler error must be reported with debug off")
ns.DEBUG = true

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

for _, line in ipairs(log) do
    -- the deliberate one below is the point of the reporter test
    if string.find(line, "error", 1, true)
       and not string.find(line, "HEROPANEL_TEST_EXPLODE", 1, true) then
        fail("runtime: " .. line)
    end
end

if #failures > 0 then
    print("FAILURES (" .. #failures .. "):")
    for _, f in ipairs(failures) do print("  - " .. f) end
    print("\n--- chat log ---")
    for _, l in ipairs(log) do print("  " .. l) end
    os.exit(1)
end

print("all checks passed (" .. #log .. " chat/debug lines)")
