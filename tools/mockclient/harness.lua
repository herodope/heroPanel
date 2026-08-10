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
-- The mock accepts every path, which would mean heroPanel's shipped glyph art
-- always loads and its block fallback was never once exercised. HP_NOMEDIA
-- fails the addon's own media the way a client that cannot read .tga would.
local NOMEDIA = os.getenv("HP_NOMEDIA")

function methods:SetTexture(path)
    if NOMEDIA and path and string.find(path, "\\media\\", 1, true) then return false end
    self.__texture = path
    return true
end
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
function methods:GetNumPoints() return #self.__points end
function methods:GetPoint(index)
    local p = self.__points[index or 1]
    if not p then return nil end
    return p.point, p.relTo, p.relPoint, p.x, p.y
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
            -- An anchor target's coordinates are in *its* scale, the offsets
            -- are in the anchored object's, and the result is in the object's.
            -- Ignoring that made every frame look as though it shared one
            -- coordinate space, which is the bug this mock most needs to be
            -- able to reproduce.
            local targetScale = (p.relTo and p.relTo.GetEffectiveScale
                and p.relTo:GetEffectiveScale()) or 1
            local ownScale = (obj.GetEffectiveScale and obj:GetEffectiveScale()) or 1
            local px = (ax * targetScale) / ownScale + p.x
            local py = (ay * targetScale) / ownScale + p.y
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

    -- A FontString with no explicit size measures itself, the way the client
    -- does. Without this, one anchored only by TOPRIGHT - which is what
    -- right-aligning a count looks like - can resolve no edge but its own.
    local width, height = obj.__width, obj.__height
    if obj.__kind == "FontString" then
        width  = width  or obj:GetStringWidth()
        height = height or (obj.__font and obj.__font[2]) or 12
    end

    if left and not right and width  then right  = left + width end
    if right and not left and width  then left   = right - width end
    if top and not bottom and height then bottom = top - height end
    if bottom and not top and height then top    = bottom + height end

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

-- The tracker's own background art: on WatchFrame itself, overhanging the top
-- edge and running the height of the panel. This is what was actually left on
-- the live client, and it evaded two guards for two different reasons - it is
-- the root's own region, so header-frame promotion skips it, and its top edge
-- is *above* the tracker's, so a top-inside-the-band test threw it out for
-- being too high. Only overlapping the band catches it.
local trackerArt = WatchFrame:CreateTexture(nil, "BACKGROUND")
trackerArt:SetTexture("Interface\\QuestFrame\\ObjectiveTracker")
trackerArt.__rect = { left = 1003, right = 1300, top = 813, bottom = 727 }

-- The quest item button. Parented to WatchFrame rather than to the line it
-- belongs to, and anchored across to that line's text - which is how this
-- client keeps it, and why a scan that only followed the quest lines never
-- found it.
local questItem = new("Button", "WatchFrameItem1", WatchFrame)
questItem.__level = 3
questItem:SetWidth(26)
questItem:SetHeight(26)
questItem:Hide()

local WatchFrameLines = new("Frame", "WatchFrameLines", WatchFrame)
WatchFrameLines.__level = 3
WatchFrameLines.__rect = { left = 1000, right = 1204, top = 780, bottom = 300 }

