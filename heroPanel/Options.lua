--[[--------------------------------------------------------------------------
    heroPanel - Options.lua

    The configuration window, reachable from /hp and from
    Interface -> AddOns -> heroPanel.

    Two rules shape this file.

    Everything writes through immediately. There is no pending-changes buffer:
    a control writes HEROPANEL_DB and re-skins on the spot, so the tracker
    behind the window shows the setting as it is being dragged. That is the
    point of a skin's config panel - a colour you cannot see until you press
    Save is a colour you are choosing blind. "Save & close" is therefore a close
    button that says out loud that nothing was left uncommitted.

    The window's own chrome is fixed, not configured. It is painted from the
    design's tokens through ns.StylePlateChrome's style override rather than
    from HEROPANEL_DB, because this is the window you change those colours in:
    a panel that restyles itself as you drag its own background swatch makes it
    impossible to see what you are setting.

    Placement is deliberate too. The window is centred on UIParent in its own
    strata, well away from where either tracker defaults to, so opening the
    config never lands on top of the frames it configures.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local options = {}
ns.Options = options

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

local PANEL_WIDTH   = 440
local PAD_X         = 20
local CONTENT_WIDTH = PANEL_WIDTH - PAD_X * 2

-- The whole window has to fit on screen without scrolling. UIParent is about
-- 768 units tall whatever the monitor is, because the client scales the UI to
-- suit, so the budget is fixed and it is not generous: laid out at the design's
-- spacing this came to 752, which fits by eight pixels a side and does not fit
-- at all once a player nudges their UI scale up. It has been tightened twice
-- now - once for the design's own spacing and again when the three per-panel
-- font scales added another hundred pixels - and lands at 684. The harness
-- fails the run if it ever goes over 768.
--
-- Eight sliders is what makes this tight. If another group of them arrives, the
-- answer is a scrolling body rather than a third round of shaving rows.
local HEADER_HEIGHT = 56
local GROUP_GAP     = 10
local ROW_HEIGHT    = 28
local SLIDER_HEIGHT = 34
local FOOTER_HEIGHT = 44
local ENABLE_HEIGHT = 48

-- The tallest the window may be. UIParent's height in UI units at the client's
-- default scale.
local MAX_HEIGHT    = 768

local SWATCH_SIZE   = 22
local SWATCH_GAP    = 6
local TILE_SIZE     = 34
local TOGGLE_WIDTH  = 44
local TOGGLE_HEIGHT = 22
local KNOB_SIZE     = 18

local DROPDOWN_ROWS   = 10
local DROPDOWN_ROW_H  = 20
local DROPDOWN_WIDTH  = 200

-- The window's own colours. Design tokens, not player configuration.
local CHROME = {
    bgColor     = "#161826",
    bgOpacity   = 1,
    borderColor = "#E9E9ED",
    borderAlpha = 0.10,
    borderStyle = "hairline",
    radius      = 12,
    shadowAlpha = 0.55,
}

local TEXT_BRIGHT = "#F3F5FE"
local TEXT_BODY   = "#C2C6D8"
local TEXT_MUTED  = "#75798C"
local TEXT_GROUP  = "#8B8FA3"
local GREEN       = "#79C68D"
local ACCENT      = "#9184D9"
local ACCENT_DEEP = "#5D5294"
local LOCK_GLYPH  = "#F5F4FF"

-- Swatch choices. The background set is the design's; the border set is the
-- configured default plus a darker, an accent and a gold, which is the range
-- the panel is actually legible across.
local BG_SWATCHES = {
    { colour = "#14161F" }, { colour = "#0D0E14" },
    { colour = "#1C1F2E" }, { colour = "#232532" },
}

-- The last one is not a colour. Transparent zeroes border.alpha and leaves the
-- style alone, which is not the same as border style None: None takes the drop
-- contour with it, this keeps it, so the panel still lifts off a bright
-- background with no line drawn around it.
local BORDER_SWATCHES = {
    { colour = "#33364A" }, { colour = "#1F2130" },
    { colour = "#9184D9" }, { colour = "#E7C67C" },
    { transparent = true },
}

local BORDER_STYLES = {
    { key = "hairline", label = "Hairline" },
    { key = "inset",    label = "Inset"    },
    { key = "none",     label = "None"     },
}

-- Only "flat" draws. The other three are in the design and heroPanel ships no
-- texture assets, so they are present, greyed and say why on hover rather than
-- being silently absent - a control that is missing reads as a build that is
-- behind, and one that does nothing reads as a bug.
local BACKDROP_TILES = {
    { key = "flat",     label = "Flat",     enabled = true  },
    { key = "noise",    label = "Noise",    enabled = false },
    { key = "gradient", label = "Gradient", enabled = false },
    { key = "glow",     label = "Glow",     enabled = false },
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local panel                 -- the window, built on first open
local controls  = {}        -- everything with a Sync method
local fontStrings = {}      -- { fontString, delta } for restyling
local syncing   = false     -- true while widgets are being set from the store

--------------------------------------------------------------------------------
-- Applying
--------------------------------------------------------------------------------

-- The one path everything takes after touching the store. Both panels restyle
-- and refresh, and so does this window - a font or colour change that skipped
-- the window would leave the control showing one thing and the tracker another.
-- pcall throughout, because a tracker that has not been found yet is a normal
-- state rather than an error.
local function Apply(reason)
    if ns.Skin then
        pcall(ns.Skin.Restyle)
        pcall(ns.Skin.Refresh, reason)
    end
    if ns.Mplus then
        pcall(ns.Mplus.Restyle)
        pcall(ns.Mplus.Refresh, reason)
    end
    pcall(options.Restyle)
end
options.Apply = Apply

--------------------------------------------------------------------------------
-- Small builders
--------------------------------------------------------------------------------

local function NewTexture(parent, layer)
    return ns.NewPlateTexture(parent, layer or "ARTWORK")
end

-- Slider values arrive as floats even with a whole-number step, and "%d" on a
-- float is a hard error under Lua 5.3 - which is what the mock client runs.
-- The game's 5.1 would silently truncate, so this would have been a bug that
-- only ever showed up in the test harness, or worse, only ever in the game.
local function Int(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

-- Every string the window draws is registered so a font change restyles the
-- window itself, not just the trackers behind it. Seeing the face you picked
-- applied to the control you picked it with is the fastest way to know it took.
local function NewText(parent, delta, colour, text, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(ns.GetFontFile(), ns.GetFontSize(delta or 0, "options"))
    if colour then fs:SetTextColor(ns.HexToRGB(colour)) end
    if text then fs:SetText(text) end
    table.insert(fontStrings, { fs = fs, delta = delta or 0 })
    return fs
end

-- A rounded box: any frame given the shared plate chrome and painted from a
-- fixed style rather than from the player's configuration. Reusing Plate.lua
-- means the corner chamfer is written once and every rounded thing in the
-- window - toggles, pills, swatches, buttons, tiles - steps its corners the
-- same way the tracker panels do.
local function Chrome(frame, style)
    ns.BuildPlateChrome(frame)
    ns.StylePlateChrome(frame, style)
    return frame
end

-- A rounded rectangle drawn as one-pixel horizontal bands, each inset by the
-- corner circle's own geometry.
--
-- The plate's chamfer is three steps, which reads as a soft corner on a 300px
-- panel and as a box with its corners sawn off on a 22px switch - the toggle
-- came out looking like a white rectangle inside a purple one. A band per pixel
-- of height is a genuine curve and costs twenty-odd textures at this size,
-- which is nothing for the two switches that need it. The plate keeps the
-- chamfer: it is drawn from three textures at any size, and a 400px panel does
-- not want four hundred.
local function NewRoundedBox(frame, layer)
    local box = { frame = frame, bands = {}, layer = layer or "ARTWORK" }

    function box:Layout(width, height, radius)
        width, height = math.floor(width), math.floor(height)
        radius = math.min(radius or (height / 2), height / 2, width / 2)

        for row = 1, height do
            local band = self.bands[row]
            if not band then
                band = NewTexture(self.frame, self.layer)
                self.bands[row] = band
            end

            -- How far this row's centre is into the corner arc, if at all.
            local y, inset = row - 0.5, 0
            local dy
            if y < radius then
                dy = radius - y
            elseif y > height - radius then
                dy = y - (height - radius)
            end
            if dy then
                inset = radius - math.sqrt(math.max(0, radius * radius - dy * dy))
            end

            band:ClearAllPoints()
            band:SetPoint("TOPLEFT", self.frame, "TOPLEFT", inset, -(row - 1))
            band:SetWidth(math.max(1, width - inset * 2))
            band:SetHeight(1)
            band:Show()
        end

        for row = height + 1, #self.bands do self.bands[row]:Hide() end
        return self
    end

    function box:SetColor(r, g, b, a)
        for i = 1, #self.bands do
            self.bands[i]:SetVertexColor(r, g, b, a or 1)
        end
        return self
    end

    return box
end

local function BoxStyle(bgColor, bgOpacity, borderColor, borderAlpha, radius)
    return {
        bgColor     = bgColor or "#000000",
        bgOpacity   = bgOpacity or 0,
        borderColor = borderColor or "#000000",
        borderAlpha = borderAlpha or 0,
        borderStyle = borderColor and "hairline" or "none",
        radius      = radius or 8,
        shadowAlpha = 0,
    }
end

--------------------------------------------------------------------------------
-- Group heading
--------------------------------------------------------------------------------

local function GroupLabel(parent, y, text)
    local fs = NewText(parent, -3, TEXT_GROUP, string.upper(text))
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD_X, -y)
    return y + 16
end

--------------------------------------------------------------------------------
-- Toggle
--
-- A pill track with a knob at one end. Two rounded boxes, so it picks up the
-- same corner treatment as everything else rather than being the one control
-- with square ends.
--------------------------------------------------------------------------------

local function NewToggle(parent, y, label, sublabel, get, set, padX)
    padX = padX or PAD_X

    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(TOGGLE_WIDTH)
    button:SetHeight(TOGGLE_HEIGHT)
    button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -padX, -y)

    local track = CreateFrame("Frame", nil, button)
    track:SetAllPoints(button)
    local trackFill = NewRoundedBox(track, "BACKGROUND")
    trackFill:Layout(TOGGLE_WIDTH, TOGGLE_HEIGHT, TOGGLE_HEIGHT / 2)

    local knob = CreateFrame("Frame", nil, button)
    knob:SetWidth(KNOB_SIZE)
    knob:SetHeight(KNOB_SIZE)
    -- Stated rather than left to creation order. Two sibling frames on the same
    -- level have no defined draw order, and a knob behind its own track is a
    -- toggle that reads as a plain coloured bar in both states.
    knob:SetFrameLevel(track:GetFrameLevel() + 1)
    local knobFill = NewRoundedBox(knob, "ARTWORK")
    knobFill:Layout(KNOB_SIZE, KNOB_SIZE, KNOB_SIZE / 2)

    local title = NewText(parent, 0.5, TEXT_BRIGHT, label)
    title:SetPoint("LEFT", parent, "TOPLEFT", padX, -(y + TOGGLE_HEIGHT / 2) + (sublabel and 7 or 0))

    local sub
    if sublabel then
        sub = NewText(parent, -2, TEXT_MUTED, sublabel)
        sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    end

    local widget = {}

    function widget:Sync()
        local on = get() and true or false
        trackFill:SetColor(ns.HexToRGB(on and ACCENT or "#2A2D3E"))
        knobFill:SetColor(ns.HexToRGB(on and "#F5F4FF" or "#8B8FA3"))
        knob:ClearAllPoints()
        if on then
            knob:SetPoint("RIGHT", track, "RIGHT", -2, 0)
        else
            knob:SetPoint("LEFT", track, "LEFT", 2, 0)
        end
    end

    button:SetScript("OnClick", function()
        set(not get())
        widget:Sync()
    end)

    table.insert(controls, widget)
    return y + (sublabel and 40 or ROW_HEIGHT), widget
end

--------------------------------------------------------------------------------
-- Slider
--
-- A real Slider frame, so clicking the track and dragging the thumb both behave
-- the way the client's own sliders do, with heroPanel's art over the top: a 2px
-- track, an accent fill up to the thumb, and the value read out on the right.
--------------------------------------------------------------------------------

local function NewSlider(parent, y, label, minValue, maxValue, step, get, set, format)
    local title = NewText(parent, 0, TEXT_BODY, label)
    title:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD_X, -y)

    local readout = NewText(parent, -1, ACCENT)
    readout:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_X, -y)

    local slider = CreateFrame("Slider", nil, parent)
    slider:SetOrientation("HORIZONTAL")
    slider:SetWidth(CONTENT_WIDTH)
    slider:SetHeight(16)
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD_X, -(y + 18))
    slider:SetMinMaxValues(minValue, maxValue)
    slider:SetValueStep(step)

    -- Track and fill sit behind the thumb. The fill is sized rather than
    -- anchored to the thumb, because a thumb at the minimum has no width to
    -- anchor against.
    local track = NewTexture(slider, "BACKGROUND")
    track:SetHeight(2)
    track:SetPoint("LEFT", slider, "LEFT", 0, 0)
    track:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
    track:SetVertexColor(ns.HexToRGB("#E9E9ED", 0.08))

    local fill = NewTexture(slider, "BORDER")
    fill:SetHeight(2)
    fill:SetPoint("LEFT", slider, "LEFT", 0, 0)
    fill:SetVertexColor(ns.HexToRGB(ACCENT))

    slider:SetThumbTexture(ns.SOLID)
    local thumb = slider:GetThumbTexture()
    if thumb then
        thumb:SetWidth(12)
        thumb:SetHeight(12)
        thumb:SetVertexColor(ns.HexToRGB("#F5F4FF"))
    end

    local function Redraw(value)
        local span = maxValue - minValue
        local fraction = (span > 0) and ((value - minValue) / span) or 0
        fill:SetWidth(math.max(1, CONTENT_WIDTH * fraction))
        readout:SetText(format and format(value) or tostring(value))
    end

    slider:SetScript("OnValueChanged", function(self, value)
        value = ns.Snap(value, step)
        Redraw(value)
        -- Setting the slider from the store fires this too. Writing back then
        -- would be harmless but the re-skin it triggers is not free, and on the
        -- scale sliders it would push a value at ns.SetScale for no reason.
        if syncing then return end
        set(value)
    end)

    local widget = {}
    function widget:Sync()
        local value = ns.Clamp(get(), minValue, maxValue)
        slider:SetValue(value)
        Redraw(value)
    end

    table.insert(controls, widget)
    return y + SLIDER_HEIGHT, widget
