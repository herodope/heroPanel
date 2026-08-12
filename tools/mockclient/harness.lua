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
-- Separate from the mouse on purpose: the panel's scroll catcher takes the
-- wheel without taking clicks, so a drag still reaches the tracker under it.
function methods:EnableMouseWheel(v) self.__wheel = v end
function methods:IsMouseWheelEnabled() return self.__wheel end
function methods:SetMovable(v) self.__movable = v end
function methods:StartMoving() end
function methods:StopMovingOrSizing() end
function methods:RegisterForDrag() end
function methods:RegisterForClicks() end
function methods:SetClampedToScreen() end
function methods:SetToplevel(v) self.__toplevel = v end

-- Slider. Enough of one to drive the options panel's sliders: a value that is
-- clamped and stepped the way the client's is, and an OnValueChanged that fires
-- on every set - including the ones the panel makes itself while syncing from
-- the store, which is the case its re-entry guard exists for.
function methods:SetOrientation(o) self.__orientation = o end
function methods:SetMinMaxValues(minValue, maxValue)
    self.__min, self.__max = minValue, maxValue
end
function methods:GetMinMaxValues() return self.__min, self.__max end
function methods:SetValueStep(step) self.__step = step end
function methods:SetValue(value)
    local minValue, maxValue = self.__min or 0, self.__max or 100
    if value < minValue then value = minValue end
    if value > maxValue then value = maxValue end
    if self.__step and self.__step > 0 then
        value = math.floor(value / self.__step + 0.5) * self.__step
    end
    self.__value = value
    local fn = self.__scripts.OnValueChanged
    if fn then fn(self, value) end
end
function methods:GetValue() return self.__value or self.__min or 0 end
function methods:SetThumbTexture(path)
    self.__thumb = self:CreateTexture()
    self.__thumb:SetTexture(path)
end
function methods:GetThumbTexture() return self.__thumb end
-- ScrollFrame. The options window's body lives in one, because a ScrollFrame is
-- the only thing on this client that clips its children. The mock does not
-- clip anything, so this is bookkeeping: enough for the panel to attach a
-- child, size a viewport and scroll it, and for a test to read back where it
-- got to.
function methods:SetScrollChild(child)
    self.__scrollChild = child
    child.__parent = self
end
function methods:GetScrollChild() return self.__scrollChild end
function methods:SetVerticalScroll(v) self.__vScroll = v end
function methods:GetVerticalScroll() return self.__vScroll or 0 end
function methods:SetHorizontalScroll(v) self.__hScroll = v end
function methods:GetHorizontalScroll() return self.__hScroll or 0 end
function methods:GetVerticalScrollRange()
    local child = self.__scrollChild
    if not child then return 0 end
    return math.max(0, (child:GetHeight() or 0) - (self:GetHeight() or 0))
end

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

-- Paths that never load, in every mode.
--
-- GetSpellInfo handing back an icon path is not a promise the client can draw
-- it: Ascension's custom affixes return paths that resolve to nothing, and
-- SetTexture does not complain - it just leaves the texture blank. A blank
-- texture on a shown, mouse-enabled button is an invisible icon that still
-- answers the cursor with a tooltip, which is what turned up on the live
-- client. Modelled here so the guard against it is actually exercised.
local UNLOADABLE = { ["Interface\\Icons\\affix_broken"] = true }

function methods:SetTexture(path)
    if NOMEDIA and path and string.find(path, "\\media\\", 1, true) then return false end
    if path and UNLOADABLE[path] then return false end
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
function methods:SetShadowColor(r, g, b, a) self.__shadowColor = { r, g, b, a } end
function methods:SetShadowOffset(x, y) self.__shadowOffset = { x, y } end
function methods:GetShadowColor()
    local c = self.__shadowColor
    if not c then return nil end
    return c[1], c[2], c[3], c[4]
end
function methods:GetShadowOffset()
    local o = self.__shadowOffset
    if not o then return 0, 0 end
    return o[1], o[2]
end
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

--------------------------------------------------------------------------------
-- 5.1 and FrameXML globals the embedded libraries expect
--
-- heroPanel's own files use plain Lua and the frame API, so the mock never
-- needed these. LibStub, CallbackHandler and LibSharedMedia are ordinary
-- WoW libraries and do: getfenv and the bit library are 5.1 and are gone in
-- the 5.3 fengari runs on, and strmatch / geterrorhandler / GetLocale are
-- FrameXML's rather than Lua's.
--------------------------------------------------------------------------------

if not getfenv then
    -- The libraries only ever call getfenv(0), meaning "the globals table".
    function getfenv() return _G end
end

if not bit then
    -- Only band is used, and only on the locale mask. Written with arithmetic
    -- rather than 5.3's & so this file stays loadable under 5.1 as well.
    bit = {
        band = function(a, b)
            local result, place = 0, 1
            while a > 0 and b > 0 do
                if (a % 2 == 1) and (b % 2 == 1) then result = result + place end
                a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
            end
            return result
        end,
    }
end

-- CallbackHandler builds its dispatchers with loadstring, which 5.1 has and
-- 5.3 renamed. Only reached once a callback actually fires, so it stayed hidden
-- until the harness registered a font.
loadstring = loadstring or load

strmatch = strmatch or string.match
strupper = strupper or string.upper
strlower = strlower or string.lower
strfind  = strfind  or string.find
strsub   = strsub   or string.sub
tinsert  = tinsert  or table.insert
tremove  = tremove  or table.remove

function geterrorhandler()
    return function(err) fail("library error: " .. tostring(err)) end
end

function GetLocale() return "enUS" end

-- Escape-to-close registry. Real, so the options panel adding itself twice
-- across a rebuild would be visible rather than silent.
UISpecialFrames = {}

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
-- The owner is tracked rather than ignored, because "whose tooltip is this?"
-- is a question heroPanel has to ask: a frame hidden while the cursor is on it
-- never gets its OnLeave, so whatever opened the tooltip has to take it down
-- on the way out or it stays on screen over nothing.
GameTooltip.SetOwner = function(self, owner) self.__owner = owner; self:Show() end
GameTooltip.IsOwned  = function(self, frame) return self.__owner == frame end
GameTooltip.AddLine  = function() end

GameFontNormal = new("Font", "GameFontNormal", nil)
GameFontNormal.__font = { "Fonts\\FRIZQT__.TTF", 12, "" }

UIPARENT_MANAGED_FRAME_POSITIONS = { WatchFrame = {} }
function UIParent_ManageFramePositions() end

-- Blizzard's interface options, enough for heroPanel to register a category in
-- and for the category's own OnShow to be driven. MINIMAL leaves all of it out,
-- which is the client where /hp is the only way in.
if not MINIMAL then
    InterfaceOptionsFrame = new("Frame", "InterfaceOptionsFrame", UIParent)
    InterfaceOptionsFrame:Hide()
    InterfaceOptionsFramePanelContainer = new("Frame", "InterfaceOptionsFramePanelContainer", InterfaceOptionsFrame)

    INTERFACE_CATEGORIES = {}
    function InterfaceOptions_AddCategory(panel)
        table.insert(INTERFACE_CATEGORIES, panel)
    end
end

local combat = false
function InCombatLockdown() return combat end

local now = 0
function GetTime() return now end

local cursorX, cursorY = -1000, -1000
function GetCursorPosition() return cursorX, cursorY end

-- The resize grip drags off the cursor and ends on the button coming back up,
-- because a release outside the grip never reaches its OnMouseUp. Tests set
-- both directly, the same way they already set the cursor for the hover pass.
local mouseDown = {}
function IsMouseButtonDown(button) return mouseDown[button or "LeftButton"] and true or false end

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
local trackerPois  = {}
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
    -- The middle quest is the one being pointed at, so the arrow has a title
    -- above and below it to be put on the wrong row of.
    --
    -- `right` because this is the one title measured against, and it is set
    -- deliberately short of the string drawn in it - 60 pixels of rect around
    -- 110 pixels of text, at the harness's own five pixels a character. That is
    -- the shape the bug was reported in: heroPanel sets the player's font in the
    -- same pass as it places the arrow, so a title laid out by the client at one
    -- size and redrawn at a larger one leaves a rect that has not caught up, and
    -- an arrow measured from that rect lands part-way along the quest name. The
    -- other 180px lines are the opposite case - room to spare around a short
    -- string - so between them the two rules are pinned from both sides.
    { text = "Supplies for the Front",    dash = nil,  top = 720, left = 1010,
      poi = true, right = 1010 + 60 },
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
    text.__rect = { left = def.left + (def.dash and 10 or 0), right = def.right or 1190,
                    top = def.top, bottom = def.top - 12 }
    text.__font = { "Fonts\\FRIZQT__.TTF", def.dash and 12 or 13, "" }

    -- A client that does not expose these parent keys is exactly what the
    -- fallback resolver in Lines.lua is for.
    if not MINIMAL then line.dash, line.text = dash, text end
    line.__dash, line.__text = dash, text

    -- The quest POI button - the directional arrow that says which quest you
    -- are being pointed at. Named, because the name is the only thing that
    -- separates it from the turn-in question mark: same size, same row, both
    -- hanging off the left. It is parented to the *line container* rather than
    -- the line on this client, which is the level two earlier attempts at the
    -- tuck walk missed entirely.
    if def.poi then
        -- Anchored rather than given a fixed rect, because where it ends up is
        -- the whole point. A fixed __rect would have made it unmovable and the
        -- checks below would have passed on an arrow nothing had touched.
        local poi = new("Button", "poiWatchFrameLines" .. i .. "_1", WatchFrameLines)
        poi:SetWidth(16)
        poi:SetHeight(16)
        poi:SetPoint("TOPRIGHT", line, "TOPLEFT", -28, 0)
        line.__poi = poi
        trackerPois[i] = poi
    end

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
-- The Mythic+ tracker
--
-- Shaped after Ascension_MythicPlus's own XML: a MainBlock carrying the level,
-- the clocks and the timer status bar, and an ObjectiveBlock carrying the boss
-- rows. Two things about it are deliberate and are the point of the test:
--
--   * it does not exist at ADDON_LOADED. The real one is created on demand by
--     an addon that may load after heroPanel, so it is built here only once
--     the addon has already booted, and heroPanel has to find it by polling.
--   * EnemyForces is the *last* row in the objective block, below the bosses,
--     which is where Ascension anchors it. The design puts enemy forces above
--     the boss rows, so heroPanel draws its own there and this is what proves
--     it does not simply follow the tracker's order.
--
-- Under HP_MINIMAL there is no C_MythicPlus, so the panel has to read the
-- numbers off the tracker's own widgets instead.
--------------------------------------------------------------------------------

MYTHIC_PLUS_BONUS_LEVEL_PERCENT = { 0.55, 0.4 }

function GetLFGDungeonInfo(id) return "Halls of Reflection" end

-- Eight, because that is what a key on this client can carry, plus one whose
-- icon does not load - the shape of Ascension's own creature and player affixes.
local AFFIX_NAMES = {
    [1001] = "Tyrannical", [1002] = "Bolstering", [1003] = "Volcanic",
    [1004] = "Sanguine",   [1005] = "Necrotic",   [1006] = "Raging",
    [1007] = "Quaking",    [1008] = "Grievous",
    [1099] = "Pack Tactics",
}

-- The one with no usable art.
local AFFIX_BROKEN = 1099

-- Encounter state, which is the authority on whether a boss is down. The
-- tracker's rows are told about a kill before the server has committed it, so
-- what a row holds and what this returns can disagree - that lag is the bug
-- the panel has to see past, and it is modelled here rather than assumed away.
local ENCOUNTERS = {
    [201] = { name = "Falric",        dead = true  },
    [202] = { name = "Marwyn",        dead = false },
    [203] = { name = "The Lich King", dead = false },
}

function GetEncounterInfo(encounterID)
    local e = ENCOUNTERS[encounterID]
    if not e then return nil end
    return e.name, nil, nil, nil, nil, nil, e.dead
end

function GetSpellInfo(spellID)
    local name = AFFIX_NAMES[spellID]
    if not name then return nil end
    -- A real path as far as GetSpellInfo is concerned; UNLOADABLE above is what
    -- decides it will not draw, which is the client's half of the same lie.
    if spellID == AFFIX_BROKEN then return name, "Level 2", "Interface\\Icons\\affix_broken" end
    return name, "Level 2", "Interface\\Icons\\affix_" .. spellID
end

function GetSpellDescription(spellID)
    return AFFIX_NAMES[spellID] and (AFFIX_NAMES[spellID] .. " description") or nil
end

local KEY_TIME_LEFT, KEY_TOTAL_TIME = 1661, 1800   -- 27:41 of 30:00
local TRASH_DEAD, TRASH_REQUIRED    = 84, 100

if not MINIMAL then
    C_MythicPlus = {
        IsKeystoneActive = function() return true end,
        GetActiveKeystoneInfo = function()
            -- activeAffixes are spell IDs; GetSpellInfo turns one into a name
            -- and an icon, which is how the tracker's own affix buttons do it.
            return { keystoneLevel = 12, dungeonID = 668, rewardMultiplier = 1,
                     activeAffixes = { 1001, 1002, 1003 } }
        end,
        GetActiveKeystoneTime  = function() return KEY_TIME_LEFT, KEY_TOTAL_TIME end,
        GetActiveKeystoneTrash = function()
            return { trashDead = TRASH_DEAD, trashRequired = TRASH_REQUIRED }
        end,
    }
end

MythicPlusObjectiveTracker = nil

local mplusRows = {}

local function BuildObjectiveRow(parent, name, label, progress, progressMax, top)
    local row = new("Frame", name, parent)
    row.__rect = { left = 1320, right = 1540, top = top, bottom = top - 12 }

    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetTexture("Interface\\Scenarios\\scenarioicon-combat")
    row.Icon.__rect = { left = 1320, right = 1336, top = top, bottom = top - 12 }

    row.Text = row:CreateFontString(nil, "ARTWORK")
    row.Text:SetText(label)
    row.Text.__rect = { left = 1340, right = 1480, top = top, bottom = top - 12 }
    row.Text.__font = { "Fonts\\FRIZQT__.TTF", 12, "" }

    row.Counter = row:CreateFontString(nil, "ARTWORK")
    row.Counter:SetText(string.format("%d/%d", progress, progressMax))
    row.Counter.__rect = { left = 1500, right = 1540, top = top, bottom = top - 12 }

    row.progress, row.progressMax = progress, progressMax

    -- What ScenarioObjectiveMixin does to a row every time its progress
    -- changes: it reassigns the font object on the text and the counter, which
    -- throws away whatever font and colour anyone else had put there. This is
    -- the behaviour that made heroPanel's boss labels vanish after a kill and
    -- never come back, so the mock has to do it or the fix is untested.
    local function ascensionRestyle(self)
        local done = self.progressMax and self.progress and self.progress >= self.progressMax
        self.Text.__font = { "Fonts\\FRIZQT__.TTF", 12, "" }
        -- PTFontDisable / PTFontHighlight: dark grey on a dark panel is what
        -- "the text disappeared" actually looked like.
        local grey = done and 0.35 or 0.75
        self.Text:SetTextColor(grey, grey, grey, 1)
        self.Counter:SetTextColor(grey, grey, grey, 1)
    end

    function row:SetProgress(progress)
        self.progress = progress
        ascensionRestyle(self)
    end

    function row:SetObjective(label, progress, progressMax)
        self.Text:SetText(label)
        self.progress, self.progressMax = progress, progressMax
        ascensionRestyle(self)
    end

    function row:SetLabel(label) self.Text:SetText(label) end

    table.insert(mplusRows, row)
    return row
end