-- A quest POI button, parented to the line container rather than to the
-- tracker or to the line it points at. This is where the live client keeps it
-- - /framestack named it poiWatchFrameLines3_1 - and it is a level below both
-- of the places earlier versions of the tuck went looking.
local poiButton = new("Button", "poiWatchFrameLines3_1", WatchFrameLines)
poiButton.__level = 4
poiButton:SetWidth(22)
poiButton:SetHeight(22)
poiButton:Hide()

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

    -- The turn-in question mark and its icon border. The tracker shows these
    -- when a quest becomes ready to hand in, so they start hidden: heroPanel
    -- has to fade art that appears long after it first saw the line.
    -- Anchored rather than given a fixed rect, because where it ends up is the
    -- whole point: it hangs off the *left* of the line's text, which is outside
    -- the panel, since the panel's left edge is inset from the tracker's.
    local statusIcon = line:CreateTexture(nil, "OVERLAY")
    statusIcon:SetTexture("Interface\\QuestFrame\\AutoQuestIcon")
    statusIcon:SetWidth(16)
    statusIcon:SetHeight(16)
    statusIcon:SetPoint("TOPRIGHT", line, "TOPLEFT", -60, 0)
    statusIcon:Hide()
    line.__statusIcon = statusIcon

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
    check(plate:GetWidth() == 204 + 34 + 14,
        "plate width follows the tracker plus its padding: got " .. tostring(plate:GetWidth()))

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
check(trackerArt:GetAlpha() == 0,
    "the tracker's own art drawn through the band should be faded, got "
    .. tostring(trackerArt:GetAlpha()))

-- The other half of widening the band to overlap: quest lines are drawn below
-- it and are a line tall, so none of them may be caught by it. If this ever
-- fails the band is eating content, which is far worse than leaving art on
-- screen.
for i = 1, #trackerLines do
    check(trackerLines[i].__text:GetAlpha() == 1,
        "quest line " .. i .. " must not be faded by the header band")
end

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

-- The count is taken out of the tracker's string and drawn right-aligned in a
-- region of heroPanel's own, which is what the design asks for. The label that
-- is left keeps its separator stripped.
check(trackerLines[2].__text:GetText() == "Dire wolves slain",
    "the count should be taken out of the line, got " .. tostring(trackerLines[2].__text:GetText()))
check(trackerLines[5].__text:GetText() == "Iron ore collected",
    "a completed line's count should come out too, got " .. tostring(trackerLines[5].__text:GetText()))

local overlay = ns.Skin.GetOverlay()
local counterText = {}
for _, region in ipairs(overlay and overlay.__regions or {}) do
    if region.__kind == "FontString" and region:IsShown() then
        counterText[region:GetText() or ""] = region
    end
end
check(counterText["6/8"] ~= nil, "the count should be drawn in its own region")
check(counterText["12/12"] ~= nil, "a completed count should be drawn too")
check(colourOf(counterText["6/8"] or trackerLines[1].__text) == "E9E9ED",
    "an outstanding count takes the count highlight")
check(colourOf(counterText["12/12"] or trackerLines[1].__text) == "79C68D",
    "a completed count reads in the done colour")

-- Right-aligned means against the panel's right edge, not the line's end.
local countRight = counterText["6/8"] and counterText["6/8"]:GetRight()
check(countRight ~= nil and math.abs(countRight - (plate:GetRight() - 14)) < 0.01,
    "the count should sit against the panel's right edge, got " .. tostring(countRight))
check(trackerLines[5].__dash:GetAlpha() == 0, "completed objective's dash should be faded for the check glyph")
check(trackerLines[7].__dash:GetAlpha() == 1, "text objective keeps its dash")

-- Art the tracker hangs off a quest line is brought back inside the panel.
--
-- It only appears once a quest is ready to turn in, which is long after
-- heroPanel first saw that line, so showing it now is the case that matters.
local icon = trackerLines[1].__statusIcon
check(icon:GetLeft() < plate:GetLeft(), "the icon should start outside the panel")

icon:Show()
ns.Skin.Refresh("quest became ready")
tick(); tick()

check(icon:GetLeft() >= plate:GetLeft() and icon:GetRight() <= plate:GetRight(),
    "line art should be tucked inside the panel, got left "
    .. tostring(icon:GetLeft()) .. " panel left " .. tostring(plate:GetLeft()))