end

--------------------------------------------------------------------------------
-- Colour swatches
--------------------------------------------------------------------------------

-- entries are { colour = "#RRGGBB" } or { transparent = true }.
--
-- A transparent entry is not a colour, so it cannot be one more hex in the
-- list: it is drawn as an empty outline rather than a filled square, which is
-- also the only honest way to show "no fill" without shipping a chequerboard
-- texture. isSelected and onSelect are passed in rather than a get/set pair on
-- a colour, because what "selected" means differs - the border row is choosing
-- between a colour and an alpha.
local function NewSwatchRow(parent, y, label, entries, isSelected, onSelect)
    local title = NewText(parent, 0, TEXT_BODY, label)
    title:SetPoint("LEFT", parent, "TOPLEFT", PAD_X, -(y + SWATCH_SIZE / 2))

    local buttons = {}
    for i = 1, #entries do
        local entry = entries[i]
        local button = CreateFrame("Button", nil, parent)
        button:SetWidth(SWATCH_SIZE)
        button:SetHeight(SWATCH_SIZE)
        button:SetPoint("TOPRIGHT", parent, "TOPRIGHT",
            -PAD_X - (#entries - i) * (SWATCH_SIZE + SWATCH_GAP), -y)
        Chrome(button, BoxStyle(entry.colour or "#000000", entry.transparent and 0 or 1,
            "#33364A", 1, 6))
        button.entry  = entry
        button.colour = entry.colour

        button:SetScript("OnClick", function()
            onSelect(entry)
            for j = 1, #buttons do buttons[j]:Refresh() end
            Apply("swatch changed")
        end)

        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(entry.transparent and "Transparent" or entry.colour, 1, 1, 1)
            if entry.transparent then
                GameTooltip:AddLine("No border line. The panel keeps its drop contour, "
                    .. "which border style None removes as well.", 0.6, 0.6, 0.7, true)
            end
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)

        function button:Refresh()
            local selected = isSelected(self.entry)
            ns.StylePlateChrome(self, BoxStyle(self.entry.colour or "#000000",
                self.entry.transparent and 0 or 1,
                selected and ACCENT or "#33364A", selected and 1 or 0.6, 6))
        end

        buttons[i] = button
    end

    local widget = {}
    function widget:Sync()
        for i = 1, #buttons do buttons[i]:Refresh() end
    end

    table.insert(controls, widget)
    return y + ROW_HEIGHT, widget
end

--------------------------------------------------------------------------------
-- Segmented control
--------------------------------------------------------------------------------

local function NewSegmented(parent, y, label, entries, get, set)
    local title = NewText(parent, 0, TEXT_BODY, label)
    title:SetPoint("LEFT", parent, "TOPLEFT", PAD_X, -(y + 13))

    local buttons = {}
    local width = 78
    for i = 1, #entries do
        local entry = entries[i]
        local button = CreateFrame("Button", nil, parent)
        button:SetWidth(width)
        button:SetHeight(26)
        button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_X - (#entries - i) * (width + 4), -y)
        Chrome(button, BoxStyle("#1C1F2E", 1, "#33364A", 1, 6))

        local text = NewText(button, -0.5, TEXT_BODY, entry.label)
        text:SetPoint("CENTER")
        button.text = text

        button:SetScript("OnClick", function()
            set(entry.key)
            for j = 1, #buttons do buttons[j]:Refresh() end
            Apply("border style changed")
        end)

        function button:Refresh()
            local selected = (get() == entry.key)
            ns.StylePlateChrome(self, BoxStyle(selected and "#232640" or "#1C1F2E", 1,
                selected and ACCENT or "#33364A", 1, 6))
            self.text:SetTextColor(ns.HexToRGB(selected and ACCENT or TEXT_BODY))
        end

        buttons[i] = button
    end

    local widget = {}
    function widget:Sync()
        for i = 1, #buttons do buttons[i]:Refresh() end
    end

    table.insert(controls, widget)
    return y + 32, widget
end

--------------------------------------------------------------------------------
-- Backdrop texture tiles
--------------------------------------------------------------------------------

local function NewTileRow(parent, y, label, entries, get, set)
    local title = NewText(parent, 0, TEXT_BODY, label)
    title:SetPoint("LEFT", parent, "TOPLEFT", PAD_X, -(y + TILE_SIZE / 2))

    local buttons = {}
    for i = 1, #entries do
        local entry = entries[i]
        local button = CreateFrame("Button", nil, parent)
        button:SetWidth(TILE_SIZE)
        button:SetHeight(TILE_SIZE)
        button:SetPoint("TOPRIGHT", parent, "TOPRIGHT",
            -PAD_X - (#entries - i) * (TILE_SIZE + SWATCH_GAP), -y)
        Chrome(button, BoxStyle("#1C1F2E", 1, "#33364A", 1, 6))

        local text = NewText(button, -3.5, entry.enabled and TEXT_BODY or TEXT_MUTED, entry.label)
        text:SetPoint("CENTER")
        button.text = text

        if entry.enabled then
            button:SetScript("OnClick", function()
                set(entry.key)
                for j = 1, #buttons do buttons[j]:Refresh() end
                Apply("backdrop texture changed")
            end)
        else
            button:SetAlpha(0.4)
            button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(entry.label, 1, 1, 1)
                GameTooltip:AddLine("heroPanel ships no texture art, so only Flat draws.", 0.6, 0.6, 0.7, true)
                GameTooltip:Show()
            end)
            button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        function button:Refresh()
            local selected = (get() == entry.key)
            ns.StylePlateChrome(self, BoxStyle(selected and "#232640" or "#1C1F2E", 1,
                selected and ACCENT or "#33364A", 1, 6))
        end

        buttons[i] = button
    end

    local widget = {}
    function widget:Sync()
        for i = 1, #buttons do buttons[i]:Refresh() end
    end

    table.insert(controls, widget)
    return y + TILE_SIZE + 2, widget
end

--------------------------------------------------------------------------------
-- State colour swatches
--
-- These three are free-form rather than a preset list, so they go through the
-- client's colour picker. It previews live: dragging in the picker re-skins the
-- tracker behind it, and cancelling puts the old colour back.
--------------------------------------------------------------------------------

local function OpenColourPicker(current, onChange)
    local picker = _G.ColorPickerFrame
    if not picker then
        ns.Warn("this client has no colour picker, so state colours can only be set in SavedVariables.")
        return false
    end

    local r, g, b = ns.HexToRGB(current)

    picker.func = function()
        local nr, ng, nb = picker:GetColorRGB()
        onChange(ns.RGBToHex(nr, ng, nb))
    end
    picker.cancelFunc = function()
        onChange(current)
    end
    picker.opacityFunc = nil
    picker.hasOpacity  = false
    picker.previousValues = { r = r, g = g, b = b, [1] = r, [2] = g, [3] = b }

    picker:SetColorRGB(r, g, b)

    -- ShowUIPanel is the documented way in; a bare Show leaves the panel's own
    -- bookkeeping out of step on this client.
    if type(_G.ShowUIPanel) == "function" then
        _G.ShowUIPanel(picker)
    else
        picker:Show()
    end
    return true
end

local function NewStateColours(parent, y, label, entries)
    local title = NewText(parent, 0, TEXT_BODY, label)
    title:SetPoint("LEFT", parent, "TOPLEFT", PAD_X, -(y + SWATCH_SIZE / 2))

    local buttons = {}
    for i = 1, #entries do
        local entry = entries[i]
        local button = CreateFrame("Button", nil, parent)
        button:SetWidth(SWATCH_SIZE)
        button:SetHeight(SWATCH_SIZE)
        button:SetPoint("TOPRIGHT", parent, "TOPRIGHT",
            -PAD_X - (#entries - i) * (SWATCH_SIZE + SWATCH_GAP + 12), -y)
        Chrome(button, BoxStyle(entry.get(), 1, "#33364A", 1, 6))

        local caption = NewText(parent, -3.5, TEXT_MUTED, entry.label)
        caption:SetPoint("TOP", button, "BOTTOM", 0, -3)

        button:SetScript("OnClick", function(self)
            OpenColourPicker(entry.get(), function(hex)
                entry.set(hex)
                self:Refresh()
                Apply("state colour changed")
            end)
        end)

        function button:Refresh()
            ns.StylePlateChrome(self, BoxStyle(entry.get(), 1, "#33364A", 1, 6))
        end

        buttons[i] = button
    end

    local widget = {}
    function widget:Sync()
        for i = 1, #buttons do buttons[i]:Refresh() end
    end

    table.insert(controls, widget)
    return y + SWATCH_SIZE + 14, widget
end

--------------------------------------------------------------------------------
-- Font dropdown
--
-- Built rather than taken from UIDropDownMenuTemplate. The template's frame is
-- Blizzard's stone chrome, which is the one thing on this window that would not
-- match, and the list can be a hundred entries long once a font pack is
-- installed - so it needs a window and a wheel, which the template does not do.
--
-- Each row is drawn in its own face. A font list you cannot see is a list of
-- names, and picking a face by name is guesswork.
--------------------------------------------------------------------------------

local function NewFontDropdown(parent, y, label, sublabel)
    local title = NewText(parent, 0, TEXT_BODY, label)
    title:SetPoint("LEFT", parent, "TOPLEFT", PAD_X, -(y + 9))

    local sub = NewText(parent, -3, TEXT_MUTED, sublabel)
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)

    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(DROPDOWN_WIDTH)
    button:SetHeight(26)
    button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_X, -y)
    Chrome(button, BoxStyle("#1C1F2E", 1, "#33364A", 1, 6))

    local current = NewText(button, -0.5, TEXT_BRIGHT)
    current:SetPoint("LEFT", button, "LEFT", 10, 0)

    local caret = ns.NewGlyph(button, 10)
    caret:SetPoint("RIGHT", button, "RIGHT", -10, 0)
    caret:SetShape("caretDown")
    caret:SetColor(ns.HexToRGB(TEXT_MUTED))

    -- The list is a child of the window so it inherits its strata, and one
    -- level up so it draws over the controls it covers.
    local list = CreateFrame("Frame", nil, parent)
    list:Hide()
    list:SetWidth(DROPDOWN_WIDTH)
    list:SetHeight(DROPDOWN_ROWS * DROPDOWN_ROW_H + 8)
    list:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -2)
    list:SetFrameLevel(parent:GetFrameLevel() + 10)
    Chrome(list, BoxStyle("#12141F", 1, "#33364A", 1, 8))
    list:EnableMouseWheel(true)

    local faces, offset, rows = {}, 0, {}

    local function RedrawRows()
        local maxOffset = math.max(0, #faces - DROPDOWN_ROWS)
        if offset > maxOffset then offset = maxOffset end
        if offset < 0 then offset = 0 end

        for i = 1, DROPDOWN_ROWS do
            local row  = rows[i]
            local face = faces[i + offset]
            if face then
                row.face = face
                -- Font before text, and not the other way round: SetText on a
                -- FontString that has no font yet throws "Font not set" on this
                -- client, and these rows deliberately start without one so a
                -- window-wide restyle cannot overwrite the face each is
                -- previewing.
                --
                -- FontFileFor falls back the same way GetFontFile does, so a row
                -- can always be drawn even if the face turns out to be
                -- unreadable.
                row.text:SetFont(ns.Media.FontFileFor(face), 12)
                row.text:SetText(face)
                local selected = (ns.db.font.face == face)
                row.text:SetTextColor(ns.HexToRGB(selected and ACCENT or TEXT_BODY))
                row:Show()
            else
                row.face = nil
                row:Hide()
            end
        end
    end

    for i = 1, DROPDOWN_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetWidth(DROPDOWN_WIDTH - 8)
        row:SetHeight(DROPDOWN_ROW_H)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -4 - (i - 1) * DROPDOWN_ROW_H)

        local highlight = NewTexture(row, "BACKGROUND")
        highlight:SetAllPoints(row)
        highlight:SetVertexColor(ns.HexToRGB(ACCENT, ns.ALPHA.hoverTint))
        highlight:Hide()

        -- Not registered with NewText: this string carries the face being
        -- previewed, so a window-wide font restyle must not overwrite it.
        -- Given a font at birth all the same, so it is never a FontString
        -- without one - RedrawRows sets the real face before every SetText, but
        -- an empty row must not be a trap for the next person either.
        row.text = row:CreateFontString(nil, "OVERLAY")
        row.text:SetFont(ns.GetFontFile(), 12)
        row.text:SetPoint("LEFT", row, "LEFT", 6, 0)

        row:SetScript("OnEnter", function() highlight:Show() end)
        row:SetScript("OnLeave", function() highlight:Hide() end)
        row:SetScript("OnClick", function(self)
            if not self.face then return end
            ns.db.font.face = self.face
            ns.Media.Apply("font face changed")
            list:Hide()
            current:SetText(self.face)
            RedrawRows()
        end)

        rows[i] = row
    end

    list:SetScript("OnMouseWheel", function(_, delta)
        offset = offset - delta
        RedrawRows()
    end)

    button:SetScript("OnClick", function()
        if list:IsShown() then
            list:Hide()
            return
        end
        faces = ns.Media.ListFonts()
        -- Open on the current selection rather than at the top, so a face a
        -- long way down the list is visible the moment the list appears.
        offset = 0
        for i = 1, #faces do
            if faces[i] == ns.db.font.face then
                offset = math.max(0, math.min(i - 1, #faces - DROPDOWN_ROWS))
                break
            end
        end
        RedrawRows()
        list:Show()
    end)

    local widget = {}
    function widget:Sync()
        current:SetText(ns.db.font.face or ns.DEFAULT_FONT_FACE)
        if list:IsShown() then
            faces = ns.Media.ListFonts()
            RedrawRows()
        end
    end
    function widget:Close() list:Hide() end

    table.insert(controls, widget)
    return y + 38, widget
end

--------------------------------------------------------------------------------
-- Footer buttons
--------------------------------------------------------------------------------

local function NewFooterButton(parent, width, label, accent, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(width)
    button:SetHeight(32)
    Chrome(button, accent
        and BoxStyle("#232640", 1, ACCENT, 1, 8)
        or  BoxStyle("#1C1F2E", 1, "#33364A", 1, 8))

    local text = NewText(button, 0, accent and ACCENT or TEXT_BODY, label)
    text:SetPoint("CENTER")

    button:SetScript("OnClick", onClick)
    return button
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

local function SavedPlacement()
    if type(ns.db.options) ~= "table" then ns.db.options = {} end
    return ns.db.options
end

local function Build()
    if panel then return panel end

    panel = CreateFrame("Frame", "HeroPanelOptionsFrame", UIParent)
    panel:Hide()
    panel:SetWidth(PANEL_WIDTH)
    -- Its own strata, above anything either tracker sits in, and deliberately
    -- not the strata the plates use: this window is a dialog over the UI, not
    -- another piece of the tracker.
    panel:SetFrameStrata("DIALOG")
    panel:SetToplevel(true)
    panel:EnableMouse(true)
    panel:SetClampedToScreen(true)
    Chrome(panel, CHROME)

    ------------------------------------------------------------------
    -- Header
    ------------------------------------------------------------------

    -- Toggles the single global lock. It is one flag covering both trackers,
    -- so this is one call - flipping it once per tracker would land back where
    -- it started.
    local lockButton = CreateFrame("Button", nil, panel)
    lockButton:SetWidth(26)
    lockButton:SetHeight(26)
    lockButton:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, -18)
    Chrome(lockButton, BoxStyle(ACCENT, 1, nil, nil, 7))

    -- The design's accent gradient. The plate's three background bands are
    -- painted as top stop / gradient / bottom stop, which is continuous enough
    -- at 26px: the outer two bands are only the corner chamfer's rows.
    local function PaintLockGradient()
        local r1, g1, b1 = ns.HexToRGB(ACCENT)
        local r2, g2, b2 = ns.HexToRGB(ACCENT_DEEP)
        lockButton.bg.top:SetVertexColor(r1, g1, b1, 1)
        lockButton.bg.bottom:SetVertexColor(r2, g2, b2, 1)
        -- VERTICAL gradients on this client take the first stop at the bottom.
        lockButton.bg.main:SetGradientAlpha("VERTICAL", r2, g2, b2, 1, r1, g1, b1, 1)
    end
    PaintLockGradient()

    local lockGlyph = ns.NewGlyph(lockButton, 14)
    lockGlyph:SetPoint("CENTER")
    lockGlyph:SetColor(ns.HexToRGB(LOCK_GLYPH))

    lockButton:SetScript("OnClick", function()
        ns.SetLocked(not ns.IsLocked())
    end)
    lockButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ns.IsLocked() and "Unlock both trackers" or "Lock both trackers", 1, 1, 1)
        GameTooltip:Show()
    end)
    lockButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local title = NewText(panel, 2, TEXT_BRIGHT, "heroPanel")
    title:SetPoint("TOPLEFT", lockButton, "TOPRIGHT", 12, -1)

    local subtitle = NewText(panel, -2, TEXT_MUTED, "Objective tracker skin \194\183 v" .. ns.version)
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)

    local pill = CreateFrame("Frame", nil, panel)
    pill:SetWidth(84)
    pill:SetHeight(22)
    pill:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD_X, -20)
    Chrome(pill, BoxStyle(GREEN, 0.12, nil, nil, 8))
    local pillText = NewText(pill, -2.5, GREEN)
    pillText:SetPoint("CENTER")

    -- Divider under the header.
    local rule = NewTexture(panel, "BORDER")
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -HEADER_HEIGHT)
    rule:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -HEADER_HEIGHT)
    rule:SetVertexColor(ns.HexToRGB("#E9E9ED", ns.ALPHA.divider))

    -- Dragging by the header. The window has no business staying put if it
    -- lands somewhere awkward, and where the player leaves it is remembered.
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local placement = SavedPlacement()
        placement.point = "TOPLEFT"
        placement.x = self:GetLeft() - UIParent:GetLeft()
        placement.y = self:GetTop() - UIParent:GetTop()
    end)

    ------------------------------------------------------------------
    -- Body
    ------------------------------------------------------------------

    local y = HEADER_HEIGHT + 12

    -- Enable skin, on its own accent-tinted row.
    --
    -- The toggle and its labels are children of the row, not of the window.
    -- Frame level beats draw layer between two frames, so a tinted child frame
    -- laid over the window would cover any of the window's own OVERLAY strings
    -- that fell inside it - the labels would simply not be there. Putting them
    -- inside the row puts them a level above its tint instead.
    local enableRow = CreateFrame("Frame", nil, panel)
    enableRow:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -(y - 8))
    enableRow:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -(y - 8))
    enableRow:SetHeight(ENABLE_HEIGHT)
    Chrome(enableRow, BoxStyle(ACCENT, 0.07, ACCENT, 0.25, 8))

    NewToggle(enableRow, 16, "Enable skin", "Off = default Blizzard look (debug)",
        function() return ns.db.enabled end,
        function(value)
            if ns.Skin and ns.Skin.SetEnabled then
                -- SetEnabled is the single entry point for the flag: it writes
                -- the store, restores or re-applies the quest skin, and drives
                -- the Mythic+ half from the same call. No reload either way.
                ns.Skin.SetEnabled(value)
            else
                ns.db.enabled = value and true or false
            end
            options.Sync()
        end, 8)

    y = y - 8 + ENABLE_HEIGHT + GROUP_GAP

    ------------------------------------------------------------------
    -- PANEL
    ------------------------------------------------------------------

    y = GroupLabel(panel, y, "Panel")

    y = NewSwatchRow(panel, y, "Background color", BG_SWATCHES,
        function(entry) return ns.db.bg.color == entry.colour end,
        function(entry) ns.db.bg.color = entry.colour end)

    y = NewSlider(panel, y, "Background opacity", 0, 100, 5,
        function() return (ns.db.bg.opacity or 1) * 100 end,
        function(value)
            ns.db.bg.opacity = value / 100
            Apply("background opacity changed")
        end,
        function(value) return string.format("%d%%", Int(value)) end)

    y = NewSwatchRow(panel, y, "Border color", BORDER_SWATCHES,
        function(entry)
            local alpha = ns.db.border.alpha or 1
            if entry.transparent then return alpha == 0 end
            return alpha > 0 and ns.db.border.color == entry.colour
        end,
        function(entry)
            if entry.transparent then
                ns.db.border.alpha = 0
            else
                ns.db.border.alpha = 1
                ns.db.border.color = entry.colour
            end
        end)

    y = NewSegmented(panel, y, "Border style", BORDER_STYLES,
        function() return ns.db.border.style end,
        function(key) ns.db.border.style = key end)

    y = NewSlider(panel, y, "Corner radius", 0, 16, 1,
        function() return ns.db.radius or 8 end,
        function(value)
            ns.db.radius = value
            Apply("radius changed")
        end,
        function(value) return string.format("%d px", Int(value)) end)

    -- Scale. These go through ns.SetScale, the same function /hp scale uses -
    -- it clamps, snaps to the 0.1 step, writes the store and re-applies the
    -- saved position, because a rescale moves the frame's top-left corner and
    -- the offsets are held in UIParent space.
    y = NewSlider(panel, y, "Quest tracker scale", 50, 150, 10,
        function() return (ns.db.frame.watch.scale or 1) * 100 end,
        function(value) ns.SetScale("watch", value / 100) end,
        function(value) return string.format("%d%%", Int(value)) end)

    y = NewSlider(panel, y, "M+ tracker scale", 50, 150, 10,
        function() return (ns.db.frame.mplus.scale or 1) * 100 end,
        function(value) ns.SetScale("mplus", value / 100) end,
        function(value) return string.format("%d%%", Int(value)) end)

    y = NewTileRow(panel, y, "Backdrop texture", BACKDROP_TILES,
        function() return ns.db.bg.texture end,
        function(key) ns.db.bg.texture = key end)

    ------------------------------------------------------------------
    -- TEXT
    ------------------------------------------------------------------

    y = y + GROUP_GAP
    y = GroupLabel(panel, y, "Text")

    local fontWidget
    y, fontWidget = NewFontDropdown(panel, y, "Font family", "via LibSharedMedia")
    options.fontDropdown = fontWidget

    y = NewSlider(panel, y, "Font size", 8, 20, 1,
        function() return ns.db.font.size or 12 end,
        function(value)
            ns.db.font.size = value
            Apply("font size changed")
        end,
        function(value) return string.format("%d px", Int(value)) end)

    -- Per-panel multipliers on that base. The three panels are different sizes
    -- and sit at different distances from where the player is looking, so one
    -- number for all of them made every change a compromise.
    --
    -- What the quest tracker actually takes is bounded by Lines.lua: the
    -- tracker measures and places each line before heroPanel sees it, so a line
    -- can never ask for more room and growth is clamped per line. Turning this
    -- past that ceiling is not an error, it just stops making a difference.
    local FONT_SCALES = {
        { key = "watch",   label = "Quest tracker font" },
        { key = "mplus",   label = "M+ tracker font"    },
        { key = "options", label = "This window's font" },
    }

    for i = 1, #FONT_SCALES do
        local entry = FONT_SCALES[i]
        y = NewSlider(panel, y, entry.label, 50, 150, 5,
            function()
                local scales = ns.db.font.scale
                return ((scales and scales[entry.key]) or 1) * 100
            end,
            function(value)
                if type(ns.db.font.scale) ~= "table" then ns.db.font.scale = {} end
                ns.db.font.scale[entry.key] = value / 100
                Apply("font scale changed")
            end,
            function(value) return string.format("%d%%", Int(value)) end)
    end

    y = NewStateColours(panel, y, "State colors", {
        { label = "Title",  get = function() return ns.db.text.title  end,
                            set = function(hex) ns.db.text.title  = hex end },
        { label = "Normal", get = function() return ns.db.text.normal end,
                            set = function(hex) ns.db.text.normal = hex end },
        { label = "Done",   get = function() return ns.db.text.done   end,
                            set = function(hex) ns.db.text.done   = hex end },
    })

    -- There is no HEADER group. header.show still exists and still governs the
    -- quest tracker's header row, but it is on and there is no control for it:
    -- heroPanel's header is where the lock, the count and the collapse caret
    -- live, so turning it off takes the skin's own chrome with it, and an
    -- option whose only sensible value is the default is a row of the window
    -- spent on nothing.

    ------------------------------------------------------------------
    -- Footer
    ------------------------------------------------------------------

    y = y + GROUP_GAP

    local save = NewFooterButton(panel, CONTENT_WIDTH - 130, "Save & close", true, function()
        options.Hide()
    end)
    save:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, -y)

    local reset = NewFooterButton(panel, 118, "Reset", false, function()
        options.Reset()
    end)
    reset:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD_X, -y)

    y = y + FOOTER_HEIGHT
    panel:SetHeight(y)

    ------------------------------------------------------------------
    -- Wiring
    ------------------------------------------------------------------

    panel.pillText   = pillText
    panel.pill       = pill
    panel.lockGlyph  = lockGlyph

    panel:SetScript("OnHide", function()
        if options.fontDropdown then options.fontDropdown:Close() end
    end)

    -- Escape closes it, like any other dialog.
    if type(_G.UISpecialFrames) == "table" then
        local already = false
        for i = 1, #_G.UISpecialFrames do
            if _G.UISpecialFrames[i] == "HeroPanelOptionsFrame" then already = true end
        end
        if not already then table.insert(_G.UISpecialFrames, "HeroPanelOptionsFrame") end
    end

    return panel
