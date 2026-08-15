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

    Placement is deliberate too. The window opens centred on UIParent in its own
    strata, and is then measured against whatever is actually on screen and slid
    clear if a tracker is under it - see ClearOfTrackers.

    Three groups, in this order.

      Global          what would read as two addons if the two panels disagreed
                      about it - the font family, the backdrop texture - plus
                      this window's own text size and background.
      Quest tracker   that panel's background, border, text shadow and three
                      font sizes (the header row, the quest names, and the
                      descriptions and their counts), plus the two auto-hide
                      toggles.
      Mythic+ tracker the same chrome controls again, three font sizes of its
                      own - header, timer and body - and the state colours.

    There are no scale sliders. All three panels carry a resize grip in their
    bottom-right corner while the trackers are unlocked, which is the corner of
    the thing being resized rather than a percentage to guess at.
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

-- The body scrolls.
--
-- The window was a fixed height once and its rows were shaved twice to stay
-- under UIParent's 768 units; splitting the chrome per tracker made that
-- unwinnable, since two of everything plus a global group does not fit however
-- tightly it is packed.
--
-- So the header, the enable row and the footer are fixed, and everything
-- between them lives in a ScrollFrame. The window is sized to its content up
-- to MAX_HEIGHT and scrolls past that, which means it is exactly as tall as it
-- needs to be on a screen with the room and never taller than the screen has.
local HEADER_HEIGHT = 56
local GROUP_GAP     = 10
local GROUP_RULE    = 16   -- space a separator rule takes, above its label
local GROUP_LABEL_H = 26   -- and the label itself, which is set over body size
local ROW_HEIGHT    = 28
local SLIDER_HEIGHT = 34
local FOOTER_HEIGHT = 44
-- Two rows now, one switch per panel. See the note on the enable block below.
local ENABLE_HEIGHT = 92

-- The scrollbar sits in the right margin, clear of the controls: they anchor
-- PAD_X in and it is inset less than half that.
local BAR_WIDTH     = 4
local BAR_INSET     = 8

-- The tallest the window may be, and the least body worth showing. UIParent is
-- about 768 units tall whatever the monitor is, because the client scales the
-- UI to suit, so this is a fixed budget rather than something to read off the
-- screen. 660 leaves room for a UI scale a couple of notches up, which is where
-- a full-height window got tight before. The harness fails the run if the
-- window ever goes over 768.
local MAX_HEIGHT    = 660
local MIN_VIEWPORT  = 200

local SWATCH_SIZE   = 22
local SWATCH_GAP    = 6
local TILE_SIZE     = 34
local TOGGLE_WIDTH  = 44
local TOGGLE_HEIGHT = 22
local KNOB_SIZE     = 18

local DROPDOWN_ROWS   = 10
local DROPDOWN_ROW_H  = 20
local DROPDOWN_WIDTH  = 200

-- The window's own chrome. Everything except the background is a design token:
-- the hairline edge, the corner and the shadow are what make this read as a
-- dialog over the UI rather than as a third tracker, and none of them is worth
-- a control. The background is the exception because it is the one surface a
-- player looks at for as long as the window is open, so it comes from
-- HEROPANEL_DB.panel.options and OptionsChrome below folds it in.
--
-- The reason the *rest* of it stays fixed has not changed: a config panel that
-- restyles itself as you drag a swatch makes it impossible to see what you are
-- setting. A background swatch escapes that because it is the window's own
-- background and nothing else's - there is no second thing it could be
-- confused with.
local CHROME = {
    bgColor     = "#161826",
    bgOpacity   = 1,
    borderColor = "#E9E9ED",
    borderAlpha = 0.10,
    borderStyle = "hairline",
    radius      = 12,
    shadowAlpha = 0.55,
}

local function OptionsChrome()
    local saved = ns.db and ns.db.panel and ns.db.panel.options
    local style = {}
    for key, value in pairs(CHROME) do style[key] = value end
    if type(saved) == "table" and saved.bgColor then style.bgColor = saved.bgColor end
    return style
end

local TEXT_BRIGHT = "#F3F5FE"
local TEXT_BODY   = "#C2C6D8"
local TEXT_MUTED  = "#75798C"
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

-- The options window's own set, which has to start with its design default or
-- nothing would read as selected the first time the window is opened.
local OPTIONS_BG_SWATCHES = {
    { colour = "#161826" }, { colour = "#0D0E14" },
    { colour = "#1C1F2E" }, { colour = "#232532" },
}

-- Colours only. There was a fifth entry, "Transparent", which zeroed
-- border.alpha and so turned off every edge heroPanel draws - and that is
-- exactly what border style **None** already does, one row further down. Two
-- controls reaching one outcome is not a choice, it is a question about which
-- of them the panel is currently obeying. The style keeps the job, because
-- "no border" belongs with the other border shapes rather than among the
-- colours; borderAlpha stays in the store because Plate.lua reads it, and
-- picking any colour here sets it back to 1.
local BORDER_SWATCHES = {
    { colour = "#33364A" }, { colour = "#1F2130" },
    { colour = "#9184D9" }, { colour = "#E7C67C" },
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
    -- The boon bar takes its chrome from the Mythic+ panel's colours, so a
    -- change made in that group has to reach it too, and its own group's
    -- orientation control routes through here as well.
    if ns.Boons then pcall(ns.Boons.Restyle) end
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

-- A group heading, optionally over a rule.
--
-- The rule is what makes "these settings belong to the Mythic+ panel and those
-- ones do not" readable at a glance. A heading on its own was enough while
-- there were two groups and no repetition; there are three now and two of them
-- carry the same six controls, so a reader scrolling past a background swatch
-- has to be able to tell which panel's background it is without scrolling back
-- up to find the heading.
local function GroupLabel(parent, y, text, rule)
    if rule then
        local line = NewTexture(parent, "BORDER")
        line:SetHeight(1)
        line:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD_X, -y)
        line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_X, -y)
        line:SetVertexColor(ns.HexToRGB("#E9E9ED", ns.ALPHA.divider))
        y = y + GROUP_RULE
    end

    -- A step *over* the body text rather than three points under it, and in the
    -- accent rather than the muted grey group colour. A heading set smaller and
    -- fainter than the rows beneath it is a heading you find by scrolling past
    -- it, which is the wrong way round in a window whose two lower groups carry
    -- the same six control labels as each other.
    local fs = NewText(parent, 2, ACCENT, string.upper(text))
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD_X, -y)
    return y + GROUP_LABEL_H
