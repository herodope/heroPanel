--[[--------------------------------------------------------------------------
    heroPanel - Mplus.lua

    The Mythic+ panel: the same plate as the quest tracker, with heroPanel's
    own header, keystone timer, threshold bar, enemy-forces meter and boss
    rows drawn over Ascension_MythicPlus's tracker.

    The same rules as Skin.lua apply, for the same reasons:

      * everything heroPanel draws is on its own plate, a sibling of the
        tracker sitting one strata below it, so nothing here can take a click
        the tracker wanted;
      * Ascension's own chrome is faded with SetAlpha and its original alpha
        kept, never hidden and never re-anchored, so Disable() gives it back;
      * boss rows are recoloured and refonted where the tracker put them. No
        objective row is moved, resized, reparented, shown or hidden.

    Where the numbers come from
    ---------------------------
    C_MythicPlus is the source. The tracker's own frames are read only as a
    fallback, so the panel still fills in if that API changes under it:

        dungeon name    GetLFGDungeonInfo(GetActiveKeystoneInfo().dungeonID)
                        else the tracker's HeaderText
        keystone level  GetActiveKeystoneInfo().keystoneLevel
                        else the tracker's MainBlock.Level
        timer           GetActiveKeystoneTime() -> timeLeft, totalTime
                        else the tracker's MainBlock.Timer status bar
        enemy forces    GetActiveKeystoneTrash() -> trashDead, trashRequired
                        else the EnemyForces row's own progress/progressMax
        bosses          the tracker's objective rows, which carry the name in
                        .Text and the state in .progress / .progressMax

    Two things the design asks for have no data behind them on this client,
    and are dealt with rather than faked - see CHEST TIERS and BOSS STATES.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local mplus = { enabled = false }
ns.Mplus = mplus

--------------------------------------------------------------------------------
-- Layout constants
--
-- From the design handoff. Font sizes are deltas against the configured base
-- size, so /hp font still moves the whole panel together.
--------------------------------------------------------------------------------

local PANEL_MIN_WIDTH = 300
local PAD_LEFT        = 14
local PAD_RIGHT       = 14
local PAD_BOTTOM      = 11
local HEADER_PAD_X    = 13
local HEADER_HEIGHT   = 30
local HEADER_GAP      = 7     -- lock -> dungeon name
local KEY_GAP         = 3     -- dungeon name -> keystone level, deliberately tighter
local AFFIX_SIZE      = 15
local AFFIX_GAP       = 3

local TIMER_ROW_TOP   = 12    -- margin above the timer row
local TIMER_GLYPH     = 14
local TIMER_ROW_H     = 26
local BAR_HEIGHT      = 5
local BAR_TOP         = 9     -- gap between the timer row and the bar
local TICK_WIDTH      = 3
local TICK_OVERHANG   = 1     -- how far a tick stands proud of the bar

local FORCES_GLYPH    = 12
local FORCES_LABEL_H  = 14
local FORCES_BAR_H    = 4
local FORCES_BAR_TOP  = 5
local FORCES_TOP      = 14    -- gap above the enemy-forces block

local BOSS_GLYPH      = 14
local BOSS_INDENT     = 4     -- glyph's left edge, in from the content edge

-- The extra-bosses list is drawn by heroPanel rather than restyled in place,
-- and windowed. Lower Blackrock Spire offers fifteen minibosses for a
-- requirement of five, and a row per candidate makes a panel taller than the
-- screen is useful. Six is about what fits without the panel dominating.
local SUB_MAX_ROWS    = 6
local SUB_ROW_H       = 15
local SUB_GLYPH       = 11
local SUB_INDENT      = 12    -- the list sits in from the heading above it

local FOOTER_TOP      = 9     -- gap between the last boss row and the rule
local FOOTER_HEIGHT   = 18

local PULSE_PERIOD    = 1.6
local PULSE_MIN       = 0.35
local TICK_INTERVAL   = 0.25  -- how often the clock, bar and tier are redrawn

-- Same reasoning as Skin.lua: frame levels bottom out at zero and only compare
-- inside a strata, so the plate goes a strata below the tracker rather than a
-- couple of levels below it.
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

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local plate                     -- the panel; everything else hangs off it
local ui       = {}             -- heroPanel's own widgets
local faded    = {}             -- region -> original alpha, for Disable()
local original = {}             -- FontString -> font/colour, for Disable()
local rows     = {}             -- pooled boss-row decorations
local affixes  = {}             -- pooled affix icons
local decorated = {}            -- FontString -> { raw, shown }, text we rewrote
local lockMouse = {}            -- button -> original mouse state, for Disable()
local hooked   = false
local queued   = false
-- Forward declaration: the row hooks installed during a draw have to be able
-- to queue the next one, and they are set up well above where it is defined.
local Refresh
local ticker
local pulse    = 0
local lastRead                  -- what the last refresh resolved, for /hp mplus

function mplus.GetPlate() return plate end

--------------------------------------------------------------------------------
-- Reading the run
--------------------------------------------------------------------------------

local function Api()
    local api = _G.C_MythicPlus
    return type(api) == "table" and api or nil
end

local function CallApi(name, ...)
    local api = Api()
    local fn  = api and api[name]
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return a, b
end

-- mm:ss. SecondsToClock exists on this client but drops to h:mm:ss past an
-- hour and returns "" for a negative, and a keystone timer is neither, so the
-- formatting is done here where both cases are decided.
local function Clock(seconds)
    seconds = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function NumbersFromText(text)
    local minutes, secs = string.match(tostring(text or ""), "(%d+):(%d+)")
    if not minutes then return nil end
    return tonumber(minutes) * 60 + tonumber(secs)
end

-- The text as the tracker set it, with any count heroPanel folded into a
-- heading taken back off. Everything downstream - the reader, the reports, the
-- next rewrite - works from the raw string, so a heading cannot end up with
-- two counts on it.
local function RawText(fontString)
    local current = fontString:GetText() or ""
    local record  = decorated[fontString]
    if record and record.shown == current then return record.raw end
    return current
end

-- A boss row as heroPanel needs it. The tracker keeps the name in .Text and
-- the state in .progress / .progressMax, which is the same pair the tracker
-- itself tests to decide whether to draw a check.
local function ReadObjectiveRow(row)
    if not row then return nil end
    if row.IsShown and not row:IsShown() then return nil end

    local label = row.Text
    if not (label and label.GetText) then return nil end

    local text = RawText(label)
    if not text or text == "" then return nil end

    local progress, maximum = row.progress, row.progressMax
    local done = false
    if type(progress) == "number" and type(maximum) == "number" and maximum > 0 then
        done = progress >= maximum
    end

    return { frame = row, label = label, counter = row.Counter, icon = row.Icon,
             text = text, done = done, progress = progress, maximum = maximum }
end

--------------------------------------------------------------------------------
-- Fresh boss state
--
-- The tracker's rows lag by one kill, and it is worth being precise about why,
-- because the two numbers on screen come from different places:
--
--   the heading's count   C_MythicPlus.GetActiveKeystoneEncounters().encountersCompleted
--   each boss's state     GetEncounterInfo(encounterID) -> isDead
--
-- UpdateEncounters reads the second one the instant MYTHIC_PLUS_ENCOUNTER_UPDATE
-- fires, and at that moment the server has not committed isDead for the boss
-- that just died. So the row stays grey until the *next* encounter update
-- refreshes every row - which is exactly the "count is one ahead of the green
-- ticks" the run screenshots show, every time.
--
-- heroPanel reads GetEncounterInfo itself at draw time instead of trusting the
-- row's stored progress. That is still reading the game's own state rather than
-- inventing one; it is just read later, when the answer is right. Rows are
-- matched by name, which is what the tracker labels them with.
--------------------------------------------------------------------------------

-- Ascension appends the kill time to a completed row - "Blind Hunter (19:21)" -
-- so the name has to come back off before it will match.
local function BossName(text)
    return (string.gsub(tostring(text or ""), "%s*%(%d+:%d%d%)%s*$", ""))
end

local function EncounterStates(tracker)
    local states = {}
    if type(_G.GetEncounterInfo) ~= "function" then return states end

    local function Read(encounterID)
        if not encounterID then return end
        local ok, name, _, _, _, _, _, isDead = pcall(_G.GetEncounterInfo, encounterID)
        if ok and name and name ~= "" then states[name] = isDead and true or false end
    end

    local list = tracker.encounters
    if type(list) == "table" then
        for i = 1, #list do Read(list[i]) end
    end
    Read(tracker.finalEncounter)

    return states
end

local function CollectBosses(tracker)
    local block = tracker.ObjectiveBlock
    if not block then return {} end

    local found = {}

    local function Add(row)
        local entry = ReadObjectiveRow(row)
        if entry then table.insert(found, entry) end
        return entry
    end

    -- The required boss is the run's headline, and is sized like one.
    local primary = Add(block.FinalEncounter)
    if primary then primary.primary = true end

    -- The extra-bosses row is expandable and keeps its children in .buttons.
    -- They are only on screen while it is expanded, and ReadObjectiveRow drops
    -- the hidden ones.
    --
    -- While it is expanded the row itself is a heading over those children -
    -- "Defeat additional bosses 1/2" - and not a boss. Styling it as one gave
    -- it a pending ring and a status word of its own, so the panel showed four
    -- indicators for three bosses. Expanded, it is marked as a group and gets
    -- the label treatment without an indicator; collapsed, its children are not
    -- drawn and it stands in for them, so it is a row like any other.
    local expandable = block.Encounters
    local subRows    = {}
    if expandable and type(expandable.buttons) == "table" then
        for i = 1, #expandable.buttons do
            local entry = ReadObjectiveRow(expandable.buttons[i])
            if entry then table.insert(subRows, entry) end
        end
    end

    local heading = ReadObjectiveRow(expandable)
    if heading then
        heading.group = #subRows > 0
        table.insert(found, heading)
    end
    for i = 1, #subRows do
        subRows[i].sub = true
        table.insert(found, subRows[i])
    end

    Add(block.Champions)

    -- Top down, which is the order they are read in.
    table.sort(found, function(a, b)
        return (a.frame:GetTop() or 0) > (b.frame:GetTop() or 0)
    end)

    -- Whatever the encounter API says now wins over what the row was told
    -- when the event fired. A name the API does not know - the extra-bosses
    -- heading, which is a label rather than an encounter - keeps the row's own
    -- state, so nothing here can invent a boss.
    local states = EncounterStates(tracker)
    for i = 1, #found do
        local fresh = states[BossName(found[i].text)]
        if fresh ~= nil then found[i].done = fresh end
    end

    return found
end

-- Everything the panel draws, resolved once per refresh.
function mplus.Read()
    local tracker = ns.GetTrackerFrame("mplus")
    if not tracker then return nil end

    local data = { tracker = tracker }

    local active = CallApi("IsKeystoneActive")
    data.active  = active and true or false

    local info = CallApi("GetActiveKeystoneInfo")
    if type(info) == "table" then
        data.level = tonumber(info.keystoneLevel)
        data.affixes = type(info.activeAffixes) == "table" and info.activeAffixes or nil
        if info.dungeonID and type(_G.GetLFGDungeonInfo) == "function" then
            local ok, name = pcall(_G.GetLFGDungeonInfo, info.dungeonID)
            if ok and name and name ~= "" then data.dungeon = name end
        end
    end

    local timeLeft, totalTime = CallApi("GetActiveKeystoneTime")
    data.timeLeft  = tonumber(timeLeft)
    data.totalTime = tonumber(totalTime)

    local trash = CallApi("GetActiveKeystoneTrash")
    if type(trash) == "table" then
        data.trashDead     = tonumber(trash.trashDead)
        data.trashRequired = tonumber(trash.trashRequired)
    end

    ------------------------------------------------------------------
    -- Fallbacks, read off the tracker's own widgets.
    --
    -- Not decoration: the panel is drawn over a frame that is plainly
    -- showing these numbers, so taking them from it is always better than
    -- drawing a blank where a name or a clock should be.
    ------------------------------------------------------------------

    if not data.dungeon and tracker.HeaderText and tracker.HeaderText.GetText then
        local name = tracker.HeaderText:GetText()
        if name and name ~= "" then data.dungeon = name end
    end

    local main = tracker.MainBlock
    if main then
        if not data.level and main.Level and main.Level.GetText then
            data.level = tonumber(string.match(main.Level:GetText() or "", "(%d+)"))
        end
        if not data.timeLeft and main.TimeLeft and main.TimeLeft.GetText then
            data.timeLeft = NumbersFromText(main.TimeLeft:GetText())
        end
        if not data.totalTime and main.Timer and main.Timer.GetMinMaxValues then
            local ok, _, maximum = pcall(main.Timer.GetMinMaxValues, main.Timer)
            if ok then data.totalTime = tonumber(maximum) end
        end
        if not data.timeLeft and main.Timer and main.Timer.GetValue then
            local ok, value = pcall(main.Timer.GetValue, main.Timer)
            if ok then data.timeLeft = tonumber(value) end
        end
    end

    data.bosses = CollectBosses(tracker)

    if not data.trashRequired then
        local forces = tracker.ObjectiveBlock and tracker.ObjectiveBlock.EnemyForces
        if forces then
            data.trashDead     = tonumber(forces.progress)
            data.trashRequired = tonumber(forces.progressMax)
        end
    end

    -- A keystone that reports no time at all is not running, whatever
    -- IsKeystoneActive said - the panel has nothing to draw a clock from.
    if not data.active and data.timeLeft and data.totalTime then data.active = true end

    lastRead = data
    return data
end

--------------------------------------------------------------------------------
-- CHEST TIERS
--
-- MYTHIC_PLUS_BONUS_LEVEL_PERCENT is the fraction of the timer that has to be
-- *left* to earn each upgrade: { 0.55, 0.4 } on this client, so +3 needs 55%
-- of the run still on the clock at the end and +2 needs 40%.
--
-- Computed here rather than read off the tracker's own TimeLeft2 / TimeLeft3
-- strings, which are wrong: Ascension works them out from (1 - PERCENT[n]),
-- so at a 30 minute key its "+3" field counts down to 18:00 remaining instead
-- of 16:30, and the two fields are swapped against the notches they are
-- coloured to match. The thresholds themselves are read from the client's own
-- constant, so if Ascension retunes them the panel follows.
--------------------------------------------------------------------------------

local FALLBACK_THRESHOLDS = { 0.55, 0.4 }

local function Thresholds()
    local percents = _G.MYTHIC_PLUS_BONUS_LEVEL_PERCENT
    if type(percents) ~= "table" then return FALLBACK_THRESHOLDS end
    local three = tonumber(percents[1]) or FALLBACK_THRESHOLDS[1]
    local two   = tonumber(percents[2]) or FALLBACK_THRESHOLDS[2]
    return { three, two }
end

-- The best tier still reachable, and how long is left to reach it.
-- Returns nil once +2 has gone as well: the design does not show +1.
function mplus.ChestTier(timeLeft, totalTime)
    timeLeft, totalTime = tonumber(timeLeft), tonumber(totalTime)
    if not (timeLeft and totalTime) or totalTime <= 0 then return nil end

    local percents = Thresholds()
    for index, tier in ipairs({ 3, 2 }) do
        local window = timeLeft - (percents[index] * totalTime)
        if window > 0 then return tier, window end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Ascension's chrome
--
-- Faded, not hidden, and every original alpha kept. Named rather than found by
-- geometry: unlike WatchFrame, this tracker is built from an XML template
-- heroPanel can read, so the widgets are known and there is nothing to guess.
-- Anything the template does not have is simply absent and skipped.
--------------------------------------------------------------------------------

local function FadeRegion(region)
    if not region or type(region.SetAlpha) ~= "function" then return end
    if faded[region] == nil then
        local ok, alpha = pcall(region.GetAlpha, region)
        faded[region] = (ok and alpha) or 1
    end
    pcall(region.SetAlpha, region, 0)
end

local function FadeRegionsOf(frame)
    if not (frame and frame.GetRegions) then return end
    local ok, regions = pcall(function() return { frame:GetRegions() } end)
    if not ok then return end
    for i = 1, #regions do FadeRegion(regions[i]) end
end

-- A button's own textures, plus everything drawn anywhere beneath it.
--
-- Fading the four button textures and the frame's own regions was not enough.
-- The affix buttons are a template with their icon on a child frame, so the
-- icon survived every pass and sat in the panel's top-right corner - which the
-- design explicitly has nothing in - looking like a second control. Anything
-- being replaced wholesale gets cleared wholesale.
local function FadeSubtree(frame)
    if not frame then return end
    FadeRegionsOf(frame)

    local getters = { "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }
    local function ButtonTextures(button)
        for i = 1, #getters do
            local getter = button[getters[i]]
            if type(getter) == "function" then
                local ok, texture = pcall(getter, button)
                if ok and texture then FadeRegion(texture) end
            end
        end
    end
    ButtonTextures(frame)

    ns.WalkFrameTree(frame, function(object, info)
        if info.kind == "region" then
            FadeRegion(object)
        elseif info.objectType == "Button" then
            ButtonTextures(object)
        end
    end, { maxDepth = 4, includeRegions = true })
end
local FadeButton = FadeSubtree

local function FadeTrackerChrome(tracker)
    -- The tracker's own header: heroPanel draws one in its place.
    FadeRegion(tracker.Header)
    FadeRegion(tracker.HeaderText)
    FadeButton(tracker.CollapseExpandButton)

    -- Ascension's own lock button, top right.
    --
    -- Not in the tracker XML this was written against - the live build has a
    -- $parentLockButton the extracted one does not - so it is resolved by
    -- parent key and by global name, and simply absent on a client without it.
    -- heroPanel has its own lock in the header's top-left corner and two locks
    -- on one panel is one too many, so this one is faded and stops taking the
    -- mouse. Its old mouse state is kept, like every other change here, so
    -- Disable() gives Ascension's button back.
    local lockButton = tracker.LockButton or _G.MythicPlusObjectiveTrackerLockButton
    if lockButton then
        FadeSubtree(lockButton)
        if lockButton.EnableMouse and lockMouse[lockButton] == nil then
            lockMouse[lockButton] = (lockButton.IsMouseEnabled and lockButton:IsMouseEnabled()) or false
        end
        pcall(lockButton.EnableMouse, lockButton, false)
    end

    -- The whole main block - background, timer art, level, clocks, loot text
    -- and affix buttons. Every one of these is redrawn by the panel, so the
    -- block is cleared as a subtree rather than widget by widget.
    local main = tracker.MainBlock
    if main then
        FadeSubtree(main)
        if main.Timer and type(main.Timer.GetStatusBarTexture) == "function" then
            -- A status bar's fill is a texture the frame owns rather than one
            -- of its regions, so it needs asking for by name.
            local ok, fill = pcall(main.Timer.GetStatusBarTexture, main.Timer)
            if ok then FadeRegion(fill) end
        end
    end

    -- The enemy-forces row is redrawn too, so its art goes; the boss rows keep
    -- their text and lose only the icon heroPanel replaces.
    local block = tracker.ObjectiveBlock
    if block then
        if block.EnemyForces then FadeSubtree(block.EnemyForces) end

        -- The expandable row's own expand control is Ascension's art and does
        -- not belong on this panel; heroPanel draws the same chevron the quest
        -- header uses over the top of it. The button itself is left alone and
        -- keeps taking its own clicks, exactly as the quest tracker's collapse
        -- button does.
        local expandable = block.Encounters
        if expandable and expandable.CollapseExpandButton then
            FadeSubtree(expandable.CollapseExpandButton)
        end
    end
end

local function RestoreChrome()
    for region, alpha in pairs(faded) do
        pcall(region.SetAlpha, region, alpha)
    end
    wipe(faded)

    for button, enabled in pairs(lockMouse) do
        pcall(button.EnableMouse, button, enabled)
    end
    wipe(lockMouse)

    -- Any heading whose count heroPanel folded into the sentence, but only
    -- where the string on screen is still the one we wrote.
    for fontString, record in pairs(decorated) do
        if fontString:GetText() == record.shown then fontString:SetText(record.raw) end
    end
    wipe(decorated)

    for fontString, saved in pairs(original) do
        if saved.path and saved.size then
            pcall(fontString.SetFont, fontString, saved.path, saved.size, saved.flags)
        end
        if saved.r then
            pcall(fontString.SetTextColor, fontString, saved.r, saved.g, saved.b, saved.a or 1)
        end
        if saved.alpha ~= nil then pcall(fontString.SetAlpha, fontString, saved.alpha) end
    end
    wipe(original)
end

-- Remembered once. A pooled row that is reused keeps the font heroPanel gave
-- it, so re-reading after styling would record our own values as Ascension's.
local function Remember(fontString)
    if not fontString or original[fontString] then return end
    local path, size, flags = fontString:GetFont()
    local r, g, b, a = fontString:GetTextColor()
    original[fontString] = { path = path, size = size, flags = flags,
                             r = r, g = g, b = b, a = a,
                             alpha = fontString:GetAlpha() }
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function NewFontString(parent, layer)
    local fontString = parent:CreateFontString(nil, layer or "OVERLAY")
    fontString:SetFont(ns.GetFontFile(), ns.GetFontSize(0, "mplus"))
    return fontString
end

local function BuildPlate(tracker)
    plate = CreateFrame("Frame", "HeroPanelMplusPlate", tracker:GetParent() or UIParent)
    plate:Hide()
    plate:SetWidth(PANEL_MIN_WIDTH)
    plate:SetHeight(HEADER_HEIGHT)

    ns.BuildPlateChrome(plate)

    -- Glyphs and text go above the plate's own fill but stay below the
    -- tracker, exactly as the quest panel does it.
    plate.overlay = CreateFrame("Frame", nil, plate)
    plate.overlay:SetAllPoints(plate)

    local overlay = plate.overlay

    ------------------------------------------------------------------
    -- Header row
    ------------------------------------------------------------------

    ui.lock = CreateFrame("Button", nil, plate)
    ui.lock:SetWidth(BOSS_GLYPH + 4)
    ui.lock:SetHeight(BOSS_GLYPH + 4)
    ui.lockIcon = ns.NewGlyph(ui.lock, 13)
    ui.lockIcon:SetPoint("CENTER")

    ui.dungeon  = NewFontString(overlay)
    ui.keystone = NewFontString(overlay)

    ------------------------------------------------------------------
    -- Timer row
    ------------------------------------------------------------------

    ui.timerGlyph = ns.NewGlyph(overlay, TIMER_GLYPH)
    ui.timerGlyph:SetShape("timer")

    ui.time      = NewFontString(overlay)
    ui.total     = NewFontString(overlay)
    ui.tier      = NewFontString(overlay)
    ui.tierTime  = NewFontString(overlay)

    ui.bar = ns.NewGradientBar(plate, "BORDER")
    ui.bar:SetStops(ns.PALETTE.accentDeep, ns.PALETTE.accent, ns.PALETTE.accentLight)

    -- Threshold ticks. Each is a white pixel run over a slightly larger dark
    -- one, which is the cheapest honest read of the design's 1px outline.
    ui.ticks = {}
    for i = 1, 2 do
        ui.ticks[i] = {
            outline = ns.NewPlateTexture(plate, "ARTWORK"),
            mark    = ns.NewPlateTexture(plate, "OVERLAY"),
        }
    end

    ------------------------------------------------------------------
    -- Enemy forces
    ------------------------------------------------------------------

    ui.forcesGlyph = ns.NewGlyph(overlay, FORCES_GLYPH)
    ui.forcesGlyph:SetShape("crosshair")

    ui.forcesLabel   = NewFontString(overlay)
    ui.forcesLabel:SetText("Enemy Forces")
    ui.forcesPercent = NewFontString(overlay)

    ui.forcesBar = ns.NewGradientBar(plate, "BORDER")
    ui.forcesBar:SetStops(ns.PALETTE.accentDeep, nil, ns.PALETTE.accent)

    ------------------------------------------------------------------
    -- Footer
    ------------------------------------------------------------------

    ui.rule = ns.NewPlateTexture(plate, "BORDER")
    ui.mark = NewFontString(overlay)
    ui.mark:SetText("heroPanel")

    -- The chevron over the expandable row's own expand control, so the panel
    -- has one collapse affordance rather than two different ones.
    ui.expandCaret = ns.NewGlyph(overlay, 12)
    ui.expandCaret:Hide()

    -- Catches the wheel over the extra-bosses list. EnableMouseWheel without
    -- EnableMouse: it takes a scroll and lets clicks and drags fall through to
    -- the tracker, which is mouse-enabled for dragging.
    ui.wheel = CreateFrame("Frame", nil, plate)
    ui.wheel:EnableMouseWheel(true)
    ui.wheel:Hide()

    return plate
end

--------------------------------------------------------------------------------
-- Affixes
--
-- The keystone's affixes are spell IDs: GetActiveKeystoneInfo().activeAffixes
-- carries them, GetSpellInfo turns one into a name and an icon, and this
-- client ships a GameTooltip:SetAffix extension that builds the full tooltip
-- from the same ID. So the icons are heroPanel's own buttons rather than
-- Ascension's, which lets them take the design's size and spacing while still
-- showing the game's own tooltip on hover.
--------------------------------------------------------------------------------

local function GetAffixButton(index)
    local button = affixes[index]
    if button then return button end

    button = CreateFrame("Button", nil, plate)
    button:SetWidth(AFFIX_SIZE)
    button:SetHeight(AFFIX_SIZE)
    button:EnableMouse(true)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints(button)
    -- Icons are square art with a border baked in; cropping the edge off is
    -- what makes them sit on the panel instead of on top of it.
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button:SetScript("OnEnter", function(self)
        if not self.affixID then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")

        -- The client's own affix tooltip when it has one, so the wording
        -- matches everywhere else the affix is shown; name and description
        -- assembled by hand when it does not.
        local ok = pcall(function() GameTooltip:SetAffix(self.affixID) end)
        if not ok then
            local name = GetSpellInfo(self.affixID)
            GameTooltip:SetText(name or ("Affix " .. tostring(self.affixID)), 1, 1, 1)
            if GetSpellDescription then
                local description = GetSpellDescription(self.affixID)
                if description then GameTooltip:AddLine(description, 1, 0.82, 0, true) end
            end
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    affixes[index] = button
    return button
end

-- Right to left from the header's right edge, so the first affix is always
-- outermost however many there are.
local function LayoutAffixes(list)
    local shown = 0

    for i = 1, #(list or {}) do
        local affixID = tonumber(list[i])
        local icon
        if affixID and type(_G.GetSpellInfo) == "function" then
            local ok, _, _, texture = pcall(_G.GetSpellInfo, affixID)
            if ok then icon = texture end
        end
        if affixID and icon then
            shown = shown + 1
            local button = GetAffixButton(shown)
            button.affixID = affixID
            button.icon:SetTexture(icon)

            button:ClearAllPoints()
            button:SetPoint("RIGHT", plate, "TOPRIGHT",
                -HEADER_PAD_X - (shown - 1) * (AFFIX_SIZE + AFFIX_GAP),
                -HEADER_HEIGHT / 2)
            button:Show()
        end
    end

    for i = shown + 1, #affixes do
        affixes[i].affixID = nil
        affixes[i]:Hide()
    end

    return shown
end

--------------------------------------------------------------------------------
-- Keeping the styling on
--
-- Ascension restyles an objective row whenever it changes: ScenarioObjectiveMixin
-- calls SetFontObject on the row's text and counter every time SetProgress runs,
-- which throws away the font and colour heroPanel gave it. The panel only
-- redraws on an event, so once a row was restyled out from under it - which is
-- what killing a boss does - it stayed that way for the rest of the run. That
-- is the "the heading text disappeared and never came back" bug: the text was
-- still there, wearing Ascension's disabled font on a dark panel.
--
-- So every row heroPanel styles is hooked, once, and any change Ascension makes
-- to it queues a refresh. hooksecurefunc rather than a wrapper, because these
-- are the game's own frames; the coalescing in Refresh means a burst of row
-- updates still costs one pass.
--------------------------------------------------------------------------------

local hookedRows = {}

local function HookRow(row)
    if not row or hookedRows[row] then return end
    hookedRows[row] = true

    for _, method in ipairs({ "SetObjective", "SetProgress", "SetLabel",
                              "UpdateSubObjectives", "Expand", "Collapse" }) do
        if type(row[method]) == "function" then
            pcall(hooksecurefunc, row, method, function()
                if mplus.enabled then Refresh("row " .. method) end
            end)
        end
    end
end

-- One boss row's decorations: the state indicator and the right-aligned
-- status word. Pooled, because the tracker pools the rows they sit on.
local function GetRow(index)
    local row = rows[index]
    if row then return row end

    local overlay = plate and plate.overlay
    if not overlay then return nil end

    row = {
        check   = ns.NewGlyph(overlay, BOSS_GLYPH),
        ring    = ns.NewGlyph(overlay, BOSS_GLYPH),
        ringDot = ns.NewGlyph(overlay, BOSS_GLYPH),
    }
    row.check:SetShape("check")
    row.ring:SetShape("ring")
    row.ringDot:SetShape("ringDot")

    rows[index] = row
    return row
end

local function HideRowsFrom(first)
    for i = first, #rows do
        local row = rows[i]
        if row then
            row.check:Hide()
            row.ring:Hide()
            row.ringDot:Hide()
        end
    end
end

--------------------------------------------------------------------------------
-- Painting
--------------------------------------------------------------------------------

local function StyleStatic()
    if not plate then return end

    ns.StylePlateChrome(plate)

    local font = ns.GetFontFile()

    local ir, ig, ib = ns.HexToRGB(ns.PALETTE.icon)
    ui.lockIcon:SetColor(ir, ig, ib, 1)

    local br, bg, bb = ns.HexToRGB(ns.PALETTE.bright)
    ui.dungeon:SetFont(font, ns.GetFontSize(1, "mplus"))
    ui.dungeon:SetTextColor(br, bg, bb, 1)

    local kr, kg, kb = ns.HexToRGB(ns.PALETTE.accentLight)
    ui.keystone:SetFont(font, ns.GetFontSize(0, "mplus"))
    ui.keystone:SetTextColor(kr, kg, kb, 1)

    local mr, mg, mb = ns.HexToRGB(ns.PALETTE.muted)
    ui.timerGlyph:SetColor(mr, mg, mb, 1)
    ui.forcesGlyph:SetColor(mr, mg, mb, 1)

    ui.time:SetFont(font, ns.GetFontSize(12, "mplus"))
    ui.time:SetTextColor(br, bg, bb, 1)

    local dr, dg, db = ns.HexToRGB(ns.PALETTE.icon)
    ui.total:SetFont(font, ns.GetFontSize(-1, "mplus"))
    ui.total:SetTextColor(dr, dg, db, 1)

    local cr, cg, cb = ns.HexToRGB(ns.PALETTE.chest)
    ui.tier:SetFont(font, ns.GetFontSize(-1, "mplus"))
    ui.tier:SetTextColor(cr, cg, cb, 1)

    local tr, tg, tb = ns.HexToRGB(ns.PALETTE.chestTime)
    ui.tierTime:SetFont(font, ns.GetFontSize(-1, "mplus"))
    ui.tierTime:SetTextColor(tr, tg, tb, 1)

    local hr, hg, hb = ns.HexToRGB(ns.PALETTE.hairline)
    ui.bar.track:SetVertexColor(hr, hg, hb, 0.08)
    ui.forcesBar.track:SetVertexColor(hr, hg, hb, 0.08)

    local wr, wg, wb = ns.HexToRGB(ns.PALETTE.bright)
    for i = 1, #ui.ticks do
        ui.ticks[i].mark:SetVertexColor(wr, wg, wb, 1)
        ui.ticks[i].outline:SetVertexColor(0, 0, 0, 0.85)
    end

    local fr, fg, fb = ns.HexToRGB(ns.PALETTE.forces)
    ui.forcesLabel:SetFont(font, ns.GetFontSize(-1, "mplus"))
    ui.forcesLabel:SetTextColor(fr, fg, fb, 1)

    ui.forcesPercent:SetFont(font, ns.GetFontSize(-1, "mplus"))
    ui.forcesPercent:SetTextColor(br, bg, bb, 1)

    -- The footer rule is an edge, so it follows the border's colour, alpha and
    -- style rather than a hairline token of its own - a border turned off must
    -- not leave a line ruled across the panel.
    local rr, rg, rb, ra = ns.BorderPaint(0.5)
    ui.rule:SetVertexColor(rr, rg, rb, ra)

    local ar, ag, ab = ns.HexToRGB(ns.PALETTE.accentDeep)
    ui.mark:SetFont(font, ns.GetFontSize(-3.5, "mplus"))
    ui.mark:SetTextColor(ar, ag, ab, 1)
end
mplus.Restyle = StyleStatic

--------------------------------------------------------------------------------
-- Layout
--
-- heroPanel's own rows are laid out from the plate's top edge; the boss rows
-- stay wherever the tracker drew them. The enemy-forces block is the hinge
-- between the two: it is anchored *up* from the first boss row when there is
-- one, so the design's spacing survives a tracker whose main block is a
-- different height from heroPanel's.
--------------------------------------------------------------------------------

local function LayoutPlate(tracker, contentBottom)
    local parent = tracker:GetParent() or UIParent
    if plate:GetParent() ~= parent then plate:SetParent(parent) end
    plate:SetScale(tracker:GetScale() or 1)

    local strata = tracker:GetFrameStrata() or "LOW"
    local level  = tracker:GetFrameLevel() or 1
    plate:SetFrameStrata(STRATA_BELOW[strata] or "BACKGROUND")
    plate:SetFrameLevel(1)
    plate.overlay:SetFrameLevel(3)

    -- The lock and the affix icons are the only things above the tracker: they
    -- have to take their own mouse even while the tracker is mouse-enabled for
    -- dragging, one for its clicks and the others for their tooltips.
    ui.lock:SetFrameStrata(strata)
    ui.lock:SetFrameLevel(level + 1)
    -- Above the tracker too, or the wheel never reaches it.
    ui.wheel:SetFrameStrata(strata)
    ui.wheel:SetFrameLevel(level + 1)
    for i = 1, #affixes do
        affixes[i]:SetFrameStrata(strata)
        affixes[i]:SetFrameLevel(level + 1)
    end

    local width = tracker:GetWidth() or 0
    width = width > 60 and (width + PAD_LEFT + PAD_RIGHT) or PANEL_MIN_WIDTH

    local top    = tracker:GetTop()
    local height = HEADER_HEIGHT + TIMER_ROW_TOP + TIMER_ROW_H + BAR_TOP + BAR_HEIGHT
                 + FORCES_TOP + FORCES_LABEL_H + FORCES_BAR_TOP + FORCES_BAR_H

    if contentBottom and top then
        height = (top - contentBottom) + FOOTER_TOP + FOOTER_HEIGHT + PAD_BOTTOM
    end

    plate:ClearAllPoints()
    plate:SetPoint("TOPLEFT", tracker, "TOPLEFT", -PAD_LEFT, 0)
    plate:SetWidth(width)
    plate:SetHeight(math.max(HEADER_HEIGHT, height))

    return width
end

local function LayoutHeader()
    ui.lockIcon:SetShape(ns.IsLocked() and "locked" or "unlocked")

    ui.lock:ClearAllPoints()
    ui.lock:SetPoint("LEFT", plate, "TOPLEFT", HEADER_PAD_X, -HEADER_HEIGHT / 2)

    ui.dungeon:ClearAllPoints()
    ui.dungeon:SetPoint("LEFT", ui.lock, "RIGHT", HEADER_GAP, 0)

    ui.keystone:ClearAllPoints()
    ui.keystone:SetPoint("LEFT", ui.dungeon, "RIGHT", KEY_GAP, -1)
end

-- The timer row, the bar and its ticks. Split out because it is the only part
-- of the panel that is redrawn on the clock ticker rather than on a refresh.
local function LayoutTimer(data, width)
    local rowTop = -(HEADER_HEIGHT + TIMER_ROW_TOP)

    ui.timerGlyph:ClearAllPoints()
    ui.timerGlyph:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", HEADER_PAD_X, rowTop - TIMER_ROW_H + 3)

    ui.time:ClearAllPoints()
    ui.time:SetPoint("BOTTOMLEFT", ui.timerGlyph, "BOTTOMRIGHT", 6, -2)

    ui.total:ClearAllPoints()
    ui.total:SetPoint("BOTTOMLEFT", ui.time, "BOTTOMRIGHT", 6, 3)

    ui.time:SetText(Clock(data.timeLeft))
    ui.total:SetText("/ " .. Clock(data.totalTime))

    ------------------------------------------------------------------
    -- Highest eligible chest tier
    ------------------------------------------------------------------

    local tier, window = mplus.ChestTier(data.timeLeft, data.totalTime)
    if tier then
        ui.tierTime:ClearAllPoints()
        ui.tierTime:SetPoint("RIGHT", plate, "TOPRIGHT", -HEADER_PAD_X, rowTop - TIMER_ROW_H + 8)
        ui.tierTime:SetText("(" .. Clock(window) .. ")")
        ui.tierTime:Show()

        ui.tier:ClearAllPoints()
        ui.tier:SetPoint("RIGHT", ui.tierTime, "LEFT", -3, 0)
        ui.tier:SetText("+" .. tier)
        ui.tier:Show()
    else
        ui.tier:Hide()
        ui.tierTime:Hide()
    end

    ------------------------------------------------------------------
    -- Timer bar
    ------------------------------------------------------------------

    local barWidth = width - HEADER_PAD_X * 2
    local barTop   = rowTop - TIMER_ROW_H - BAR_TOP

    ui.bar.track:ClearAllPoints()
    ui.bar.track:SetPoint("TOPLEFT", plate, "TOPLEFT", HEADER_PAD_X, barTop)
    ui.bar.track:SetWidth(barWidth)
    ui.bar.track:SetHeight(BAR_HEIGHT)
    ui.bar.track:Show()

    -- The bar carries time *remaining*, which is what the tracker's own status
    -- bar carries, so it drains left as the run goes on and the thresholds are
    -- fixed marks the fill edge passes.
    local fraction = 0
    if data.timeLeft and data.totalTime and data.totalTime > 0 then
        fraction = data.timeLeft / data.totalTime
    end
    ui.bar:Layout(barWidth, BAR_HEIGHT, fraction)

    local percents = Thresholds()
    for i = 1, #ui.ticks do
        local tick = ui.ticks[i]
        local x    = HEADER_PAD_X + barWidth * ns.Clamp(percents[i], 0, 1)

        tick.outline:ClearAllPoints()
        tick.outline:SetPoint("TOPLEFT", plate, "TOPLEFT", x - 1, barTop + TICK_OVERHANG + 1)
        tick.outline:SetWidth(TICK_WIDTH + 2)
        tick.outline:SetHeight(BAR_HEIGHT + (TICK_OVERHANG + 1) * 2)
        tick.outline:Show()

        tick.mark:ClearAllPoints()
        tick.mark:SetPoint("TOPLEFT", plate, "TOPLEFT", x, barTop + TICK_OVERHANG)
        tick.mark:SetWidth(TICK_WIDTH)
        tick.mark:SetHeight(BAR_HEIGHT + TICK_OVERHANG * 2)
        tick.mark:Show()
    end

    return barTop - BAR_HEIGHT
end

local function LayoutForces(data, width, barBottom, firstBossTop)
    local plateTop = plate:GetTop()

    -- Above the first boss row when there is one, so the two always sit the
    -- design's distance apart; otherwise straight under the timer bar.
    local labelTop = barBottom - FORCES_TOP
    if firstBossTop and plateTop then
        local wanted = (firstBossTop - plateTop) + FORCES_TOP + FORCES_BAR_H + FORCES_BAR_TOP + FORCES_LABEL_H
        if wanted < labelTop then labelTop = wanted end
    end

    ui.forcesGlyph:ClearAllPoints()
    ui.forcesGlyph:SetPoint("TOPLEFT", plate, "TOPLEFT", HEADER_PAD_X, labelTop)

    ui.forcesLabel:ClearAllPoints()
    ui.forcesLabel:SetPoint("LEFT", ui.forcesGlyph, "RIGHT", 6, 0)

    ui.forcesPercent:ClearAllPoints()
    ui.forcesPercent:SetPoint("RIGHT", plate, "TOPRIGHT", -HEADER_PAD_X, labelTop - FORCES_GLYPH / 2)

    -- The percentage is deliberately NOT clamped to 100, and this is a feature
    -- rather than an oversight - please leave it alone.
    --
    -- C_MythicPlus.GetActiveKeystoneTrash reports the raw counts, so a group
    -- that pulled more than the key needed reads 114% or 160%. Ascension's own
    -- objective row clamps that away with MClamp and shows a flat 100%, which
    -- throws away the one number that says how much trash was overpulled -
    -- worth knowing during a run and worth knowing after one.
    --
    -- The bar underneath does clamp, because a fill cannot run past the end of
    -- its track. The two disagreeing above 100% is intended: the bar says
    -- "done", the number says "and this much again".
    local fraction = 0
    if data.trashDead and data.trashRequired and data.trashRequired > 0 then
        fraction = data.trashDead / data.trashRequired
    end
    ui.forcesPercent:SetText(string.format("%d%%", math.floor(fraction * 100 + 0.5)))

    local barWidth = width - HEADER_PAD_X * 2
    local barTop   = labelTop - FORCES_LABEL_H - FORCES_BAR_TOP

    ui.forcesBar.track:ClearAllPoints()
    ui.forcesBar.track:SetPoint("TOPLEFT", plate, "TOPLEFT", HEADER_PAD_X, barTop)
    ui.forcesBar.track:SetWidth(barWidth)
    ui.forcesBar.track:SetHeight(FORCES_BAR_H)
    ui.forcesBar.track:Show()

    ui.forcesBar:Layout(barWidth, FORCES_BAR_H, fraction)

    for _, widget in ipairs({ ui.forcesGlyph, ui.forcesLabel, ui.forcesPercent }) do
        widget:Show()
    end
end

--------------------------------------------------------------------------------
-- BOSS STATES
--
-- Recolour and refont only. Nothing here moves, resizes, reparents, shows or
-- hides an objective row: the indicator and the status word are heroPanel's
-- own regions, placed against the row's text the same way the quest panel
-- places its check marks.
--
-- Two of the design's three states have data behind them - the tracker keeps
-- .progress and .progressMax on every row, which is the same pair it tests to
-- decide whether to draw its own check. The third, "in combat", does not:
-- there is no per-boss engaged flag anywhere in Ascension's Mythic+ data, and
-- this client has neither ENCOUNTER_START nor IsEncounterInProgress. Deciding
-- it from "the player is fighting and this is the first boss still up" would
-- be heroPanel inventing state and getting it wrong on every pull that is not
-- the next boss in the list, so the state is drawn when something sets it and
-- is not guessed at.
--------------------------------------------------------------------------------

-- The text a heading shows, with the count folded into it.
--
-- The tracker draws "Defeat Additional Bosses" with a right-aligned "1/6"
-- against the panel's far edge, which reads as an unrelated number. The design
-- wants it in the sentence, and only once there is something to count.
--
-- Rewriting a tracker string is the one thing in here that changes what the
-- game drew, so it follows Lines.lua's rule for the same move: the original is
-- kept, and the rewrite is only recognised as ours if the string on screen is
-- still the one we wrote.
local function SetHeadingText(fontString, raw, progress, maximum)
    local shown = raw
    if progress and maximum and maximum > 0 and progress > 0 then
        shown = string.format("%s (%d/%d)", raw, progress, maximum)
    end

    if shown == raw then
        decorated[fontString] = nil
    else
        decorated[fontString] = { raw = raw, shown = shown }
    end
    fontString:SetText(shown)
end

local function StyleBossRow(index, boss)
    local row = GetRow(index)
    if not row then return end

    local font = ns.GetFontFile()

    Remember(boss.label)
    Remember(boss.counter)

    -- Three sizes, which is what makes the block read as a hierarchy rather
    -- than a list: the required boss is the title, the extra-bosses heading
    -- sits a step under it, and the bosses under that are body text.
    local size = ns.GetFontSize(-0.5, "mplus")
    if boss.primary then
        size = ns.GetFontSize(1.5, "mplus")
    elseif boss.group then
        size = ns.GetFontSize(0.5, "mplus")
    end
    pcall(boss.label.SetFont, boss.label, font, size)

    -- The tracker's own icon is replaced by heroPanel's indicator, and its
    -- right-aligned counter either moves into the heading's text or is said
    -- by the check mark instead.
    if boss.icon then FadeRegion(boss.icon) end
    if boss.counter then FadeRegion(boss.counter) end

    row.check:Hide()
    row.ring:Hide()
    row.ringDot:Hide()
    row.pulsing = false

    if boss.group then
        SetHeadingText(boss.label, boss.text, boss.progress, boss.maximum)

        -- Green once the requirement is met, whether the row is expanded or
        -- collapsed. Collapsed it is a completed objective like any other and
        -- was already green; expanded it stayed muted, so the same run read as
        -- finished or unfinished depending on which way the chevron pointed.
        local r, g, b
        if boss.done then
            r, g, b = ns.HexToRGB(ns.db.text.done)
        else
            r, g, b = ns.HexToRGB(ns.PALETTE.muted)
        end
        boss.label:SetTextColor(r, g, b, 1)
        return
    end

    local indicator = row.ring

    if boss.done then
        local dr, dg, db = ns.HexToRGB(ns.db.text.done)
        boss.label:SetTextColor(dr, dg, db, 1)

        -- A check mark on its own. It was a tick knocked out of a filled disc,
        -- which at 14 pixels read as a green blob with a notch in it; the
        -- check alone is legible and says the same thing, so the "slain" text
        -- beside it is gone too.
        row.check:SetColor(dr, dg, db, 1)
        row.check:Show()
        indicator = row.check

    elseif boss.active then
        local cr, cg, cb = ns.HexToRGB(ns.PALETTE.count)
        boss.label:SetTextColor(cr, cg, cb, 1)

        local ar, ag, ab = ns.HexToRGB(ns.PALETTE.accent)
        row.ringDot:SetColor(ar, ag, ab, 1)
        row.ringDot:Show()
        row.pulsing = true
        indicator = row.ringDot

    else
        local mr, mg, mb = ns.HexToRGB(ns.PALETTE.muted)
        boss.label:SetTextColor(mr, mg, mb, 1)

        local hr, hg, hb = ns.HexToRGB(ns.PALETTE.hairline)
        row.ring:SetColor(hr, hg, hb, 0.18)
        row.ring:Show()
        indicator = row.ring
    end

    -- Placed against the row's own text, never against the row's frame: the
    -- text is what the eye lines the indicator up with, and reading its
    -- position does not disturb it.
    indicator:ClearAllPoints()
    indicator:SetPoint("RIGHT", boss.label, "LEFT", -6, 0)
end

--------------------------------------------------------------------------------
-- The extra-bosses list
--
-- Drawn by heroPanel rather than restyled in place, which is a departure from
-- the rule the rest of this file keeps, and worth saying why.
--
-- A dungeon can offer far more minibosses than the key requires - fifteen for a
-- requirement of five in Lower Blackrock Spire - and a row per candidate makes
-- a panel taller than the screen. Windowing the tracker's own rows would mean
-- hiding the ones outside the window and moving the rest as it scrolls, and
-- showing, hiding and re-anchoring pooled objective rows is exactly what must
-- not happen: the tracker owns their layout and reasserts it on every update.
--
-- So Ascension's sub-rows are faded whole - alpha only, the same reversible
-- change made everywhere else here - and the list is drawn again on heroPanel's
-- own plate, where it can be six rows tall and scroll without anything the
-- tracker owns being touched.
--------------------------------------------------------------------------------

local subRowPool = {}
local scrollOffset = 0
local subCount, subVisible = 0, 0

local function GetSubRow(index)
    local row = subRowPool[index]
    if row then return row end

    local overlay = plate and plate.overlay
    if not overlay then return nil end

    row = {
        check = ns.NewGlyph(overlay, SUB_GLYPH),
        ring  = ns.NewGlyph(overlay, SUB_GLYPH),
        label = NewFontString(overlay),
    }
    row.check:SetShape("check")
    row.ring:SetShape("ring")

    subRowPool[index] = row
    return row
end

local function HideSubRowsFrom(first)
    for i = first, #subRowPool do
        local row = subRowPool[i]
        if row then
            row.check:Hide()
            row.ring:Hide()
            row.label:Hide()
        end
    end
end

-- Returns the bottom edge of the list, so the plate can be sized from it.
local function LayoutSubList(list, top)
    subCount = #list

    local maxOffset = math.max(0, subCount - SUB_MAX_ROWS)
    if scrollOffset > maxOffset then scrollOffset = maxOffset end
    if scrollOffset < 0 then scrollOffset = 0 end

    subVisible = math.min(subCount, SUB_MAX_ROWS)

    local font  = ns.GetFontFile()
    local size  = ns.GetFontSize(-1, "mplus")
    local left  = HEADER_PAD_X + SUB_INDENT
    local bottom = top

    for slot = 1, subVisible do
        local boss = list[slot + scrollOffset]
        local row  = GetSubRow(slot)
        if not (boss and row) then break end

        local y = top - (slot - 1) * SUB_ROW_H

        row.check:Hide()
        row.ring:Hide()

        local indicator
        if boss.done then
            local dr, dg, db = ns.HexToRGB(ns.db.text.done)
            row.label:SetTextColor(dr, dg, db, 1)
            row.check:SetColor(dr, dg, db, 1)
            indicator = row.check
        else
            local mr, mg, mb = ns.HexToRGB(ns.PALETTE.muted)
            row.label:SetTextColor(mr, mg, mb, 1)
            local hr, hg, hb = ns.HexToRGB(ns.PALETTE.hairline)
            row.ring:SetColor(hr, hg, hb, 0.18)
            indicator = row.ring
        end

        indicator:ClearAllPoints()
        indicator:SetPoint("LEFT", plate, "TOPLEFT", left, y - SUB_ROW_H / 2)
        indicator:Show()

        -- The name as the tracker wrote it, kill time and all: that time is
        -- the tracker's own and is worth keeping.
        row.label:SetFont(font, size)
        row.label:SetText(boss.text)
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", indicator, "RIGHT", 6, 0)
        row.label:Show()

        bottom = y - SUB_ROW_H
    end

    HideSubRowsFrom(subVisible + 1)

    -- The wheel catcher covers the rows it scrolls. Mouse wheel is enabled
    -- without the mouse itself, so it takes a scroll and still lets a click or
    -- a drag through to the tracker underneath.
    if subCount > SUB_MAX_ROWS then
        ui.wheel:ClearAllPoints()
        ui.wheel:SetPoint("TOPLEFT", plate, "TOPLEFT", 0, top)
        ui.wheel:SetPoint("TOPRIGHT", plate, "TOPRIGHT", 0, top)
        ui.wheel:SetHeight(subVisible * SUB_ROW_H)
        ui.wheel:Show()
    else
        ui.wheel:Hide()
    end

    return bottom
end

--------------------------------------------------------------------------------
-- Refresh
--
-- Every trigger funnels through here and is coalesced onto the next frame, so
-- the burst of events a boss kill produces costs one pass rather than one per
-- event.
--------------------------------------------------------------------------------

local function Redraw()
    if not mplus.enabled or not plate then return end

    local tracker = ns.GetTrackerFrame("mplus")
    if not tracker then return end

    if not tracker:IsVisible() then
        plate:Hide()
        return
    end

    local data = mplus.Read()
    if not data then return end

    FadeTrackerChrome(tracker)

    local width = LayoutPlate(tracker, nil)
    plate:Show()

    LayoutHeader()

    ui.dungeon:SetText(data.dungeon or "Mythic+")
    if data.level then
        ui.keystone:SetText("(" .. data.level .. ")")
        ui.keystone:Show()
    else
        ui.keystone:Hide()
    end

    LayoutAffixes(data.affixes)
    LayoutPlate(tracker, nil)   -- affix buttons need the tracker's strata

    local barBottom = LayoutTimer(data, width)


    -- Two lists with two different treatments. The required boss and the
    -- extra-bosses heading are few and fixed, so they are restyled where the
    -- tracker drew them. The extra bosses themselves are a variable-length
    -- list that has to be windowed, so heroPanel fades them and draws its own.
    local contentBottom, firstBossTop
    local styled, subList = 0, {}

    for i = 1, #data.bosses do
        local boss = data.bosses[i]
        HookRow(boss.frame)

        if boss.sub then
            -- Faded whole, text included: the panel redraws this row itself.
            FadeRegion(boss.label)
            if boss.icon then FadeRegion(boss.icon) end
            if boss.counter then FadeRegion(boss.counter) end
            table.insert(subList, boss)
        else
            styled = styled + 1
            StyleBossRow(styled, boss)

            local top    = boss.label:GetTop()
            local bottom = boss.label:GetBottom()
            if top and (not firstBossTop or top > firstBossTop) then firstBossTop = top end
            if bottom and (not contentBottom or bottom < contentBottom) then contentBottom = bottom end
        end
    end
    HideRowsFrom(styled + 1)

    if #subList > 0 and contentBottom then
        local plateTop = plate:GetTop()
        local listTop  = plateTop and (contentBottom - plateTop - 4) or -120
        local listBottom = LayoutSubList(subList, listTop)
        if plateTop then contentBottom = plateTop + listBottom end
    else
        HideSubRowsFrom(1)
        ui.wheel:Hide()
        subCount, subVisible = 0, 0
    end

    ------------------------------------------------------------------
    -- The expandable row's chevron
    --
    -- Drawn over Ascension's own expand control, whose art is faded above.
    -- The button underneath keeps taking its own clicks, so the chevron only
    -- has to point the right way - the same arrangement the quest header uses.
    ------------------------------------------------------------------

    local expandable = tracker.ObjectiveBlock and tracker.ObjectiveBlock.Encounters
    local expandButton = expandable and expandable.CollapseExpandButton
    if expandButton and expandButton:IsShown() and expandable:IsShown() then
        HookRow(expandable)
        ui.expandCaret:SetShape(expandable.isExpanded and "caretUp" or "caretDown")
        local ir, ig, ib = ns.HexToRGB(ns.PALETTE.icon)
        ui.expandCaret:SetColor(ir, ig, ib, 1)
        ui.expandCaret:ClearAllPoints()
        ui.expandCaret:SetPoint("CENTER", expandButton, "CENTER", 0, 0)
        ui.expandCaret:Show()
    else
        ui.expandCaret:Hide()
    end

    LayoutForces(data, width, barBottom, firstBossTop)

    -- Sized to what is actually drawn, not to the tracker's own height: the
    -- enemy-forces row heroPanel replaced is faded but still occupies space at
    -- the bottom of the tracker, and the panel must not stretch to cover it.
    LayoutPlate(tracker, contentBottom)

    ------------------------------------------------------------------
    -- Footer
    ------------------------------------------------------------------

    ui.rule:ClearAllPoints()
    ui.rule:SetPoint("BOTTOMLEFT", plate, "BOTTOMLEFT", HEADER_PAD_X, PAD_BOTTOM + FOOTER_HEIGHT)
    ui.rule:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -HEADER_PAD_X, PAD_BOTTOM + FOOTER_HEIGHT)
    ui.rule:SetHeight(1)
    ui.rule:Show()

    ui.mark:ClearAllPoints()
    ui.mark:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -HEADER_PAD_X, PAD_BOTTOM)
    ui.mark:Show()

    ns.Debug("mplus panel refreshed (%d boss row(s)).", #data.bosses)
end

function Refresh(reason)
    if queued then return end
    queued = true
    ns.After(0, function()
        queued = false
        Redraw()
        ns.Debug("mplus refreshed (%s).", tostring(reason))
    end)
end
mplus.Refresh = Refresh

--------------------------------------------------------------------------------
-- Clock
--
-- The timer row is the only thing on the panel that changes without an event
-- to hang off: MYTHIC_PLUS_TIMER_UPDATE arrives from the server at whatever
-- rate it arrives at, and a clock that only moves when the server says so
-- reads as a stuck clock. So the row - text, bar and tier, nothing else - is
-- redrawn four times a second off the shared ticker. The rest of the panel
-- still only moves when something happens.
--------------------------------------------------------------------------------

local function ClockTick()
    if not mplus.enabled or not plate or not plate:IsVisible() then return end

    local data = lastRead
    if not (data and data.totalTime) then return end

    -- Count down locally between server updates rather than re-reading, which
    -- would just hand back the same number until the next event.
    local timeLeft = CallApi("GetActiveKeystoneTime")
    if timeLeft then
        data.timeLeft = timeLeft
    elseif data.timeLeft then
        data.timeLeft = math.max(0, data.timeLeft - TICK_INTERVAL)
    end

    LayoutTimer(data, plate:GetWidth() or PANEL_MIN_WIDTH)

    -- The active boss's dot breathes. One sine over PULSE_PERIOD, sampled at
    -- whatever rate the ticker runs, so the period is right regardless.
    pulse = (pulse + TICK_INTERVAL) % PULSE_PERIOD
    local alpha = PULSE_MIN + (1 - PULSE_MIN)
                * (0.5 + 0.5 * math.sin((pulse / PULSE_PERIOD) * math.pi * 2))
    local ar, ag, ab = ns.HexToRGB(ns.PALETTE.accent)
    for i = 1, #rows do
        local row = rows[i]
        if row and row.pulsing and row.ringDot:IsShown() then
            row.ringDot:SetColor(ar, ag, ab, alpha)
        end
    end
end

--------------------------------------------------------------------------------
-- Hooks
--
-- The tracker's scripts go through ns.HookScript so nothing Ascension
-- installed is replaced. Its events are registered defensively: they are
-- Ascension's own, and RegisterEvent on an event a client does not have is not
-- something to find out about through a Lua error at login.
--------------------------------------------------------------------------------

local MPLUS_EVENTS = {
    "MYTHIC_PLUS_STARTED",
    "MYTHIC_PLUS_COUNTDOWN_STARTED",
    "MYTHIC_PLUS_COMPLETE",
    "MYTHIC_PLUS_TIMER_UPDATE",
    "MYTHIC_PLUS_TRASH_UPDATE",
    "MYTHIC_PLUS_CHAMPIONS_UPDATE",
    "MYTHIC_PLUS_ENCOUNTER_UPDATE",
}

local function InstallHooks(tracker)
    if hooked then return end
    hooked = true

    ns.HookScript(tracker, "OnShow", function() Refresh("shown") end)
    ns.HookScript(tracker, "OnHide", function()
        if plate then plate:Hide() end
    end)
    ns.HookScript(tracker, "OnSizeChanged", function() Refresh("resized") end)

    for i = 1, #MPLUS_EVENTS do
        local event = MPLUS_EVENTS[i]
        local ok = pcall(function() ns:On(event, function() Refresh(event) end) end)
        if not ok then ns.Debug("client has no %s event.", event) end
    end

    ui.wheel:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, subCount - SUB_MAX_ROWS)
        local wanted    = scrollOffset - (delta or 0)
        if wanted < 0 then wanted = 0 end
        if wanted > maxOffset then wanted = maxOffset end
        if wanted == scrollOffset then return end
        scrollOffset = wanted
        Refresh("scrolled")
    end)

    ui.lock:SetScript("OnClick", function()
        ns:ToggleLock("mplus")
    end)
    ui.lock:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ns.IsLocked() and "Unlock to move the Mythic+ tracker"
                                          or "Lock the Mythic+ tracker", 1, 1, 1)
        GameTooltip:Show()
    end)
    ui.lock:SetScript("OnLeave", function() GameTooltip:Hide() end)

    ns.Debug("mplus hooks installed.")