end

--------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------

local SCREEN_MARGIN = 8    -- keep this much of the window off the screen edge
local CLEARANCE     = 12   -- and this much between it and a tracker

-- The frames the window must not open on top of.
--
-- Both the trackers and heroPanel's own plates. The trackers because with the
-- skin disabled there are no plates and "do not cover the tracker" is still
-- true; the plates because a skinned panel is not the same rectangle as the
-- frame it skins - it is sized from the lines actually drawn and carries the
-- left margin the tucked quest art lives in, so it reaches further left than
-- WatchFrame does. Clearing the tracker and landing on the panel drawn around
-- it would satisfy the letter of the requirement and none of the point.
local function Obstacles()
    local list = {}

    local function Add(frame)
        if frame and frame.IsVisible and frame:IsVisible() and frame:GetLeft() then
            table.insert(list, frame)
        end
    end

    for i = 1, #ns.TRACKER_KEYS do
        Add(ns.GetTrackerFrame(ns.TRACKER_KEYS[i]))
    end
    if ns.Skin  and ns.Skin.GetPlate  then Add(ns.Skin.GetPlate())  end
    if ns.Mplus and ns.Mplus.GetPlate then Add(ns.Mplus.GetPlate()) end

    return list
end

local function Intersects(left, right, top, bottom, frame)
    local fLeft, fRight = frame:GetLeft(), frame:GetRight()
    local fTop, fBottom = frame:GetTop(), frame:GetBottom()
    if not (fLeft and fRight and fTop and fBottom) then return false end
    return left < fRight and right > fLeft and bottom < fTop and top > fBottom