end

--------------------------------------------------------------------------------
-- Toggle
--
-- A pill track with a knob at one end. Two rounded boxes, so it picks up the
-- same corner treatment as everything else rather than being the one control
-- with square ends.
--------------------------------------------------------------------------------

-- The label column: everything to the left of the switch.
--
-- Set explicitly, because a FontString with no width is as wide as its text and
-- draws straight under whatever is to its right - which is a sublabel
-- disappearing behind the toggle, unreadable, looking like a rendering fault
-- rather than like a string that is too long.
--
-- Both toggle callers land on the same number: the body is 440 wide with PAD_X
-- either side and the enable block is 416 with 8, so the content column is 400
-- in both cases.
--
-- The practical budget for a sublabel is about 46 characters. That is not a
-- limit anything enforces - a longer one wraps and grows its row now rather
-- than breaking - but a window where every row is one line reads as a list,
-- and one where some rows are two reads as a form.
local LABEL_WIDTH  = CONTENT_WIDTH - TOGGLE_WIDTH - 12
local ACTION_WIDTH = CONTENT_WIDTH - 118 - 12

-- How many lines a string takes once it is given a width.
--
-- 3.3.5a's FontString has no word-wrap switch: a width means it wraps, and no
-- width means it runs under its neighbour. So the width is set and the row is
-- grown to fit whatever that produces - which is what keeps this window honest
-- when somebody drags the options font size up, since every row in it is
-- absolutely placed at build time and cannot reflow afterwards.
--
-- GetStringWidth measures the string unwrapped, which is all that is needed to
-- count the lines it will break into.
local function WrappedLines(fs, width)
    local ok, measured = pcall(fs.GetStringWidth, fs)
    measured = (ok and tonumber(measured)) or 0
    if measured <= 0 or width <= 0 then return 1 end
    return math.max(1, math.ceil(measured / width))
end

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
    title:SetWidth(LABEL_WIDTH)
    title:SetJustifyH("LEFT")
    title:SetPoint("LEFT", parent, "TOPLEFT", padX, -(y + TOGGLE_HEIGHT / 2) + (sublabel and 7 or 0))

    -- sublabel is a string, or a list of them for a control that needs two
    -- lines. A list rather than one string with a newline in it: an embedded
    -- break is invisible in the source, and GetStringWidth measures the whole
    -- string rather than its longest line, so the row-height arithmetic below
    -- would silently get it wrong.
    local subLines = sublabel
    if type(subLines) == "string" then subLines = { subLines } end

    local extraHeight, anchor = 0, title
    if subLines then
        local lineHeight = ns.GetFontSize(-2, "options") + 3
        for i = 1, #subLines do
            local sub = NewText(parent, -2, TEXT_MUTED, subLines[i])
            sub:SetWidth(LABEL_WIDTH)
            sub:SetJustifyH("LEFT")
            sub:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, (i == 1) and -3 or -1)
            anchor = sub

            -- The first line is what the row's base height already allows for.
            -- Every line after it, and every line any of them wraps onto, is
            -- height the row has to grow by.
            extraHeight = extraHeight
                + (WrappedLines(sub, LABEL_WIDTH) - (i == 1 and 1 or 0)) * lineHeight
        end
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
    return y + (subLines and (40 + extraHeight) or ROW_HEIGHT), widget
end

--------------------------------------------------------------------------------
-- Slider
--
-- A real Slider frame, so clicking the track and dragging the thumb both behave
-- the way the client's own sliders do, with heroPanel's art over the top: a 2px
-- track, an accent fill up to the thumb, and the value read out on the right.
--------------------------------------------------------------------------------

-- sublabel is optional and costs the row fourteen more pixels. It earns them
-- wherever a label alone cannot say which of several near-identical controls
-- this one is: "Header font size" and "Quest name font size" are the same three
-- words rearranged, and the panel now carries five font sizes.
local function NewSlider(parent, y, label, minValue, maxValue, step, get, set, format, sublabel)
    local title = NewText(parent, 0, TEXT_BODY, label)
    title:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD_X, -y)

    local readout = NewText(parent, -1, ACCENT)
    readout:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_X, -y)

    local trackTop = y + 18
    if sublabel then
        local sub = NewText(parent, -3, TEXT_MUTED, sublabel)
        sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
        trackTop = y + 32
    end

    local slider = CreateFrame("Slider", nil, parent)
    slider:SetOrientation("HORIZONTAL")
    slider:SetWidth(CONTENT_WIDTH)
    slider:SetHeight(16)
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD_X, -trackTop)
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
    return y + SLIDER_HEIGHT + (sublabel and 14 or 0), widget
end

--------------------------------------------------------------------------------
-- Colour swatches
--------------------------------------------------------------------------------