end

--------------------------------------------------------------------------------
-- Enable / disable
--------------------------------------------------------------------------------

function mplus.Enable()
    if not ns.db then return false, "SavedVariables are not loaded yet" end

    local tracker = ns.GetTrackerFrame("mplus")
    if not tracker then return false, "the Mythic+ tracker has not been found" end

    if not plate then
        BuildPlate(tracker)
        InstallHooks(tracker)
        ns.Debug("mplus panel built.")
    end

    mplus.enabled = true
    StyleStatic()

    if not ticker then ticker = ns.NewTicker(TICK_INTERVAL, ClockTick) end
    ticker:Start()

    Refresh("enabled")
    return true
end

function mplus.Disable()
    mplus.enabled = false
    if ticker then ticker:Stop() end

    RestoreChrome()
    HideRowsFrom(1)
    if plate then plate:Hide() end
    return true
end

function mplus.SetEnabled(enabled)
    if enabled then
        if not mplus.Enable() then
            ns.Debug("mplus skin enabled but the tracker is not available yet.")
        end
    else
        mplus.Disable()
    end
end

--------------------------------------------------------------------------------
-- Status
--------------------------------------------------------------------------------

function mplus.PrintStatus()
    if not ns.db then return end

    ns.Print("  Mythic+ panel is |cFFC2C6D8%s|r", mplus.enabled and "on" or "off")

    if not plate then
        ns.Print("    |cFF8B8FA3panel not built|r - the Mythic+ tracker was not available")
        return
    end

    ns.Print("    panel %s, %.0f x %.0f",
        plate:IsVisible() and "|cFF79C68Dvisible|r" or "|cFFFFAA00not visible|r",
        plate:GetWidth() or 0, plate:GetHeight() or 0)

    ns.Print("    keystone API: |cFFC2C6D8%s|r",
        Api() and "|cFF79C68DC_MythicPlus|r" or "|cFFFFAA00absent - reading the tracker's frames|r")

    local data = lastRead
    if not data then
        ns.Print("    |cFF8B8FA3nothing read yet|r")
        return
    end

    ns.Print("    %s (%s), %s of %s left, %.0f boss row(s)",
        tostring(data.dungeon or "?"), tostring(data.level or "?"),
        Clock(data.timeLeft), Clock(data.totalTime), #(data.bosses or {}))

    local tier, window = mplus.ChestTier(data.timeLeft, data.totalTime)
    local percents = Thresholds()
    if tier then
        ns.Print("    chest: |cFFECCE82+%d|r with |cFFC9A95F%s|r left (thresholds %.0f%% / %.0f%%)",
            tier, Clock(window), percents[1] * 100, percents[2] * 100)
    else
        ns.Print("    chest: |cFF8B8FA3no upgrade still reachable|r")
    end
end

--------------------------------------------------------------------------------
-- Dump
--
-- /hp mplus. What the panel resolved and where it got each number, which is
-- the first question when a field comes out blank: an absent API and a
-- keystone that is not running look identical on screen.
--------------------------------------------------------------------------------

function mplus.Dump()
    local tracker = ns.GetTrackerFrame("mplus")
    ns.Print("Mythic+ dump")

    if not tracker then
        ns.Print("  |cFFFFAA00tracker not found|r - Ascension_MythicPlus may not be loaded")
        return
    end

    ns.Print("  tracker %s, %.0f x %.0f, strata %s level %.0f",
        tracker:IsVisible() and "visible" or "|cFFFFAA00not visible|r",
        tracker:GetWidth() or 0, tracker:GetHeight() or 0,
        tostring(tracker:GetFrameStrata()), tracker:GetFrameLevel() or 0)

    local api = Api()
    ns.Print("  C_MythicPlus: %s", api and "|cFF79C68Dpresent|r" or "|cFFFFAA00absent|r")
    if api then
        for _, name in ipairs({ "IsKeystoneActive", "GetActiveKeystoneInfo",
                                "GetActiveKeystoneTime", "GetActiveKeystoneTrash" }) do
            ns.Print("    %s %s", name,
                type(api[name]) == "function" and "|cFF79C68Dyes|r" or "|cFFFFAA00missing|r")
        end
    end

    local percents = Thresholds()
    ns.Print("  thresholds: +3 at |cFFECCE82%.0f%%|r, +2 at |cFFC9A95F%.0f%%|r time remaining%s",
        percents[1] * 100, percents[2] * 100,
        _G.MYTHIC_PLUS_BONUS_LEVEL_PERCENT and "" or " |cFFFFAA00(client constant missing, using defaults)|r")

    local data = mplus.Read()
    if not data then return end

    ns.Print("  read: dungeon %s, level %s, %s / %s, forces %s/%s",
        tostring(data.dungeon), tostring(data.level),
        tostring(data.timeLeft and Clock(data.timeLeft)),
        tostring(data.totalTime and Clock(data.totalTime)),
        tostring(data.trashDead), tostring(data.trashRequired))

    for i = 1, #data.bosses do
        local boss = data.bosses[i]
        ns.Print("    boss %d |cFFC2C6D8%s|r: %s", i, boss.text,
            boss.done and "|cFF79C68Dslain|r" or "|cFF8B8FA3up|r")
    end
    if #data.bosses == 0 then
        ns.Print("    |cFFFFAA00no boss rows|r - the objective block is empty or hidden")
    end
end

--------------------------------------------------------------------------------
-- Wiring
--
-- The tracker frequently does not exist at ADDON_LOADED, so the panel is built
-- from the same discovery point Phase 1 already polls for rather than from a
-- second timer of its own.
--------------------------------------------------------------------------------

ns:On("HEROPANEL_TRACKER_FOUND", function(key)
    if key ~= "mplus" then return end
    if not ns.db then ns.InitDB() end
    if ns.db.enabled then mplus.Enable() end
end)

ns:On("HEROPANEL_LOCK_CHANGED", function()
    if mplus.enabled and plate then
        ui.lockIcon:SetShape(ns.IsLocked() and "locked" or "unlocked")
    end
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    if mplus.enabled then Refresh("entering world") end
end)