end

-- Centring is the rule, but centring alone is not the guarantee. A 440px window
-- in the middle of a 1600px screen reaches x 1020, and a tracker parked at 1000
-- is under it - which is the mock's layout, and it is a real one. So the centred
-- position is measured against whatever is actually on screen and slid clear if
-- it is not, preferring the side with room. If neither side has room the window
-- stays centred: covering a tracker beats opening off the edge of the screen
-- where it cannot be reached at all.
local function ClearOfTrackers()
    local left,  right  = panel:GetLeft(),  panel:GetRight()
    local top,   bottom = panel:GetTop(),   panel:GetBottom()
    if not (left and right and top and bottom) then return end

    local blockLeft, blockRight
    local obstacles = Obstacles()
    for i = 1, #obstacles do
        local frame = obstacles[i]
        if Intersects(left, right, top, bottom, frame) then
            local fLeft, fRight = frame:GetLeft(), frame:GetRight()
            blockLeft  = blockLeft  and math.min(blockLeft,  fLeft)  or fLeft
            blockRight = blockRight and math.max(blockRight, fRight) or fRight
        end
    end
    if not blockLeft then return end

    local width       = right - left
    local screenLeft  = UIParent:GetLeft()  or 0
    local screenRight = UIParent:GetRight() or (screenLeft + width)

    local newLeft
    if (blockLeft - CLEARANCE - width) >= (screenLeft + SCREEN_MARGIN) then
        newLeft = blockLeft - CLEARANCE - width
    elseif (blockRight + CLEARANCE + width) <= (screenRight - SCREEN_MARGIN) then
        newLeft = blockRight + CLEARANCE
    else
        ns.Debug("no room to open the options window clear of the trackers; leaving it centred.")
        return
    end

    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT",
        newLeft - screenLeft, top - (UIParent:GetTop() or top))
    ns.Debug("options window moved clear of a tracker (%.0f -> %.0f).", left, newLeft)