-- Inside the panel's content box, not merely inside the panel: the two differ
-- by the padding, and art sitting in that margin reads as outside the skin.
check(math.abs(icon:GetLeft() - (plate:GetLeft() + 4)) < 0.01,
    "it should sit in the panel's left margin, beside the title, got "
    .. tostring(icon:GetLeft() - plate:GetLeft()) .. " in from the panel")

-- ...and having been tucked there, it must read as settled, or every refresh
-- would move it again.
ns.Skin.Refresh("second pass over a tucked icon")
tick(); tick()
check(math.abs(icon:GetLeft() - (plate:GetLeft() + 4)) < 0.01,
    "a tucked icon must stay put on the next pass, got "
    .. tostring(icon:GetLeft() - plate:GetLeft()) .. " in from the panel")

-- Its size has to survive being re-anchored: something anchored by two corners
-- loses its size the moment its points are cleared.
check(icon:GetWidth() == 16 and icon:GetHeight() == 16,
    "the icon should keep its size, got " .. tostring(icon:GetWidth())
    .. "x" .. tostring(icon:GetHeight()))

-- ...and it stays on its own row rather than being stacked somewhere generic.
check(math.abs(icon:GetTop() - trackerLines[1].__text:GetTop()) < 0.01,
    "the icon should stay level with its line, got " .. tostring(icon:GetTop())
    .. " against " .. tostring(trackerLines[1].__text:GetTop()))

-- An object in a different scale chain from the panel.
--
-- This is what the live client does: the line container carries a scale of its
-- own, so a POI button sits at effective 0.64 against a panel at 0.71. Its
-- GetLeft then reads as comfortably inside the panel's range while on screen it
-- is off the panel's left edge, and comparing the two directly compares two
-- different coordinate spaces.
-- The offset is chosen so the item lands at own-space 1100..1126, numerically
-- inside the panel's 986..1218, while at half scale its screen span is 550..563
-- and nowhere near the panel's 986..1218 pixels. An object merely outside in
-- both spaces does not test anything: it gets tucked either way, which is what
-- a first version of this check did.
questItem:SetScale(0.5)
questItem:ClearAllPoints()
questItem:SetPoint("TOPRIGHT", trackerLines[4], "TOPLEFT", -894, 0)
questItem:Show()

local itemScale = questItem:GetEffectiveScale()
local panelScale = plate:GetEffectiveScale()
check(math.abs(itemScale - panelScale) > 0.01, "the two must be in different scale chains to be a test")
check(questItem:GetLeft() > plate:GetLeft() and questItem:GetRight() < plate:GetRight(),
    "in its own units the item must look inside the panel, got "
    .. tostring(questItem:GetLeft()) .. ".." .. tostring(questItem:GetRight()))
check(questItem:GetLeft() * itemScale < plate:GetLeft() * panelScale,
    "on screen it must actually be outside, got "
    .. tostring(questItem:GetLeft() * itemScale))

ns.Skin.Refresh("scaled item appeared")
tick(); tick()

check(questItem:GetLeft() * itemScale >= plate:GetLeft() * panelScale,
    "a scaled object must be judged on screen, not in its own units - got screen left "
    .. tostring(questItem:GetLeft() * itemScale)
    .. " panel " .. tostring(plate:GetLeft() * panelScale))

questItem:SetScale(1)
questItem:Hide()

-- The quest item button, which hangs off the tracker rather than off the line
-- it points at. Same treatment, reached by a different route.
questItem:ClearAllPoints()
questItem:SetPoint("TOPRIGHT", trackerLines[4], "TOPLEFT", -40, 0)
questItem:Show()
check(questItem:GetLeft() < plate:GetLeft(), "the quest item should start outside the panel")

ns.Skin.Refresh("quest item appeared")
tick(); tick()

check(questItem:GetLeft() >= plate:GetLeft() and questItem:GetRight() <= plate:GetRight(),
    "a quest item on the tracker should be tucked in too, got left "
    .. tostring(questItem:GetLeft()) .. " panel left " .. tostring(plate:GetLeft()))