-- entries are { colour = "#RRGGBB" }.
--
-- There was a { transparent = true } form as well, drawn as an empty outline
-- rather than a filled square, and the border row used it to mean "no border at
-- all". It is gone: border style **None** says the same thing one row down, and
-- a panel obeying two controls that reach one outcome is a panel you have to
-- check twice.
--
-- isSelected and onSelect are still passed in rather than a get/set pair on a
-- colour, because a click has to write more than the colour - the border row
-- also sets borderAlpha back to 1, so picking a colour always shows one.
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
        Chrome(button, BoxStyle(entry.colour, 1, "#33364A", 1, 6))
        button.entry  = entry
        button.colour = entry.colour

        button:SetScript("OnClick", function()
            onSelect(entry)
            for j = 1, #buttons do buttons[j]:Refresh() end
            Apply("swatch changed")
        end)

        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(entry.colour, 1, 1, 1)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)

        function button:Refresh()
            local selected = isSelected(self.entry)
            ns.StylePlateChrome(self, BoxStyle(self.entry.colour, 1,
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

-- width is optional and defaults to what the border-style row wants. It is
-- offered because a segment is only as readable as its label fits into:
-- "Horizontal" and "Vertical" do not go in 78 units at the sizes this window is
-- set at, and the answer to that is a wider segment rather than a shorter word.
local function NewSegmented(parent, y, label, entries, get, set, width)
    local title = NewText(parent, 0, TEXT_BODY, label)
    title:SetPoint("LEFT", parent, "TOPLEFT", PAD_X, -(y + 13))

    local buttons = {}
    width = width or 78
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
    -- The swatch, plus its caption underneath, plus clearance.
    --
    -- This was 14, which covered the swatch and left the caption to overlap the
    -- next row's title by a couple of pixels - the one row in the window where
    -- the label hangs *below* its control rather than beside it, so the row's
    -- height has to account for a string the other builders never have.
    return y + SWATCH_SIZE + 26, widget
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

-- host is the frame the open list is parented to, which is deliberately not the
-- frame the button is on. The controls live in a ScrollFrame now, and a
-- ScrollFrame clips its children: a list built there would be cut off at the
-- viewport's edge, and a font list that shows four of its ten rows is not a
-- list. Parented to the window and anchored to the button, it draws over
-- whatever it needs to and still follows the button as the body scrolls.
local function NewFontDropdown(parent, y, label, sublabel, host)
    host = host or parent

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

    -- The list is a child of the window so it inherits its strata, and ten
    -- levels up so it draws over the controls it covers.
    local list = CreateFrame("Frame", nil, host)
    list:Hide()
    list:SetWidth(DROPDOWN_WIDTH)
    list:SetHeight(DROPDOWN_ROWS * DROPDOWN_ROW_H + 8)
    list:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -2)
    list:SetFrameLevel(host:GetFrameLevel() + 10)
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
-- One panel's chrome
--
-- The same five controls, built twice - once against HEROPANEL_DB.panel.watch
-- and once against .mplus. They were one set covering both panels, and one set
-- is a compromise rather than a setting: the Mythic+ panel is a block of
-- numbers that wants something solid behind it and the quest tracker is a
-- column of lines a player often wants nearly transparent over the world.
--
-- Written as a function rather than copied, so the two groups cannot drift.
--------------------------------------------------------------------------------

-- Resolved per call rather than captured. Reset replaces the whole store, and a
-- closure holding the old table would go on writing to a table nothing reads.
local function PanelSaved(key)
    if type(ns.db.panel) ~= "table" then ns.db.panel = {} end
    if type(ns.db.panel[key]) ~= "table" then ns.db.panel[key] = {} end
    return ns.db.panel[key]
end

local function OptionsSaved() return PanelSaved("options") end

local function PanelGroup(parent, y, key)
    local function saved() return PanelSaved(key) end

    y = NewSwatchRow(parent, y, "Background color", BG_SWATCHES,
        function(entry) return saved().bgColor == entry.colour end,
        function(entry) saved().bgColor = entry.colour end)

    y = NewSlider(parent, y, "Background opacity", 0, 100, 5,
        function() return (saved().bgOpacity or 1) * 100 end,
        function(value)
            saved().bgOpacity = value / 100
            Apply("background opacity changed")
        end,
        function(value) return string.format("%d%%", Int(value)) end)

    y = NewSwatchRow(parent, y, "Border color", BORDER_SWATCHES,
        function(entry) return saved().borderColor == entry.colour end,
        function(entry)
            saved().borderColor = entry.colour
            -- Picking a colour means wanting to see it. A store carried across
            -- from a build where "Transparent" set the alpha to nought would
            -- otherwise take the new colour and go on drawing nothing.
            saved().borderAlpha = 1
        end)

    y = NewSegmented(parent, y, "Border style", BORDER_STYLES,
        function() return saved().borderStyle end,
        function(style) saved().borderStyle = style end)

    -- There is no corner radius control.
    --
    -- There are no rounded corners on 3.3.5a and heroPanel ships no corner art,
    -- so ns.NotchFor turns any radius into one of four chamfers, nought to three
    -- pixels - a range nobody can see at gameplay distance, which two attempts at
    -- a control (a 0-16 slider, then four four-pixel steps) both demonstrated.
    --
    -- So the panels are square, HEROPANEL_DB.panel.<key>.radius is 0, and the
    -- key stays in the store because Plate.lua reads it and real corner art
    -- would make it mean something again.

    return y
end

--------------------------------------------------------------------------------
-- One panel's text shadow
--
-- A toggle and a thickness, kept together because neither is any use alone.
-- Split out from PanelGroup rather than folded into it because these belong
-- with that panel's *font* controls rather than with its background: what they
-- do is make text legible, and the row above them wants to be a font size.
--------------------------------------------------------------------------------

local function ShadowGroup(parent, y, key)
    local function saved() return PanelSaved(key) end

    y = NewToggle(parent, y, "Text shadow", "holds this panel's text against the world behind it",
        function() return saved().textShadow end,
        function(value)
            saved().textShadow = value and true or false
            Apply("text shadow toggled")
        end)

    y = NewSlider(parent, y, "Shadow thickness", 1, 3, 1,
        function() return saved().textShadowSize or 1 end,
        function(value)
            saved().textShadowSize = value
            Apply("text shadow size changed")
        end,
        function(value) return string.format("%d px", Int(value)) end,
        -- Said out loud because the three steps are not one effect getting
        -- bigger. 1 is the drop shadow on its own; 2 and 3 outline the glyphs
        -- with the font's own OUTLINE and THICKOUTLINE, which is the only thing
        -- that actually surrounds a letter. See ns.ApplyTextShadow.
        "1 is a drop shadow, 2 and 3 outline the letters")

    return y
end

--------------------------------------------------------------------------------
-- One text role's size
--
-- Absolute points, straight into HEROPANEL_DB.font.size. A percentage over a
-- shared base came first and was dropped: what a player set and what was drawn
-- were never the same number.
--------------------------------------------------------------------------------

local function NewFontSlider(parent, y, label, role, sublabel)
    return NewSlider(parent, y, label, ns.FONT_SIZE_MIN, ns.FONT_SIZE_MAX, 1,
        function() return ns.GetFontSize(0, role) end,
        function(value)
            if type(ns.db.font.size) ~= "table" then ns.db.font.size = {} end
            ns.db.font.size[role] = value
            Apply("font size changed")
        end,
        function(value) return string.format("%d px", Int(value)) end,
        sublabel)
end

--------------------------------------------------------------------------------
-- Footer buttons
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- A labelled action button on its own row
--
-- Not a setting - it does something on the spot and has nothing to show back.
-- The one in the window so far, Reset, is a footer button, which is right for a
-- control that applies to the whole window and wrong for one that applies to a
-- single group.
--------------------------------------------------------------------------------

local function NewActionRow(parent, y, label, sublabel, action, onClick)
    local title = NewText(parent, 0.5, TEXT_BRIGHT, label)
    title:SetWidth(ACTION_WIDTH)
    title:SetJustifyH("LEFT")
    title:SetPoint("LEFT", parent, "TOPLEFT", PAD_X, -(y + 13) + (sublabel and 7 or 0))

    local extraHeight = 0
    if sublabel then
        local sub = NewText(parent, -2, TEXT_MUTED, sublabel)
        sub:SetWidth(ACTION_WIDTH)
        sub:SetJustifyH("LEFT")
        sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
        extraHeight = (WrappedLines(sub, ACTION_WIDTH) - 1)
            * (ns.GetFontSize(-2, "options") + 3)
    end

    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(118)
    button:SetHeight(26)
    button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_X, -y)
    Chrome(button, BoxStyle("#1C1F2E", 1, "#33364A", 1, 6))

    local text = NewText(button, -0.5, TEXT_BODY, action)
    text:SetPoint("CENTER")

    button:SetScript("OnClick", onClick)
    return y + (sublabel and (40 + extraHeight) or ROW_HEIGHT)