end

local function Place()
    if not panel then return end
    local placement = SavedPlacement()

    panel:ClearAllPoints()
    if placement.point and placement.x then
        -- The player dragged it somewhere. That is a decision, and it is not
        -- second-guessed - no clearance pass here.
        panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", placement.x, placement.y or 0)
        return
    end

    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    ClearOfTrackers()
end

--------------------------------------------------------------------------------
-- Sync
--------------------------------------------------------------------------------

-- Pushes the store into every control. Called on open, so a value changed by a
-- slash command while the window was shut is what the window comes back
-- showing, rather than whatever it was left at.
function options.Sync()
    if not panel then return end
    syncing = true
    for i = 1, #controls do
        local ok, err = pcall(controls[i].Sync, controls[i])
        if not ok then ns.ReportError("options control", err) end
    end
    syncing = false

    local enabled = ns.db.enabled and true or false
    panel.pillText:SetText(enabled and "ENABLED" or "DISABLED")
    local colour = enabled and GREEN or "#C98A8A"
    panel.pillText:SetTextColor(ns.HexToRGB(colour))
    ns.StylePlateChrome(panel.pill, BoxStyle(colour, 0.12, nil, nil, 8))

    panel.lockGlyph:SetShape(ns.IsLocked() and "locked" or "unlocked")
    panel.lockGlyph:SetColor(ns.HexToRGB(LOCK_GLYPH))