check(questItem:GetWidth() == 26 and questItem:GetHeight() == 26,
    "the quest item should keep its size, got " .. tostring(questItem:GetWidth()))

-- The tracker's own big furniture must not be dragged in with it.
check(WatchFrameLines:GetLeft() == 1000,
    "the line container must not be tucked, got " .. tostring(WatchFrameLines:GetLeft()))
check(collapseBtn:GetLeft() == 1186,
    "the collapse button is already inside and must not move, got "
    .. tostring(collapseBtn:GetLeft()))

questItem:Hide()

-- ...and the POI button, which hangs off the line container - a level below
-- both of the places the earlier, narrower versions of this searched.
poiButton:ClearAllPoints()
poiButton:SetPoint("TOPRIGHT", trackerLines[6], "TOPLEFT", -50, 0)
poiButton:Show()
check(poiButton:GetLeft() < plate:GetLeft(), "the POI button should start outside the panel")

ns.Skin.Refresh("poi button appeared")
tick(); tick()

check(poiButton:GetLeft() >= plate:GetLeft() and poiButton:GetRight() <= plate:GetRight(),
    "a POI button under the line container should be tucked in, got left "
    .. tostring(poiButton:GetLeft()) .. " panel left " .. tostring(plate:GetLeft()))
check(poiButton:GetWidth() == 22 and poiButton:GetHeight() == 22,
    "the POI button should keep its size, got " .. tostring(poiButton:GetWidth()))

-- Text is never moved, whatever else the walk touches.
check(trackerLines[6].__text:GetLeft() == 1010,
    "quest text must not be tucked, got " .. tostring(trackerLines[6].__text:GetLeft()))

-- The walk has to be able to say what it saw and what it decided. Three
-- attempts at this icon were wrong about where it lived, and from the outside
-- each failure looked identical: nothing moved.
-- Interrogating one frame by name. The wide reports sort by position and
-- truncate, so the object being chased falls off the end; once /framestack has
-- named it, the question is narrow and deserves a narrow tool.
local frameLogFrom = #log
SlashCmdList["HEROPANEL"]("frame poiWatchFrameLines3_1")
local frameReport = table.concat(log, "\n", frameLogFrom + 1)
check(string.find(frameReport, "poiWatchFrameLines3_1", 1, true) ~= nil,
    "/hp frame should name the frame it was asked about")
check(string.find(frameReport, "parents:", 1, true) ~= nil,
    "/hp frame should report the parent chain, got:\n" .. frameReport)
check(string.find(frameReport, "on screen", 1, true) ~= nil,
    "/hp frame should convert to screen pixels, since /framestack reports those")

frameLogFrom = #log
SlashCmdList["HEROPANEL"]("frame NoSuchFrameName")
check(string.find(table.concat(log, "\n", frameLogFrom + 1), "no frame called", 1, true) ~= nil,
    "/hp frame should say so when the name resolves to nothing")

local tuckLogFrom = #log
SlashCmdList["HEROPANEL"]("dump")
local tuckDump = table.concat(log, "\n", tuckLogFrom + 1)
check(string.find(tuckDump, "tuck walk", 1, true) ~= nil,
    "/hp dump should report what the tuck walk saw")
check(string.find(tuckDump, "poiWatchFrameLines3_1", 1, true) ~= nil,
    "the tuck report must name what it moved, got:\n" .. tuckDump)

poiButton:Hide()

-- Something already inside the panel is left exactly where the tracker put it.
local inside = trackerLines[3].__statusIcon
inside:ClearAllPoints()
inside:SetPoint("TOPLEFT", trackerLines[3], "TOPLEFT", 4, 0)
inside:Show()
local insideLeft = inside:GetLeft()
ns.Skin.Refresh("icon already inside")
tick(); tick()
check(inside:GetLeft() == insideLeft,
    "art already inside the panel must not be moved, got " .. tostring(inside:GetLeft())
    .. " was " .. tostring(insideLeft))