end

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
    Chrome(panel, OptionsChrome())

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

    -- The glyph, not the button. 26px is what the accent tile wants to be next
    -- to the title; 19px is what the padlock inside it has to be to read as a
    -- padlock rather than as a mark on the tile.
    local lockGlyph = ns.NewGlyph(lockButton, 19)
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

    -- Both trackers, named. "Objective tracker skin" undersold half of what is
    -- in the window: the Mythic+ panel is a group of its own now.
    local subtitle = NewText(panel, -2, TEXT_MUTED,
        "M+ and Objective tracker skin \194\183 v" .. ns.version)
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
        -- In UIParent's space, not the window's own. This was a plain
        -- subtraction of two GetLefts, which is correct only while the window
        -- is at scale 1 - the two values are then in the same units. It is
        -- scalable now, so the conversion has to be explicit or a window left
        -- in the corner at 130% comes back somewhere else entirely.
        local x, y = ns.GetUIOffsets(self)
        if not x then return end

        local placement = SavedPlacement()
        placement.point = "TOPLEFT"
        placement.x, placement.y = x, y
    end)

    ------------------------------------------------------------------
    -- Enable skin
    --
    -- Fixed under the header rather than inside the scrolling body. It is the
    -- escape hatch - the control whose whole purpose is being reachable when
    -- something else has gone wrong - and one you have to go looking for is not
    -- that.
    --
    -- One switch per panel. A single "Enable skin" covering both came first and
    -- made the commonest thing anybody wants from a skin - seeing one panel
    -- without it - impossible to do to one panel at a time.
    --
    -- Both stay in the fixed block rather than moving down into each panel's
    -- own group. A switch that turns a panel off is not a setting of that panel
    -- in the way its background colour is, and burying either one behind a
    -- scroll is exactly what the block exists to avoid.
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

    -- ns.SetSkinEnabled is the single entry point for either flag: it writes the
    -- store and restores or re-applies that panel on the spot. No reload either
    -- way, and no way for one of the two to be written without the other being
    -- consulted.
    -- rowY, not y: the enable rows are placed inside their own frame and must
    -- not disturb the running y this function builds the rest of the window on.
    local function EnableToggle(rowY, key, label, sublabel)
        NewToggle(enableRow, rowY, label, sublabel,
            function() return ns.SkinEnabled(key) end,
            function(value)
                if ns.SetSkinEnabled then
                    ns.SetSkinEnabled(key, value)
                elseif type(ns.db.skin) == "table" then
                    ns.db.skin[key] = value and true or false
                end
                options.Sync()
            end, 8)
    end

    EnableToggle(12, "watch", "Objective panel skin", "Off = Blizzard's own quest tracker")
    EnableToggle(50, "mplus", "M+ panel skin",        "Off = Ascension's own Mythic+ tracker")

    local bodyTop = y - 8 + ENABLE_HEIGHT + GROUP_GAP

    ------------------------------------------------------------------
    -- The scrolling body
    --
    -- A ScrollFrame is the only thing on this client that clips its children,
    -- so it is what stops a body taller than the window from being drawn over
    -- the header and the footer. Everything below is built into `body` at its
    -- natural height and the viewport shows as much of it as the screen has
    -- room for.
    ------------------------------------------------------------------

    local viewport = CreateFrame("ScrollFrame", nil, panel)
    viewport:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -bodyTop)
    viewport:SetWidth(PANEL_WIDTH)

    -- Same width as the window, so every control's TOPRIGHT anchor lands where
    -- it did when they hung off the window itself. It is attached to the
    -- viewport further down, once it has been built and its real height is
    -- known: SetScrollChild reads the child's size, and handing it a frame that
    -- is one pixel tall and then growing it is asking the client to keep up.
    local body = CreateFrame("Frame", nil, viewport)
    body:SetWidth(PANEL_WIDTH)

    y = 0

    ------------------------------------------------------------------
    -- GLOBAL
    --
    -- What is here rather than in a panel's own group is what would read as two
    -- addons if the two panels disagreed about it. A font family is one voice
    -- and a backdrop texture is one piece of art; a background colour is not,
    -- which is why those moved down.
    ------------------------------------------------------------------

    y = GroupLabel(body, y, "Global")

    local fontWidget
    y, fontWidget = NewFontDropdown(body, y, "Font family", "via LibSharedMedia", panel)
    options.fontDropdown = fontWidget

    y = NewFontSlider(body, y, "Options font size", "options",
        "the size of this window's own text")

    -- This window's own background, on the same kind of control the two panels
    -- use for theirs. The rest of its chrome stays a design token - see the note
    -- on CHROME - so there is no opacity or border row here to go with it.
    y = NewSwatchRow(body, y, "Options background", OPTIONS_BG_SWATCHES,
        function(entry) return OptionsSaved().bgColor == entry.colour end,
        function(entry) OptionsSaved().bgColor = entry.colour end)

    y = NewTileRow(body, y, "Backdrop texture", BACKDROP_TILES,
        function() return ns.db.bg.texture end,
        function(key) ns.db.bg.texture = key end)

    ------------------------------------------------------------------
    -- QUEST TRACKER
    --
    -- Three font sizes rather than one. They are three different jobs on
    -- screen: the header is a label you read once and then stop seeing, the
    -- quest name is what you scan for, and the description is what you read
    -- when you have found it. One number for all three meant making the names
    -- big enough to scan also made the descriptions big enough to fill the
    -- panel.
    ------------------------------------------------------------------

    y = GroupLabel(body, y + GROUP_GAP, "Quest tracker", true)
    y = PanelGroup(body, y, "watch")

    y = NewFontSlider(body, y, "Header font size", "watchHeader",
        "the QUESTS row and its count")
    y = NewFontSlider(body, y, "Quest name font size", "watchTitle",
        "the name of each tracked quest")
    y = NewFontSlider(body, y, "Description font size", "watchBody",
        "objectives, descriptions and their counts")

    y = ShadowGroup(body, y, "watch")

    -- Nothing tracked, nothing drawn.
    --
    -- With no quests being followed the skin is a header reading "QUESTS 0" and
    -- a plate around an empty column. This takes the whole thing off screen
    -- rather than just the header row, because a bare plate with no header on it
    -- reads as the skin having half failed rather than as a setting.
    y = NewToggle(body, y, "Hide when empty", "no header or panel while nothing is tracked",
        function() return ns.db.header.hideEmpty end,
        function(value)
            ns.db.header.hideEmpty = value and true or false
            if ns.Skin then pcall(ns.Skin.Refresh, "hide-when-empty toggled") end
        end)

    -- The header row on demand.
    --
    -- QUESTS, the count, the lock and the caret are chrome: useful while you
    -- are arranging the tracker, and nothing you need on screen while reading
    -- the quest under them. This fades them rather than removing the row, so
    -- the quest lines stay where they are.
    y = NewToggle(body, y, "Header on mouseover",
        "shows the header only while you hover the panel",
        function() return ns.db.header.mouseover end,
        function(value)
            ns.db.header.mouseover = value and true or false
            if ns.Skin and ns.Skin.RefreshHeaderFade then
                pcall(ns.Skin.RefreshHeaderFade)
            end
        end)

    -- Getting the tracker out of the way on its own.
    --
    -- Both of these fade the tracker to nothing rather than hiding it, because
    -- WatchFrame is protected and Hide is refused under lockdown - which is
    -- precisely the moment "hide in combat" has to work. See the note in
    -- Skin.lua; the short version is that the obvious call is the one that is
    -- guaranteed to fail.
    y = NewToggle(body, y, "Hide in combat", "fades the tracker while you are fighting",
        function() return ns.db.autoHide.combat end,
        function(value)
            ns.db.autoHide.combat = value and true or false
            if ns.Skin and ns.Skin.RefreshAutoHide then pcall(ns.Skin.RefreshAutoHide) end
        end)

    y = NewToggle(body, y, "Hide in Mythic+", "...and for the length of a keystone run",
        function() return ns.db.autoHide.mythic end,
        function(value)
            ns.db.autoHide.mythic = value and true or false
            if ns.Skin and ns.Skin.RefreshAutoHide then pcall(ns.Skin.RefreshAutoHide) end
        end)

    ------------------------------------------------------------------
    -- MYTHIC+ TRACKER
    --
    -- Three font sizes, the same way the quest tracker has three. One number
    -- moved the whole panel together, which sounds harmless until you try to
    -- use it: the clock is deliberately about twice everything else, so
    -- enlarging the boss rows enough to read them at a glance gave the timer a
    -- third of the panel. The clock therefore gets its own control, and the
    -- design's steps *within* each role - the keystone level a point under the
    -- dungeon name, the required boss a point and a half over the others -
    -- stay in the code, because those are proportions rather than preferences.
    --
    -- The state colours live in this group even though they are quest-tracker
    -- language - a quest title, a normal line, a completed one - because the only
    -- place all three are visible side by side at a glance is the Mythic+ panel's
    -- boss list.
    ------------------------------------------------------------------

    y = GroupLabel(body, y + GROUP_GAP, "Mythic+ tracker", true)

    -- Placement preview.
    --
    -- First in the group, above the colours and the fonts, because it is what
    -- makes the rest of the group usable: the panel only exists during a
    -- keystone run, so every control below this one is otherwise being set
    -- blind and judged a week later, thirty seconds into a timed key.
    --
    -- Not stored. The switch reads and writes the module's own session flag, so
    -- a reload puts it back off - see the preview section in Mplus.lua for why
    -- a preview that survived a login would read as a bug rather than a switch.
    y = NewToggle(body, y, "Show panel for placement",
        { "draws it outside a key, with sample data",
          "drag to place; turns itself off in a real key" },
        function() return ns.Mplus and ns.Mplus.IsPreview() end,
        function(value)
            if ns.Mplus then ns.Mplus.SetPreview(value) end
        end)

    y = PanelGroup(body, y, "mplus")

    y = NewFontSlider(body, y, "Header font size", "mplusHeader",
        "the dungeon name and keystone level")
    y = NewFontSlider(body, y, "Timer font size", "mplusTimer",
        "the clock")
    y = NewFontSlider(body, y, "Body font size", "mplusBody",
        "chest tiers, enemy forces and boss rows")

    y = ShadowGroup(body, y, "mplus")

    y = NewStateColours(body, y, "State colors", {
        { label = "Title",  get = function() return ns.db.text.title  end,
                            set = function(hex) ns.db.text.title  = hex end },
        { label = "Normal", get = function() return ns.db.text.normal end,
                            set = function(hex) ns.db.text.normal = hex end },
        { label = "Done",   get = function() return ns.db.text.done   end,
                            set = function(hex) ns.db.text.done   = hex end },
    })

    -- Party key checks.
    --
    -- Not a skin setting, and in this group anyway: it is the only thing in the
    -- window that is about keystones rather than about how a panel is drawn,
    -- and a group of its own for one switch would cost more scroll than it
    -- saves confusion. The sublabel carries a sigil, because "key checks" does
    -- not say what to type and the whole feature is what to type.
    --
    -- It says "links your keystone" rather than naming the feature twice. This
    -- switch puts a line in chat under the player's own name, which is the one
    -- thing in this window that other people see, and a player deciding whether
    -- to leave it on is deciding about that rather than about key checks.
    -- Two lines, because the feature *is* what to type and one sigil is not the
    -- whole of it. Which one a server's players settle on is local habit, so
    -- heroPanel answers eight spellings - and a control that names one of them
    -- reads as the only one that works.
    --
    -- The second line is built from ns.Keys.COMMANDS rather than written out
    -- again. That list is published for exactly this, and a hand-copied one is a
    -- list that goes stale the first time a sigil is added.
    local function OtherKeyCommands()
        local list = ns.Keys and ns.Keys.COMMANDS
        if type(list) ~= "table" then return "also !keys and the singular forms" end

        local others = {}
        for i = 1, #list do
            if list[i] ~= "?keys" then table.insert(others, list[i]) end
        end
        return "also " .. table.concat(others, " ")
    end

    y = NewToggle(body, y, "Answer party key checks",
        {
            "?keys in group chat links your keystone for you",
            OtherKeyCommands(),
        },
        function() return ns.Keys and ns.Keys.IsEnabled() end,
        function(value)
            if ns.Keys then ns.Keys.SetEnabled(value) end
        end)

    ------------------------------------------------------------------
    -- BOONS
    --
    -- The Mythic+ boon bar, which is a third panel rather than a skin over
    -- somebody else's frame - see Boons.lua. Its group is last because it is
    -- the one feature in this window that is off until asked for, and a group
    -- of controls for something switched off does not want to be the first
    -- thing anybody scrolls past.
    --
    -- There is no scale slider and no lock of its own. The bar carries the same
    -- corner resize grip the other three panels do, and it obeys the single
    -- global lock the padlock in this window's header sets - which is why the
    -- lock row below says out loud that it covers the trackers too, rather than
    -- looking like a control for this bar alone.
    ------------------------------------------------------------------

    y = GroupLabel(body, y + GROUP_GAP, "Boons", true)

    -- Resolved per call rather than captured, for the same reason PanelSaved is:
    -- Reset replaces the whole store, and a closure holding the old table would
    -- go on writing to a table nothing reads.
    local function BoonsSaved()
        if type(ns.db.boons) ~= "table" then ns.db.boons = {} end
        return ns.db.boons
    end

    -- Every boon setting except the enable switch changes the bar's shape or
    -- its visuals and nothing else, so they all land the same way.
    local function BoonsRefresh(reason)
        if ns.Boons then pcall(ns.Boons.Refresh, reason) end
    end

    y = NewToggle(body, y, "Boon bar", "a clickable bar of your Mythical Boons",
        function() return ns.Boons and ns.Boons.IsEnabled() end,
        function(value)
            if ns.Boons then ns.Boons.SetEnabled(value) end
        end)

    y = NewSegmented(body, y, "Orientation", {
            { key = "horizontal", label = "Horizontal" },
            { key = "vertical",   label = "Vertical"   },
        },
        function() return BoonsSaved().orientation or "horizontal" end,
        function(key) BoonsSaved().orientation = key end,
        100)

    -- Icon size and the corner grip's scale are not the same lever and both are
    -- worth having. Size is how big one icon is, which is what decides whether
    -- the bar can be read at a glance; scale is how big the whole bar is,
    -- including the gaps between its three groups.
    y = NewSlider(body, y, "Icon size",
        ns.BOON_ICON_MIN or 20, ns.BOON_ICON_MAX or 64, ns.BOON_ICON_STEP or 2,
        function() return BoonsSaved().iconSize or 32 end,
        function(value)
            BoonsSaved().iconSize = value
            BoonsRefresh("boon icon size changed")
        end,
        function(value) return string.format("%d px", Int(value)) end,
        "drag the bar's corner to scale the whole bar")

    y = NewToggle(body, y, "Only in Mythic dungeons",
        "off shows it everywhere, for positioning",
        function() return BoonsSaved().mythicOnly ~= false end,
        function(value)
            BoonsSaved().mythicOnly = value and true or false
            BoonsRefresh("boon gating changed")
        end)

    y = NewToggle(body, y, "Hide unowned boons", "compacts the bar; out of combat only",
        function() return BoonsSaved().hideUnowned end,
        function(value)
            BoonsSaved().hideUnowned = value and true or false
            BoonsRefresh("boon hide-unowned toggled")
        end)

    y = NewToggle(body, y, "Hide when you have none",
        "hides the bar until you pick one up",
        function() return BoonsSaved().hideEmpty end,
        function(value)
            BoonsSaved().hideEmpty = value and true or false
            BoonsRefresh("boon hide-empty toggled")
        end)

    -- "Mark melee-only boons" was here, and is shelved. Boons.lua keeps the
    -- code and gates it off; see MELEE_MARK_SHELVED there, which is also the
    -- one line to change to bring this row back.

    -- The expiry warning.
    --
    -- Sits with the appearance rows because it is one, and above the two
    -- settings that move things. Four buttons rather than a slider: the
    -- question is how much warning you want and the difference between forty
    -- and forty-five seconds is not a thing anybody has an opinion about.
    --
    -- Off is first and is the default. See the note in Core.lua on why an
    -- animation is a thing to opt into.
    y = NewSegmented(body, y, "Expiry glow",
        ns.BOON_EXPIRY_WARNINGS or { { key = 0, label = "Off" } },
        function() return tonumber(BoonsSaved().expiryWarn) or 0 end,
        function(key)
            BoonsSaved().expiryWarn = key
            BoonsRefresh("boon expiry warning changed")
        end,
        62)

    -- Anchoring, and then the slot order, are the two settings that move things
    -- rather than colour them, so they sit below the appearance rows.
    --
    -- The sublabel has to carry the packing as well as the anchoring, because
    -- anchoring does both: a bar hanging under that panel draws only the boons
    -- you are holding, hard against the panel's left edge, so the nth icon is
    -- the nth keybind slot. Two separate checkboxes for one request would be a
    -- version where this one looks broken on its own.
    y = NewToggle(body, y, "Anchor under Mythic+ panel",
        { "follows that panel; you cannot drag it",
          "packs held boons into slots 1-5, bottom left" },
        function() return BoonsSaved().anchorMplus end,
        function(value)
            BoonsSaved().anchorMplus = value and true or false
            BoonsRefresh("boon anchoring toggled")
        end)

    -- The slot order and the keybinds are one idea, so the sublabel has to
    -- carry both halves: what moves, and what that does for the keys. Said in
    -- one line because a setting that needs a paragraph is a setting nobody
    -- turns on.
    y = NewToggle(body, y, "Line boons up in slots 1-5",
        "held boons move to the front, for the keys",
        function() return BoonsSaved().slotOrder end,
        function(value)
            BoonsSaved().slotOrder = value and true or false
            BoonsRefresh("boon slot order toggled")
        end)

    -- Shift-click reporting.
    --
    -- The sublabel says both halves because the setting changes what a click
    -- does, and a player who ticks this and then wonders why shift-clicking a
    -- boon stopped using it has been told something the box did not say.
    --
    -- Routed through BoonsRefresh rather than saved and forgotten, unlike the
    -- tooltip toggle below it: this one is a secure attribute on fifteen
    -- buttons, so it does not take effect until the next secure pass, and the
    -- next secure pass has to be now rather than whenever a bag changes.
    y = NewToggle(body, y, "Shift-click reports remaining duration",
        { "says how long your boon has left, in party chat",
          "that click no longer uses the boon" },
        function() return BoonsSaved().reportDuration end,
        function(value)
            BoonsSaved().reportDuration = value and true or false
            BoonsRefresh("boon shift-click reporting toggled")
        end)

    -- The in-combat tooltip is a one-line summary heroPanel writes, because
    -- three of the fifteen live client strings are wrong - BoonData.lua names
    -- them. This is the way back to the client's own text for anyone who would
    -- rather read that and judge for themselves.
    y = NewToggle(body, y, "Full boon text", "client's own text instead of a summary",
        function() return BoonsSaved().rawTooltip end,
        function(value)
            BoonsSaved().rawTooltip = value and true or false
        end)

    y = NewToggle(body, y, "Lock position", "the same lock as the trackers",
        function() return ns.IsLocked() end,
        function(value) ns.SetLocked(value and true or false) end)

    -- Where the keys are. Not a control, and worth a row anyway: the bindings
    -- live in the client's own Key Bindings window rather than in here, and
    -- nothing else in this group would say so.
    --
    -- Two lines, because there are now two kinds of key and the difference
    -- between them is the thing worth saying: the slot keys are direct access
    -- and the cycle key is sequential. "Cycle boons" is the one most people
    -- want and it is named second only because the slots came first.
    do
        local note = NewText(body, -2, TEXT_MUTED,
            "Keys: Key Bindings \194\183 heroPanel \194\183 Boon slot 1-5")
        note:SetPoint("TOPLEFT", body, "TOPLEFT", PAD_X, -y)
        y = y + 16

        local cycle = NewText(body, -2, TEXT_MUTED,
            "or \194\183 Cycle boons \194\183 one key, next boon each press")
        cycle:SetPoint("TOPLEFT", body, "TOPLEFT", PAD_X, -y)
        y = y + 22
    end

    y = NewActionRow(body, y, "Bar position",
        "back to the middle of the screen", "Reset",
        function()
            if ns.Boons then ns.Boons.ResetPosition() end
        end)

    -- There is no HEADER group. header.show still exists and still governs the
    -- quest tracker's header row, but it is on and there is no control for it:
    -- heroPanel's header is where the lock, the count and the collapse caret
    -- live, so turning it off takes the skin's own chrome with it, and an
    -- option whose only sensible value is the default is a row of the window
    -- spent on nothing.
    --
    -- There are no scale sliders either. Both panels carry a resize grip in
    -- their bottom-right corner while the trackers are unlocked, and dragging
    -- the corner of the thing being resized beats guessing a percentage and
    -- then looking away from the slider to see what the percentage did.

    body:SetHeight(y + GROUP_GAP)

    ------------------------------------------------------------------
    -- Viewport and scrollbar
    ------------------------------------------------------------------

    local room     = MAX_HEIGHT - bodyTop - FOOTER_HEIGHT - 8
    local viewHigh = math.max(MIN_VIEWPORT, math.min(body:GetHeight(), room))
    viewport:SetHeight(viewHigh)
    viewport:SetScrollChild(body)

    local range = math.max(0, body:GetHeight() - viewHigh)

    local bar = CreateFrame("Slider", nil, panel)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(BAR_WIDTH)
    bar:SetPoint("TOPRIGHT", viewport, "TOPRIGHT", -BAR_INSET, 0)
    bar:SetPoint("BOTTOMRIGHT", viewport, "BOTTOMRIGHT", -BAR_INSET, 0)
    bar:SetMinMaxValues(0, range)
    bar:SetValueStep(1)

    local barTrack = NewTexture(bar, "BACKGROUND")
    barTrack:SetAllPoints(bar)
    barTrack:SetVertexColor(ns.HexToRGB("#E9E9ED", 0.06))

    bar:SetThumbTexture(ns.SOLID)
    local barThumb = bar:GetThumbTexture()
    if barThumb then
        barThumb:SetWidth(BAR_WIDTH)
        barThumb:SetHeight(math.max(24, viewHigh * viewHigh / math.max(1, body:GetHeight())))
        barThumb:SetVertexColor(ns.HexToRGB(ACCENT, 0.7))
    end

    bar:SetScript("OnValueChanged", function(_, value)
        viewport:SetVerticalScroll(value)
    end)
    bar:SetValue(0)

    -- A body that fits needs no bar, and a visible one that cannot move reads
    -- as a window that has failed to scroll.
    if range <= 0 then bar:Hide() end

    local WHEEL_STEP = 34   -- about one control row per notch
    viewport:EnableMouseWheel(true)
    viewport:SetScript("OnMouseWheel", function(_, delta)
        bar:SetValue(ns.Clamp((bar:GetValue() or 0) - delta * WHEEL_STEP, 0, range))
    end)

    panel.viewport = viewport
    panel.scrollBar = bar

    ------------------------------------------------------------------
    -- Footer
    ------------------------------------------------------------------

    local footerTop = bodyTop + viewHigh + 8

    local save = NewFooterButton(panel, CONTENT_WIDTH - 130, "Save & close", true, function()
        options.Hide()
    end)
    save:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X, -footerTop)

    local reset = NewFooterButton(panel, 118, "Reset", false, function()
        options.Reset()
    end)
    reset:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD_X, -footerTop)

    panel:SetHeight(footerTop + FOOTER_HEIGHT)

    ------------------------------------------------------------------
    -- Resize grip
    --
    -- The same handle both trackers carry, so the three panels resize the same
    -- way. It scales rather than resizes, which matters more here than it does
    -- on a tracker: this window is a column of absolutely-placed rows 440 units
    -- wide, so stretching the frame would leave every control exactly where it
    -- was and just add empty space down the right.
    --
    -- It follows the lock, like the trackers' grips do. Built always-on at
    -- first, on the grounds that the lock governs the trackers rather than this
    -- window - which read as the third panel having missed the memo. The lock
    -- button is in this window's own header, so the way back is one click.
    ------------------------------------------------------------------

    panel.grip = ns.NewResizeGrip(panel, {
        label   = "options window",
        visible = function() return not ns.IsLocked() end,
        get     = function() return SavedPlacement().scale or 1 end,
        set     = function(scale) options.SetScale(scale) end,
    })
    -- Above the footer buttons it sits beside, and above the scrollbar.
    panel.grip:Raise(nil, panel:GetFrameLevel() + 10)

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
        --
        -- The offsets are held in UIParent's space and converted on the way
        -- back out, because the window is scalable now: a SetPoint offset is
        -- read in the moved frame's own units, so the same pair of numbers
        -- means a different place on screen at a different scale. Storing screen
        -- position and converting is what keeps a window that was left in the
        -- corner in the corner after a rescale.
        ns.ApplyUIOffsets(panel, placement.x, placement.y or 0)
        return
    end

    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    ClearOfTrackers()