end

-- Re-applies the configured face and size to the window's own strings, so
-- changing the font shows up here as well as on the trackers.
function options.Restyle()
    if not panel then return end
    local file = ns.GetFontFile()
    for i = 1, #fontStrings do
        local entry = fontStrings[i]
        pcall(entry.fs.SetFont, entry.fs, file, ns.GetFontSize(entry.delta, "options"))
    end
end

--------------------------------------------------------------------------------
-- Show / hide
--------------------------------------------------------------------------------

function options.Show()
    if not ns.db then
        ns.Warn("SavedVariables are not loaded yet - try again in a moment.")
        return false
    end
    Build()
    Place()
    options.Restyle()
    options.Sync()
    panel:Show()
    return true
end

function options.Hide()
    if panel then panel:Hide() end
    return true
end

function options.Toggle()
    if panel and panel:IsShown() then return options.Hide() end
    return options.Show()
end

function options.IsShown()
    return panel and panel:IsShown() and true or false
end

--------------------------------------------------------------------------------
-- Reset
--------------------------------------------------------------------------------

-- Everything back to the defaults, applied live. This clears the saved
-- positions along with everything else - that is what resetting the store
-- means - so the frames stay where they are until a reload puts them back where
-- the game wants them, which is exactly what /hp reset already says.
function options.Reset()
    ns.ResetDB()
    ns.Media.Invalidate()

    for i = 1, #ns.TRACKER_KEYS do
        local key = ns.TRACKER_KEYS[i]
        pcall(ns.ApplyLockState, key)
        pcall(ns.RestoreScale, key)
    end

    if ns.Skin and ns.Skin.SetEnabled then
        ns.Skin.SetEnabled(ns.db.enabled)
    end
    Apply("options reset")

    options.Restyle()
    options.Sync()

    ns.Print("settings reset to defaults. Saved positions were cleared too - "
        .. "|cFFC2C6D8/reload|r puts the frames back where the game wants them.")