inside:Hide()

-- The tracker's own header text must not come back from the line walk as a
-- quest title. In minimal mode the badge below counts blocks, so a phantom
-- block shows up there too; this says outright which mistake was made.
check(colourOf(nativeHeaderText) ~= "E7C67C",
    "the tracker's header text was styled as a quest title by the line walk")

-- Fonts may grow past what the tracker measured, but only so far. Clamping to
-- the original meant the objective size - half a point under the base - could
-- only ever come out smaller than Blizzard's, so the skin made its own text
-- harder to read than the text it replaced.
local _, titleSize = trackerLines[1].__text:GetFont()
local _, lineSize  = trackerLines[2].__text:GetFont()
check(titleSize == 13.5, "title font should be base + 0.5, got " .. tostring(titleSize))
check(lineSize == 12.5, "objective font should be base - 0.5, got " .. tostring(lineSize))

-- ...and the bound holds however large the config goes. Unbounded growth would
-- run lines into each other, since the tracker placed them on its own pitch.
local restoreSize = ns.db.font.size
SlashCmdList["HEROPANEL"]("font 20")
tick(); tick()
local _, hugeTitle = trackerLines[1].__text:GetFont()
local _, hugeLine  = trackerLines[2].__text:GetFont()
check(hugeTitle == 13 + 2, "title font must stop 2 past the original 13, got " .. tostring(hugeTitle))
check(hugeLine == 12 + 2, "objective font must stop 2 past the original 12, got " .. tostring(hugeLine))
SlashCmdList["HEROPANEL"]("font " .. tostring(restoreSize))
tick(); tick()

-- Header badge
local badge
for _, region in ipairs(plate and plate.__regions or {}) do
    if region.__kind == "FontString" and region:GetText() == "3" then badge = region end
end
check(badge ~= nil, "count badge should read 3")

-- Where the caret sits.
--
-- It used to be anchored to Blizzard's collapse button, which put it wherever
-- the tracker kept that button - on the live client seven pixels below the
-- header row's centre, hard against the divider and reading as though it had
-- slipped into the body. It belongs to heroPanel's header, so it is placed
-- against the panel, and that is what this pins down.
local caretGlyph
for _, child in ipairs(plate and plate.__children or {}) do
    if child.shape == "caretUp" or child.shape == "caretDown" then caretGlyph = child end
end
check(caretGlyph ~= nil, "the header caret should be a child of the panel")

if caretGlyph then
    local HEADER_PAD_X, HEADER_HEIGHT = 13, 30
    check(math.abs(caretGlyph:GetRight() - (plate:GetRight() - HEADER_PAD_X)) < 0.01,
        "the caret should sit HEADER_PAD_X in from the panel's right edge, got "
        .. tostring(plate:GetRight() - caretGlyph:GetRight()))

    local caretMid = (caretGlyph:GetTop() + caretGlyph:GetBottom()) / 2
    check(math.abs(caretMid - (plate:GetTop() - HEADER_HEIGHT / 2)) < 0.01,
        "the caret should be centred in the header row, got "
        .. tostring(plate:GetTop() - caretMid) .. " from the top")

    -- The symptom that started this: a caret tall enough or low enough to
    -- cross the divider reads as belonging to the body, not the header.
    check(caretGlyph:GetBottom() > plate:GetTop() - HEADER_HEIGHT,
        "the caret must stay above the header divider")

    -- A texture path has to survive the slash dispatcher exactly as typed. It
    -- used to fold the whole input to lower case, which is harmless for the
    -- keyword commands and destroys Interface\AddOns\... outright.
    local probePath = "Interface\\AddOns\\WeakAuras\\Media\\Textures\\Circle_White.tga"
    SlashCmdList["HEROPANEL"]("texture " .. probePath)
    check(caretGlyph.artPath == probePath,
        "a texture path must reach the addon as typed, got " .. tostring(caretGlyph.artPath))
    check(caretGlyph.art:GetTexture() == probePath, "the test texture should be set")

    -- ...and a refresh must not wipe the test out from under whoever is
    -- looking at it.
    ns.Skin.Refresh("while testing a texture")
    tick(); tick()
    check(caretGlyph.art:GetTexture() == probePath,
        "a refresh must leave the test texture alone, got " .. tostring(caretGlyph.art:GetTexture()))

    SlashCmdList["HEROPANEL"]("texture")
    tick(); tick()
    check(caretGlyph.shape == "caretUp" or caretGlyph.shape == "caretDown",
        "clearing the test should put the caret back, got " .. tostring(caretGlyph.shape))