end

--------------------------------------------------------------------------------
-- Scale
--
-- Driven by the corner grip. This is the window's own scale rather than one of
-- the trackers', so it does not go through ns.SetScale - nothing here is
-- protected and there is no holder to reason about - but it has the same
-- obligation: re-pin the top-left corner afterwards, because the saved offsets
-- are in UIParent space and a rescale changes what an offset in the window's own
-- space means.
--------------------------------------------------------------------------------

function options.SetScale(scale)
    if not (panel and ns.db) then return false end

    scale = ns.Snap(ns.Clamp(scale, ns.SCALE_MIN, ns.SCALE_MAX), 0.05)
    local placement = SavedPlacement()
    placement.scale = scale

    panel:SetScale(scale)
    if placement.point and placement.x then
        ns.ApplyUIOffsets(panel, placement.x, placement.y or 0)
    end
    return true, scale
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

    -- Three states, because there are two switches. "Enabled" over a window
    -- where one of the two panels is off would be the pill telling a half-truth
    -- about the very thing it exists to report at a glance.
    local watchOn, mplusOn = ns.SkinEnabled("watch"), ns.SkinEnabled("mplus")
    local label, colour
    if watchOn and mplusOn then
        label, colour = "ENABLED", GREEN
    elseif watchOn or mplusOn then
        label, colour = "PARTIAL", "#E7C67C"
    else
        label, colour = "DISABLED", "#C98A8A"
    end

    panel.pillText:SetText(label)
    panel.pillText:SetTextColor(ns.HexToRGB(colour))
    ns.StylePlateChrome(panel.pill, BoxStyle(colour, 0.12, nil, nil, 8))

    panel.lockGlyph:SetShape(ns.IsLocked() and "locked" or "unlocked")
    panel.lockGlyph:SetColor(ns.HexToRGB(LOCK_GLYPH))
