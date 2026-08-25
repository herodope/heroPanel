--[[--------------------------------------------------------------------------
    heroPanel - Dungeon.lua

    The dungeon panel: the Mythic+ panel, drawn over LFGObjectiveTracker - the
    tracker Ascension puts on screen in a Normal, Heroic or Mythic 0 dungeon.

    It is the Mythic+ panel with the keystone taken out of it. Same plate, same
    header, same boss rows, same footer; no clock, no threshold bar, no affixes,
    no enemy forces, because none of those exist outside a key. Everything it is
    drawn with - colours, border, opacity, text shadow and the three Mythic+
    font sizes - is read from the Mythic+ panel's own settings rather than from
    a set of its own, so the two panels cannot drift apart. It has a skin switch
    and a saved position of its own, and nothing else: they are two frames, and
    a panel that cannot be placed separately from a frame it is not is no use.

    Where the frame comes from
    --------------------------
    LFGObjectiveTracker is FrameXML rather than an addon - Ascension's
    Interface\FrameXML\Scenario\ScenarioObjectiveTracker.xml - so unlike the
    Mythic+ tracker it exists from login and Trackers.lua finds it first time.
    It inherits ObjectiveTrackerTemplate, which is the same base the Mythic+
    tracker is built on, so the parent keys this file reads are the ones
    Mplus.lua already reads: .Header, .HeaderText, .CollapseExpandButton,
    .LockButton, .MainBlock, .ObjectiveBlock.

    Ascension only shows it inside a dungeon entered through the group finder -
    LFGObjectiveTrackerMixin:Update tests C_Instance.IsInDungeon() and
    IsPartyLFG(). heroPanel skins the frame it is given and cannot conjure it
    where Ascension does not draw it, which is what the placement preview is
    for.

    Where the numbers come from
    ---------------------------
        dungeon name   GetInstanceInfo()
                       else the tracker's MainBlock.Title
        difficulty     GetInstanceInfo()'s difficulty index, else
                       GetDungeonDifficulty(). 1/2/3 is normal/heroic/mythic,
                       which is the mapping Ascension's own tracker uses
        objectives     the tracker's pooled rows, which carry the label in
                       .Text and the state in .progress / .progressMax
        boss state     GetEncounterInfo(tracker.getEncounterID()) -> isDead

    Two departures from Mplus.lua, both deliberate
    ----------------------------------------------
    THE ROWS ARE HEROPANEL'S OWN. The Mythic+ panel restyles Ascension's
    objective rows where Ascension drew them, and this one does not: it fades
    them and draws the same rows on its own plate. That is the same departure
    the Mythic+ extra-bosses list makes, for a different reason. Ascension
    anchors this tracker's MainBlock 40px below the header and gives it 87px of
    height for a name and a piece of toast art - all of which heroPanel fades -
    so the first objective row lands roughly 127px down a panel whose header
    ends at 30. Restyled in place, the panel would be a header, a hundred pixels
    of nothing, and one line. Closing that gap means moving a row, and moving a
    row the tracker owns is the one thing the skin must never do. Drawing them
    is what is left, and it is cheap here: this tracker has a single objective.

    THE HEADER SAYS WHICH DUNGEON. Ascension's says "Dungeon". Its own Update
    works out "Heroic Dungeon" or "Mythic Dungeon" from the difficulty and then
    calls SetHeaderText(LFG_TYPE_DUNGEON) anyway, so the difficulty it computed
    never reaches the screen. heroPanel's header carries the dungeon name with
    the difficulty beside it, in the slot the Mythic+ header puts the keystone
    level in - which makes the two panels read the same and says the one thing
    Ascension's own panel drops.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local dungeon = { enabled = false }
ns.Dungeon = dungeon

--------------------------------------------------------------------------------
-- Layout constants
--
-- The header block is the Mythic+ panel's, value for value, because the two
-- panels are the same panel and a header that sat two pixels differently would
-- be visible the moment somebody alt-tabbed between a key and a Mythic 0.
--
-- The row block is this file's own: the Mythic+ panel does not have one, since
-- its rows are wherever Ascension put them.
--------------------------------------------------------------------------------

local PANEL_MIN_WIDTH = 300
local PAD_LEFT        = 14
local PAD_RIGHT       = 14
local PAD_BOTTOM      = 11
local HEADER_PAD_X    = 13
local HEADER_HEIGHT   = 30
local HEADER_GAP      = 7     -- lock -> dungeon name
local DIFFICULTY_GAP  = 3     -- dungeon name -> difficulty, deliberately tighter

local LOCK_GLYPH_SIZE = 15

local ROWS_TOP        = 12    -- gap between the header row and the first objective
local ROW_GLYPH       = 14
local ROW_INDENT      = 4     -- indicator's left edge, in from the content edge
local ROW_LABEL_GAP   = 6     -- indicator -> label
local ROW_COUNT_GAP   = 8     -- least gap between a label and its count

-- A row is as tall as the text in it, with a floor.
--
-- Fixed row heights would have been simpler and would have broken the font
-- slider: the body size runs to 30 points, and rows spaced at a constant 20
-- would have drawn the last four sizes on top of each other. The Mythic+ panel
-- never had to answer this because Ascension lays its rows out; this one places
-- its own, so it has to size them from the font it is drawing with.
local ROW_MIN_HEIGHT  = 18
local ROW_LEADING     = 1.45  -- line height as a multiple of the font size

local FOOTER_TOP      = 9     -- gap between the last row and the rule
local FOOTER_HEIGHT   = 18

-- Font steps inside the Mythic+ body role, as deltas rather than sizes - the
-- same proportions Mplus.lua's boss rows take, so a boss reads the same size on
-- either panel. The single objective a dungeon has is the panel's headline and
-- takes the primary step; anything past the first is body text.
local PRIMARY_DELTA   = 1.5
local ROW_DELTA       = -0.5
local COUNT_DELTA     = -1

-- Same reasoning as Skin.lua and Mplus.lua: frame levels bottom out at zero and
-- only compare inside a strata, so the plate goes a strata below the tracker
-- rather than a couple of levels below it.
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

-- 1/2/3 is what GetInstanceInfo reports for a five-player instance on this
-- client, and it is the mapping LFGObjectiveTrackerMixin:Update itself uses to
-- pick between LFG_TYPE_DUNGEON, LFG_TYPE_HEROIC_DUNGEON and
-- LFG_TYPE_MYTHIC_DUNGEON. The words here are the difficulty alone, because the
-- panel already says which dungeon beside it.
local DIFFICULTY_LABEL = { [1] = "Normal", [2] = "Heroic", [3] = "Mythic" }

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local plate                     -- the panel; everything else hangs off it
local ui       = {}             -- heroPanel's own widgets
local rows     = {}             -- pooled objective rows, drawn by heroPanel
local faded    = {}             -- region -> original alpha, for Disable()
local hiddenArt = {}            -- region -> original shown state, for Disable()
local lockMouse = {}            -- button -> original mouse state, for Disable()
local hooked   = false
local queued   = false
local lastRead                  -- what the last refresh resolved, for /hp dungeon

-- Forward declaration: the row hooks installed during a draw have to be able to
-- queue the next one, and they are set up above where it is defined.
local Refresh

--------------------------------------------------------------------------------
-- Placement preview
--
-- The same problem the Mythic+ panel has, for the same reason: the tracker is
-- only on screen inside a dungeon, which is the worst possible moment to be
-- deciding where a panel goes. Preview draws it over sample data from anywhere.
--
-- It is this panel, drawn by the same layout code against a made-up read - and
-- here it is the whole panel rather than most of it, because this panel draws
-- its own rows in a real dungeon too. What preview shows is what a dungeon
-- shows.
--
-- Session only, deliberately, exactly as the Mythic+ preview is: a panel that
-- survived a reload showing a dungeon you are not in reads as a broken addon
-- rather than as a switch somebody left on.
--------------------------------------------------------------------------------

local preview = false

local DrawPreview
local SyncPreviewMouse

function dungeon.IsPreview() return preview end

function dungeon.GetPlate() return plate end

--------------------------------------------------------------------------------
-- Reading the dungeon
--------------------------------------------------------------------------------

-- The label a row carries with its verb taken off.
--
-- The tracker builds this row's label as DEFEAT_S:format(bossName), which on
-- this client is "Defeat: Razorlash". The Mythic+ panel draws a required boss
-- as its name alone, so this one has to as well or the same boss reads
-- differently on the two panels.
--
-- The name is preferred over the pattern: when the encounter API has told us
-- what the boss is called, a label that contains that name is drawn as the name
-- and nothing is being guessed at. The prefix strip is the fallback, and it is
-- taken from DEFEAT_S itself rather than written out in English, so a client
-- that localises it is stripped correctly and one that does not use the
-- constant at all is left alone.
local function DefeatPrefix()
    local template = _G.DEFEAT_S
    if type(template) ~= "string" then return nil end
    local prefix = string.match(template, "^(.-)%%s")
    if not prefix or prefix == "" then return nil end
    return prefix
end

local function ShortLabel(text, bossName)
    if bossName and bossName ~= "" and string.find(text, bossName, 1, true) then
        return bossName
    end

    local prefix = DefeatPrefix()
    if prefix and string.sub(text, 1, #prefix) == prefix then
        return (string.gsub(string.sub(text, #prefix + 1), "^%s+", ""))
    end

    return text
end

-- One objective row as heroPanel needs it. Same pair the tracker itself tests
-- to decide whether to draw a check: .progress against .progressMax.
--
-- Read straight off the font string rather than through a raw-text helper,
-- because nothing in this file ever rewrites a string the tracker owns - the
-- rows on screen are heroPanel's own, and Ascension's are faded whole.
local function ReadObjectiveRow(row)
    if type(row) ~= "table" then return nil end

    -- Visible, not merely shown.
    --
    -- Collapsing the tracker hides its MainBlock and ObjectiveBlock and leaves
    -- every row inside them shown - that is what ObjectiveTrackerMixin:OnCollapse
    -- does. A shown test therefore reads a collapsed tracker as a full one, and
    -- the panel would draw a boss list over a tracker that had just been folded
    -- away. heroPanel does not drive that button; it only has to agree with it.
    if row.IsVisible then
        if not row:IsVisible() then return nil end
    elseif row.IsShown and not row:IsShown() then
        return nil
    end

    local label = row.Text
    if not (label and label.GetText) then return nil end

    local ok, text = pcall(label.GetText, label)
    if not ok or not text or text == "" then return nil end

    local progress, maximum = tonumber(row.progress), tonumber(row.progressMax)
    local done = false
    if progress and maximum and maximum > 0 then done = progress >= maximum end

    return { frame = row, text = text, done = done,
             progress = progress, maximum = maximum }
end

-- The tracker keeps its live rows in .objectives, which is the pool
-- ObjectiveTrackerMixin:CreateObjective fills. The walk underneath it is for a
-- client whose template stopped doing that: a panel drawn with no rows at all
-- is indistinguishable from a bug, and finding them by shape costs one walk of
-- a frame with a handful of children.
local function CollectObjectives(tracker)
    local found, seen = {}, {}

    local function Add(row)
        if seen[row] then return end
        local entry = ReadObjectiveRow(row)
        if entry then
            seen[row] = true
            table.insert(found, entry)
        end
    end

    local list = tracker.objectives
    if type(list) == "table" then
        for i = 1, #list do Add(list[i]) end
    end

    if #found == 0 and tracker.ObjectiveBlock then
        ns.WalkFrameTree(tracker.ObjectiveBlock, function(object, info)
            if info.kind == "child" then Add(object) end
        end, { maxDepth = 2, includeRegions = false })
    end

    -- Top down, which is the order they are read in.
    table.sort(found, function(a, b)
        return (a.frame:GetTop() or 0) > (b.frame:GetTop() or 0)
    end)

    return found
end

-- The boss the tracker is following, and whether the server says it is dead.
--
-- The row's own state is not trusted for the same reason the Mythic+ panel does
-- not trust its rows, arriving by a different route. This tracker sets
-- bossDefeated from COMBAT_LOG_EVENT_UNFILTERED while the frame is shown, so a
-- kill seen through a reload, a disconnect, or a zone-in after the fact never
-- reaches it and the row sits at 0/1 over a boss that is long dead.
-- GetEncounterInfo is the server's answer and is right in all of those cases.
local function EncounterState(tracker)
    local getter = tracker.getEncounterID
    if type(getter) ~= "function" then return nil, nil end

    local ok, encounterID = pcall(getter)
    if not ok or not encounterID then return nil, nil end

    if type(_G.GetEncounterInfo) ~= "function" then return nil, nil end
    local read, name, _, _, _, _, _, isDead = pcall(_G.GetEncounterInfo, encounterID)
    if not read or not name or name == "" then return nil, nil end

    return name, isDead and true or false
end

-- The difficulty, as an index. GetInstanceInfo is what Ascension's own tracker
-- reads; GetDungeonDifficulty is the fallback for a client that answers one and
-- not the other, and it is the call the boon bar already uses for the same job.
local function Difficulty()
    if type(_G.GetInstanceInfo) == "function" then
        local ok, _, _, difficulty = pcall(_G.GetInstanceInfo)
        if ok and tonumber(difficulty) then return tonumber(difficulty), "GetInstanceInfo" end
    end

    if type(_G.GetDungeonDifficulty) == "function" then
        local ok, difficulty = pcall(_G.GetDungeonDifficulty)
        if ok and tonumber(difficulty) then return tonumber(difficulty), "GetDungeonDifficulty" end
    end

    return nil, nil
end

-- Everything the panel draws, resolved once per refresh.
function dungeon.Read()
    local tracker = ns.GetTrackerFrame("dungeon")
    if not tracker then return nil end

    local data = { tracker = tracker }

    if type(_G.GetInstanceInfo) == "function" then
        local ok, name = pcall(_G.GetInstanceInfo)
        if ok and type(name) == "string" and name ~= "" then
            data.dungeon = name
            data.dungeonFrom = "GetInstanceInfo"
        end
    end

    -- The tracker is plainly showing a name, so taking it from there beats
    -- drawing a blank where one should be.
    if not data.dungeon then
        local title = tracker.MainBlock and tracker.MainBlock.Title
        if title and title.GetText then
            local ok, text = pcall(title.GetText, title)
            if ok and text and text ~= "" then
                data.dungeon = text
                data.dungeonFrom = "MainBlock.Title"
            end
        end
    end

    data.difficulty, data.difficultyFrom = Difficulty()
    data.difficultyLabel = DIFFICULTY_LABEL[data.difficulty or 0]

    data.bossName, data.bossDead = EncounterState(tracker)
    data.objectives = CollectObjectives(tracker)

    -- Whatever the encounter API says now wins over what the row was told when
    -- the combat log fired. A row the API cannot speak for - anything whose
    -- label does not carry the boss's name - keeps its own state, so nothing
    -- here can invent an objective or complete one.
    if data.bossName and data.bossDead ~= nil then
        for i = 1, #data.objectives do
            local entry = data.objectives[i]
            if string.find(entry.text, data.bossName, 1, true) then
                entry.done = data.bossDead
            end
        end
    end

    lastRead = data
    return data
end

--------------------------------------------------------------------------------
-- Ascension's chrome
--
-- Every rule Mplus.lua keeps is kept here, and for the same reasons: alpha
-- rather than Hide wherever alpha is enough, the original value remembered so
-- Disable() gives the frame back exactly as it was found, and nothing the
-- tracker owns re-anchored, resized or given a script.
--
-- The state tables are this file's own rather than shared with Mplus.lua. They
-- are the record of what to hand back, and one table across two panels would
-- mean turning either skin off restored the other's frame as well - and wiped
-- the record it needed to do its own job later.
--------------------------------------------------------------------------------

local function FadeRegion(region)
    if not region or type(region.SetAlpha) ~= "function" then return end
    if faded[region] == nil then
        local ok, alpha = pcall(region.GetAlpha, region)
        faded[region] = (ok and alpha) or 1
    end
    pcall(region.SetAlpha, region, 0)
end

local BUTTON_TEXTURES = { "GetNormalTexture", "GetPushedTexture",
                          "GetHighlightTexture", "GetDisabledTexture" }

-- A button's four state textures, which are its own rather than its regions and
-- so are missed by a walk of the regions.
local function FadeButtonTextures(button, fade)
    for i = 1, #BUTTON_TEXTURES do
        local getter = button[BUTTON_TEXTURES[i]]
        if type(getter) == "function" then
            local ok, texture = pcall(getter, button)
            if ok and texture then (fade or FadeRegion)(texture) end
        end
    end
end

local function FadeRegionsOf(frame)
    if not (frame and frame.GetRegions) then return end
    local ok, regions = pcall(function() return { frame:GetRegions() } end)
    if not ok then return end
    for i = 1, #regions do FadeRegion(regions[i]) end
end

-- A status bar's fill is a texture the frame owns rather than one of its
-- regions, so GetRegions never returns it and a subtree walk goes straight past
-- it. A dungeon objective can be a status-bar row - the template is there and
-- Ascension uses it for enemy forces on the Mythic+ tracker - so it is covered
-- here too rather than left as a surprise for the first client that uses one.
local function FadeFill(bar, fade)
    if not bar or type(bar.GetStatusBarTexture) ~= "function" then return end
    local ok, fill = pcall(bar.GetStatusBarTexture, bar)
    if ok and fill then (fade or FadeRegion)(fill) end
end

local function FadeSubtree(frame)
    if not frame then return end
    FadeRegionsOf(frame)
    FadeButtonTextures(frame)

    ns.WalkFrameTree(frame, function(object, info)
        if info.kind == "region" then
            FadeRegion(object)
        elseif info.objectType == "Button" then
            FadeButtonTextures(object)
        end
    end, { maxDepth = 4, includeRegions = true })
end

-- Art that needs more than alpha.
--
-- An objective row animates when it completes: ScenarioObjectiveMixin plays
-- IconFlash and Sheen the moment progress reaches its maximum, and an animation
-- owns the alpha of what it animates - it writes the value every frame for as
-- long as it plays, so a zero set by FadeRegion is simply gone for the length
-- of the flash. On the Mythic+ panel that was the enemy-forces glow drawing
-- across the bottom of the panel on every pull; here it would be a starburst
-- over heroPanel's own row every time a boss died.
--
-- So these are hidden as well as faded. Hiding is what the rest of this file
-- avoids, and the objection is about frames: this hides regions only, so the
-- row keeps its height, its anchors and its children and the tracker still
-- measures it exactly as it did.
--
-- Show is hooked to keep it that way, because the animation's own scripts show
-- the texture again on the next kill and there is no event heroPanel could hang
-- a re-hide off that lands before the frame it would be visible on. The hook is
-- gated on dungeon.enabled, so Disable() hands the row straight back.
local function HideArt(region)
    if not region or type(region.Hide) ~= "function" then return end
    FadeRegion(region)

    if hiddenArt[region] == nil then
        local ok, shown = pcall(region.IsShown, region)
        hiddenArt[region] = (ok and shown) or false
        pcall(hooksecurefunc, region, "Show", function(self)
            if dungeon.enabled then pcall(self.Hide, self) end
        end)
    end
    pcall(region.Hide, region)
end

local function ClearSubtree(frame)
    if not frame then return end

    FadeFill(frame, HideArt)
    FadeButtonTextures(frame, HideArt)

    ns.WalkFrameTree(frame, function(object, info)
        if info.kind == "region" then
            HideArt(object)
        else
            FadeFill(object, HideArt)
            if info.objectType == "Button" then FadeButtonTextures(object, HideArt) end
        end
    end, { maxDepth = 4, includeRegions = true })
end

local function FadeTrackerChrome(tracker, objectives)
    -- The tracker's own header: heroPanel draws one in its place.
    FadeRegion(tracker.Header)
    FadeRegion(tracker.HeaderText)
    FadeSubtree(tracker.CollapseExpandButton)

    -- Ascension's lock button, top right. heroPanel has its own in the header's
    -- top-left corner, and two locks on one panel is one too many, so this one
    -- is faded and stops taking the mouse. Its old mouse state is kept like
    -- every other change here.
    local lockButton = tracker.LockButton or _G.LFGObjectiveTrackerLockButton
    if lockButton then
        FadeSubtree(lockButton)
        if lockButton.EnableMouse and lockMouse[lockButton] == nil then
            lockMouse[lockButton] = (lockButton.IsMouseEnabled and lockButton:IsMouseEnabled()) or false
        end
        pcall(lockButton.EnableMouse, lockButton, false)
    end

    -- The whole main block - the toast background, the dungeon name, the
    -- subtext, the two corner strings and the final-stage filigree. heroPanel
    -- redraws the one piece of that anybody reads, so the block goes as a
    -- subtree rather than widget by widget.
    if tracker.MainBlock then FadeSubtree(tracker.MainBlock) end

    -- Every objective row, cleared rather than faded: heroPanel draws these
    -- again on its own plate, and they animate. See HideArt.
    for i = 1, #objectives do ClearSubtree(objectives[i].frame) end
end

local function RestoreChrome()
    -- Shown state first, then alpha: a region that comes back invisible looks
    -- exactly like one that was never restored at all.
    for region, shown in pairs(hiddenArt) do
        if shown then pcall(region.Show, region) end
    end
    wipe(hiddenArt)

    for region, alpha in pairs(faded) do
        pcall(region.SetAlpha, region, alpha)
    end
    wipe(faded)

    for button, enabled in pairs(lockMouse) do
        pcall(button.EnableMouse, button, enabled)
    end
    wipe(lockMouse)
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function NewFontString(parent, layer)
    local fontString = parent:CreateFontString(nil, layer or "OVERLAY")
    fontString:SetFont(ns.GetFontFile(), ns.GetFontSize(0, "mplusBody"))
    return fontString
end

local function BuildPlate(tracker)
    plate = CreateFrame("Frame", "HeroPanelDungeonPlate", tracker:GetParent() or UIParent)
    plate:Hide()
    plate:SetWidth(PANEL_MIN_WIDTH)
    plate:SetHeight(HEADER_HEIGHT)

    -- Draggable, but not mouse-enabled. The plate only ever takes the mouse
    -- while the placement preview is up - see SyncPreviewMouse - because the
    -- panel sits one strata below the tracker precisely so it can never take a
    -- click the tracker wanted.
    plate:SetMovable(true)
    plate:SetClampedToScreen(true)
    plate:RegisterForDrag("LeftButton")

    ns.BuildPlateChrome(plate)

    plate.overlay = CreateFrame("Frame", nil, plate)
    plate.overlay:SetAllPoints(plate)

    local overlay = plate.overlay

    ui.lock = CreateFrame("Button", nil, plate)
    ui.lock:SetWidth(LOCK_GLYPH_SIZE + 4)
    ui.lock:SetHeight(LOCK_GLYPH_SIZE + 4)
    -- Outlined, like the other two panels': this one's background is the
    -- player's to turn down too, and a grey padlock over a lit floor is not a
    -- padlock.
    ui.lockIcon = ns.NewGlyph(ui.lock, LOCK_GLYPH_SIZE, true)
    ui.lockIcon:SetPoint("CENTER")

    ui.dungeon    = NewFontString(overlay)
    ui.difficulty = NewFontString(overlay)

    ui.rule = ns.NewPlateTexture(plate, "BORDER")
    ui.mark = NewFontString(overlay)
    ui.mark:SetText("heroPanel")

    -- The corner handle that scales this panel, hidden while the trackers are
    -- locked. Same widget as the other two panels', from Move.lua, so the three
    -- cannot end up behaving differently.
    plate.grip = ns.NewResizeGrip(plate, {
        label    = "Dungeon tracker",
        deferred = true,
        visible  = function() return not ns.IsLocked() end,
        get      = function() return ns.db.frame.dungeon.scale or 1 end,
        set      = function(scale) ns.SetScale("dungeon", scale) end,
    })

    return plate
end

-- One objective row's widgets: an indicator, the label and a count. Pooled,
-- because a tracker can gain and lose rows without the panel being rebuilt.
local function GetRow(index)
    local row = rows[index]
    if row then return row end

    local overlay = plate and plate.overlay
    if not overlay then return nil end

    row = {
        check = ns.NewGlyph(overlay, ROW_GLYPH),
        ring  = ns.NewGlyph(overlay, ROW_GLYPH),
        label = NewFontString(overlay),
        count = NewFontString(overlay),
    }
    row.check:SetShape("check")
    row.ring:SetShape("ring")

    rows[index] = row
    return row
end

local function HideRowsFrom(first)
    for i = first, #rows do
        local row = rows[i]
        if row then
            row.check:Hide()
            row.ring:Hide()
            row.label:Hide()
            row.count:Hide()
        end
    end
end

--------------------------------------------------------------------------------
-- Painting
--
-- Everything here reads the Mythic+ panel's settings: ns.PanelStyle("mplus"),
-- ns.BorderPaint(_, "mplus"), ns.ApplyTextShadow(_, "mplus") and the mplus font
-- roles. That is the whole of "the dungeon panel follows the M+ settings" -
-- there is no second set of keys to keep matched, so there is no way for the
-- two panels to disagree about how they are drawn.
--------------------------------------------------------------------------------

local function StyleStatic()
    if not plate then return end

    ns.StylePlateChrome(plate, ns.PanelStyle("mplus"))

    local font = ns.GetFontFile()

    local ir, ig, ib = ns.HexToRGB(ns.PALETTE.icon)
    ui.lockIcon:SetColor(ir, ig, ib, 1)

    local br, bg, bb = ns.HexToRGB(ns.PALETTE.bright)
    ui.dungeon:SetFont(font, ns.GetFontSize(0, "mplusHeader"))
    ui.dungeon:SetTextColor(br, bg, bb, 1)

    -- The difficulty takes the keystone level's colour and its step down in
    -- size, because it is the same thing in the same place: the qualifier on
    -- the dungeon name.
    local dr, dg, db = ns.HexToRGB(ns.PALETTE.accentLight)
    ui.difficulty:SetFont(font, ns.GetFontSize(-1, "mplusHeader"))
    ui.difficulty:SetTextColor(dr, dg, db, 1)

    -- The footer rule is an edge, so it follows the border's colour, alpha and
    -- style rather than a hairline token of its own - a border turned off must
    -- not leave a line ruled across the panel.
    local rr, rg, rb, ra = ns.BorderPaint(0.5, "mplus")
    ui.rule:SetVertexColor(rr, rg, rb, ra)

    local ar, ag, ab = ns.HexToRGB(ns.PALETTE.accentDeep)
    ui.mark:SetFont(font, ns.GetFontSize(-3.5, "mplusBody"))
    ui.mark:SetTextColor(ar, ag, ab, 1)

    for _, fontString in ipairs({ ui.dungeon, ui.difficulty, ui.mark }) do
        ns.ApplyTextShadow(fontString, "mplus")
    end
end
dungeon.Restyle = StyleStatic

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local function LayoutPlate(tracker, contentBottom)
    local parent = tracker:GetParent() or UIParent
    if plate:GetParent() ~= parent then plate:SetParent(parent) end
    ns.MatchScale(plate, tracker:GetScale() or 1)

    local strata = tracker:GetFrameStrata() or "LOW"
    local level  = tracker:GetFrameLevel() or 1
    plate:SetFrameStrata(STRATA_BELOW[strata] or "BACKGROUND")
    plate:SetFrameLevel(1)
    plate.overlay:SetFrameLevel(3)

    -- The lock is the only thing above the tracker: it has to take its own
    -- clicks even while the tracker is mouse-enabled for dragging.
    ui.lock:SetFrameStrata(strata)
    ui.lock:SetFrameLevel(level + 1)

    if plate.grip then plate.grip:Raise(strata, level) end

    local width = tracker:GetWidth() or 0
    width = width > 60 and (width + PAD_LEFT + PAD_RIGHT) or PANEL_MIN_WIDTH

    local height = HEADER_HEIGHT
    if contentBottom then
        height = contentBottom + FOOTER_TOP + FOOTER_HEIGHT + PAD_BOTTOM
    end

    plate:ClearAllPoints()
    plate:SetPoint("TOPLEFT", tracker, "TOPLEFT", -PAD_LEFT, 0)
    plate:SetWidth(width)
    plate:SetHeight(math.max(HEADER_HEIGHT, height))

    return width
end

local function LayoutHeader(data)
    ui.lockIcon:SetShape(ns.IsLocked() and "locked" or "unlocked")

    ui.lock:ClearAllPoints()
    ui.lock:SetPoint("LEFT", plate, "TOPLEFT", HEADER_PAD_X, -HEADER_HEIGHT / 2)

    -- Shortened at the point of drawing, not in Read: data.dungeon stays the
    -- string the game gave so /hp dungeon can still report it, and the table it
    -- is shortened against is the Mythic+ panel's, so one dungeon has one name
    -- across both panels.
    local name = data.dungeon
    if ns.Mplus and ns.Mplus.ShortName then name = ns.Mplus.ShortName(name) end
    ui.dungeon:SetText(name or "Dungeon")
    ui.dungeon:ClearAllPoints()
    ui.dungeon:SetPoint("LEFT", ui.lock, "RIGHT", HEADER_GAP, 0)
    ui.dungeon:Show()

    if data.difficultyLabel then
        ui.difficulty:SetText("(" .. data.difficultyLabel .. ")")
        ui.difficulty:ClearAllPoints()
        ui.difficulty:SetPoint("LEFT", ui.dungeon, "RIGHT", DIFFICULTY_GAP, -1)
        ui.difficulty:Show()
    else
        ui.difficulty:Hide()
    end
end

-- The objective rows, top down from under the header. Returns how far down the
-- plate the last one reached, in pixels from the plate's top edge, so the plate
-- can be sized from what was actually drawn.
local function LayoutRows(list, bossName)
    local font   = ns.GetFontFile()
    local bottom = HEADER_HEIGHT
    local left   = HEADER_PAD_X + ROW_INDENT

    for i = 1, #list do
        local entry = list[i]
        local row   = GetRow(i)
        if not row then break end

        -- The first objective is the panel's headline and is sized like one,
        -- which is the step the Mythic+ panel's required boss takes over the
        -- rows under it.
        local size   = ns.GetFontSize(i == 1 and PRIMARY_DELTA or ROW_DELTA, "mplusBody")
        local height = math.max(ROW_MIN_HEIGHT, math.ceil(size * ROW_LEADING))
        local top    = (i == 1) and (bottom + ROWS_TOP) or bottom
        local middle = -(top + height / 2)

        row.check:Hide()
        row.ring:Hide()

        local indicator
        if entry.done then
            local cr, cg, cb = ns.HexToRGB(ns.db.text.done)
            row.label:SetTextColor(cr, cg, cb, 1)
            row.check:SetColor(cr, cg, cb, 1)
            indicator = row.check
        else
            local mr, mg, mb = ns.HexToRGB(ns.PALETTE.muted)
            row.label:SetTextColor(mr, mg, mb, 1)
            local hr, hg, hb = ns.HexToRGB(ns.PALETTE.hairline)
            row.ring:SetColor(hr, hg, hb, 0.18)
            indicator = row.ring
        end

        indicator:ClearAllPoints()
        indicator:SetPoint("LEFT", plate, "TOPLEFT", left, middle)
        indicator:Show()

        row.label:SetFont(font, size)
        row.label:SetText(ShortLabel(entry.text, bossName))
        ns.ApplyTextShadow(row.label, "mplus")
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", indicator, "RIGHT", ROW_LABEL_GAP, 0)
        row.label:Show()

        -- A count only where there is something to count.
        --
        -- Every boss objective is 0/1 or 1/1, and the indicator beside it
        -- already says which - the Mythic+ panel drops the counter on its boss
        -- rows for exactly that reason. A row that asks for more than one of
        -- something is the case where the number is the objective, so that one
        -- keeps it.
        if entry.maximum and entry.maximum > 1 then
            local nr, ng, nb = ns.HexToRGB(ns.PALETTE.count)
            row.count:SetFont(font, ns.GetFontSize(COUNT_DELTA, "mplusBody"))
            row.count:SetTextColor(nr, ng, nb, 1)
            row.count:SetText(string.format("%d/%d", entry.progress or 0, entry.maximum))
            ns.ApplyTextShadow(row.count, "mplus")
            row.count:ClearAllPoints()
            row.count:SetPoint("RIGHT", plate, "TOPRIGHT", -HEADER_PAD_X, middle)
            row.count:Show()

            -- The label stops where the count starts, so a long objective is
            -- truncated by the client rather than drawn through the number.
            row.label:SetPoint("RIGHT", row.count, "LEFT", -ROW_COUNT_GAP, 0)
        else
            row.count:Hide()
            -- Still bounded, just by the panel instead. Without this a long
            -- boss name draws straight out past the right edge: heroPanel owns
            -- this row, so nothing else is going to stop it.
            row.label:SetPoint("RIGHT", plate, "TOPRIGHT", -HEADER_PAD_X, middle)
        end

        bottom = top + height
    end

    HideRowsFrom(#list + 1)
    return bottom
end

-- The rule and the mark, or neither.
--
-- With no rows to draw - a collapsed tracker, or one that has not been given an
-- objective yet - the panel is a header bar and nothing else. A rule and a
-- signature under an empty header is chrome saying there is nothing to say, and
-- it is exactly what a collapsed tracker is folded away to avoid.
local function LayoutFooter(show)
    if not show then
        ui.rule:Hide()
        ui.mark:Hide()
        return
    end

    ui.rule:ClearAllPoints()
    ui.rule:SetPoint("BOTTOMLEFT", plate, "BOTTOMLEFT", HEADER_PAD_X, PAD_BOTTOM + FOOTER_HEIGHT)
    ui.rule:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -HEADER_PAD_X, PAD_BOTTOM + FOOTER_HEIGHT)
    ui.rule:SetHeight(1)
    ui.rule:Show()

    ui.mark:ClearAllPoints()
    ui.mark:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -HEADER_PAD_X, PAD_BOTTOM)
    ui.mark:Show()
end

--------------------------------------------------------------------------------
-- Keeping the styling on
--
-- Ascension rewrites an objective row whenever it changes - SetObjective,
-- SetProgress and SetLabel all run on a kill - and this panel is drawn from
-- what those rows say. It only redraws on an event, so a row that changed
-- without one would leave a dead boss showing as pending for the rest of the
-- run.
--
-- So every row the panel reads is hooked, once, and any change queues a
-- refresh. hooksecurefunc rather than a wrapper, because these are the game's
-- own frames; the coalescing in Refresh means a burst still costs one pass.
--------------------------------------------------------------------------------

local hookedRows = {}

local function HookRow(row)
    if not row or hookedRows[row] then return end
    hookedRows[row] = true

    for _, method in ipairs({ "SetObjective", "SetProgress", "SetLabel" }) do
        if type(row[method]) == "function" then
            pcall(hooksecurefunc, row, method, function()
                if dungeon.enabled then Refresh("row " .. method) end
            end)
        end
    end
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local function DoRedraw()
    if not dungeon.enabled or not plate then return end

    local tracker = ns.GetTrackerFrame("dungeon")
    if not tracker then return end

    if preview then
        -- A real dungeon wins, always. Standing the preview down here rather
        -- than off an event means it cannot be missed: whatever put the tracker
        -- on screen, the next draw is the one that notices.
        if tracker:IsVisible() then
            preview = false
            SyncPreviewMouse()
            ns.Print("Dungeon placement preview off - the dungeon tracker is up.")
        else
            DrawPreview(tracker)
            return
        end
    end

    if not tracker:IsVisible() then
        plate:Hide()
        return
    end

    local data = dungeon.Read()
    if not data then return end

    FadeTrackerChrome(tracker, data.objectives)
    for i = 1, #data.objectives do HookRow(data.objectives[i].frame) end

    LayoutPlate(tracker, nil)
    plate:Show()

    LayoutHeader(data)
    local drawn         = #data.objectives
    local contentBottom = LayoutRows(data.objectives, data.bossName)
    LayoutPlate(tracker, drawn > 0 and contentBottom or nil)
    LayoutFooter(drawn > 0)

    ns.Debug("dungeon panel refreshed (%d objective row(s)).", drawn)
end

function Refresh(reason)
    if queued then return end
    queued = true
    ns.After(0, function()
        queued = false
        DoRedraw()
        ns.Debug("dungeon refreshed (%s).", tostring(reason))
    end)
end
dungeon.Refresh = Refresh

--------------------------------------------------------------------------------
-- The preview draw
--
-- Sample data chosen to exercise what is hard to judge on an empty panel: a
-- dungeon whose name the short-name table has something to do with, a
-- difficulty that is not the default, and one objective in each state.
--------------------------------------------------------------------------------

local function PreviewData()
    return {
        dungeon         = "Blackrock Depths",
        difficulty      = 3,
        difficultyLabel = DIFFICULTY_LABEL[3],
        objectives = {
            { text = "Emperor Dagran Thaurissan", done = false, progress = 0, maximum = 1 },
            { text = "Golem Lord Argelmach",      done = true,  progress = 1, maximum = 1 },
        },
    }
end

function DrawPreview(tracker)
    local data = PreviewData()

    -- Nothing of Ascension's is touched, read, faded or restored in here. The
    -- panel is drawn over whatever the last real draw left, which costs nothing
    -- and avoids the trap Mplus.lua documents: restoring hidden art from a
    -- preview draw puts a region back for one frame, the re-hide hook takes it
    -- away again, and the record of "this was shown" is lost in between.
    LayoutPlate(tracker, nil)
    plate:Show()

    LayoutHeader(data)
    local contentBottom = LayoutRows(data.objectives, data.bossName)
    LayoutPlate(tracker, contentBottom)
    LayoutFooter(true)
end

--------------------------------------------------------------------------------
-- Moving the preview
--
-- The panel is normally moved by dragging the tracker: Ascension's frame is the
-- mover, it is unprotected, and Move.lua owns saving where it ended up. None of
-- that works while the tracker is hidden - a frame nobody can see is a frame
-- nobody can grab - so in preview the plate takes the mouse instead and hands
-- the result back to Move.lua rather than working out a position itself.
--
-- Nothing here computes a coordinate. The plate carries the tracker's scale,
-- and hand-rolled arithmetic between two scaled frames is how a panel ends up
-- half a screen away at 0.8 scale.
--------------------------------------------------------------------------------

function SyncPreviewMouse()
    if not plate then return end

    local wanted = preview and not ns.IsLocked()
    plate:EnableMouse(wanted and true or false)

    if not wanted and plate.previewMoving then
        plate.previewMoving = nil
        pcall(plate.StopMovingOrSizing, plate)
    end
end

local function PreviewOnDragStart(self)
    if not preview then return end

    if ns.IsLocked() then
        ns.Warn("the dungeon panel is locked. Click the padlock in its header, "
            .. "or |cFFC2C6D8/hp unlock|r.")
        return
    end

    self:StartMoving()
    self.previewMoving = true
end

local function PreviewOnDragStop(self)
    if not self.previewMoving then return end
    self.previewMoving = nil
    pcall(self.StopMovingOrSizing, self)

    local tracker = ns.GetTrackerFrame("dungeon")
    if not tracker then return end

    -- Pin the plate to UIParent first: the next line anchors the tracker to the
    -- plate, and a plate still anchored to the tracker would make that pair
    -- circular and the client would refuse the point.
    local x, y = ns.GetUIOffsets(self)
    if x then ns.ApplyUIOffsets(self, x, y) end

    -- The tracker hangs off the plate for exactly two statements and is then
    -- put straight back onto UIParent. The anchor is how the PAD_LEFT offset is
    -- resolved without arithmetic, and putting it back immediately is not
    -- tidiness: Move.lua decides who owns a tracker partly by what it is
    -- anchored to, so a tracker left hanging off heroPanel's own plate makes
    -- heroPanel conclude it has lost the argument with itself.
    tracker:ClearAllPoints()
    tracker:SetPoint("TOPLEFT", self, "TOPLEFT", PAD_LEFT, 0)

    local tx, ty = ns.GetUIOffsets(tracker)
    if tx then ns.ApplyUIOffsets(tracker, tx, ty) end

    ns.SavePosition("dungeon")
    Refresh("preview moved")
end

function dungeon.SetPreview(on)
    on = on and true or false
    if on == preview then return preview end

    if on and not dungeon.enabled then
        ns.Warn("the dungeon skin is off, so there is no panel to place. "
            .. "Turn it on first.")
        return false
    end

    preview = on
    SyncPreviewMouse()

    if not preview and plate then plate:Hide() end
    Refresh(on and "preview on" or "preview off")

    ns.Print("Dungeon placement preview %s.%s",
        on and "|cFF79C68Don|r" or "|cFF8B8FA3off|r",
        on and (ns.IsLocked()
                    and " Unlock the trackers to drag it."
                    or  " Drag the panel to place it.")
            or "")
    return preview
end

--------------------------------------------------------------------------------
-- Hooks
--
-- The tracker's scripts go through ns.HookScript so nothing Ascension installed
-- is replaced. Its events are registered defensively: CURRENT_LFG_DUNGEON_ID_CHANGED
-- is Ascension's own, and RegisterEvent on an event a client does not have is
-- not something to find out about through a Lua error at login.
--------------------------------------------------------------------------------

local DUNGEON_EVENTS = {
    "CURRENT_LFG_DUNGEON_ID_CHANGED",
    "ZONE_CHANGED_NEW_AREA",
}

local function InstallHooks(tracker)
    if hooked then return end
    hooked = true

    ns.HookScript(tracker, "OnShow", function() Refresh("shown") end)
    ns.HookScript(tracker, "OnHide", function()
        if plate then plate:Hide() end
    end)
    ns.HookScript(tracker, "OnSizeChanged", function() Refresh("resized") end)

    for i = 1, #DUNGEON_EVENTS do
        local event = DUNGEON_EVENTS[i]
        local ok = pcall(function() ns:On(event, function() Refresh(event) end) end)
        if not ok then ns.Debug("client has no %s event.", event) end
    end

    ui.lock:SetScript("OnClick", function()
        ns:ToggleLock("dungeon")
    end)
    ui.lock:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ns.IsLocked() and "Unlock to move the dungeon tracker"
                                          or "Lock the dungeon tracker", 1, 1, 1)
        GameTooltip:Show()
    end)
    ui.lock:SetScript("OnLeave", function() GameTooltip:Hide() end)

    plate:SetScript("OnDragStart", PreviewOnDragStart)
    plate:SetScript("OnDragStop", PreviewOnDragStop)

    ns:On("HEROPANEL_LOCK_CHANGED", function()
        SyncPreviewMouse()
        if preview then Refresh("lock changed") end
    end)

    ns.Debug("dungeon hooks installed.")
end

--------------------------------------------------------------------------------
-- Enable / disable
--------------------------------------------------------------------------------

function dungeon.Enable()
    if not ns.db then return false, "SavedVariables are not loaded yet" end

    local tracker = ns.GetTrackerFrame("dungeon")
    if not tracker then return false, "the dungeon tracker has not been found" end

    if not plate then
        BuildPlate(tracker)
        InstallHooks(tracker)
        ns.Debug("dungeon panel built.")
    end

    dungeon.enabled = true
    StyleStatic()

    Refresh("enabled")
    return true
end

function dungeon.Disable()
    dungeon.enabled = false

    -- The preview goes with it. It is a view of this panel, and a panel that
    -- has been switched off has no view to leave on screen.
    preview = false
    SyncPreviewMouse()

    RestoreChrome()
    HideRowsFrom(1)
    if plate then plate:Hide() end
    return true
end

function dungeon.SetEnabled(enabled)
    if enabled then
        if not dungeon.Enable() then
            ns.Debug("dungeon skin enabled but the tracker is not available yet.")
        end
    else
        dungeon.Disable()
    end
end

--------------------------------------------------------------------------------
-- Status
--------------------------------------------------------------------------------

function dungeon.PrintStatus()
    if not ns.db then return end

    ns.Print("  Dungeon panel is |cFFC2C6D8%s|r", dungeon.enabled and "on" or "off")

    if not plate then
        ns.Print("    |cFF8B8FA3panel not built|r - the dungeon tracker was not available")
        return
    end

    ns.Print("    panel %s, %.0f x %.0f",
        plate:IsVisible() and "|cFF79C68Dvisible|r" or "|cFFFFAA00not visible|r",
        plate:GetWidth() or 0, plate:GetHeight() or 0)

    local data = lastRead
    if not data then
        ns.Print("    |cFF8B8FA3nothing read yet|r")
        return
    end

    ns.Print("    %s (%s), %.0f objective row(s)",
        tostring(data.dungeon or "?"),
        tostring(data.difficultyLabel or "?"),
        #(data.objectives or {}))
end

--------------------------------------------------------------------------------
-- Dump
--
-- /hp dungeon. What the panel resolved and where each value came from, which is
-- the first question when a field comes out blank: a tracker that is not shown
-- and a name the client would not answer for look identical on screen.
--------------------------------------------------------------------------------

function dungeon.Dump()
    local tracker = ns.GetTrackerFrame("dungeon")
    ns.Print("Dungeon dump")

    if not tracker then
        ns.Print("  |cFFFFAA00tracker not found|r - this client may have no LFGObjectiveTracker")
        return
    end

    ns.Print("  tracker |cFFC2C6D8%s|r, panel |cFFC2C6D8%s|r%s",
        tracker:IsVisible() and "visible" or "hidden",
        dungeon.enabled and "on" or "off",
        preview and " |cFF8B8FA3(placement preview)|r" or "")

    local data = dungeon.Read()
    if not data then return end

    ns.Print("  dungeon: |cFFC2C6D8%s|r |cFF8B8FA3(%s)|r",
        tostring(data.dungeon), tostring(data.dungeonFrom or "nothing answered"))
    ns.Print("  difficulty: |cFFC2C6D8%s|r (%s) |cFF8B8FA3(%s)|r",
        tostring(data.difficultyLabel or "?"), tostring(data.difficulty or "?"),
        tostring(data.difficultyFrom or "nothing answered"))
    ns.Print("  boss: |cFFC2C6D8%s|r, %s |cFF8B8FA3(GetEncounterInfo)|r",
        tostring(data.bossName or "?"),
        data.bossDead == nil and "unknown"
            or (data.bossDead and "|cFF79C68Ddead|r" or "|cFF8B8FA3alive|r"))

    for i = 1, #data.objectives do
        local entry = data.objectives[i]
        ns.Print("    objective %d |cFFC2C6D8%s|r: %s %s", i, entry.text,
            entry.done and "|cFF79C68Ddone|r" or "|cFF8B8FA3open|r",
            (entry.progress and entry.maximum)
                and string.format("(%d/%d)", entry.progress, entry.maximum) or "")
    end
    if #data.objectives == 0 then
        ns.Print("    |cFFFFAA00no objective rows|r - the objective block is empty or hidden")
    end
end

--------------------------------------------------------------------------------
-- Wiring
--
-- LFGObjectiveTracker is FrameXML rather than an addon, so unlike the Mythic+
-- tracker it is normally there at ADDON_LOADED. The panel is still built off
-- HEROPANEL_TRACKER_FOUND rather than assuming that, because Trackers.lua polls
-- for both and one discovery point is one thing to get right.
--------------------------------------------------------------------------------

ns:On("HEROPANEL_TRACKER_FOUND", function(key)
    if key ~= "dungeon" then return end
    if not ns.db then ns.InitDB() end
    if ns.SkinEnabled("dungeon") then dungeon.Enable() end
end)

ns:On("HEROPANEL_LOCK_CHANGED", function()
    if dungeon.enabled and plate then
        ui.lockIcon:SetShape(ns.IsLocked() and "locked" or "unlocked")
    end
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    if dungeon.enabled then Refresh("entering world") end
end)