function CreateMplusTracker()
    local t = new("Frame", "MythicPlusObjectiveTracker", UIParent)
    -- Deliberately far taller than its contents, like WatchFrame above: the
    -- real frame is given a region to draw in rather than shrunk to what it
    -- drew, so a panel sized from the frame instead of from the rows would
    -- reach hundreds of pixels past the last boss line. Ascension's template
    -- sets no strata, so it lands on the default.
    t.__rect  = { left = 1300, right = 1560, top = 600, bottom = 200 }
    t.__level = 1
    MythicPlusObjectiveTracker = t

    t.Header = t:CreateTexture(nil, "ARTWORK")
    t.Header.__rect = { left = 1300, right = 1560, top = 600, bottom = 570 }

    t.HeaderText = t:CreateFontString(nil, "ARTWORK")
    t.HeaderText:SetText("Halls of Reflection")
    t.HeaderText.__rect = { left = 1326, right = 1460, top = 592, bottom = 578 }

    -- The live build's own lock button, top right. It is not in the tracker XML
    -- this was written against, and /framestack on the running client named it,
    -- so it is resolved by parent key and by global name both.
    local lockButton = new("Button", "MythicPlusObjectiveTrackerLockButton", t)
    lockButton.__normal = lockButton:CreateTexture()
    lockButton.GetNormalTexture = function(self) return self.__normal end
    lockButton.__rect = { left = 1526, right = 1546, top = 596, bottom = 576 }
    lockButton:EnableMouse(true)
    t.LockButton = lockButton
    MythicPlusObjectiveTrackerLockButton = lockButton

    t.CollapseExpandButton = new("Button", nil, t)
    t.CollapseExpandButton.__normal = t.CollapseExpandButton:CreateTexture()
    t.CollapseExpandButton.__rect = { left = 1530, right = 1552, top = 594, bottom = 574 }
    t.CollapseExpandButton.GetNormalTexture = function(self) return self.__normal end

    ------------------------------------------------------------------
    -- Main block
    ------------------------------------------------------------------

    local main = new("Frame", "MythicPlusObjectiveTrackerMainBlock", t)
    main.__rect = { left = 1300, right = 1560, top = 560, bottom = 473 }
    t.MainBlock = main

    main.Background = main:CreateTexture(nil, "ARTWORK")
    main.Background.__rect = main.__rect
    main.TimerBarBackground = main:CreateTexture(nil, "BACKGROUND")
    main.TimerBarBackground.__rect = { left = 1310, right = 1550, top = 500, bottom = 486 }

    main.Level = main:CreateFontString(nil, "ARTWORK")
    main.Level:SetText("Level 12")
    main.Level.__rect = { left = 1328, right = 1390, top = 542, bottom = 528 }

    main.TimeLeft = main:CreateFontString(nil, "ARTWORK")
    main.TimeLeft:SetText("27:41")
    main.TimeLeft.__rect = { left = 1328, right = 1390, top = 522, bottom = 502 }

    -- Ascension computes these two from (1 - PERCENT[n]), which is wrong, and
    -- colours them against the notches they do not match. heroPanel does not
    -- read them; they are here so the panel is proven to fade them rather than
    -- leave two stale clocks showing through it.
    main.TimeLeft2 = main:CreateFontString(nil, "ARTWORK")
    main.TimeLeft2:SetText("18:41")
    main.TimeLeft2.__rect = { left = 1400, right = 1440, top = 520, bottom = 506 }

    main.TimeLeft3 = main:CreateFontString(nil, "ARTWORK")
    main.TimeLeft3:SetText("07:41")
    main.TimeLeft3.__rect = { left = 1450, right = 1490, top = 520, bottom = 506 }

    main.BottomRightText = main:CreateFontString(nil, "ARTWORK")
    main.BottomRightText:SetText("100% loot")
    main.BottomRightText.__rect = { left = 1480, right = 1546, top = 500, bottom = 488 }

    local timer = new("Frame", "MythicPlusObjectiveTrackerMainBlockTimer", main)
    timer.__rect = { left = 1318, right = 1542, top = 496, bottom = 483 }
    timer.__min, timer.__max, timer.__value = 0, KEY_TOTAL_TIME, KEY_TIME_LEFT
    timer.GetMinMaxValues = function(self) return self.__min, self.__max end
    timer.GetValue        = function(self) return self.__value end
    timer.__fill          = timer:CreateTexture(nil, "ARTWORK")
    table.remove(timer.__regions)   -- as above: a status bar's fill is not a region
    timer.GetStatusBarTexture = function(self) return self.__fill end
    timer.PlusTwoNotch    = timer:CreateTexture(nil, "OVERLAY")
    timer.PlusThreeNotch  = timer:CreateTexture(nil, "OVERLAY")
    main.Timer = timer

    for i = 1, 5 do
        local affix = new("Button", nil, main)
        affix.__normal = affix:CreateTexture()
        affix.GetNormalTexture = function(self) return self.__normal end
        affix.__rect = { left = 1500 - i * 20, right = 1516 - i * 20, top = 542, bottom = 526 }
        -- The affix template keeps its icon on a child frame, not on the
        -- button's own regions. Fading the four button textures missed it, and
        -- it sat in the panel's top-right corner - which the design has nothing
        -- in - reading as a second control.
        affix.IconFrame = new("Frame", nil, affix)
        affix.IconFrame.__rect = affix.__rect
        affix.__icon = affix.IconFrame:CreateTexture(nil, "ARTWORK")
        affix.__icon:SetTexture("Interface\\Icons\\spell_shadow_shadowbolt")
        main["Affix" .. i] = affix
    end

    ------------------------------------------------------------------
    -- Objective block
    ------------------------------------------------------------------

    local block = new("Frame", "MythicPlusObjectiveTrackerObjectiveBlock", t)
    block.__rect = { left = 1310, right = 1550, top = 471, bottom = 386 }
    t.ObjectiveBlock = block

    -- The encounter IDs the tracker keeps, which is what the panel re-reads
    -- the live state from.
    t.encounters     = { 201, 202, 203 }
    t.finalEncounter = 203

    block.FinalEncounter = BuildObjectiveRow(block, "MplusFinalEncounter",
        "The Lich King", 0, 1, 470)

    block.Encounters = BuildObjectiveRow(block, "MplusEncounters",
        "Defeat additional bosses", 1, 2, 454)
    block.Encounters.isExpanded = true

    -- Ascension's own expand control on the extra-bosses row. heroPanel fades
    -- its art and draws the quest header's chevron over it, so the panel has
    -- one collapse affordance rather than two unrelated ones.
    local expand = new("Button", nil, block.Encounters)
    expand.__normal = expand:CreateTexture()
    expand.GetNormalTexture = function(self) return self.__normal end
    expand.__rect = { left = 1524, right = 1540, top = 454, bottom = 440 }
    block.Encounters.CollapseExpandButton = expand
    function block.Encounters:UpdateSubObjectives() end

    block.Encounters.buttons = {
        BuildObjectiveRow(block.Encounters, "MplusEncounters1", "Falric", 1, 1, 438),
        BuildObjectiveRow(block.Encounters, "MplusEncounters2", "Marwyn", 0, 1, 422),
    }

    -- Level 12, so the champions row is hidden - exactly as the real tracker
    -- leaves it below 14.
    block.Champions = BuildObjectiveRow(block, "MplusChampions", "Champions", 0, 3, 410)
    block.Champions:Hide()

    -- Last, below the bosses, which is where Ascension anchors it.
    block.EnemyForces = BuildObjectiveRow(block, "MplusEnemyForces",
        "Enemy Forces", TRASH_DEAD, TRASH_REQUIRED, 400)

    -- The bar Ascension animates as trash dies.
    --
    -- Two things here are what the animation costs heroPanel. The fill is a
    -- status-bar texture rather than one of the frame's regions, so a walk over
    -- GetRegions never sees it; and Play() writes alpha and shown state
    -- directly, exactly as an alpha animation does, so whatever the skin set
    -- before it ran is gone. Both are modelled rather than described: a fade
    -- that only holds until the first pull is the bug this stands in for.
    local bar = new("Frame", nil, block.EnemyForces)
    bar.__rect  = { left = 1320, right = 1540, top = 396, bottom = 388 }
    bar.__border = bar:CreateTexture()
    bar.__fill   = bar:CreateTexture(nil, "ARTWORK")
    table.remove(bar.__regions)   -- the fill is the bar's own, not one of its regions
    bar.GetStatusBarTexture = function(self) return self.__fill end
    bar.Glow = bar:CreateTexture(nil, "OVERLAY")
    function bar:Play()
        for _, region in ipairs({ self.__fill, self.Glow }) do
            region:Show()
            region:SetAlpha(1)
        end
    end
    block.EnemyForces.StatusBar = bar

    return t
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

-- The load order is read out of the .toc rather than written down here.
--
-- It used to be a list in this file, and that list quietly went stale the
-- moment a file was added to the addon: the new file simply was not loaded, and
-- the run failed somewhere unrelated - a nil where a helper that moved into it
-- used to be - with nothing pointing at the real cause. Reading the manifest
-- means a file the addon loads is a file the harness loads.
--
-- Library paths use backslashes in a .toc and are directories on disk, so they
-- are translated. LibStub and friends are loaded as ordinary chunks with no
-- addon-name/namespace pair, which is how the client loads them too.
--
-- The manifest arrives as a string from run.js: fengari's io library has no
-- `open`, so Lua here can load a chunk but cannot read a text file.
local function ReadTocFiles()
    if type(HP_TOC) ~= "string" then
        error("HP_TOC was not set - run this through run.js, not directly")
    end

    local list = {}
    for line in HP_TOC:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:match("^#") and line:match("%.lua$") then
            table.insert(list, (line:gsub("\\", "/")))
        end
    end
    return list
end

local ns = {}
for _, file in ipairs(ReadTocFiles()) do
    local chunk, err = loadfile(ADDON .. file)
    if not chunk then error("load " .. file .. ": " .. tostring(err)) end
    if file:match("^libs/") then
        chunk()
    else
        chunk("heroPanel", ns)
    end
end

HEROPANEL_DB = { debug = true }

fire("ADDON_LOADED", "heroPanel")
tick(); tick()
fire("PLAYER_LOGIN")
tick(); tick()
fire("PLAYER_ENTERING_WORLD")
tick(); tick(); tick()

-- The Mythic+ tracker turns up late, which is the case Phase 1's poll exists
-- for. Nothing fires an event to announce it: heroPanel has to notice on its
-- own, and the skin has to go on from the same discovery point.
local mplusTracker = CreateMplusTracker()
tick(0.6); tick(0.6); tick(); tick()

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
--
-- Stated against the configured base rather than against the numbers that base
-- happened to produce. These were literals - 13.5 and 12.5 - and changing the
-- default from 13 to 12 broke both, which is a test measuring the default
-- rather than the offsets it is supposed to be checking.
local _, titleSize = trackerLines[1].__text:GetFont()
local _, lineSize  = trackerLines[2].__text:GetFont()
check(titleSize == ns.GetFontSize(0, "watchTitle"),
    "title font should be the quest-name size (" .. tostring(ns.GetFontSize(0, "watchTitle"))
    .. "), got " .. tostring(titleSize))
check(lineSize == ns.GetFontSize(0, "watchBody"),
    "objective font should be the description size (" .. tostring(ns.GetFontSize(0, "watchBody"))
    .. "), got " .. tostring(lineSize))

-- ...and it keeps going all the way up.
--
-- Lines.lua used to clamp a quest line to two points over the size the tracker
-- laid it out at, which on this client meant everything from 14 upwards drew
-- identically: the header and the objective counts - heroPanel's own
-- FontStrings, never clamped - moved, and the quest text did not. A size
-- control that stops responding half way along its track reads as broken, so
-- the clamp is gone and text that outgrows the panel is answered by the resize
-- grip instead.
local restoreSizes = {}
for role, size in pairs(ns.db.font.size) do restoreSizes[role] = size end

SlashCmdList["HEROPANEL"]("font 20")
tick(); tick()
local _, hugeTitle = trackerLines[1].__text:GetFont()
local _, hugeLine  = trackerLines[2].__text:GetFont()
check(hugeTitle == 20, "the quest name should take the configured 20, got " .. tostring(hugeTitle))
check(hugeLine == 20, "and so should the description, got " .. tostring(hugeLine))

SlashCmdList["HEROPANEL"]("font 26")
tick(); tick()
local _, hugerTitle = trackerLines[1].__text:GetFont()
check(hugerTitle == 26,
    "...and it must still be moving at the top of the range, got " .. tostring(hugerTitle))

for role, size in pairs(restoreSizes) do ns.db.font.size[role] = size end
ns.Media.Apply("harness restoring font sizes")
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

check(HEROPANEL_DB.skin.watch == false, "the flag should be stored")
check(HEROPANEL_DB.skin.mplus == false, "...for both panels, which is what /hp skin means")
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
HEROPANEL_DB.panel.watch.borderStyle = "none"
HEROPANEL_DB.panel.watch.radius = 0
HEROPANEL_DB.panel.watch.bgOpacity = 0.5
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

HEROPANEL_DB.panel.watch.borderStyle = "hairline"
HEROPANEL_DB.panel.watch.radius = 8
HEROPANEL_DB.panel.watch.bgOpacity = 1
ns.Skin.Restyle()
local notched = 0
for _, pixels in pairs(plate.corner) do
    for _, pixel in ipairs(pixels) do
        if pixel:IsShown() then notched = notched + 1 end
    end
end
check(notched == 8, "an 8px radius should be a 2px step at each of the four corners, got " .. notched)

-- The two panels carry their own chrome, so one of them changing must not move
-- the other. This was one global block and the options window now offers the
-- same six controls twice; a shared table underneath would make the second copy
-- a lie.
do
    HEROPANEL_DB.panel.mplus.bgColor = "#0D0E14"
    ns.Skin.Restyle()
    ns.Mplus.Restyle()

    local watchPaint = HeroPanelWatchPlate.bg.main.__color
    local mplusPaint = HeroPanelMplusPlate and HeroPanelMplusPlate.bg.main.__color
    check(watchPaint and math.abs(watchPaint[1] - select(1, ns.HexToRGB("#14161F"))) < 0.01,
        "the quest panel keeps its own background when the Mythic+ one changes")
    if mplusPaint then
        check(math.abs(mplusPaint[1] - select(1, ns.HexToRGB("#0D0E14"))) < 0.01,
            "...and the Mythic+ panel takes the colour set for it")
    end

    HEROPANEL_DB.panel.mplus.bgColor = ns.defaults.panel.mplus.bgColor
    ns.Mplus.Restyle()
end

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
-- The Mythic+ panel
--------------------------------------------------------------------------------

-- Discovery first. The tracker did not exist at ADDON_LOADED, so a panel at
-- all is the proof that the poll found it and that the skin hung off the same
-- discovery point rather than a timer of its own.
check(ns.trackers.mplus.found, "the Mythic+ tracker should have been found by polling")
local mplate = HeroPanelMplusPlate
check(mplate ~= nil, "the Mythic+ panel was never created")

if mplate then
    check(mplate:IsShown(), "the Mythic+ panel is not shown")

    -- Same plate as the quest tracker, which is the requirement: both are
    -- built by Plate.lua, so a background here proves the shared chrome ran.
    check(mplate.bg ~= nil and mplate.edge ~= nil,
        "the Mythic+ panel should carry the shared plate chrome")
    check(mplate:GetFrameStrata() == "LOW",
        "the panel should sit a strata below the tracker's MEDIUM, got " .. tostring(mplate:GetFrameStrata()))

    -- Sized from the rows it drew, not from the frame it is drawn over. The
    -- tracker's rect runs down to 200 while its lowest boss row is at 410, so
    -- a panel that followed the frame would be around 200 pixels too tall.
    local bottom = mplate:GetBottom()
    check(bottom ~= nil and bottom > 340,
        "the panel should be sized from its rows, not the tracker's frame; bottom " .. tostring(bottom))
    check(bottom ~= nil and bottom < 410,
        "the panel has to reach below the last boss row to fit the footer; bottom " .. tostring(bottom))
end

-- Ascension's chrome is faded, never hidden, and its own clocks go with it -
-- leaving those on screen is what "two headers stacked" looked like in Phase 2.
check(mplusTracker.HeaderText:GetAlpha() == 0, "the tracker's header text should be faded")
check(mplusTracker.HeaderText:IsShown(), "the tracker's header text should be faded, not hidden")
check(mplusTracker.MainBlock.Level:GetAlpha() == 0, "the tracker's level text should be faded")
check(mplusTracker.MainBlock.TimeLeft:GetAlpha() == 0, "the tracker's clock should be faded")
check(mplusTracker.MainBlock.TimeLeft2:GetAlpha() == 0,
    "Ascension's miscomputed +2 clock should be faded")
check(mplusTracker.MainBlock.TimeLeft3:GetAlpha() == 0,
    "Ascension's miscomputed +3 clock should be faded")
check(mplusTracker.MainBlock.Timer.PlusTwoNotch:GetAlpha() == 0,
    "the tracker's own threshold notches should be faded")
check(mplusTracker.MainBlock.Timer.__fill:GetAlpha() == 0,
    "the keystone timer's fill is a status-bar texture and has to be asked for by name")
check(mplusTracker.MainBlock.Affix1.__normal:GetAlpha() == 0, "affix button art should be faded")

--------------------------------------------------------------------------------
-- The enemy-forces bar, which fights back
--
-- Every other piece of Ascension's chrome sits still once it has been faded.
-- That row does not: it animates on every trash kill, and an animation writes
-- the alpha of what it animates for as long as it plays, so a zero set before
-- it ran is gone. In game that drew Ascension's glow across the bottom of the
-- panel on every pull.
--
-- So the row is hidden as well as faded, and the checks are in that order: the
-- fill must be found at all - it is a status-bar texture, not one of the
-- frame's regions - it must be off the screen, and it must still be off the
-- screen after the animation has run.
--------------------------------------------------------------------------------

local forcesBar = mplusTracker.ObjectiveBlock.EnemyForces.StatusBar

check(forcesBar.__fill:GetAlpha() == 0,
    "the enemy-forces fill is a status-bar texture and has to be asked for by name")
check(not forcesBar.__fill:IsShown(), "the enemy-forces fill should be hidden, not just faded")
check(not forcesBar.Glow:IsShown(), "the enemy-forces glow should be hidden, not just faded")

forcesBar:Play()
check(not forcesBar.Glow:IsShown(),
    "an animation showing the glow again must not put it back on screen")
check(not forcesBar.__fill:IsShown(),
    "an animation showing the fill again must not put it back on screen")

-- ...and the row is still where it was. Hiding regions is the whole of it -
-- nothing about the frame the tracker laid out may change.
check(mplusTracker.ObjectiveBlock.EnemyForces:IsShown(),
    "the enemy-forces row itself must not be hidden")
check(forcesBar:IsShown(), "the enemy-forces bar frame must not be hidden")
check(mplusTracker.ObjectiveBlock.EnemyForces:GetTop() == 400,
    "the enemy-forces row must not be moved")

-- Boss text survives: the rows are recoloured and refonted, never hidden.
local finalRow = mplusTracker.ObjectiveBlock.FinalEncounter
local falric   = mplusTracker.ObjectiveBlock.Encounters.buttons[1]
local marwyn   = mplusTracker.ObjectiveBlock.Encounters.buttons[2]

check(finalRow.Text:GetAlpha() == 1, "boss text must not be faded")
check(finalRow.Text:GetText() == "The Lich King", "boss text must not be rewritten")
check(falric.Text:GetText() == "Falric", "sub-objective text must not be rewritten")

-- ...and nothing moved. This is the rule the design calls out twice.
check(finalRow.Text:GetLeft() == 1340, "boss text must not be re-anchored")
check(finalRow:GetTop() == 470, "boss rows must not be moved")
check(falric:GetTop() == 438, "sub-objective rows must not be moved")