end

-- Re-applies the configured face and size to the window's own strings, so
-- changing the font shows up here as well as on the trackers.
function options.Restyle()
    if not panel then return end

    -- The window's own background is configurable now, so a restyle has to
    -- repaint it. Everything else about its chrome is still a design token and
    -- is painted once at build time.
    ns.StylePlateChrome(panel, OptionsChrome())

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
    -- Scale before Place: the placement offsets are converted using the
    -- window's own scale, so applying them first would put it where it belonged
    -- at whatever scale it happened to be carrying.
    panel:SetScale(SavedPlacement().scale or 1)
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

    -- The lock is back to its default, so the corner grips have to follow. This
    -- goes through the same call the lock event does rather than each panel
    -- deciding for itself, which is what stops the two disagreeing.
    if ns.SyncResizeGrips then pcall(ns.SyncResizeGrips) end

    -- This window's own scale went with the store, so it has to come off the
    -- frame too. Resetting to a default the window is not actually drawn at is
    -- the kind of half-reset that makes people reload to check.
    if panel then panel:SetScale(SavedPlacement().scale or 1) end

    -- Both panels, each from its own restored default, rather than one call
    -- that would have to pick one of the two flags to speak for both.
    if ns.SetSkinEnabled then
        ns.SetSkinEnabled("watch", ns.SkinEnabled("watch"))
        ns.SetSkinEnabled("mplus", ns.SkinEnabled("mplus"))
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
        .. "heroPanel's settings open in their own window, centred on screen and moved aside if a "
        .. "tracker is under it. Type |cFFC2C6D8/hp|r at any time, or use the button below.")

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

    -- No OnShow handler here on purpose. Opening the real window from OnShow
    -- looks harmless but traps the player: the interface frame reopens on
    -- whichever category was selected last, so once heroPanel has been visited
    -- every later Esc -> Interface immediately closes Blizzard's frame and
    -- throws up /hp instead, and no other category can be reached again. The
    -- button above is the only way in, which is what "signpost" means.

    _G.InterfaceOptions_AddCategory(category)
    options.category = category
end

ns:On("PLAYER_LOGIN", function()
    local ok, err = pcall(BuildInterfaceCategory)
    if not ok then ns.ReportError("Interface options category", err) end
end)