end

--------------------------------------------------------------------------------
-- Live updates from elsewhere
--------------------------------------------------------------------------------

-- The lock can be flipped from either tracker's header or from /hp lock while
-- this window is open, and the header glyph has to follow.
ns:On("HEROPANEL_LOCK_CHANGED", function()
    if options.IsShown() then options.Sync() end
end)

--------------------------------------------------------------------------------
-- Interface -> AddOns
--
-- The category panel is a signpost rather than a second copy of the controls.
-- Rebuilding every widget inside Blizzard's options frame would mean two
-- windows that drift apart, and the interface frame is the wrong shape for a
-- 700px panel anyway.
--------------------------------------------------------------------------------

local function BuildInterfaceCategory()
    if type(_G.InterfaceOptions_AddCategory) ~= "function" then
        ns.Debug("this client has no Interface options category API; /hp still opens the panel.")
        return
    end

    local category = CreateFrame("Frame", "HeroPanelInterfaceCategory", _G.InterfaceOptionsFramePanelContainer)
    category.name = "heroPanel"
    category:Hide()

    local heading = category:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 16, -16)
    heading:SetText("heroPanel")

    local blurb = category:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    blurb:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
    blurb:SetWidth(500)
    blurb:SetJustifyH("LEFT")
    blurb:SetText("Skin, mover and lock controls for the objective tracker and the Mythic+ tracker.\n\n"
        .. "heroPanel's settings open in their own window, centred on screen so it never sits on "
        .. "top of the trackers it configures. Type |cFFC2C6D8/hp|r at any time, or use the button below.")

    local open = CreateFrame("Button", nil, category, "UIPanelButtonTemplate")
    open:SetWidth(180)
    open:SetHeight(24)
    open:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -16)
    open:SetText("Open heroPanel options")
    open:SetScript("OnClick", function()
        if type(_G.InterfaceOptionsFrame) == "table" then _G.InterfaceOptionsFrame:Hide() end
        if type(_G.HideUIPanel) == "function" and _G.GameMenuFrame then
            pcall(_G.HideUIPanel, _G.GameMenuFrame)
        end
        options.Show()
    end)

    -- Selecting the category opens the real window as well. Deferred by a frame
    -- because hiding the interface options from inside its own OnShow is asking
    -- the client to close a panel it is in the middle of opening.
    category:SetScript("OnShow", function()
        ns.After(0, function()
            if type(_G.InterfaceOptionsFrame) == "table" and _G.InterfaceOptionsFrame:IsShown() then
                _G.InterfaceOptionsFrame:Hide()
            end
            options.Show()
        end)
    end)

    _G.InterfaceOptions_AddCategory(category)
    options.category = category
end

ns:On("PLAYER_LOGIN", function()
    local ok, err = pcall(BuildInterfaceCategory)
    if not ok then ns.ReportError("Interface options category", err) end
end)