end

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

    -- Shipped art when the client can read it, blocks when it cannot. Exactly
    -- one of the two may be visible, and both have to draw something.
    local blocksShown = 0
    for _, part in ipairs(glyph.parts) do
        if part:IsShown() then blocksShown = blocksShown + 1 end
    end

    if glyph.usingArt then
        check(glyph.art:IsShown(), name .. " claims art but does not show it")
        check(glyph.art:GetTexture() ~= nil, name .. " art has no texture")
        check(blocksShown == 0, name .. " draws art and blocks at once")

        -- One spelling per glyph, with nothing to fall through to. A chain
        -- meant a green square said nothing about which file produced it.
        check(string.sub(glyph.art:GetTexture() or "", -4) == ".tga",
            name .. " should come from its .tga, got " .. tostring(glyph.art:GetTexture()))
    else
        check(not glyph.art:IsShown(), name .. " fell back to blocks but still shows art")
        check(blocksShown == #hp.GLYPHS[name],
            name .. " drew " .. tostring(blocksShown) .. " of "
            .. tostring(#hp.GLYPHS[name]) .. " blocks")

        local boxLeft, boxRight = glyph:GetLeft(), glyph:GetRight()
        local boxTop, boxBottom = glyph:GetTop(), glyph:GetBottom()

        local minLeft, maxRight, maxTop, minBottom
        for _, part in ipairs(glyph.parts) do
            if part:IsShown() then
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

        -- The grid scales to fit, so the longer axis must reach the full 12px.
        -- A shape rendering at a few pixels inside a 12px box is what getting
        -- the unit maths wrong looks like, and every other check here passes.
        local reach = math.max(maxRight - minLeft, maxTop - minBottom)
        check(reach >= 11.99, name .. " does not fill its box, longest axis " .. tostring(reach))
    end
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

-- Smallest shape then largest, so the swap is guaranteed to build blocks that
-- have never been coloured. Chosen by size rather than named, because which
-- shape has the most cells is a detail of how they are drawn and has already
-- changed once.
local fewest, most
for _, name in ipairs(shapeNames) do
    if not fewest or #hp.GLYPHS[name] < #hp.GLYPHS[fewest] then fewest = name end
    if not most   or #hp.GLYPHS[name] > #hp.GLYPHS[most]   then most   = name end
end
check(#hp.GLYPHS[most] > #hp.GLYPHS[fewest], "the shape swap must add blocks to be a test")

-- Forcing a route. Which one is live is invisible in a screenshot and the two
-- look very different, so being able to pin it is how a bad glyph gets
-- diagnosed in one step rather than three.
local restoreGlyphMode = ns.db.glyph.mode

SlashCmdList["HEROPANEL"]("glyphs blocks")
glyph:SetShape("caretUp")
check(not glyph.usingArt, "/hp glyphs blocks must force the drawn shapes")
check(not glyph.art:IsShown(), "forced blocks must not leave art showing")

SlashCmdList["HEROPANEL"]("glyphs art")
glyph:SetShape("caretUp")
check(glyph.usingArt, "/hp glyphs art must force the shipped art")
check(glyph.art:IsShown(), "forced art must show it")

-- Forcing one file at a time, and reporting which one is on screen. Two files
-- can fail identically here - the client draws green for anything it resolves
-- and will not decode - so the mode has to be able to pin a single file and
-- the addon has to be able to name it.
SlashCmdList["HEROPANEL"]("glyphs tga")
glyph:SetShape("caretUp")
check(glyph.usingArt, "/hp glyphs tga must use the art")
check(string.sub(glyph.artPath or "", -4) == ".tga",
    "/hp glyphs tga must pin that file, got " .. tostring(glyph.artPath))

SlashCmdList["HEROPANEL"]("glyphs " .. restoreGlyphMode)
tick(); tick()

glyph:SetShape(fewest)
glyph:SetColor(hp.HexToRGB("#75798C"))

if glyph.usingArt then
    check(glyphHex(glyph.art) == "75798C",
        "glyph art colour should be exact, got " .. glyphHex(glyph.art))
    glyph:SetShape(most)
    check(glyphHex(glyph.art) == "75798C",
        "art should keep the glyph's colour across a shape change, got " .. glyphHex(glyph.art))
else
    check(glyphHex(glyph.parts[1]) == "75798C",
        "glyph colour should be exact, got " .. glyphHex(glyph.parts[1]))

    glyph:SetShape(most)
    local lastBlock = glyph.parts[#hp.GLYPHS[most]]
    check(lastBlock ~= nil, "the shape change should have built the extra blocks")
    check(glyphHex(lastBlock) == "75798C",
        "a block built by a shape change should take the glyph's colour, got "
        .. glyphHex(lastBlock))
end

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
check(trackerLines[1].__statusIcon:GetLeft() < plate:GetLeft(),
    "art tucked into the panel should be back where the tracker had it, got left "
    .. tostring(trackerLines[1].__statusIcon:GetLeft()))
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

-- Art drawn over the panel by a frame that is neither the tracker nor heroPanel
-- and that draws nothing in the header band. The band dump cannot see it by
-- construction - it only looks at regions in the band and at the frames that
-- draw there - and that blind spot is the whole reason /hp probe exists.
local strayOwner = new("Frame", "SomeOtherAddonDecor", UIParent)
strayOwner.__rect = { left = 1000, right = 1204, top = 795, bottom = 700 }
local strayArt = strayOwner:CreateTexture(nil, "ARTWORK")
strayArt.__rect = { left = 1000, right = 1204, top = 794, bottom = 790 }
strayArt:SetTexture("Interface\\SomeAddon\\GoldSwoosh")

before = #log
SlashCmdList["HEROPANEL"]("probe")
local probed = table.concat(log, "\n", before + 1)
check(string.find(probed, "SomeOtherAddonDecor", 1, true) ~= nil,
    "/hp probe should name whatever draws over the panel, got:\n" .. probed)
check(string.find(probed, "GoldSwoosh", 1, true) ~= nil,
    "/hp probe should report the texture path that names the art")

-- heroPanel's own regions are the majority - the panel is solid blocks and the
-- glyphs are dozens more - so by default they are counted and not listed. Left
-- in, they would fill the listing before it reached what is being looked for.
check(string.find(probed, "ours", 1, true) == nil,
    "/hp probe should not list heroPanel's own regions by default, got:\n" .. probed)
check(string.find(probed, "not listed", 1, true) ~= nil,
    "/hp probe should say how many of its own regions it left out, got:\n" .. probed)

-- ...but "that streak is ours" is an answer worth being able to get.
before = #log
SlashCmdList["HEROPANEL"]("probe all")
local probedAll = table.concat(log, "\n", before + 1)
check(string.find(probedAll, "ours", 1, true) ~= nil,
    "/hp probe all should mark heroPanel's own regions, got:\n" .. probedAll)
check(string.find(probedAll, "SomeOtherAddonDecor", 1, true) ~= nil,
    "/hp probe all should still name foreign art")

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