local function mcolour(fontString)
    local c = fontString.__textColor
    if not c then return "none" end
    return string.format("%02X%02X%02X", math.floor(c[1] * 255 + 0.5),
        math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

-- The extra bosses are drawn by heroPanel on its own plate, so their colour is
-- read off the panel's rows rather than off the tracker's, which are faded.
local function subRow(name)
    for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
        local text = region.GetText and region:GetText()
        if text and region:IsShown() and string.sub(text, 1, #name) == name then
            return region
        end
    end
end

local function subColour(name)
    local region = subRow(name)
    return region and mcolour(region) or "missing"
end

check(falric.Text:GetAlpha() == 0,
    "the tracker's own extra-boss row should be faded; heroPanel redraws it")
check(subColour("Falric") == "79C68D",
    "a slain boss should be green on the panel, got " .. subColour("Falric"))
check(subColour("Marwyn") == "8B8FA3",
    "a boss still up should be muted, got " .. subColour("Marwyn"))
check(mcolour(finalRow.Text) == "8B8FA3",
    "the final boss still up should be muted, got " .. mcolour(finalRow.Text))

-- The row's own icon and counter are replaced by heroPanel's indicator and
-- status word, so both have to be faded rather than left underneath.
check(falric.Icon:GetAlpha() == 0, "the tracker's boss icon should be faded")
check(falric.Counter:GetAlpha() == 0, "the tracker's boss counter should be faded")

--------------------------------------------------------------------------------
-- Chest tiers
--
-- The arithmetic the design specifies, checked against the thresholds the
-- client actually ships: +3 needs 55% of the timer left, +2 needs 40%. This is
-- computed rather than read off Ascension's own fields, which are wrong.
--------------------------------------------------------------------------------

local tier, window = ns.Mplus.ChestTier(1661, 1800)     -- 27:41 of 30:00
check(tier == 3, "at 27:41 of 30:00 the top tier should still be +3, got " .. tostring(tier))
check(window ~= nil and math.abs(window - (1661 - 0.55 * 1800)) < 0.01,
    "the +3 window should be measured against 55% of the timer, got " .. tostring(window))

tier, window = ns.Mplus.ChestTier(900, 1800)            -- 50% left: +3 gone
check(tier == 2, "at half time the top tier should be +2, got " .. tostring(tier))
check(window ~= nil and math.abs(window - (900 - 0.4 * 1800)) < 0.01,
    "the +2 window should be measured against 40% of the timer")

tier = ns.Mplus.ChestTier(600, 1800)                    -- 33% left: +2 gone too
check(tier == nil, "below the +2 threshold the tier display should be hidden, not show +1")

tier = ns.Mplus.ChestTier(nil, nil)
check(tier == nil, "no timer means no tier")

-- The thresholds are read from the client, so retuning them moves the display.
MYTHIC_PLUS_BONUS_LEVEL_PERCENT = { 0.5, 0.25 }
tier = ns.Mplus.ChestTier(1000, 1800)                   -- 55% left
check(tier == 3, "the tier should follow the client's own thresholds, got " .. tostring(tier))
MYTHIC_PLUS_BONUS_LEVEL_PERCENT = { 0.55, 0.4 }

--------------------------------------------------------------------------------
-- What the panel read
--------------------------------------------------------------------------------

local read = ns.Mplus.Read()
check(read ~= nil, "the panel should be able to read the run")

if read then
    -- In full mode these come from C_MythicPlus; under HP_MINIMAL there is no
    -- such API and the same fields have to come off the tracker's widgets.
    check(read.dungeon == "Halls of Reflection",
        "the dungeon name should be resolved, got " .. tostring(read.dungeon))
    check(read.level == 12, "the keystone level should be resolved, got " .. tostring(read.level))
    check(read.totalTime == 1800, "the total time should be resolved, got " .. tostring(read.totalTime))
    check(read.timeLeft ~= nil and math.abs(read.timeLeft - 1661) < 1,
        "the remaining time should be resolved, got " .. tostring(read.timeLeft))
    check(read.trashRequired == 100, "enemy forces should be resolved, got " .. tostring(read.trashRequired))

    -- Three bosses and one heading. The champions row is hidden below key
    -- level 14, and enemy forces is not a boss at all.
    local byName, bossCount = {}, 0
    for _, b in ipairs(read.bosses) do
        byName[b.text] = b
        if not b.group then bossCount = bossCount + 1 end
    end
    check(bossCount == 3, "expected 3 boss rows, got " .. tostring(bossCount))
    check(byName["Defeat additional bosses"] ~= nil
          and byName["Defeat additional bosses"].group,
        "the expanded extra-bosses row is a heading, not a boss")
    check(byName["Falric"] ~= nil and byName["Falric"].done, "Falric should read as slain")
    check(byName["Marwyn"] ~= nil and not byName["Marwyn"].done, "Marwyn should read as still up")
    check(byName["Champions"] == nil, "a hidden objective row must not be collected")
    check(byName["Enemy Forces"] == nil, "the enemy-forces row is not a boss row")

    -- Top down, so the indicators line up with the rows on screen.
    check(read.bosses[1].text == "The Lich King",
        "boss rows should be ordered top down, got " .. tostring(read.bosses[1].text))
end

--------------------------------------------------------------------------------
-- Enemy forces is drawn where the design puts it, not where the tracker does
--------------------------------------------------------------------------------

-- Ascension anchors its enemy-forces row at the bottom, below the bosses.
-- heroPanel draws its own above them, so the label has to sit above the
-- topmost boss row rather than following the tracker's order.
check(mplusTracker.ObjectiveBlock.EnemyForces:GetTop() == 400,
    "the tracker's own enemy-forces row must not be moved")

local forcesLabel, percentLabel
for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
    local text = region.GetText and region:GetText()
    if text == "Enemy Forces" then forcesLabel = region end
    if text == "84%" then percentLabel = region end
end

check(forcesLabel ~= nil, "heroPanel should draw its own Enemy Forces label")
check(percentLabel ~= nil, "the enemy-forces percentage should be drawn from live data")

if forcesLabel then
    check(forcesLabel:GetTop() > 470,
        "heroPanel's enemy-forces row belongs above the topmost boss row at 470, got "
        .. tostring(forcesLabel:GetTop()))
end

-- The dungeon name and keystone level are heroPanel's, drawn over the faded
-- header rather than by rewriting Ascension's string.
local nameLabel, keyLabel
for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
    local text = region.GetText and region:GetText()
    if text == "Halls of Reflection" then nameLabel = region end
    if text == "(12)" then keyLabel = region end
end
check(nameLabel ~= nil, "the dungeon name should be drawn on the panel")
check(keyLabel ~= nil, "the keystone level should be drawn inline as (12)")
check(mplusTracker.HeaderText:GetText() == "Halls of Reflection",
    "Ascension's own header string must not be rewritten")

--------------------------------------------------------------------------------
-- Short dungeon names
--
-- The header gives the dungeon name about 158px between the padlock and the
-- affix icons, and nothing clamps it: a long name runs underneath them. The
-- table in Mplus.lua shortens the long ones.
--
-- What this mock CAN check is the table and the wiring. What it cannot check is
-- whether a given short name fits, because it measures five pixels per
-- character regardless of font size - so the budget is enforced here as a
-- character limit, which is the thing that was actually measured against real
-- font metrics. See the note in "Known unverified" in TESTING.md.
--------------------------------------------------------------------------------

local NAME_CHAR_LIMIT = 20

check(ns.Mplus.ShortName("Blackrock Depths - Upper City") == "BRD - Upper City",
    "a long dungeon name should be shortened, got "
    .. tostring(ns.Mplus.ShortName("Blackrock Depths - Upper City")))

-- Matching is on a normalised form, so whichever separator this client uses
-- lands on the same row.
for _, spelling in ipairs({ "Blackrock Depths: Upper City", "Blackrock Depths Upper City",
                            "blackrock depths - upper city", "BLACKROCK DEPTHS UPPER CITY" }) do
    check(ns.Mplus.ShortName(spelling) == "BRD - Upper City",
        "the separator and case should not matter: " .. spelling .. " gave "
        .. tostring(ns.Mplus.ShortName(spelling)))
end

check(ns.Mplus.ShortName("Some Dungeon Ascension Added") == "Some Dungeon Ascension Added",
    "a name the table does not know should come back untouched")
check(ns.Mplus.ShortName("Deadmines") == "Deadmines",
    "a name that is already short enough should come back untouched")
check(ns.Mplus.ShortName(nil) == nil, "a nil name should not error")

-- The whole table, spelled out, because two things about it are easy to break
-- by editing one row: the character budget, and the naming convention.
--
-- The convention is "dungeon - wing", with the same " - " separator every time.
-- It was mixed at first - "SM Graveyard" beside "DM - East" - which reads as
-- two different schemes rather than one, so it is pinned here rather than left
-- to whoever adds the next row.
local EXPECTED = {
    { "Ragefire Chasm",                "Ragefire Chasm" },
    { "Deadmines",                     "Deadmines" },
    { "Stormwind Stockades",           "Stockades" },
    { "Wailing Caverns",               "WC" },
    { "Wailing Caverns - Crag of the Everliving", "WC - Crag" },
    { "Scarlet Monastery - Graveyard", "SM - Graveyard" },
    { "Scarlet Monastery - Library",   "SM - Library" },
    { "Scarlet Monastery - Armory",    "SM - Armory" },
    { "Scarlet Monastery - Cathedral", "SM - Cathedral" },
    { "Razorfen Kraul",                "Razorfen Kraul" },
    { "Razorfen Downs",                "Razorfen Downs" },
    { "Gnomeregan",                    "Gnomeregan" },
    { "Uldaman",                       "Uldaman" },
    { "Maraudon",                      "Mara" },
    { "Maraudon - Purple Crystals",    "Mara - Purple" },
    { "Maraudon - Orange Crystals",    "Mara - Orange" },
    { "Maraudon - Pristine Waters",    "Mara - Princess" },
    { "Zul'Farrak",                    "Zul'Farrak" },
    { "Sunken Temple",                 "Sunken Temple" },
    { "Scholomance",                   "Scholo" },
    { "Scholomance - Lower",           "Scholo - Lower" },
    { "Scholomance - Upper",           "Scholo - Upper" },
    { "Lower Blackrock Spire",         "LBRS" },
    { "Upper Blackrock Spire",         "UBRS" },
    { "Stratholme",                    "Strat" },
    { "Stratholme - Main Gate",        "Strat - Live" },
    { "Stratholme - Service Gate",     "Strat - Undead" },
    { "Dire Maul",                     "DM" },
    { "Dire Maul - East",              "DM - East" },
    { "Dire Maul - West",              "DM - West" },
    { "Dire Maul - North",             "DM - North" },
    { "Blackrock Depths",              "BRD" },
    { "Blackrock Depths - Prison",     "BRD - Prison" },
    { "Blackrock Depths - Upper City", "BRD - Upper City" },
}

for _, row in ipairs(EXPECTED) do
    local full, want = row[1], row[2]
    local short = ns.Mplus.ShortName(full)

    check(short == want,
        string.format("%s should shorten to %q, got %q", full, want, tostring(short)))

    -- The budget. This is the check that stops a future entry being added
    -- straight back into the overlap the table exists to prevent.
    check(short ~= nil and #short <= NAME_CHAR_LIMIT,
        string.format("%s shortens to %q, %d chars, over the %d-char budget",
            full, tostring(short), #tostring(short), NAME_CHAR_LIMIT))

    -- A wing is joined with " - " and nothing else. A short name that splits on
    -- a bare space when the full name had a wing is the mixed scheme coming
    -- back: "SM Graveyard" rather than "SM - Graveyard".
    if string.find(full, " %- ") then
        check(string.find(short, " %- ") ~= nil,
            string.format("%s has a wing, so %q should join it with ' - '", full, short))
    end
end

-- ...and the wiring: the panel draws the short name while Read still reports
-- the raw one, so /hp mplus can show a table row that never matched.
--
-- Both sources are set, because they are the two routes to data.dungeon and
-- which one runs depends on the client: GetLFGDungeonInfo when C_MythicPlus is
-- there, the tracker's own HeaderText when it is not. Shortening happens where
-- the name is drawn, so it has to reach a name that arrived either way - and
-- under HP_MINIMAL this is the only route there is.
GetLFGDungeonInfo = function() return "Blackrock Depths - Upper City" end
mplusTracker.HeaderText:SetText("Blackrock Depths - Upper City")
ns.Mplus.Refresh("test: a long dungeon name")
tick(); tick()

local shortLabel, rawLabel
for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
    local text = region.GetText and region:GetText()
    if text == "BRD - Upper City" then shortLabel = region end
    if text == "Blackrock Depths - Upper City" then rawLabel = region end
end
check(shortLabel ~= nil, "the header should draw the shortened name")
check(rawLabel == nil, "the header should not still be drawing the full name")
check(ns.Mplus.Read().dungeon == "Blackrock Depths - Upper City",
    "Read should still report the name the game gave, got "
    .. tostring(ns.Mplus.Read().dungeon))

-- The name and keystone have the whole row to themselves now that the affixes
-- have their own beneath it, so what has to hold is that the pair stays inside
-- the panel. The affix collision is checked in the affix section, vertically -
-- the two are no longer competing for the same horizontal space.
if shortLabel then
    local keystone
    for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
        if region.GetText and region:GetText() == "(12)" then keystone = region end
    end
    check(keystone and keystone:GetRight() <= HeroPanelMplusPlate:GetRight() - 13,
        "the name and keystone should stay inside the panel's content column, got "
        .. tostring(keystone and keystone:GetRight()) .. " against "
        .. tostring(HeroPanelMplusPlate:GetRight() - 13))
end

GetLFGDungeonInfo = function() return "Halls of Reflection" end
mplusTracker.HeaderText:SetText("Halls of Reflection")
ns.Mplus.Refresh("test: back to the usual name")
tick(); tick()

-- The timer row reads remaining time, and the total beside it.
local clock, total
for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
    local text = region.GetText and region:GetText()
    if text == "27:41" then clock = region end
    if text == "/ 30:00" then total = region end
end
check(clock ~= nil, "the panel should show 27:41 remaining")
check(total ~= nil, "the panel should show the total time as / 30:00")

-- ...and the chest tier, computed rather than taken from Ascension's fields.
-- 1661 - 0.55*1800 = 671s = 11:11, where Ascension's own TimeLeft3 says 07:41.
--
-- Checked as a number with a little slack rather than as an exact string:
-- without C_MythicPlus to re-read, the clock counts down locally between
-- refreshes, so by the time the assertions run it is a second or two along.
-- That drift is the fallback working, not a fault.
local tierText, tierWindow
for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
    local text = region.GetText and region:GetText()
    if text == "+3" then tierText = region end
    if text and string.match(text, "^%(%d+:%d%d%)$") then tierWindow = text end
end
check(tierText ~= nil, "the panel should show +3 as the highest eligible tier")
check(tierWindow ~= nil, "the +3 window should be drawn beside the tier")

if tierWindow then
    local minutes, secs = string.match(tierWindow, "(%d+):(%d+)")
    local seconds = tonumber(minutes) * 60 + tonumber(secs)
    check(math.abs(seconds - 671) <= 5,
        "the +3 window should be ~11:11 (1661 - 55% of 1800), not Ascension's "
        .. "miscomputed 07:41; got " .. tierWindow)
end

--------------------------------------------------------------------------------
-- Nothing of Ascension's is left in the header
--
-- The affix icon hangs off a child frame rather than the button's own regions,
-- so a pass over the button's four textures missed it and left an icon in the
-- panel's top-right corner - which the design deliberately has nothing in.
--------------------------------------------------------------------------------

check(mplusTracker.MainBlock.Affix1.__icon:GetAlpha() == 0,
    "the affix icon on a child frame should be faded, not just the button's own art")
check(mplusTracker.CollapseExpandButton.__normal:GetAlpha() == 0,
    "the tracker's own collapse button art should be faded")

-- Ascension's own lock button, which /framestack named on the live client as
-- MythicPlusObjectiveTrackerLockButton. heroPanel has its own lock in the
-- header's top-left corner, and two locks on one panel is one too many.
local ascensionLock = mplusTracker.LockButton
check(ascensionLock.__normal:GetAlpha() == 0,
    "Ascension's lock button art should be faded")
check(not ascensionLock:IsMouseEnabled(),
    "the faded lock button should stop taking the mouse, or it swallows affix hovers")

--------------------------------------------------------------------------------
-- The expandable row wears heroPanel's chevron
--------------------------------------------------------------------------------

local expandButton = mplusTracker.ObjectiveBlock.Encounters.CollapseExpandButton
check(expandButton.__normal:GetAlpha() == 0,
    "Ascension's expand control art should be faded")

local caret
for _, child in ipairs(HeroPanelMplusPlate.overlay.__children) do
    if child.shape == "caretUp" or child.shape == "caretDown" then caret = child end
end
check(caret ~= nil, "heroPanel should draw its own chevron on the expandable row")
check(caret == nil or caret.shape == "caretUp",
    "an expanded row's chevron should point up, got " .. tostring(caret and caret.shape))

--------------------------------------------------------------------------------
-- Killing a boss must not strip heroPanel's styling for the rest of the run
--
-- Ascension reassigns the font object on a row every time its progress changes,
-- which threw away heroPanel's font and colour. The panel only redrew on an
-- event, so a row restyled out from under it stayed Ascension's dark grey on a
-- dark panel - the text was still there and simply could not be seen, and it
-- never came back. Every styled row is hooked now, so the change queues a
-- redraw of its own.
--------------------------------------------------------------------------------

check(subColour("Marwyn") == "8B8FA3", "Marwyn should start muted")

ENCOUNTERS[202].dead = true                 -- the server commits the kill
marwyn:SetProgress(1)                       -- the tracker restyles the row

tick(); tick()                              -- heroPanel's hook queues a redraw

check(subColour("Marwyn") == "79C68D",
    "the panel should follow the kill after Ascension changed the row, got " .. subColour("Marwyn"))
check(marwyn.Text:GetText() == "Marwyn", "the boss name must survive the kill")

--------------------------------------------------------------------------------
-- The encounter API outranks the row's stored progress
--
-- The tracker is told about a kill before the server has committed it, so its
-- row reads "not dead" for one more update - which on a live run showed as the
-- heading counting 3/3 while only two bosses had gone green. The panel re-reads
-- GetEncounterInfo at draw time, so it is right on the first pass instead of
-- the second.
--------------------------------------------------------------------------------

-- The row still says 0/1 and the API says the boss is down: the API wins.
ENCOUNTERS[201].dead = true
falric:SetObjective("Falric", 0, 1)         -- the stale value the tracker holds
tick(); tick()
check(falric.progress == 0, "the row should still be holding the stale progress")
check(subColour("Falric") == "79C68D",
    "a boss the encounter API calls dead should read as slain even while the row lags, got "
    .. subColour("Falric"))

-- ...and the reverse, so the override cannot invent a kill.
ENCOUNTERS[201].dead = false
falric:SetObjective("Falric", 1, 1)
tick(); tick()
check(subColour("Falric") ~= "79C68D",
    "a boss the encounter API says is up must not read as slain, got " .. subColour("Falric"))
ENCOUNTERS[201].dead = true
falric:SetObjective("Falric", 1, 1)
tick(); tick()

-- A completed row wears its kill time, which must not break the name match.
falric.Text:SetText("Falric (14:46)")
tick(); tick()
check(subColour("Falric") == "79C68D",
    "the kill time Ascension appends must not stop the name matching, got " .. subColour("Falric"))
falric:SetObjective("Falric", 1, 1)
tick(); tick()

-- The heading is the row that actually went missing in the run, so it gets its
-- own check rather than riding on the sub-row's.
local heading = mplusTracker.ObjectiveBlock.Encounters
heading:SetObjective("Defeat additional bosses", 2, 2)
tick(); tick()
-- Complete, so it is green whether it is expanded or collapsed. Expanded it
-- used to stay muted, so the same finished run read as unfinished depending on
-- which way the chevron pointed.
check(mcolour(heading.Text) == "79C68D",
    "a completed heading should be green while expanded, got " .. mcolour(heading.Text))
check(heading.isExpanded, "this check is only meaningful while the row is expanded")

-- The count moves out of the right-aligned counter and into the sentence,
-- where it reads as part of the heading rather than as a stray number against
-- the panel's far edge.
check(heading.Text:GetText() == "additional bosses (2/2)",
    "the heading should carry its count inline, got " .. tostring(heading.Text:GetText()))
check(heading.Counter:GetAlpha() == 0,
    "the heading's right-aligned counter should be faded once the count is inline")

-- ...including before the first one dies. The count was held back until then
-- and that hid the half that matters most early: the denominator is how many
-- the key needs, which is what decides whether the group detours for them at
-- all, and it arrived after that decision rather than before it.
heading:SetObjective("Defeat additional bosses", 0, 6)
tick(); tick()
check(heading.Text:GetText() == "additional bosses (0/6)",
    "the requirement should be shown before any extra boss dies, got "
    .. tostring(heading.Text:GetText()))

heading:SetObjective("Defeat additional bosses", 1, 6)
tick(); tick()
check(heading.Text:GetText() == "additional bosses (1/6)",
    "...and count up from there, got " .. tostring(heading.Text:GetText()))

-- The rewrite must not compound: reading the row back gives the raw string.
tick(); tick()
check(heading.Text:GetText() == "additional bosses (1/6)",
    "a second pass must not stack a second count, got " .. tostring(heading.Text:GetText()))

--------------------------------------------------------------------------------
-- Sizes make a hierarchy, and a completed boss is a check mark
--------------------------------------------------------------------------------

local function msize(fontString) return fontString.__font and fontString.__font[2] end

-- Against the configured base rather than fixed numbers, because /hp font
-- moves all three together and an earlier test in this run changes it.
check(msize(finalRow.Text) == ns.GetFontSize(1.5, "mplusBody"),
    "the required boss should be title-sized, got " .. tostring(msize(finalRow.Text)))
check(msize(heading.Text) == ns.GetFontSize(0, "mplusBody"),
    "the extra-bosses heading should sit a step under it, got " .. tostring(msize(heading.Text)))
check(msize(subRow("Falric")) == ns.GetFontSize(-1, "mplusBody"),
    "a boss row should be body text, got " .. tostring(msize(subRow("Falric"))))
check(msize(finalRow.Text) > msize(heading.Text)
      and msize(heading.Text) > msize(subRow("Falric")),
    "the three sizes have to descend for the block to read as a hierarchy")

-- No "slain" text any more: the check mark says it.
local slain
for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
    if region.GetText and region:GetText() == "slain" then slain = region end
end
check(slain == nil or not slain:IsShown(),
    "a completed boss should be marked by the check alone, with no status text")

--------------------------------------------------------------------------------
-- A long miniboss list is windowed and scrolls
--
-- Lower Blackrock Spire offers fifteen candidates for a requirement of five,
-- which made a panel taller than the screen.
--------------------------------------------------------------------------------

local LONG = { "Mor Grayhoof", "Burning Felguard", "Ghok Bashguud", "Crystal Fang",
               "Bannok Grimaxe", "Spirestone Lord Magus", "Spirestone Battle Lord",
               "Spirestone Butcher", "Highlord Omokk", "Shadow Hunter Voshgajin",
               "War Master Voone", "Mother Smolderweb", "Urok Doomhowl",
               "Quartermaster Zigris", "Halycon" }

local heightBefore = HeroPanelMplusPlate:GetHeight()

local longRows = {}
for i, name in ipairs(LONG) do
    longRows[i] = BuildObjectiveRow(mplusTracker.ObjectiveBlock.Encounters,
        "MplusLong" .. i, name, 0, 1, 438 - (i - 1) * 16)
end
mplusTracker.ObjectiveBlock.Encounters.buttons = longRows
ns.Mplus.Refresh("test: long list")
tick(); tick()

local function visibleSubRows()
    local n = 0
    for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
        local text = region.GetText and region:GetText()
        if text and region:IsShown() then
            for _, name in ipairs(LONG) do
                if text == name then n = n + 1 break end
            end
        end
    end
    return n
end

check(visibleSubRows() == 6,
    "a fifteen-boss list should be windowed to six rows, got " .. visibleSubRows())

local heightWindowed = HeroPanelMplusPlate:GetHeight()
check(heightWindowed < heightBefore + 15 * 15,
    "the panel must not grow a row per candidate; height " .. tostring(heightWindowed))

-- The window starts at the top of the list.
check(subRow("Mor Grayhoof") ~= nil, "the first boss should be visible before scrolling")
check(subRow("Halycon") == nil, "the last boss should be out of the window before scrolling")

-- Scrolling moves the window, and the panel does not change size doing it.
local wheel
for _, child in ipairs(HeroPanelMplusPlate.__children) do
    if child.IsMouseWheelEnabled and child:IsMouseWheelEnabled() then wheel = child end
end
check(wheel ~= nil, "there should be a wheel catcher over the list")
check(wheel ~= nil and not wheel:IsMouseEnabled(),
    "the wheel catcher must not take the mouse, or it swallows drags on the tracker")

if wheel then
    local onWheel = wheel:GetScript("OnMouseWheel")
    check(onWheel ~= nil, "the wheel catcher needs a handler")

    onWheel(wheel, -1)                      -- one row down
    tick(); tick()
    check(subRow("Mor Grayhoof") == nil, "scrolling down should move the first boss out of view")
    check(visibleSubRows() == 6, "the window stays six rows while scrolling")
    check(HeroPanelMplusPlate:GetHeight() == heightWindowed,
        "scrolling must not resize the panel")

    for _ = 1, 40 do onWheel(wheel, -1) end  -- far past the end
    tick(); tick()
    check(subRow("Halycon") ~= nil, "scrolling to the end should reach the last boss")
    check(visibleSubRows() == 6, "the window must not run off the end of the list")

    for _ = 1, 40 do onWheel(wheel, 1) end   -- and back past the start
    tick(); tick()
    check(subRow("Mor Grayhoof") ~= nil, "scrolling back should return to the first boss")
    check(visibleSubRows() == 6, "the window must not run off the start of the list")
end

-- Back to the short list for the checks that follow.
mplusTracker.ObjectiveBlock.Encounters.buttons = { falric, marwyn }
for _, row in ipairs(longRows) do row:Hide() end
ns.Mplus.Refresh("test: short list")
tick(); tick()
check(visibleSubRows() == 0, "the long list should be gone once its rows are")

--------------------------------------------------------------------------------
-- Enemy forces overflows past 100% on purpose
--
-- Ascension's own row clamps the count with MClamp and shows a flat 100%,
-- which throws away how much trash was overpulled. heroPanel keeps it. The bar
-- still clamps, because a fill cannot run past its track, so above 100% the
-- two deliberately disagree. This check exists so that never gets "fixed".
--------------------------------------------------------------------------------

TRASH_DEAD = 160
mplusTracker.ObjectiveBlock.EnemyForces.progress = 160
ns.Mplus.Refresh("test: overpulled")
tick(); tick()

local forcesPct
for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
    local text = region.GetText and region:GetText()
    if text and region:IsShown() and string.match(text, "^%d+%%$") then forcesPct = text end
end

check(forcesPct == "160%",
    "enemy forces should report the overpull, not clamp to 100%; got " .. tostring(forcesPct))

-- ...while the bar itself stays inside its track.
check(ns.Mplus.GetPlate() ~= nil, "the panel should still be there")
local forcesBarRight, trackRight
for _, region in ipairs(HeroPanelMplusPlate.__regions) do
    local r = region:GetRight()
    if r and region:GetHeight() == 4 then
        if not trackRight or r > trackRight then trackRight = r end
        if region:IsShown() then forcesBarRight = math.max(forcesBarRight or 0, r) end
    end
end
if forcesBarRight and trackRight then
    check(forcesBarRight <= trackRight + 0.01,
        "the enemy-forces fill must not run past its track even when overpulled")
end

TRASH_DEAD = 84
mplusTracker.ObjectiveBlock.EnemyForces.progress = 84
ns.Mplus.Refresh("test: back to normal")
tick(); tick()

--------------------------------------------------------------------------------
-- Affixes
--
-- Drawn as heroPanel's own buttons from the keystone's affix spell IDs, on
-- their own row under the dungeon name, each with the game's tooltip on hover.
--
-- They used to share the name row, anchored right-to-left from the panel's
-- top-right corner. Eight of them at 20px is 181px of a 262px content width, so
-- sharing meant driving through the dungeon name whatever it was shortened to.
--------------------------------------------------------------------------------

local function shownAffixes()
    local found = {}
    for _, child in ipairs(HeroPanelMplusPlate.__children) do
        if child.affixID and child:IsShown() then table.insert(found, child) end
    end
    table.sort(found, function(a, b) return a:GetLeft() < b:GetLeft() end)
    return found
end

local function setAffixes(list)
    C_MythicPlus.GetActiveKeystoneInfo = function()
        return { keystoneLevel = 12, dungeonID = 668, rewardMultiplier = 1,
                 activeAffixes = list }
    end
    ns.Mplus.Refresh("test: affixes")
    tick(); tick()
    return shownAffixes()
end

local affixButtons = shownAffixes()

if MINIMAL then
    -- No C_MythicPlus, so no affix list to read; the row is simply absent
    -- rather than the panel failing.
    check(#affixButtons == 0, "with no keystone API there is nothing to draw affixes from")
else
    check(#affixButtons == 3,
        "the keystone's three affixes should be drawn, got " .. #affixButtons)

    local plateTop, plateLeft = HeroPanelMplusPlate:GetTop(), HeroPanelMplusPlate:GetLeft()

    check(affixButtons[1]:GetLeft() >= plateLeft,
        "affixes belong inside the panel's left edge")
    check(affixButtons[#affixButtons]:GetRight() <= HeroPanelMplusPlate:GetRight(),
        "affixes belong inside the panel's right edge")

    -- Their own row: below the 30px name row, not in it.
    check(affixButtons[1]:GetTop() <= plateTop - 30,
        "affixes belong under the name row, got top "
        .. tostring(affixButtons[1]:GetTop()) .. " against a plate top of " .. tostring(plateTop))

    -- On the panel's content column, the same left margin as the timer glyph,
    -- the bars and the enemy-forces row.
    check(math.abs(affixButtons[1]:GetLeft() - (plateLeft + 13)) < 0.01,
        "the affix row should start on the content column at +13, got "
        .. tostring(affixButtons[1]:GetLeft() - plateLeft))

    check(affixButtons[1]:GetLeft() < affixButtons[2]:GetLeft(),
        "affixes should lay out left to right, first one leftmost")
    check(affixButtons[1]:GetWidth() == 20,
        "an affix icon should be 20px, got " .. tostring(affixButtons[1]:GetWidth()))
    check(affixButtons[1].icon:GetTexture() == "Interface\\Icons\\affix_1001",
        "the affix icon should come from GetSpellInfo, got "
        .. tostring(affixButtons[1].icon:GetTexture()))
    check(affixButtons[1]:IsMouseEnabled(), "an affix needs the mouse for its tooltip")

    -- The dungeon name is what the old placement collided with, and the point
    -- of the move is that it now cannot.
    local nameRow
    for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
        if region.GetText and region:GetText() == "Halls of Reflection" then nameRow = region end
    end
    if nameRow then
        check(affixButtons[#affixButtons]:GetTop() <= nameRow:GetBottom(),
            "no affix should reach up into the dungeon name's row")
    end

    -- The tooltip is the whole reason these take the mouse, so it has to run.
    local enter = affixButtons[1]:GetScript("OnEnter")
    check(enter ~= nil, "an affix should have a tooltip handler")
    if enter then
        local ok = pcall(enter, affixButtons[1])
        check(ok, "hovering an affix must not error")
    end

    ------------------------------------------------------------------
    -- Eight of them, which is this client's maximum
    ------------------------------------------------------------------

    local eight = setAffixes({ 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008 })
    check(#eight == 8, "all eight affixes should be drawn, got " .. #eight)
    check(eight[8]:GetRight() <= HeroPanelMplusPlate:GetRight() - 13,
        "eight affixes should still sit inside the content column's right edge, got "
        .. tostring(eight[8]:GetRight()) .. " against "
        .. tostring(HeroPanelMplusPlate:GetRight() - 13))

    -- One row, not two: every icon shares a top edge.
    for i = 2, #eight do
        check(math.abs(eight[i]:GetTop() - eight[1]:GetTop()) < 0.01,
            "affix " .. i .. " should share the row's top edge")
    end

    -- A client that reports more than the panel plans for is clamped rather
    -- than allowed to run off the edge.
    local nine = setAffixes({ 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1001 })
    check(#nine == 8, "more than eight affixes should be capped at eight, got " .. #nine)

    ------------------------------------------------------------------
    -- An affix whose icon does not load is not drawn at all
    --
    -- This is the invisible-affix bug: the button was shown and mouse-enabled
    -- on the strength of GetSpellInfo returning a path, without anyone checking
    -- the path drew anything. What was left was a hoverable hole - no icon, but
    -- a tooltip on mouseover.
    ------------------------------------------------------------------

    local mixed = setAffixes({ 1001, AFFIX_BROKEN, 1002 })
    check(#mixed == 2,
        "an affix with an unloadable icon should not be drawn, expected 2 got " .. #mixed)

    for _, button in ipairs(mixed) do
        check(button.affixID ~= AFFIX_BROKEN,
            "the affix with no art should not be left holding an affixID - that is "
            .. "what makes an invisible button answer with a tooltip")
        check(button.icon:GetTexture() ~= "Interface\\Icons\\affix_broken",
            "no drawn affix should be wearing the icon that does not load")
    end

    -- The two that did load close the gap rather than leaving a hole where the
    -- third would have been.
    check(math.abs(mixed[1]:GetLeft() - (HeroPanelMplusPlate:GetLeft() + 13)) < 0.01,
        "the first drawn affix still starts the row")
    check(math.abs((mixed[2]:GetLeft() - mixed[1]:GetLeft()) - 23) < 0.01,
        "the surviving affixes should sit next to each other, got a gap of "
        .. tostring(mixed[2]:GetLeft() - mixed[1]:GetLeft()))

    -- Every affix unloadable: the row goes away entirely rather than leaving a
    -- band of invisible buttons across the panel.
    local none = setAffixes({ AFFIX_BROKEN })
    check(#none == 0, "an affix list with no usable art should draw nothing, got " .. #none)

    ------------------------------------------------------------------
    -- A tooltip does not outlive the button that opened it
    --
    -- The affix list changes mid-run - a key ends, a refresh lands - and a
    -- button hidden while the cursor is on it never receives OnLeave. Without
    -- this the tooltip is left up over an empty panel.
    ------------------------------------------------------------------

    local hovered = setAffixes({ 1001, 1002, 1003 })[2]
    hovered:GetScript("OnEnter")(hovered)
    check(GameTooltip:IsOwned(hovered), "the hovered affix should own the tooltip")
    check(GameTooltip:IsShown(), "hovering should put the tooltip up")

    setAffixes({ 1001 })
    check(not hovered:IsShown(), "the affix that went away should be hidden")
    check(not GameTooltip:IsShown(),
        "hiding the hovered affix should take its tooltip with it - a hidden "
        .. "button gets no OnLeave, so nothing else will")

    ------------------------------------------------------------------
    -- The row's height is the panel's, and only when there is a row
    ------------------------------------------------------------------

    local function timerTop()
        for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
            local text = region.GetText and region:GetText()
            if text and string.match(text, "^%d+:%d%d$") then return region:GetTop() end
        end
    end

    local function forcesLabelTop()
        for _, region in ipairs(HeroPanelMplusPlate.overlay.__regions) do
            if region.GetText and region:GetText() == "Enemy Forces" then return region:GetTop() end
        end
    end

    ------------------------------------------------------------------
    -- With room, the affix row costs exactly its own height
    --
    -- The tracker's objective rows are pushed down first, so heroPanel's block
    -- fits above them with room to spare and the gap budget stays at its design
    -- values. That is the case the 4 + 20 is a promise about.
    ------------------------------------------------------------------

    local function shiftObjectiveRows(dy)
        local seen = {}
        local function shift(object)
            if not object or seen[object] then return end
            seen[object] = true
            if object.__rect then
                object.__rect.top    = object.__rect.top + dy
                object.__rect.bottom = object.__rect.bottom + dy
            end
            for _, region in ipairs(object.__regions or {}) do shift(region) end
            for _, child  in ipairs(object.__children or {}) do shift(child) end
        end
        shift(mplusTracker.ObjectiveBlock)
    end

    shiftObjectiveRows(-60)

    setAffixes({})
    local roomyBare = timerTop()
    setAffixes({ 1001, 1002, 1003 })
    local roomyRow = timerTop()

    if roomyBare and roomyRow then
        check(math.abs((roomyBare - roomyRow) - 24) < 0.01,
            "with room above the boss rows the affix row should push the timer "
            .. "down by 4 + 20, got " .. tostring(roomyBare - roomyRow))
    end

    shiftObjectiveRows(60)

    ------------------------------------------------------------------
    -- Without room, the gaps pay for part of it
    --
    -- This mock's tracker is compact: its first boss row is 130px under the
    -- tracker's top and heroPanel's block does not fit above it with the affix
    -- row in place. The gaps give until the bar clears the row again, so the
    -- affix row costs less than its own height and the panel is tighter rather
    -- than overlapping.
    ------------------------------------------------------------------

    setAffixes({})
    local bareTimer = timerTop()
    setAffixes({ 1001, 1002, 1003 })
    local rowTimer = timerTop()

    if bareTimer and rowTimer then
        local cost = bareTimer - rowTimer
        check(cost > 0 and cost < 24,
            "on a tracker with no room the affix row should cost less than its "
            .. "own 24px, with the gaps paying the rest; got " .. tostring(cost))
    end

    -- The panel's own height does NOT change, and that is right: with boss rows
    -- on screen LayoutPlate sizes the plate from the tracker's content, not from
    -- heroPanel's block. What the extra 24px can do is push heroPanel's rows
    -- down into the tracker's first boss row, and that is what has to hold.
    -- The topmost boss row is at 470 in this mock.
    local forcesTop = forcesLabelTop()
    check(forcesTop and forcesTop > 470,
        "the enemy-forces row must still clear the topmost boss row at 470 with "
        .. "the affix row in place, got " .. tostring(forcesTop))

    -- The label clearing the boss row is not the same as the block clearing it.
    -- The bar hangs 19px under the label and is the lowest thing heroPanel draws
    -- before the tracker's own rows start, so it is the one that has to clear -
    -- checking the label alone is how the bar came to be drawn straight through
    -- "Lord Vyletongue" with the affix row in place.
    local function forcesBarBottom()
        local lowest
        for _, region in ipairs(HeroPanelMplusPlate.__regions) do
            if region:IsShown() and region:GetHeight() == 4 then
                local bottom = region:GetBottom()
                if bottom and (not lowest or bottom < lowest) then lowest = bottom end
            end
        end
        return lowest
    end

    local barBottom = forcesBarBottom()
    check(barBottom and barBottom >= 470,
        "the enemy-forces bar must clear the topmost boss row at 470 too, got "
        .. tostring(barBottom))

    -- Back to the three the rest of the run expects.
    setAffixes({ 1001, 1002, 1003 })
end

--------------------------------------------------------------------------------
-- Disable puts Ascension's tracker back
--------------------------------------------------------------------------------

ns.Mplus.Disable()
check(mplusTracker.HeaderText:GetAlpha() == 1, "disabling should restore the header text")
check(mplusTracker.MainBlock.TimeLeft:GetAlpha() == 1, "disabling should restore the clock")
check(mplusTracker.MainBlock.Affix1.__normal:GetAlpha() == 1, "disabling should restore affix art")
check(mplusTracker.LockButton.__normal:GetAlpha() == 1, "disabling should restore Ascension's lock art")
check(mplusTracker.LockButton:IsMouseEnabled(),
    "disabling should give Ascension's lock button its mouse back")
check(falric.Icon:GetAlpha() == 1, "disabling should restore the boss icon")
check(falric.Counter:GetAlpha() == 1, "disabling should restore the boss counter")

-- The heading loses its verb and gains its count on the way in, and both are
-- heroPanel's edits to a string Ascension wrote. Disabling gives the sentence
-- back whole - the verb included, which the panel drops for width and has no
-- business dropping once it is not the one drawing.
local restoredHeading = heading.Text:GetText() or ""
check(string.sub(restoredHeading, 1, 7) == "Defeat ",
    "disabling should give the heading its verb back, got " .. restoredHeading)
check(not string.find(restoredHeading, "(", 1, true),
    "disabling should take heroPanel's inline count back off, got " .. restoredHeading)
check(HeroPanelMplusPlate:IsShown() == false, "disabling should hide the panel")

-- The enemy-forces row is the one thing heroPanel hides rather than fades, so
-- it is also the one thing that can come back invisible. Both halves of what
-- was taken from it have to be handed back, and its animation has to be free to
-- show it again once the skin is off.
check(forcesBar.Glow:GetAlpha() == 1, "disabling should restore the enemy-forces glow's alpha")
check(forcesBar.Glow:IsShown(), "disabling should show the enemy-forces glow again")
check(forcesBar.__fill:IsShown(), "disabling should show the enemy-forces fill again")
forcesBar.Glow:Hide()
forcesBar:Play()
check(forcesBar.Glow:IsShown(), "with the skin off, the animation owns the row again")

ns.Mplus.Enable()
tick(); tick()
check(HeroPanelMplusPlate:IsShown(), "re-enabling should bring the panel back")
check(mplusTracker.HeaderText:GetAlpha() == 0, "re-enabling should fade the header text again")
check(not forcesBar.Glow:IsShown(), "re-enabling should take the enemy-forces glow back off")

-- The reports have to work whether or not a keystone is running.
ns.Mplus.Dump()
ns.Mplus.PrintStatus()

-- The dump sweeps the tracker for art still drawing below the panel, which is
-- how a strip of Ascension's chrome under it gets named rather than guessed at
-- from a screenshot. A sweep that silently does not run is worse than no
-- sweep - it reads as "nothing found" - so the line it prints is checked for.
do
    local swept
    for i = #log, 1, -1 do
        if string.find(log[i], "below the panel", 1, true) then swept = log[i]; break end
    end
    check(swept ~= nil, "the dump should report what is drawing below the panel")
    check(swept == nil or not string.find(swept, "stray", 1, true),
        "the skinned tracker should leave nothing drawing below the panel; got " .. tostring(swept))

    -- ...and the same for the gap budget. This mock's tracker is compact enough
    -- that the squeeze is running here, so the line is reporting a real number
    -- rather than the trivial case.
    local cleared
    for i = #log, 1, -1 do
        if string.find(log[i], "clears the first boss row", 1, true) then cleared = log[i]; break end
    end
    check(cleared ~= nil, "the dump should report the forces bar's clearance over the boss row")
    check(cleared == nil or not string.find(cleared, "drawn over the row", 1, true),
        "the panel must not be drawing its forces bar over a boss row; got " .. tostring(cleared))
end

--------------------------------------------------------------------------------
-- Fonts through LibSharedMedia
--------------------------------------------------------------------------------

check(ns.GetFontFile() ~= nil, "there must always be a font path to draw with")

do
    local lsm = ns.Media.GetLSM()
    check(lsm ~= nil, "the embedded LibSharedMedia should resolve")

    local faces = ns.Media.ListFonts()
    check(#faces > 0, "the font list must never be empty")

    local hasDefault = false
    for i = 1, #faces do
        if faces[i] == ns.DEFAULT_FONT_FACE then hasDefault = true end
    end
    check(hasDefault, "the default face has to be listed whatever else is")

    -- The default is answered without going through Fetch, so it survives a
    -- library that never registered it and a locale that names it differently.
    ns.db.font.face = ns.DEFAULT_FONT_FACE
    ns.Media.Invalidate()
    check(ns.GetFontFile() == ns.Media.ClientFontFile(),
        "the default face should come from the client, not from the library")

    -- A registered face is fetched and used.
    if lsm then lsm:Register("font", "HeroPanel Test Face", "Fonts\\MORPHEUS.TTF") end
    ns.db.font.face = "HeroPanel Test Face"
    ns.Media.Invalidate()
    check(ns.GetFontFile() == "Fonts\\MORPHEUS.TTF",
        "a registered face should be fetched from the library, got " .. tostring(ns.GetFontFile()))

    -- A face nobody registered falls back rather than handing out nil, which
    -- would blank every string on both panels.
    ns.db.font.face = "No Such Face At All"
    ns.Media.Invalidate()
    check(ns.GetFontFile() == ns.Media.ClientFontFile(),
        "an unknown face must fall back to the client's own")

    ns.db.font.face = ns.DEFAULT_FONT_FACE
    ns.Media.Apply("harness restoring the default face")
    tick(); tick()
end

--------------------------------------------------------------------------------
-- Options panel
--------------------------------------------------------------------------------

check(ns.Options ~= nil, "the options module should be loaded")

-- A bare /hp opens it. That is the command the design puts on the panel and
-- what someone who has not read the command list will type.
SlashCmdList["HEROPANEL"]("")
tick(); tick()
check(ns.Options.IsShown(), "/hp should open the options window")
check(HeroPanelOptionsFrame ~= nil, "the window needs a global name for escape-to-close")

do
    local optionsFrame = HeroPanelOptionsFrame

    check(optionsFrame:GetWidth() == 440,
        "the window is 440 wide, got " .. tostring(optionsFrame:GetWidth()))
    check(optionsFrame:GetFrameStrata() == "DIALOG",
        "the window belongs in its own strata, got " .. tostring(optionsFrame:GetFrameStrata()))

    -- It has to fit on screen. UIParent is about 768 units tall whatever the
    -- monitor is, because the client scales the UI to suit, so this is a fixed
    -- budget rather than a property of the mock's 900-pixel screen - which is
    -- why the number is written down here rather than read off UIParent.
    check(optionsFrame:GetHeight() <= 768,
        "the window must fit inside UIParent's 768 units, got "
        .. tostring(optionsFrame:GetHeight()))
    note("options window: " .. tostring(optionsFrame:GetWidth()) .. " x "
        .. tostring(optionsFrame:GetHeight()))
    check(optionsFrame:GetHeight() > 400,
        "...and it should not have collapsed to nothing, got "
        .. tostring(optionsFrame:GetHeight()))

    -- It must not open on top of the frames it configures. Both trackers live
    -- down one edge; the window defaults to the centre. Checked as an actual
    -- rectangle overlap rather than by trusting the anchor.
    local function Overlaps(a, b)
        if not (a and b) then return false end
        if not (a:GetLeft() and b:GetLeft()) then return false end
        return a:GetLeft() < b:GetRight() and a:GetRight() > b:GetLeft()
           and a:GetBottom() < b:GetTop() and a:GetTop() > b:GetBottom()
    end

    check(not Overlaps(optionsFrame, HeroPanelWatchPlate),
        "the options window must not cover the quest tracker at default positions")
    check(not Overlaps(optionsFrame, HeroPanelMplusPlate),
        "the options window must not cover the Mythic+ tracker at default positions")

    -- Escape-to-close is registered exactly once, however many times the window
    -- is opened and closed.
    ns.Options.Hide()
    ns.Options.Show()
    ns.Options.Hide()
    ns.Options.Show()
    local registrations = 0
    for i = 1, #UISpecialFrames do
        if UISpecialFrames[i] == "HeroPanelOptionsFrame" then registrations = registrations + 1 end
    end
    check(registrations == 1,
        "the window should register for escape once, got " .. registrations)
end

-- Every control gets clicked.
--
-- Building the window and syncing it exercises almost none of what a control
-- actually does: the writes, the live re-skin and the selection redraws all
-- hang off OnClick, and a panel that draws perfectly and does nothing on click
-- looks identical in a screenshot. So each kind of control is driven here and
-- checked against the store afterwards.
do
    ns.Options.Show()
    tick(); tick()

    -- Walk the window for the widgets, rather than having Options.lua export
    -- handles purely so a test can reach them.
    -- One level deeper than it was: the controls live in a ScrollFrame's scroll
    -- child now rather than hanging off the window itself.
    local clickable = {}
    ns.WalkFrameTree(HeroPanelOptionsFrame, function(object, info)
        if info.kind == "child" and object.GetScript and object:GetScript("OnClick") then
            table.insert(clickable, object)
        end
    end, { maxDepth = 5, includeRegions = false })

    check(#clickable >= 20,
        "the window should have a good number of clickable controls, found " .. #clickable)

    -- Background colour: pick a swatch that is not the current one and confirm
    -- the store followed and the tracker was re-skinned rather than merely
    -- recorded.
    --
    -- There are two of every swatch now, one per panel, so both get clicked and
    -- both stores have to follow. A single shared table underneath would pass
    -- the first check and fail the isolation one below.
    local wanted = "#0D0E14"
    local hits = 0
    for i = 1, #clickable do
        if clickable[i].colour == wanted then
            clickable[i]:Click()
            hits = hits + 1
        end
    end
    check(hits >= 2, "a background swatch for " .. wanted .. " should exist for each panel, found " .. hits)
    check(ns.db.panel.watch.bgColor == wanted,
        "clicking a swatch should write the quest panel's store, got "
        .. tostring(ns.db.panel.watch.bgColor))
    check(ns.db.panel.mplus.bgColor == wanted,
        "...and the Mythic+ panel's, got " .. tostring(ns.db.panel.mplus.bgColor))

    -- The store following is only half of it: a swatch that writes the config
    -- and does not re-skin is exactly the "changes need a reload" behaviour the
    -- panel exists to avoid, and it is invisible until you reload.
    local painted = HeroPanelWatchPlate.bg.main.__color
    check(painted ~= nil, "the plate should have been painted at all")
    if painted then
        local wr, wg, wb = ns.HexToRGB(wanted)
        check(math.abs(painted[1] - wr) < 0.01
          and math.abs(painted[2] - wg) < 0.01
          and math.abs(painted[3] - wb) < 0.01,
            "the plate should be repainted live, not on next reload; got "
            .. ns.RGBToHex(painted[1], painted[2], painted[3]))
    end

    -- Border style: the segmented control writes a key the plate understands,
    -- and "inset" has to actually draw differently from "hairline" now that it
    -- is a real style rather than a synonym.
    local hairlineTop = HeroPanelWatchPlate.edge.top:GetTop()
    ns.db.panel.watch.borderStyle = "inset"
    ns.Skin.Restyle()
    local insetTop = HeroPanelWatchPlate.edge.top:GetTop()
    check(insetTop ~= hairlineTop,
        "an inset border should sit a pixel inside a hairline one, both at "
        .. tostring(insetTop))

    ns.db.panel.watch.borderStyle = "none"
    ns.Skin.Restyle()
    check(not HeroPanelWatchPlate.edge.top:IsShown(), "border style none draws no edge")

    ns.db.panel.watch.borderStyle = "hairline"
    ns.Skin.Restyle()
    check(HeroPanelWatchPlate.edge.top:IsShown(), "border style hairline draws an edge")

    -- The font dropdown: open it, and pick a face off it.
    if ns.Media.GetLSM() then
        ns.Media.GetLSM():Register("font", "Harness Clickable Face", "Fonts\\ARIALN.TTF")
    end

    local opened, picked = false, false
    for i = 1, #clickable do
        local before = ns.db.font.face
        clickable[i]:Click()
        -- Opening the dropdown reveals its rows, which are a level deeper.
        ns.WalkFrameTree(HeroPanelOptionsFrame, function(object, info)
            if picked then return false end
            if info.kind == "child" and object.face == "Harness Clickable Face" then
                opened = true
                object:Click()
                picked = true
            end
        end, { maxDepth = 5, includeRegions = false })
        if picked then break end
        -- Undo anything else the click did to the face.
        ns.db.font.face = before
    end

    check(opened, "the font dropdown should list a newly registered face")
    check(ns.db.font.face == "Harness Clickable Face",
        "picking a face should write the store, got " .. tostring(ns.db.font.face))
    check(ns.GetFontFile() == "Fonts\\ARIALN.TTF",
        "...and it should be the file the trackers now draw with, got " .. tostring(ns.GetFontFile()))

    -- Put everything back and confirm the round trip left nothing broken.
    ns.Options.Reset()
    tick(); tick()
    check(ns.db.panel.watch.bgColor == ns.defaults.panel.watch.bgColor,
        "reset should undo the swatch click")
    check(ns.db.panel.mplus.bgColor == ns.defaults.panel.mplus.bgColor,
        "...on both panels")
    check(ns.db.font.face == ns.DEFAULT_FONT_FACE, "reset should undo the font pick")
    check(ns.GetFontFile() == ns.Media.ClientFontFile(),
        "reset should put the client's own face back on the trackers")

    ns.Options.Hide()
end

-- Every control reads the store when the window opens, so a value changed by a
-- slash command while it was shut is what comes back on screen.
do
    SlashCmdList["HEROPANEL"]("font 17")
    tick(); tick()
    ns.Options.Hide()
    ns.Options.Show()
    check(ns.db.font.size.watchTitle == 17, "the slash command should still own the store")
    check(ns.db.font.size.mplusTimer == 17,
        "...for every role, which is what one argument can mean; got "
        .. tostring(ns.db.font.size.mplusTimer))

    -- Scale is set from outside the window now - by /hp scale and by the corner
    -- grips - so what matters is that opening the window does not overwrite it.
    -- It used to have two sliders, and the risk was those pushing their own
    -- stale value back on sync; the risk with no sliders is Reset or a rebuild
    -- quietly resetting it instead, which this catches just the same.
    ns.SetScale("watch", 1.3)
    ns.SetScale("mplus", 0.7)
    ns.Options.Hide()
    ns.Options.Show()
    tick()
    check(math.abs(ns.db.frame.watch.scale - 1.3) < 0.001,
        "opening the window must not overwrite a scale set from elsewhere, got "
        .. tostring(ns.db.frame.watch.scale))
    check(math.abs(ns.db.frame.mplus.scale - 0.7) < 0.001,
        "the Mythic+ scale should survive the same round trip, got "
        .. tostring(ns.db.frame.mplus.scale))

    SlashCmdList["HEROPANEL"]("font 12")
    tick(); tick()
end

-- The enable toggle restores and re-applies live, in both directions, with no
-- reload. This is the escape hatch, so it is the one that must not be subtly
-- broken.
do
    local watchTitle = trackerLines[1].__text
    local skinnedColour = colourOf(watchTitle)

    ns.Skin.SetEnabled(false)
    tick(); tick()
    check(not ns.SkinEnabled("watch"), "disabling should write the store")
    check(not ns.SkinEnabled("mplus"), "...for both panels")
    check(not HeroPanelWatchPlate:IsShown(), "disabling should hide the quest panel")
    check(not HeroPanelMplusPlate:IsShown(), "disabling should hide the Mythic+ panel too")
    check(colourOf(watchTitle) ~= skinnedColour,
        "disabling should hand the quest title's colour back to Blizzard")

    ns.Options.Sync()
    ns.Skin.SetEnabled(true)
    tick(); tick()
    check(ns.SkinEnabled("watch"), "re-enabling should write the store")
    check(HeroPanelWatchPlate:IsShown(), "re-enabling should bring the quest panel back")
    check(colourOf(watchTitle) == skinnedColour,
        "re-enabling should put the skin's colour back, got " .. tostring(colourOf(watchTitle)))
end

-- ...and the two panels are independent, which is the whole point of splitting
-- the one flag in two. Turning the Mythic+ panel off to compare it against
-- Ascension's own tracker must leave the quest tracker alone.
do
    ns.SetSkinEnabled("mplus", false)
    tick(); tick()
    check(not ns.SkinEnabled("mplus"), "the Mythic+ flag should be written on its own")
    check(ns.SkinEnabled("watch"), "...without touching the objective tracker's")
    check(not HeroPanelMplusPlate:IsShown(), "the Mythic+ panel should be gone")
    check(HeroPanelWatchPlate:IsShown(), "...and the quest panel still there")

    ns.SetSkinEnabled("mplus", true)
    tick(); tick(); tick()
    check(HeroPanelMplusPlate:IsShown(), "the Mythic+ panel should come back on its own")

    ns.SetSkinEnabled("watch", false)
    tick(); tick()
    check(not HeroPanelWatchPlate:IsShown(), "the quest panel should go on its own")
    check(HeroPanelMplusPlate:IsShown(), "...leaving the Mythic+ panel up")

    ns.SetSkinEnabled("watch", true)
    tick(); tick(); tick()
    check(HeroPanelWatchPlate:IsShown(), "...and come back")
    ns.Options.Sync()
end

-- Nothing tracked, nothing drawn. Off by default, so the panel is up over an
-- empty tracker until the setting says otherwise.
--
-- Full client only: with no GetNumQuestWatches the count falls back to the
-- blocks the line walk found, and the mock's tracker always has three of them.
-- That fallback is a real path and it is exercised by the badge test; there is
-- just no way to drive it to zero from here without dismantling the tracker.
if not MINIMAL then
    local watched = questWatches
    questWatches = 0
    ns.Skin.Refresh("harness: nothing tracked")
    tick(); tick()
    check(HeroPanelWatchPlate:IsShown(),
        "an empty tracker keeps its panel while hide-when-empty is off")

    ns.db.header.hideEmpty = true
    ns.Skin.Refresh("harness: hide when empty")
    tick(); tick()
    check(not HeroPanelWatchPlate:IsShown(),
        "hide-when-empty should take the whole panel off, not just the header")
    check(titleFS:GetAlpha() == 0,
        "...and leave Blizzard's own header faded rather than swapping one for the other")

    questWatches = watched
    ns.Skin.Refresh("harness: tracking again")
    tick(); tick()
    check(HeroPanelWatchPlate:IsShown(),
        "tracking a quest again should bring the panel straight back")

    ns.db.header.hideEmpty = false
    ns.Skin.Refresh("harness: hide-when-empty off")
    tick(); tick()
end

-- Reset puts the defaults back and re-applies them, rather than only writing
-- the store and waiting for a reload.
do
    ns.db.panel.watch.bgColor = "#232532"
    ns.db.panel.watch.radius  = 12
    ns.db.panel.mplus.radius  = 0
    ns.db.font.size.watchTitle = 19
    ns.db.font.size.mplus      = 26
    ns.db.header.show = false

    ns.Options.Reset()
    tick(); tick()

    check(ns.db.panel.watch.bgColor == ns.defaults.panel.watch.bgColor,
        "reset should restore the background colour, got " .. tostring(ns.db.panel.watch.bgColor))
    check(ns.db.panel.watch.radius == ns.defaults.panel.watch.radius,
        "reset should restore the quest panel's radius, got " .. tostring(ns.db.panel.watch.radius))
    check(ns.db.panel.mplus.radius == ns.defaults.panel.mplus.radius,
        "...and the Mythic+ panel's, got " .. tostring(ns.db.panel.mplus.radius))
    check(ns.db.font.size.watchTitle == ns.defaults.font.size.watchTitle,
        "reset should restore the quest-name size, got " .. tostring(ns.db.font.size.watchTitle))
    check(ns.db.font.size.mplus == ns.defaults.font.size.mplus,
        "...and the Mythic+ size, got " .. tostring(ns.db.font.size.mplus))
    check(ns.db.header.show == true, "reset should restore the header")
    check(ns.SkinEnabled("watch") and ns.SkinEnabled("mplus"),
        "reset should leave both skins enabled")

    local _, titleAfterReset = trackerLines[1].__text:GetFont()
    check(titleAfterReset == ns.GetFontSize(0, "watchTitle"),
        "reset should re-apply the skin, not just write the store; got " .. tostring(titleAfterReset))
end

-- Interface -> AddOns registers one category, and its button opens the same
-- window rather than a second copy of the controls.
if not MINIMAL then
    check(#INTERFACE_CATEGORIES == 1,
        "exactly one interface options category, got " .. #INTERFACE_CATEGORIES)
    check(INTERFACE_CATEGORIES[1] and INTERFACE_CATEGORIES[1].name == "heroPanel",
        "the category should be named heroPanel")
end

--------------------------------------------------------------------------------
-- The scrolling body
--
-- The window carried eight sliders and only just fitted; splitting the panel
-- and border settings per tracker put the same six controls in twice, and no
-- amount of shaving rows fits that into UIParent's 768 units. So the body
-- scrolls, and the checks are that it is actually taller than its viewport -
-- otherwise the scroll plumbing is untested decoration - and that the wheel
-- moves it and stops at both ends.
--------------------------------------------------------------------------------

do
    ns.Options.Show()
    tick()

    local viewport = HeroPanelOptionsFrame.viewport
    local body     = viewport and viewport:GetScrollChild()
    check(viewport ~= nil and body ~= nil, "the options body should live in a ScrollFrame")

    note("options body: " .. tostring(body:GetHeight())
        .. " of content in a " .. tostring(viewport:GetHeight()) .. " viewport")
    check(body:GetHeight() > viewport:GetHeight(),
        "the body should be taller than its viewport - a body that fits leaves the "
        .. "scrolling untested; got " .. tostring(body:GetHeight())
        .. " in " .. tostring(viewport:GetHeight()))

    local wheel = viewport:GetScript("OnMouseWheel")
    check(wheel ~= nil, "the viewport should take the wheel")

    wheel(viewport, -1)
    check(viewport:GetVerticalScroll() > 0,
        "a wheel notch down should scroll the body, got " .. tostring(viewport:GetVerticalScroll()))

    for _ = 1, 40 do wheel(viewport, -1) end
    check(viewport:GetVerticalScroll() <= body:GetHeight() - viewport:GetHeight() + 0.001,
        "scrolling past the end should stop at the end, got "
        .. tostring(viewport:GetVerticalScroll()))

    for _ = 1, 60 do wheel(viewport, 1) end
    check(viewport:GetVerticalScroll() == 0, "and scrolling back up should stop at the top")

    ns.Options.Hide()
end

--------------------------------------------------------------------------------
-- The resize grip
--
-- This replaced the two scale sliders. The sliders wrote the store through
-- ns.SetScale and so does the grip, so what is new here is the drag: the anchor
-- is the panel's top-left corner in screen pixels, and the scale follows how
-- far the cursor is from it. Everything is measured in screen pixels on purpose
-- - the panel's own units change meaning as it is scaled, which is the one
-- coordinate space a rescale must not be measured in.
--------------------------------------------------------------------------------

do
    local grip = HeroPanelWatchPlate.grip
    check(grip ~= nil, "the quest panel should carry a resize grip")
    check(HeroPanelMplusPlate.grip ~= nil, "and so should the Mythic+ panel")

    ns.SetLocked(true)
    check(not grip:IsShown(),
        "the grip is put away while the trackers are locked - it is edit-mode furniture")
    check(not HeroPanelMplusPlate.grip:IsShown(), "both of them")

    ns.SetLocked(false)
    check(grip:IsShown(), "and both come back when the trackers are unlocked")
    check(HeroPanelMplusPlate.grip:IsShown(), "both of them")

    -- A locked grip refuses the drag even if something manages to click it.
    ns.SetLocked(true)
    grip:GetScript("OnMouseDown")(grip)
    check(grip.drag == nil, "a locked grip must not start a drag")
    ns.SetLocked(false)

    ns.SetScale("watch", 1.0)
    tick()

    local plate  = HeroPanelWatchPlate
    local scale  = plate:GetEffectiveScale()
    local anchorX, anchorY = plate:GetLeft() * scale, plate:GetTop() * scale

    -- Grab the corner.
    cursorX = plate:GetRight()  * scale
    cursorY = plate:GetBottom() * scale
    local startReach = (cursorX - anchorX) + (anchorY - cursorY)

    mouseDown.LeftButton = true
    grip:GetScript("OnMouseDown")(grip)
    check(grip.drag ~= nil, "clicking the grip should start a drag")

    -- Pull it out to one and a fifth of that reach, along both axes.
    cursorX = anchorX + (cursorX - anchorX) * 1.2
    cursorY = anchorY - (anchorY - cursorY) * 1.2
    grip:GetScript("OnUpdate")(grip)
    tick()

    check(math.abs(ns.db.frame.watch.scale - 1.2) < 0.051,
        "dragging the grip out should scale the tracker up, got "
        .. tostring(ns.db.frame.watch.scale))

    -- ...and back in, past the floor, which clamps rather than inverting.
    cursorX = anchorX + startReach * 0.05
    cursorY = anchorY
    grip:GetScript("OnUpdate")(grip)
    tick()
    check(ns.db.frame.watch.scale >= ns.SCALE_MIN - 0.001,
        "the grip must not drag the panel below the floor, got "
        .. tostring(ns.db.frame.watch.scale))

    -- Releasing outside the grip never reaches its OnMouseUp, so the button
    -- state is what has to end the drag.
    mouseDown.LeftButton = nil
    grip:GetScript("OnUpdate")(grip)
    check(grip.drag == nil, "the drag should end when the button comes up, wherever the cursor is")

    cursorX, cursorY = -1000, -1000
    ns.SetScale("watch", 1.0)
    ns.SetLocked(true)
    tick(); tick()
end

--------------------------------------------------------------------------------
-- The options window resizes too
--
-- Same grip widget as the trackers', wired to the window's own scale instead of
-- a tracker's. Two things separate it from theirs: it is always shown, because
-- the lock governs whether the *trackers* can be dragged and this window has
-- never consulted it to decide whether its own header can be; and its saved
-- position has to survive a rescale, which is the bug a scalable window
-- introduces. A SetPoint offset is read in the moved frame's own units, so the
-- same pair of numbers means a different place on screen once the frame is
-- scaled - store screen position, convert on the way out.
--------------------------------------------------------------------------------

do
    ns.Options.Show()
    tick()

    local grip = HeroPanelOptionsFrame.grip
    check(grip ~= nil, "the options window should carry a resize grip")

    -- It follows the lock, the same as the trackers' grips.
    --
    -- This was built always-on, reasoning that the lock governs the trackers and
    -- this window has never consulted it to decide whether its own header can be
    -- dragged. The reasoning holds and the result was still wrong: three panels
    -- with a corner handle, two of which put it away on lock and one of which
    -- does not, reads as the third having missed the memo.
    ns.SetLocked(true)
    check(not grip:IsShown(),
        "the options window's grip goes away with the trackers', so all three agree")

    ns.SetLocked(false)
    check(grip:IsShown(), "...and comes back with them")

    -- Put it somewhere definite and remember where that is on screen.
    ns.db.options.point = "TOPLEFT"
    ns.db.options.x, ns.db.options.y = 120, -90
    ns.Options.Hide()
    ns.Options.Show()
    tick()

    local uiScale = UIParent:GetEffectiveScale()
    local beforeX = HeroPanelOptionsFrame:GetLeft() * HeroPanelOptionsFrame:GetEffectiveScale()
    local beforeY = HeroPanelOptionsFrame:GetTop()  * HeroPanelOptionsFrame:GetEffectiveScale()

    ns.Options.SetScale(1.3)
    check(math.abs((ns.db.options.scale or 1) - 1.3) < 0.001,
        "the scale should be written to the store, got " .. tostring(ns.db.options.scale))
    check(math.abs(HeroPanelOptionsFrame:GetScale() - 1.3) < 0.001,
        "...and applied to the frame, got " .. tostring(HeroPanelOptionsFrame:GetScale()))

    local afterX = HeroPanelOptionsFrame:GetLeft() * HeroPanelOptionsFrame:GetEffectiveScale()
    local afterY = HeroPanelOptionsFrame:GetTop()  * HeroPanelOptionsFrame:GetEffectiveScale()
    check(math.abs(afterX - beforeX) < 1 and math.abs(afterY - beforeY) < 1,
        "the window's top-left corner must stay put across a rescale, moved from "
        .. tostring(beforeX) .. "," .. tostring(beforeY)
        .. " to " .. tostring(afterX) .. "," .. tostring(afterY))

    -- ...and it survives the window being shut and reopened, which is where a
    -- scale that is applied but never re-read shows up.
    ns.Options.Hide()
    ns.Options.Show()
    tick()
    check(math.abs(HeroPanelOptionsFrame:GetScale() - 1.3) < 0.001,
        "reopening should re-apply the saved scale, got "
        .. tostring(HeroPanelOptionsFrame:GetScale()))
    local reopenX = HeroPanelOptionsFrame:GetLeft() * HeroPanelOptionsFrame:GetEffectiveScale()
    check(math.abs(reopenX - beforeX) < 1,
        "...and put it back in the same place, got " .. tostring(reopenX))

    -- Dragging writes UIParent-space offsets, so a drag at 130% and a reopen
    -- have to agree about where the window was left.
    local dropX, dropY = 260, -140
    HeroPanelOptionsFrame:ClearAllPoints()
    ns.ApplyUIOffsets(HeroPanelOptionsFrame, dropX, dropY)
    HeroPanelOptionsFrame:GetScript("OnDragStop")(HeroPanelOptionsFrame)
    check(math.abs(ns.db.options.x - dropX) < 1 and math.abs(ns.db.options.y - dropY) < 1,
        "a drag at a non-default scale should save UIParent-space offsets, got "
        .. tostring(ns.db.options.x) .. "," .. tostring(ns.db.options.y))

    ns.Options.SetScale(1.0)
    ns.db.options.point, ns.db.options.x, ns.db.options.y = nil, 0, 0
    ns.Options.Hide()
end

--------------------------------------------------------------------------------
-- Glyph outlines
--
-- The lock and the caret are drawn in a mid grey over whatever the world is
-- doing behind a panel the player can make transparent, and grey over a lit
-- hillside is not a shape. A texture has no SetShadowColor, so an outlined
-- glyph draws four black copies of itself on a lower layer.
--------------------------------------------------------------------------------

do
    -- Found by the flag, not by having shadow tables: every glyph carries those
    -- now, empty, so testing for them finds the check marks and the resize grip
    -- as readily as the two that asked to be outlined.
    local lock
    ns.WalkFrameTree(HeroPanelWatchPlate, function(object)
        if not lock and object.outlined then lock = object end
    end, { maxDepth = 3, includeRegions = false })

    check(lock ~= nil, "the header glyphs should be outlined")

    if lock then

        -- Whichever route the glyph took, the outline has to have followed it.
        local set = (lock.usingArt and lock.artShadows[1]) or lock.partShadows[1]
        check(set ~= nil,
            "an outlined glyph should have built its shadow textures ("
            .. (lock.usingArt and "art" or "blocks") .. " route)")
        if set then
            check(#set == 4, "four offsets, one per side, got " .. tostring(#set))
            local colour = set[1].__color
            check(colour and colour[1] == 0 and colour[2] == 0 and colour[3] == 0,
                "the outline is black, whatever the glyph in front of it is")
            check(set[1]:IsShown(), "and it is actually drawn")
        end
    end

    -- A plain glyph must not pay for any of it.
    local plain = ns.NewGlyph(UIParent, 12)
    plain:SetShape("check")
    check(not plain.outlined, "glyphs are not outlined unless asked")
    check(#plain.artShadows == 0 and #plain.partShadows == 0,
        "...and an un-outlined glyph builds no shadow textures")
end

--------------------------------------------------------------------------------
-- The caret has a click target of its own
--
-- Clicking the chevron used to rely on one of two things underneath it: the
-- header strip, which sits below the tracker's frame level and so stops
-- receiving anything once the tracker has been unlocked and keeps the mouse, or
-- Blizzard's collapse button, which is not the same rectangle as the glyph
-- heroPanel draws. After the glyph grew, what was left was noticeably smaller
-- than what you could see.
--------------------------------------------------------------------------------

do
    local button = HeroPanelWatchPlate and HeroPanelWatchPlate.__caretButton
    -- Reached by walking, for the same reason the glyph above is: Skin.lua does
    -- not export its header widgets purely so a test can find them.
    if not button then
        ns.WalkFrameTree(HeroPanelWatchPlate, function(object, info)
            if button then return false end
            if info.kind == "child" and object.__kind == "Button"
               and object:GetWidth() == 26 and object:GetHeight() == 26
               and object:GetScript("OnClick") then
                button = object
            end
        end, { maxDepth = 2, includeRegions = false })
    end

    check(button ~= nil, "the caret should have a button of its own")

    if button then
        check(button:GetWidth() >= 24,
            "...and it should be bigger than the 15px chevron it covers, got "
            .. tostring(button:GetWidth()))

        -- Above the tracker, like the lock. An unlocked tracker is mouse-enabled
        -- across its whole rectangle, so anything left below it stops taking
        -- clicks the first time the tracker is unlocked in a session.
        check(button:GetFrameLevel() > WatchFrame:GetFrameLevel(),
            "...and raised above the tracker, got " .. tostring(button:GetFrameLevel())
            .. " against " .. tostring(WatchFrame:GetFrameLevel()))

        local before = ns.IsCollapsed("watch")
        button:GetScript("OnClick")(button)
        tick(); tick()
        check(ns.IsCollapsed("watch") ~= before, "clicking it should collapse the tracker")
        button:GetScript("OnClick")(button)
        tick(); tick()
        check(ns.IsCollapsed("watch") == before, "...and clicking again should expand it")
    end
end

--------------------------------------------------------------------------------
-- Text shadow
--
-- Off by default, because the design's colours were chosen against a solid
-- background. It earns its place the moment the background opacity comes down.
--------------------------------------------------------------------------------

do
    local title = trackerLines[1].__text

    ns.db.panel.watch.textShadow = false
    ns.Options.Apply("shadow off")
    tick(); tick()
    local _, _, _, a = title:GetShadowColor()
    check((a or 0) == 0, "no shadow on a quest line by default, got " .. tostring(a))

    ns.db.panel.watch.textShadow     = true
    ns.db.panel.watch.textShadowSize = 2
    ns.Options.Apply("shadow on")
    tick(); tick()

    local _, _, _, on = title:GetShadowColor()
    check((on or 0) > 0, "turning it on should reach the quest names, got " .. tostring(on))
    local ox, oy = title:GetShadowOffset()
    check(ox == 2 and oy == -2,
        "...at the configured thickness, got " .. tostring(ox) .. "," .. tostring(oy))

    -- Per panel. The Mythic+ setting is a different flag and must not follow.
    check(ns.db.panel.mplus.textShadow == false,
        "the two panels carry their own shadow setting")

    -- Clamped: a store holding something outside 1-3 must still draw something
    -- sane rather than a 40px smear.
    ns.db.panel.watch.textShadowSize = 99
    ns.Options.Apply("shadow clamp")
    tick(); tick()
    local cx = select(1, title:GetShadowOffset())
    check(cx == 3, "the thickness is clamped to 3, got " .. tostring(cx))

    -- And /hp skin off hands the line back without it.
    ns.db.panel.watch.textShadowSize = 1
    ns.Skin.SetEnabled(false)
    tick(); tick()
    local _, _, _, off = title:GetShadowColor()
    check((off or 0) == 0,
        "disabling the skin should take the shadow back off, got " .. tostring(off))

    ns.Skin.SetEnabled(true)
    ns.db.panel.watch.textShadow = false
    ns.Options.Apply("shadow test reset")
    tick(); tick()
end

--------------------------------------------------------------------------------
-- Auto-hide
--
-- Two halves, because neither one is enough. The alpha goes to zero, which is
-- the half that always lands: Hide is refused on WatchFrame under lockdown,
-- which is exactly when "hide in combat" has to take effect, and SetAlpha is not
-- protected. Then the frame is hidden outright when the client allows it, which
-- is the half that makes the rectangle click-through - a faded tracker still
-- takes the clicks, and its quest lines and POI buttons take their own.
--
-- The split falls where the two triggers need it: a key starting is not a combat
-- transition, so the Mythic+ hide lands immediately; a combat hide waits, and
-- must then not land after the fight it was queued for has ended.
--------------------------------------------------------------------------------

do
    -- The two halves of a combat transition, which the mock keeps apart: the
    -- lockdown flag is what protected calls test, and the event is what
    -- heroPanel listens for.
    local function enterCombat()
        combat = true
        fire("PLAYER_REGEN_DISABLED")
    end
    local function leaveCombat()
        combat = false
        fire("PLAYER_REGEN_ENABLED")
    end

    ns.db.autoHide.combat = true
    ns.db.autoHide.mythic = false

    enterCombat()
    tick(); tick()
    check(WatchFrame:GetAlpha() == 0,
        "entering combat should fade the tracker, got " .. tostring(WatchFrame:GetAlpha()))
    check(not HeroPanelWatchPlate:IsShown(), "...and take heroPanel's panel with it")
    check(ns.Skin.IsAutoHidden(), "...and say so")
    check(WatchFrame:IsShown(),
        "Hide is protected, so a combat hide cannot land during the fight itself")

    -- A refresh mid-fight must not put the panel back up over a tracker that is
    -- not there. Quest turn-ins fire plenty of these.
    ns.Skin.Refresh("mid-combat update")
    tick(); tick()
    check(not HeroPanelWatchPlate:IsShown(),
        "a refresh while auto-hidden must not bring the panel back")

    leaveCombat()
    tick(); tick()
    check(WatchFrame:GetAlpha() == 1,
        "leaving combat should bring it back, got " .. tostring(WatchFrame:GetAlpha()))
    check(HeroPanelWatchPlate:IsShown(), "...and the panel with it")
    check(not ns.Skin.IsAutoHidden(), "...and clear the flag")
    -- The deferred hide and the lift both run off PLAYER_REGEN_ENABLED. A hide
    -- queued for a fight must not land a frame after that fight has ended.
    check(WatchFrame:IsShown(),
        "the hide queued during the fight must not fire once the fight is over")

    -- Off means off: a fight with the setting disabled changes nothing.
    ns.db.autoHide.combat = false
    enterCombat()
    tick(); tick()
    check(WatchFrame:GetAlpha() == 1, "with the setting off, combat leaves the tracker alone")
    leaveCombat()
    tick(); tick()

    -- The Mythic+ half asks the Mythic+ module rather than the API, so there is
    -- one answer to "is a key running".
    check(type(ns.Mplus.IsActive) == "function", "the Mythic+ module should answer that")
    ns.db.autoHide.mythic = true
    ns.Skin.RefreshAutoHide()
    tick(); tick()
    check(ns.Skin.IsAutoHidden() == ns.Mplus.IsActive(),
        "the quest tracker should follow the keystone state")

    -- The case this was reported for: a key starts out of combat, so the Hide
    -- lands there and then and the tracker's rectangle stops taking clicks for
    -- the length of the run. A faded frame is still a frame.
    if ns.Mplus.IsActive() then
        check(not WatchFrame:IsShown(),
            "a key starting out of combat should hide the tracker outright, not just fade it")

        -- The game shows the tracker again from under the fade often enough - a
        -- turn-in is one - and it comes back invisible and clickable.
        WatchFrame:Show()
        ns.Skin.Refresh("tracker shown from under the fade")
        tick(); tick()
        check(not WatchFrame:IsShown(),
            "a tracker shown from under an auto-hide should be hidden again")
    end

    ns.db.autoHide.mythic = false
    ns.Skin.RefreshAutoHide()
    tick(); tick()
    check(WatchFrame:IsShown(), "ending the auto-hide should show the tracker again")
    check(WatchFrame:GetAlpha() == 1, "...at the alpha it had before")

    -- Turning the skin off must never leave a faded tracker behind.
    ns.db.autoHide.combat = true
    enterCombat()
    tick(); tick()
    ns.Skin.SetEnabled(false)
    tick(); tick()
    check(WatchFrame:GetAlpha() == 1,
        "/hp skin off must hand back a visible tracker even mid-fight, got "
        .. tostring(WatchFrame:GetAlpha()))
    check(WatchFrame:IsShown(), "...and a shown one")
    leaveCombat()
    ns.Skin.SetEnabled(true)
    ns.db.autoHide.combat = false
    tick(); tick()

    -- The same switch, over the half that does land: a tracker hidden outright
    -- for a key must be shown again by the skin being turned off, not left
    -- hidden with nothing on screen saying why.
    if ns.Mplus.IsActive() then
        ns.db.autoHide.mythic = true
        ns.Skin.RefreshAutoHide()
        tick(); tick()
        check(not WatchFrame:IsShown(), "the key should have hidden it outright")

        ns.Skin.SetEnabled(false)
        tick(); tick()
        check(WatchFrame:IsShown(), "/hp skin off must show a tracker heroPanel hid")
        check(WatchFrame:GetAlpha() == 1, "...at the alpha it had before")

        ns.db.autoHide.mythic = false
        ns.Skin.SetEnabled(true)
        tick(); tick(); tick()
    end
end

--------------------------------------------------------------------------------
-- The options window's own background is configurable
--
-- The rest of its chrome stays a design token. The reason that rule existed --
-- a config panel that restyles itself as you drag a swatch makes it impossible
-- to see what you are setting -- does not reach the window's own background,
-- because there is no second thing that swatch could be confused with.
--------------------------------------------------------------------------------

do
    ns.Options.Show()
    tick()

    local before = HeroPanelOptionsFrame.bg.main.__color
    check(before ~= nil, "the window should have a painted background at all")

    ns.db.panel.options.bgColor = "#232532"
    ns.Options.Restyle()

    local after = HeroPanelOptionsFrame.bg.main.__color
    local wr, wg, wb = ns.HexToRGB("#232532")
    check(after and math.abs(after[1] - wr) < 0.01 and math.abs(after[2] - wg) < 0.01
        and math.abs(after[3] - wb) < 0.01,
        "restyling should repaint the window's background live, got "
        .. ns.RGBToHex(after[1], after[2], after[3]))

    -- The border stays the design's, whatever the background is set to.
    local edge = HeroPanelOptionsFrame.edge.top.__color
    local er, eg, eb = ns.HexToRGB("#E9E9ED")
    check(edge and math.abs(edge[1] - er) < 0.01 and math.abs(edge[2] - eg) < 0.01
        and math.abs(edge[3] - eb) < 0.01,
        "...without touching the border, which is not configurable")

    ns.db.panel.options.bgColor = ns.defaults.panel.options.bgColor
    ns.Options.Restyle()
    ns.Options.Hide()
end

ns.Options.Hide()
check(not ns.Options.IsShown(), "Save & close should hide the window")

--------------------------------------------------------------------------------
-- The quest POI arrow goes beside its own title
--
-- The turn-in question mark and the POI arrow both hang off the left of a quest
-- line and are the same size on the same row, so the left-margin tuck put them
-- in the same column - which says nothing about which quest is being pointed
-- at, and stacks them when both are up. The arrow goes to the right of its own
-- title instead.
--------------------------------------------------------------------------------

do
    local poi = trackerPois[4]
    check(poi ~= nil, "the mock should have a POI arrow on the second quest")

    local title = trackerLines[4].__text
    ns.Skin.Refresh("poi placement")
    tick(); tick()

    check(poi:GetLeft() >= plate:GetLeft() and poi:GetRight() <= plate:GetRight(),
        "the arrow belongs inside the panel, got left " .. tostring(poi:GetLeft())
        .. " against panel " .. tostring(plate:GetLeft()) .. ".." .. tostring(plate:GetRight()))

    -- Measured from where the name is drawn, not from the rect it is drawn in.
    -- This title's rect deliberately stops short of its own string, which is the
    -- shape the bug was reported in: an arrow placed from the rect lands
    -- part-way along the quest name instead of after it.
    local textEnd = title:GetLeft() + title:GetStringWidth()
    check(textEnd > title:GetRight() + 1,
        "the mock's title must draw wider than its own rect or this proves nothing, "
        .. "text ends " .. tostring(textEnd) .. ", rect ends " .. tostring(title:GetRight()))
    check(poi:GetLeft() >= textEnd,
        "the arrow should sit after the last character of the quest name, got "
        .. tostring(poi:GetLeft()) .. " against text ending at " .. tostring(textEnd))

    -- On its own quest's row, not the one above or below it.
    local top, bottom = poi:GetTop(), poi:GetBottom()
    check(top > title:GetBottom() and bottom < title:GetTop(),
        "the arrow should be on its own title's row")

    local otherTitle = trackerLines[1].__text
    check(not (top > otherTitle:GetBottom() and bottom < otherTitle:GetTop()),
        "...and not on another quest's row")

    -- It must not land in the left margin with the question mark.
    check(poi:GetLeft() > plate:GetLeft() + 40,
        "the arrow must not be tucked into the left margin, got "
        .. tostring(poi:GetLeft() - plate:GetLeft()) .. " in from the panel")

    -- Re-anchored every pass rather than settling, so a title that changes
    -- length does not leave it behind. Idempotent: a pass that changes nothing
    -- moves nothing.
    local settled = poi:GetLeft()
    ns.Skin.Refresh("poi second pass")
    tick(); tick()
    check(math.abs(poi:GetLeft() - settled) < 0.01,
        "a second pass must not move it again, got " .. tostring(poi:GetLeft()))

    -- Turning the skin off puts it back where the tracker had it.
    local before = poi:GetLeft()
    ns.Skin.SetEnabled(false)
    tick(); tick()
    check(poi:GetLeft() ~= before, "disabling should restore the arrow's own anchor")
    ns.Skin.SetEnabled(true)
    tick(); tick(); tick()
end

--------------------------------------------------------------------------------
-- Scaling a tracker that another addon has docked into a holder
--
-- The bug this exists for: "quest tracker scale" slid the tracker sideways
-- instead of resizing it.
--
-- A holder is a frame the tracker is anchored *to*, not one it is parented to.
-- ElvUI's is the case in hand - WatchFrameHolder is a child of UIParent and
-- ElvUI does WatchFrame:SetPoint("TOP", WatchFrameHolder, "TOP") - so scaling
-- the holder cannot scale the tracker, because scale is inherited through
-- parentage and the tracker is not its child. What it does do is move it: the
-- holder's TOP is its horizontal centre, a scaled holder is wider on screen, so
-- its centre shifts and the tracker hanging off it shifts with it.
--
-- So scale goes to the tracker and position keeps going to the mover.
--------------------------------------------------------------------------------

do
    local holder = CreateFrame("Frame", "TestWatchFrameHolder", UIParent)
    holder:SetWidth(207)
    holder:SetHeight(22)
    holder.__rect = { left = 1000, right = 1207, top = 800, bottom = 778 }

    local record = ns.trackers.watch
    local realHolderFrame, realHolderName = record.holderFrame, record.holderName
    local realOwnership = HEROPANEL_DB.frame.ownership

    record.holderFrame = holder
    record.holderName  = "TestWatchFrameHolder"
    ns.SetOwnership("holder", "watch")

    check(ns.GetMode("watch") == "holder", "the tracker should be in holder mode for this check")
    check(ns.GetActiveMover("watch") == holder, "the mover should be the holder")
    check(ns.GetScaleTarget("watch") == WatchFrame,
        "the scale target must be the tracker itself, never the holder")

    local holderScaleBefore = holder:GetScale()
    ns.SetScale("watch", 1.3)
    tick(); tick()

    check(math.abs(WatchFrame:GetScale() - 1.3) < 0.001,
        "scaling should reach the tracker, got " .. tostring(WatchFrame:GetScale()))
    check(math.abs(holder:GetScale() - holderScaleBefore) < 0.001,
        "scaling must not touch the holder - that is what moved the tracker sideways; got "
        .. tostring(holder:GetScale()))

    -- ...and the plate follows, because it reads the tracker's own scale.
    ns.Skin.Refresh("scaled in holder mode")
    tick(); tick()
    check(math.abs(HeroPanelWatchPlate:GetScale() - 1.3) < 0.001,
        "the plate should follow the tracker's scale, got "
        .. tostring(HeroPanelWatchPlate:GetScale()))

    ns.SetScale("watch", 1.0)
    tick(); tick()
    check(math.abs(WatchFrame:GetScale() - 1.0) < 0.001, "and back down again")

    record.holderFrame, record.holderName = realHolderFrame, realHolderName
    ns.SetOwnership(realOwnership or "auto", "watch")
    ns.Skin.Refresh("holder check finished")
    tick(); tick()
end

--------------------------------------------------------------------------------
-- Unlocking during combat
--
-- The lock used to push its whole job through ns.RunWhenSafe, so unlocking mid
-- fight did nothing until the fight was over - and a fight is exactly when you
-- notice the tracker is in the way. Dragging itself has never been the problem;
-- only EnableMouse is refused under lockdown, and locking no longer takes the
-- mouse away, so there is normally nothing left to defer.
--------------------------------------------------------------------------------

do
    local mover = ns.GetActiveMover("watch")

    ns.SetLocked(false)
    tick()
    check(mover:IsMouseEnabled(), "unlocking out of combat should give the frame the mouse")

    ns.SetLocked(true)
    tick()
    check(mover:IsMouseEnabled(),
        "locking must leave the mouse on - taking it away is what made unlocking in combat wait")

    combat = true
    local before = #log
    ns.SetLocked(false)
    tick()

    check(not ns.IsLocked(), "the flag should flip in combat")
    check(mover:IsMouseEnabled(), "and the frame should be draggable straight away")

    local deferred = false
    for i = before + 1, #log do
        if string.find(log[i], "leave combat", 1, true) then deferred = true end
    end
    check(not deferred,
        "unlocking in combat should not warn about waiting; nothing needed deferring")

    -- A drag still has to be refused while locked, whatever the mouse state is:
    -- the lock is a flag heroPanel reads, not frame state it rewrites.
    ns.SetLocked(true)
    local start = mover:GetScript("OnDragStart")
    check(start ~= nil, "the mover should have a drag handler")
    if start then
        local ok = pcall(start, mover)
        check(ok, "a drag attempt while locked must not error")
        check(ns.trackers.watch.movingFrame == nil, "a locked tracker must not start moving")
    end

    ns.SetLocked(false)
    if start then
        pcall(start, mover)
        check(ns.trackers.watch.movingFrame ~= nil,
            "an unlocked tracker should start moving, in combat as much as out of it")
        local stop = mover:GetScript("OnDragStop")
        if stop then pcall(stop, mover) end
    end

    combat = false
    fire("PLAYER_REGEN_ENABLED")
    ns.SetLocked(true)
    tick(); tick()
end

--------------------------------------------------------------------------------
-- Turning the border off turns off every edge
--
-- The panel's border is not only the four lines around the plate: the header's
-- divider and the Mythic+ footer's rule are edges too, and they were fixed
-- hairline tokens. Setting the border transparent and the background to nothing
-- left those lines ruled across a panel that was otherwise not there - which on
-- a collapsed tracker is most of what is left to see.
--
-- Transparent and style None therefore agree. They did not while the contour
-- survived transparent; keeping them apart is not worth a black outline around
-- a panel the player has asked to stop drawing.
--------------------------------------------------------------------------------

do
    local function EdgeAlpha() return (HeroPanelWatchPlate.edge.top.__color or {})[4] end
    local function ContourAlpha() return (HeroPanelWatchPlate.shadow.top.__color or {})[4] end
    local function DividerAlpha() return (HeroPanelWatchPlate.divider.mid.__color or {})[4] end

    ns.db.panel.watch.borderStyle = "hairline"
    ns.db.panel.watch.borderAlpha = 1
    ns.Skin.Restyle()
    check(EdgeAlpha() == 1, "a normal border draws at full alpha")
    check(ContourAlpha() > 0, "...with its contour under it")
    check(DividerAlpha() > 0, "...and the header divider drawn")

    -- The divider takes the border's colour now, not a hairline token.
    local dr, dg, db_ = ns.HexToRGB(ns.db.panel.watch.borderColor)
    local painted = HeroPanelWatchPlate.divider.mid.__color
    check(painted and math.abs(painted[1] - dr) < 0.01 and math.abs(painted[2] - dg) < 0.01
        and math.abs(painted[3] - db_) < 0.01,
        "the divider should take the border's colour, got "
        .. ns.RGBToHex(painted[1], painted[2], painted[3]))

    for _, case in ipairs({ { style = "hairline", alpha = 0 }, { style = "none", alpha = 1 } }) do
        ns.db.panel.watch.borderStyle = case.style
        ns.db.panel.watch.borderAlpha = case.alpha
        ns.Skin.Restyle()

        local what = case.style .. " at alpha " .. tostring(case.alpha)
        check(EdgeAlpha() == 0 or not HeroPanelWatchPlate.edge.top:IsShown(),
            "no edge with " .. what .. ", got alpha " .. tostring(EdgeAlpha()))
        check(ContourAlpha() == 0,
            "no contour with " .. what .. " - a black outline around nothing is the one "
            .. "thing still visible on a collapsed tracker; got " .. tostring(ContourAlpha()))
        check(DividerAlpha() == 0 or not HeroPanelWatchPlate.divider.mid:IsShown(),
            "no header divider with " .. what .. ", got alpha " .. tostring(DividerAlpha()))
    end

    ns.db.panel.watch.borderStyle = ns.defaults.panel.watch.borderStyle
    ns.db.panel.watch.borderAlpha = ns.defaults.panel.watch.borderAlpha
    ns.Skin.Restyle()
    check(EdgeAlpha() == 1, "and it all comes back")
end

--------------------------------------------------------------------------------
-- The header row says QUESTS
--------------------------------------------------------------------------------

do
    local labels = {}
    ns.WalkFrameTree(HeroPanelWatchPlate, function(object, info)
        if info.kind == "region" and object.GetText then
            local text = object:GetText()
            if text then labels[text] = object end
        end
    end, { maxDepth = 2 })

    check(labels["QUESTS"], "the header should be labelled QUESTS")
    check(not labels["OBJECTIVES"], "...and not OBJECTIVES, which named the lines under it")

    -- Both header strings get a shadow, because the panel's opacity is the
    -- player's to set and colour alone cannot hold text over the world.
    local questsLabel = labels["QUESTS"]
    if questsLabel and questsLabel.GetShadowColor then
        local _, _, _, a = questsLabel:GetShadowColor()
        check(a and a > 0, "the header label needs a shadow to read on a transparent panel")
    end
end

--------------------------------------------------------------------------------
-- Font sizes, one per role
--
-- The quest tracker draws three different jobs - a header row, the quest names
-- and their descriptions - and each has its own size. This is what the old
-- per-panel multiplier could not do: it moved the whole panel together, so
-- making the names big enough to scan made the descriptions big enough to fill
-- the panel.
--------------------------------------------------------------------------------

do
    local sizes = ns.db.font.size

    sizes.watchTitle  = 22
    sizes.watchBody   = 10
    sizes.watchHeader = 14
    sizes.mplus       = 12

    check(ns.GetFontSize(0, "watchTitle") == 22,
        "a role's size is the number in the store, got " .. tostring(ns.GetFontSize(0, "watchTitle")))
    check(ns.GetFontSize(0, "watchBody") == 10,
        "...and each role is its own, got " .. tostring(ns.GetFontSize(0, "watchBody")))
    check(ns.GetFontSize(0, "mplus") == 12,
        "...and the other panel is untouched, got " .. tostring(ns.GetFontSize(0, "mplus")))

    -- The design's small steps ride on the role rather than on a shared base,
    -- so the badge stays under the header it sits beside at any header size.
    check(ns.GetFontSize(-2.5, "watchHeader") < ns.GetFontSize(0, "watchHeader"),
        "the badge keeps its step under the header label")

    -- An unknown role must answer something drawable rather than nil.
    check(ns.GetFontSize(0, "nosuchrole") == ns.GetFontSize(0, "watchBody"),
        "an unknown role falls back to the description size, got "
        .. tostring(ns.GetFontSize(0, "nosuchrole")))

    -- ...and all of it reaches the tracker, unclamped.
    ns.Options.Apply("font role test")
    tick(); tick()
    local _, titleNow = trackerLines[1].__text:GetFont()
    local _, bodyNow  = trackerLines[2].__text:GetFont()
    check(titleNow == 22,
        "the quest name should be drawn at the size set for it, got " .. tostring(titleNow))
    check(bodyNow == 10,
        "and the description at its own, got " .. tostring(bodyNow))

    for role in pairs(ns.db.font.size) do
        ns.db.font.size[role] = ns.defaults.font.size[role]
    end
    ns.Options.Apply("font role test reset")
    tick(); tick()
end

--------------------------------------------------------------------------------
-- A stale store is discarded, not migrated
--
-- heroPanel is pre-release, its shape has changed four times and will change
-- again, and nobody is running a build old enough for an old store to be worth
-- carrying forward. There was a migration chain here - each shape change knew
-- how to re-say itself in the next shape - and it was the right code for a
-- released addon and the wrong code to keep for one that is not: every step had
-- to go on working and being tested forever, to protect settings that take a
-- minute to set again.
--
-- So the rule is one rule: a store stamped with anything other than this
-- build's version is thrown away. What has to be true is that the rule is
-- narrow - it fires on a mismatch, it does not fire on a fresh install, and it
-- says so out loud when it does.
--------------------------------------------------------------------------------

do
    local saved = HEROPANEL_DB

    -- An old store goes, whatever was in it - except the geometry.
    HEROPANEL_DB = {
        dbVersion = 1,
        enabled   = false,
        bg        = { color = "#232532", opacity = 0.4 },
        border    = { color = "#E7C67C", alpha = 1, style = "inset" },
        radius    = 12,
        font      = { face = "Some Old Face", size = 14 },
        frame     = { locked = false, ownership = "own",
                      watch = { point = "TOPLEFT", x = 500, y = -300, scale = 1.3, v = 2 } },
        options   = { point = "TOPLEFT", x = 120, y = -90, scale = 1.2 },
    }
    local before = #log
    ns.InitDB()
    local said = table.concat(log, "\n", before + 1)

    check(ns.SkinEnabled("watch") and ns.SkinEnabled("mplus"),
        "a store from an older shape should be discarded, not merged; the skin flags came back "
        .. tostring(ns.db.skin and ns.db.skin.watch))
    check(ns.db.font.face == ns.DEFAULT_FONT_FACE,
        "...so its font face is gone too, got " .. tostring(ns.db.font.face))
    check(ns.db.bg.color == nil and ns.db.border == nil and ns.db.radius == nil,
        "...and none of the old keys survive to confuse the next reader")
    check(ns.db.panel.watch.bgColor == ns.defaults.panel.watch.bgColor,
        "...and the new shape is filled in from the defaults")
    check(ns.db.dbVersion == ns.DB_VERSION, "...and stamped, so it is not discarded twice")
    check(string.find(said, "older build", 1, true) ~= nil,
        "throwing settings away is not something to do silently, got:\n" .. said)

    -- ...but the geometry is carried across. Dragging three panels into place
    -- and sizing them is the only part of configuring this addon that costs
    -- real effort, and these keys have never changed shape - while the colour
    -- and font blocks have changed four times between them.
    check(ns.db.frame.watch.x == 500 and ns.db.frame.watch.y == -300,
        "a discard must keep the tracker's position, got "
        .. tostring(ns.db.frame.watch.x) .. "," .. tostring(ns.db.frame.watch.y))
    check(ns.db.frame.watch.point == "TOPLEFT", "...including its anchor")
    check(math.abs(ns.db.frame.watch.scale - 1.3) < 0.001,
        "...and its scale, got " .. tostring(ns.db.frame.watch.scale))
    check(ns.db.frame.locked == false, "...and the lock state, which lives in the same block")
    check(ns.db.options.x == 120 and math.abs(ns.db.options.scale - 1.2) < 0.001,
        "...and where the options window was left, at the size it was left at")
    check(string.find(said, "were kept", 1, true) ~= nil,
        "...and it should say so, got:\n" .. said)

    -- Exempting geometry is not trusting it blindly. A frame block missing keys
    -- is completed by ApplyDefaults rather than believed as-is.
    HEROPANEL_DB = { dbVersion = 1, frame = { watch = { x = 42 } } }
    ns.InitDB()
    check(ns.db.frame.watch.x == 42, "a partial frame block keeps what it had")
    check(ns.db.frame.mplus ~= nil and ns.db.frame.mplus.scale == 1.0,
        "...and is completed from the defaults, not carried over half-built")
    check(ns.db.frame.locked == true, "...including keys the old block never had")

    -- A fresh install is not a stale store. It has no stamp either, and warning
    -- someone that their nonexistent settings were reset is worse than saying
    -- nothing at all.
    HEROPANEL_DB = nil
    before = #log
    ns.InitDB()
    said = table.concat(log, "\n", before + 1)
    check(ns.db.dbVersion == ns.DB_VERSION, "a fresh store is stamped")
    check(string.find(said, "older build", 1, true) == nil,
        "...and says nothing about being reset, got:\n" .. said)

    -- A current store is left exactly alone, which is the case that runs every
    -- login and the one a too-eager rule would quietly destroy.
    HEROPANEL_DB = { dbVersion = ns.DB_VERSION, skin = { watch = false },
                     font = { face = "Kept Face" } }
    ns.InitDB()
    check(ns.db.skin.watch == false and ns.db.font.face == "Kept Face",
        "a store stamped for this build must survive untouched")

    HEROPANEL_DB = saved
    ns.InitDB()
end

--------------------------------------------------------------------------------
-- The header option is gone, and the header is on
--------------------------------------------------------------------------------

check(ns.db.header.show == true, "the quest header stays on by default")
check(ns.defaults.header.show == true, "...and that is the default, not a leftover")

do
    local labels = {}
    ns.WalkFrameTree(HeroPanelOptionsFrame, function(object, info)
        if info.kind == "region" and object.GetText then
            local text = object:GetText()
            if text then labels[text] = true end
        end
    end, { maxDepth = 4 })

    check(not labels["Show quest header"],
        "the header toggle should be gone from the window")

    check(labels["GLOBAL"] and labels["QUEST TRACKER"] and labels["MYTHIC+ TRACKER"],
        "the window should be split into its three groups")

    check(labels["Header font size"] and labels["Quest name font size"]
        and labels["Description font size"],
        "the quest tracker's three font sizes should be in the window")
    check(labels["Timer font size"] and labels["Body font size"],
        "the Mythic+ panel splits the same way, with the clock on its own control")
    check(labels["Options font size"], "and this window's own size in the global group")
    check(labels["Options background"],
        "the global group should carry this window's own background swatches")

    check(not labels["Quest tracker scale"] and not labels["M+ tracker scale"],
        "the scale sliders are gone - the panels carry a resize grip instead")
    check(not labels["Corner radius"],
        "the corner radius control is gone - its whole range was one invisible pixel")

    check(labels["Text shadow"] and labels["Shadow thickness"],
        "each panel should carry a text shadow toggle and a thickness")
    check(labels["Hide in combat"] and labels["Hide in Mythic+"],
        "the quest tracker should carry both auto-hide toggles")

    check(labels["M+ and Objective tracker skin \194\183 v" .. ns.version],
        "the subtitle should name both trackers")
end

--------------------------------------------------------------------------------
-- Combat, with both panels up and the options window open
--
-- Not a taint test - the mock does not model taint, and nothing here can stand
-- in for a live pull. What it does check is that every path taken while the
-- protected calls are refused still runs, and that the work deferred by
-- ns.RunWhenSafe is actually flushed afterwards rather than dropped. The log
-- scan at the bottom turns anything that threw into a failure.
--------------------------------------------------------------------------------

do
    ns.Options.Show()
    tick(); tick()

    combat = true
    fire("PLAYER_REGEN_DISABLED")

    -- The settings a player would reach for mid-pull.
    ns.Skin.Refresh("combat started")
    ns.Mplus.Refresh("combat started")
    ns.db.bg.color = "#0D0E14"
    ns.Options.Apply("colour changed in combat")
    ns.SetScale("watch", 1.1)
    ns.SetLocked(false)
    ns.SetLocked(true)
    tick(); tick(); tick()

    check(HeroPanelOptionsFrame:IsShown(), "the options window stays up through combat")
    check(HeroPanelWatchPlate:IsShown(), "the quest panel stays up through combat")

    combat = false
    fire("PLAYER_REGEN_ENABLED")
    tick(); tick(); tick()

    check(math.abs(ns.db.frame.watch.scale - 1.1) < 0.001,
        "a scale set in combat should be applied once combat ends, got "
        .. tostring(ns.db.frame.watch.scale))
    check(math.abs(WatchFrame:GetScale() - 1.1) < 0.001,
        "the deferred SetScale should have reached the frame, got "
        .. tostring(WatchFrame:GetScale()))

    ns.SetScale("watch", 1.0)
    ns.db.bg.color = ns.defaults.bg.color
    ns.Options.Apply("restoring after the combat test")
    ns.Options.Hide()
    tick(); tick()
end

--------------------------------------------------------------------------------
-- Enabling twice does not stack
--
-- Enable() builds the plate and installs the hooks on first call and must be a
-- no-op for both afterwards. A second plate is invisible on screen - it is the
-- same size in the same place - so this is checked by counting frames rather
-- than by looking at one.
--------------------------------------------------------------------------------

do
    local plateBefore  = ns.Skin.GetPlate()
    local framesBefore = #frames

    ns.Skin.Enable()
    ns.Skin.Enable()
    ns.Skin.Enable()
    tick(); tick()

    check(ns.Skin.GetPlate() == plateBefore, "re-enabling must reuse the plate, not build another")
    check(#frames == framesBefore,
        "re-enabling must not create frames; " .. tostring(#frames - framesBefore) .. " appeared")
end

--------------------------------------------------------------------------------
-- Another tracker addon in the same UI
--
-- heroPanel installs its own hooks regardless, and says so once. Twice is a
-- chat spam bug, and never is a player left wondering why two addons are
-- fighting over the tracker.
--------------------------------------------------------------------------------

do
    ElvUI = {}
    ns.conflictsWarned = false

    local function CountElvUINotices()
        local n = 0
        for _, line in ipairs(log) do
            if string.find(line, "ElvUI", 1, true) then n = n + 1 end
        end
        return n
    end

    local before = CountElvUINotices()
    ns.CheckConflicts()
    ns.CheckConflicts()
    ns.CheckConflicts()
    local after = CountElvUINotices()

    check(after - before == 1,
        "the conflict notice should be said exactly once, got " .. tostring(after - before))

    -- ...and heroPanel's own hooks still work with it loaded.
    ns.Skin.Refresh("with ElvUI present")
    tick(); tick()
    check(HeroPanelWatchPlate:IsShown(), "the skin keeps working with another tracker addon loaded")
    check(colourOf(trackerLines[1].__text) == "E7C67C",
        "heroPanel's own line styling survives another addon being present")

    ElvUI = nil
end

--------------------------------------------------------------------------------
-- A store written by nothing at all
--
-- What a new player's first login looks like. Every default has to land with no
-- error, which is the one case that cannot be checked by editing an existing
-- store: a missing sub-table and a sub-table with a missing key are different
-- shapes, and ApplyDefaults has to survive both.
--------------------------------------------------------------------------------

do
    HEROPANEL_DB = nil
    local ok, err = pcall(ns.InitDB)
    check(ok, "a fresh install must initialise without error: " .. tostring(err))
    check(type(HEROPANEL_DB) == "table", "InitDB should create the store")
    check(HEROPANEL_DB.skin.watch == true and HEROPANEL_DB.skin.mplus == true,
        "a fresh store skins both panels")
    check(HEROPANEL_DB.header.hideEmpty == false,
        "...and keeps the quest panel up over an empty tracker")
    check(HEROPANEL_DB.font.face == ns.DEFAULT_FONT_FACE, "a fresh store gets the default face")
    check(HEROPANEL_DB.font.size.watchBody == 12, "a fresh store gets the design's 12px body")
    check(HEROPANEL_DB.font.size.watchTitle == 14, "...with the quest names two points over it")
    check(HEROPANEL_DB.font.size.watchHeader == 16, "...and the header row over both")
    check(HEROPANEL_DB.font.size.mplusTimer == 20, "...and the Mythic+ clock at its own size")
    check(HEROPANEL_DB.font.size.mplusHeader == 14 and HEROPANEL_DB.font.size.mplusBody == 14,
        "...with the Mythic+ header and body matched to each other")
    check(HEROPANEL_DB.panel.watch.bgColor == ns.defaults.panel.watch.bgColor,
        "a fresh store gets a chrome block for each panel")
    check(HEROPANEL_DB.panel.watch.radius == 0 and HEROPANEL_DB.panel.mplus.radius == 0,
        "...with square corners, which is no longer configurable")
    check(HEROPANEL_DB.panel.options.bgColor == ns.defaults.panel.options.bgColor,
        "...and one for the options window's own background")
    check(HEROPANEL_DB.frame.locked == true, "a fresh store is locked")
    check(HEROPANEL_DB.options ~= nil, "a fresh store has somewhere to remember the window")

    -- Half a store, stamped for this build. This is what ApplyDefaults is
    -- actually for now that a *stale* store is discarded outright: a store of
    -- the right shape that predates one added key, which is what every login
    -- after a small change looks like. A missing sub-table and a sub-table with
    -- a missing key are different shapes and it has to survive both.
    HEROPANEL_DB = {
        dbVersion = ns.DB_VERSION,
        skin      = { watch = false },
        font      = { size = { watchBody = 15 } },
    }
    local ok2, err2 = pcall(ns.InitDB)
    check(ok2, "a partial store must be filled in without error: " .. tostring(err2))
    check(HEROPANEL_DB.skin.watch == false, "an existing value must not be clobbered")
    check(HEROPANEL_DB.skin.mplus == true,
        "...and a missing key beside it is filled in, got " .. tostring(HEROPANEL_DB.skin.mplus))
    check(HEROPANEL_DB.font.size.watchBody == 15,
        "...nor an existing font size, got " .. tostring(HEROPANEL_DB.font.size.watchBody))
    check(HEROPANEL_DB.font.size.watchTitle == ns.defaults.font.size.watchTitle,
        "a missing key beside it is filled in, got "
        .. tostring(HEROPANEL_DB.font.size.watchTitle))
    check(HEROPANEL_DB.font.face == ns.DEFAULT_FONT_FACE, "a missing face is filled in")
    check(HEROPANEL_DB.text.title == ns.defaults.text.title, "a missing sub-table is filled in")

    -- Put the run's store back so the report below is about the real one.
    HEROPANEL_DB = nil
    ns.InitDB()
end

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
