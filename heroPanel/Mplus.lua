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
-- From the design handoff. This panel's text is drawn at three absolute sizes -
-- mplusHeader, mplusTimer and mplusBody - with the design's small steps within
-- each role kept in the code as deltas against it.
--------------------------------------------------------------------------------

local PANEL_MIN_WIDTH = 300
local PAD_LEFT        = 14
local PAD_RIGHT       = 14
local PAD_BOTTOM      = 11
local HEADER_PAD_X    = 13
local HEADER_HEIGHT   = 30    -- the name row alone, not the whole header block
local HEADER_GAP      = 7     -- lock -> dungeon name
local KEY_GAP         = 3     -- dungeon name -> keystone level, deliberately tighter

-- The affixes have their own row under the dungeon name.
--
-- Sharing the name row, anchored right-to-left from its top-right corner, came
-- first: this client runs up to eight affixes, and at 20px eight of them are
-- 181px of a 262px content width, so they drove straight through the dungeon
-- name whatever it was shortened to. A row of their own removes the contest
-- rather than tuning it.
--
-- Left to right on the panel's own content column, so the first affix is
-- leftmost and the row starts where the timer glyph, the bars and the enemy
-- forces row start.
local AFFIX_SIZE      = 20
local AFFIX_GAP       = 3
local AFFIX_ROW_TOP   = 4     -- gap between the name row and the affix row
local AFFIX_MAX       = 8     -- what this client can put on a key

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

-- The header's padlock. Its own constant rather than borrowing BOSS_GLYPH,
-- which it did: the two are unrelated and sizing one moved the other.
local LOCK_GLYPH_SIZE = 15

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

-- Font steps inside the Mythic+ body role, as deltas rather than sizes: the
-- role's size is the player's, and these are the proportions the design puts on
-- one string relative to the rest of it.
--
-- The total is four points over what it was. "/ 30:00" is the run's whole
-- budget, which is the number the clock beside it is read *against*, and at a
-- point under the body text it read as a footnote to the clock rather than as
-- the other half of the same fact. Its slash goes up with it, because the
-- separator is part of that string rather than a piece of punctuation between
-- two of them.
--
-- The threshold pair is at the body size exactly. It was a point under, which
-- is the step the enemy-forces row takes, but that row is a label over a bar
-- and this one is the panel's second-most-read number - and the options
-- window's own sublabel promises the body size governs the chest tiers, so it
-- may as well govern them literally.
local TOTAL_DELTA     = 3
local TIER_DELTA      = 0

local PULSE_PERIOD    = 1.6
local PULSE_MIN       = 0.35
local TICK_INTERVAL   = 0.25  -- how often the clock, bar and tier are redrawn

--------------------------------------------------------------------------------
-- The gap budget
--
-- Everything above the first boss row is heroPanel's - header, affix row, timer
-- row, timer bar, enemy forces - and the boss row itself is Ascension's, drawn
-- where Ascension put it. heroPanel does not move objective rows, so the space
-- between the top of the tracker and that row is a fixed budget, and on a
-- compact tracker heroPanel's block is taller than it.
--
-- It overflowed silently once: LayoutForces gave up on sitting above the boss row
-- and fell back to under the timer bar, which put heroPanel's own enemy-forces
-- bar straight through a boss name. The affix row tipped it over, but nothing was
-- checking, so the overflow was always one design change away.
--
-- So the gaps give. Each one has a floor, pixels are taken from them in this
-- order until the bar clears the row again, and a tracker with room keeps every
-- gap at its design value - the squeeze only exists on the trackers that need
-- it. Every gap here is worth exactly one pixel of clearance, the forces gap
-- included: shrinking it lifts the whole block by a pixel and gives a pixel
-- back to the row below in the same move.
--
-- What it squeezes *to* is FORCES_MIN_CLEAR, not the design gap. Asking for the
-- design gap back would tighten panels that are merely snug rather than broken,
-- which is spending the budget where there is no bug.
--
-- If the floors are not enough the block still overruns, by however much is
-- left. That is reported rather than hidden - see the debug line in Redraw.
--------------------------------------------------------------------------------

local FORCES_MIN_CLEAR = 7    -- least gap the squeeze will settle for

local GAP_BUDGET = {
    { key = "forces",   default = FORCES_TOP,    floor = 7 },
    { key = "timerRow", default = TIMER_ROW_TOP, floor = 6 },
    { key = "bar",      default = BAR_TOP,       floor = 5 },
    { key = "affixRow", default = AFFIX_ROW_TOP, floor = 2 },
}

-- Resolved once per draw. Read by every Layout function instead of the
-- constants above, which stay as the design values the budget starts from.
local gap = {}

local function ResetGaps()
    for i = 1, #GAP_BUDGET do
        local entry = GAP_BUDGET[i]
        gap[entry.key] = entry.default
    end
end
ResetGaps()

-- Takes `wanted` pixels out of the gaps and returns whatever it could not find.
-- Zero or less asks for nothing and puts every gap back to its design value.
local function SqueezeGaps(wanted)
    ResetGaps()
    if not wanted or wanted <= 0 then return 0 end

    for i = 1, #GAP_BUDGET do
        local entry = GAP_BUDGET[i]
        local give  = math.min(entry.default - entry.floor, wanted)
        if give > 0 then
            gap[entry.key] = entry.default - give
            wanted = wanted - give
            if wanted <= 0 then return 0 end
        end
    end

    return wanted
end

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
-- SHORT DUNGEON NAMES
--
-- The header draws the dungeon name between the padlock and the affix icons,
-- and nothing arbitrates that gap: the name is anchored left and grows right,
-- the affixes are anchored right and grow left, so a long name runs underneath
-- them. At the design's 288px panel and the 13px header default the name has
-- about 158px to live in - roughly 20 characters in a font of Friz Quadrata's
-- width - and "Blackrock Depths: Upper City" is half as long again.
--
-- So the long ones are shortened here. Every dungeon is listed, including the
-- ones whose name is already short enough, so that the whole set is in one
-- place if this ever becomes something the player can edit.
--
-- A dungeon with wings reads "dungeon - wing", with the same " - " separator
-- every time: "SM - Graveyard", "DM - East", "BRD - Upper City". A dungeon with
-- no wings is just its own name. Mixing the two - "SM Graveyard" beside
-- "DM - East" - reads as two schemes rather than one, so the harness pins it.
--
-- Each row is { short name, full name, alias, alias, ... }. Matching is done on
-- a normalised form - lowercased, with everything that is not a letter or digit
-- removed - so "SM: Graveyard", "SM - Graveyard" and "Scarlet Monastery
-- Graveyard" all land on the same row and the separator Ascension happens to
-- use does not matter. A name that matches nothing is drawn as the game gave
-- it, which is what the panel did before this existed.
--
-- The aliases are guesses at what this client's GetLFGDungeonInfo returns, and
-- a wrong guess fails silently - the full name simply keeps being drawn. That
-- is why `data.dungeon` below stays raw and only the *drawn* string is
-- shortened: `/hp mplus` reports the name the game actually gave, so a row that
-- never fires can be seen and corrected.
--------------------------------------------------------------------------------

local SHORT_NAMES = {
    { "Ragefire Chasm", "Ragefire Chasm" },
    { "Deadmines",      "Deadmines", "The Deadmines" },
    { "Stockades",      "Stormwind Stockades", "The Stockade", "The Stockades" },

    { "WC",         "Wailing Caverns", "The Wailing Caverns" },
    { "WC - Crag",  "Wailing Caverns - Crag of the Everliving",
                    "WC Crag of the Everliving", "Wailing Caverns Crag" },

    { "SM - Graveyard", "Scarlet Monastery - Graveyard", "SM Graveyard" },
    { "SM - Library",   "Scarlet Monastery - Library",   "SM Library" },
    { "SM - Armory",    "Scarlet Monastery - Armory",    "SM Armory" },
    { "SM - Cathedral", "Scarlet Monastery - Cathedral", "SM Cathedral" },

    { "Razorfen Kraul", "Razorfen Kraul" },
    { "Razorfen Downs", "Razorfen Downs" },
    { "Gnomeregan",     "Gnomeregan" },
    { "Uldaman",        "Uldaman" },

    { "Mara",            "Maraudon" },
    { "Mara - Purple",   "Maraudon - Purple Crystals", "Mara Purple Crystals" },
    { "Mara - Orange",   "Maraudon - Orange Crystals", "Mara Orange Crystals" },
    -- Princess Theradras is behind the Pristine Waters entrance, and she is
    -- what the wing gets called in a group.
    { "Mara - Princess", "Maraudon - Pristine Waters", "Mara Pristine Waters" },

    { "Zul'Farrak",     "Zul'Farrak" },
    { "Sunken Temple",  "Sunken Temple", "The Temple of Atal'Hakkar" },

    { "Scholo",         "Scholomance" },
    { "Scholo - Lower", "Scholomance - Lower", "Scholomance Lower" },
    { "Scholo - Upper", "Scholomance - Upper", "Scholomance Upper" },

    { "LBRS",           "Lower Blackrock Spire" },
    { "UBRS",           "Upper Blackrock Spire" },

    { "Strat",          "Stratholme" },
    { "Strat - Live",   "Stratholme - Main Gate",    "Stratholme Main Gate" },
    { "Strat - Undead", "Stratholme - Service Gate", "Stratholme Service Gate" },

    { "DM",             "Dire Maul" },
    { "DM - East",      "Dire Maul - East",  "Dire Maul East" },
    { "DM - West",      "Dire Maul - West",  "Dire Maul West" },
    { "DM - North",     "Dire Maul - North", "Dire Maul North" },

    { "BRD",            "Blackrock Depths" },
    { "BRD - Prison",     "Blackrock Depths - Prison",     "Blackrock Depths Prison" },
    { "BRD - Upper City", "Blackrock Depths - Upper City", "Blackrock Depths Upper City" },
}

local function NormaliseName(name)
    return (string.gsub(string.lower(tostring(name or "")), "[^%a%d]", ""))
end

-- Built once from the rows above rather than written out twice.
local shortByName = {}
for i = 1, #SHORT_NAMES do
    local row = SHORT_NAMES[i]
    for alias = 2, #row do shortByName[NormaliseName(row[alias])] = row[1] end
end

-- The name as the header should draw it. Unknown names come back untouched.
function mplus.ShortName(name)
    if not name or name == "" then return name end
    return shortByName[NormaliseName(name)] or name
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local plate                     -- the panel; everything else hangs off it
local ui       = {}             -- heroPanel's own widgets
local faded    = {}             -- region -> original alpha, for Disable()
local original = {}             -- FontString -> font/colour, for Disable()
local rows     = {}             -- pooled boss-row decorations
local affixes  = {}             -- pooled affix icons
-- How much the affix row adds to the header block, recomputed by LayoutAffixes
-- on every draw. Zero when there are no affixes to draw, so a panel without
-- them is exactly as tall as it was before the row existed.
local affixRowHeight = 0
local decorated = {}            -- FontString -> { raw, shown }, text we rewrote
local lockMouse = {}            -- button -> original mouse state, for Disable()
local hiddenArt = {}            -- region -> original shown state, for Disable()
local hooked   = false
local queued   = false
-- Forward declaration: the row hooks installed during a draw have to be able
-- to queue the next one, and they are set up well above where it is defined.
local Refresh
local ticker
local pulse    = 0
local lastRead                  -- what the last refresh resolved, for /hp mplus
-- The size the threshold pair was last drawn at. See ApplyTierFont, which is
-- the only thing that writes it; StyleStatic clears it.
local tierSize

--------------------------------------------------------------------------------
-- Placement preview
--
-- The panel only exists during a keystone run, which is the worst possible time
-- to be positioning it: the tracker is hidden the rest of the week, so the
-- first chance anybody gets to see where they put it is thirty seconds into a
-- timed key, with a pull incoming.
--
-- Preview draws the panel over sample data so it can be placed and styled from
-- a capital city.
--
-- It is not a second panel. It is this panel, drawn by the same layout code
-- against a made-up read - so what is on screen in preview is what will be on
-- screen in a key, and the two cannot drift apart. What it leaves out is the
-- half of the panel that is not heroPanel's to draw: the required boss row and
-- the extra-bosses heading are Ascension's own font strings, restyled where the
-- tracker put them, and with the tracker hidden there is nothing there to
-- restyle. Preview draws its boss list out of heroPanel's own sub-row pool
-- instead, which is the same art the extra bosses always use.
--
-- Session only, deliberately. A preview that survived a reload would be a panel
-- showing a dungeon you are not in, with no obvious cause, and the first
-- thought would be that the addon is broken rather than that a switch is on. It
-- also stands down the moment a real key starts - see Redraw.
--------------------------------------------------------------------------------

local preview = false

-- Forward declarations, for the same reason Refresh has one: Redraw is the
-- thing that decides a preview is wanted and it is defined a long way above the
-- code that draws one. Without these, the names inside Redraw would resolve to
-- globals rather than to these locals, and the preview would silently be nil.
local DrawPreview
local SyncPreviewMouse

function mplus.IsPreview() return preview end

function mplus.GetPlate() return plate end

-- Whether a keystone run is under way, as of the last refresh.
--
-- Read off the cached result rather than by calling mplus.Read again: Read
-- walks the tracker's frames and this is asked from the quest tracker's
-- auto-hide check, which runs on every combat transition. The cached answer is
-- at most one refresh stale, and the Mythic+ panel refreshes on the events that
-- change it.
function mplus.IsActive()
    return (lastRead and lastRead.active) and true or false
end

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

    -- The pair the tracker itself tests, with its own right-aligned counter as
    -- the fallback. That counter is the same number in text form - "1/6" - and
    -- reading it matters for one row in particular: the extra-bosses heading is
    -- the row whose count is the whole of what it has to say, and a build that
    -- draws the counter without setting the pair would leave that row saying
    -- nothing at all once heroPanel has faded the art.
    local progress, maximum = tonumber(row.progress), tonumber(row.progressMax)
    if not (progress and maximum) then
        local counter = row.Counter and row.Counter.GetText and row.Counter:GetText()
        local have, need = string.match(tostring(counter or ""), "(%d+)%s*/%s*(%d+)")
        if have then progress, maximum = tonumber(have), tonumber(need) end
    end

    local done = false
    if progress and maximum and maximum > 0 then
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
        -- It is the heading of that block whichever way the chevron points, and
        -- is only *drawn* as one while its children are on screen. Keeping the
        -- two apart is what carries the count into the collapsed state, where
        -- the row stands in for children nobody can see - see SetHeadingText.
        heading.heading = true
        heading.group   = #subRows > 0
        table.insert(found, heading)
    end
    for i = 1, #subRows do
        subRows[i].sub = true
        table.insert(found, subRows[i])
    end

    -- Champions. Collected but not drawn - see the champions note in Redraw.
    -- It is read so the row can be faded like every other piece of the tracker
    -- heroPanel is standing in front of, and marked so Redraw can tell it from
    -- an additional boss, which is what its row looks like on screen and is not.
    local champions = Add(block.Champions)
    if champions then champions.champions = true end

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

    -- Champions, and the one place in this file where the API is not merely
    -- preferred to the row but is the only thing that can answer.
    --
    -- On this client the tracker draws the champions row whether or not the
    -- objective is required. A +15 Stratholme carried "Defeat Champions" for
    -- the whole run and completed timed without ever finishing it, while
    -- GetActiveKeystoneChampions reported championsRequired = 0 throughout -
    -- and every recorded run on this account says the same, at every key level
    -- from 1 to 15.
    --
    -- So the row being on screen does not mean the party owes anything, and the
    -- row's own progressMax cannot be read as a requirement either. Only the
    -- API separates "displayed" from "required".
    --
    -- Nothing on the panel draws these at the moment - see the champions note
    -- in Redraw. They are read anyway, and reported by /hp dump, because the
    -- open question is where a champion's slice of enemy forces belongs, and
    -- that question needs the numbers to answer it.
    local champ = CallApi("GetActiveKeystoneChampions")
    if type(champ) == "table" then
        data.championsDead     = tonumber(champ.championsDead)
        data.championsRequired = tonumber(champ.championsRequired)
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

    -- Only when the API said nothing at all. A championsRequired of 0 is an
    -- answer - "drawn, not required" - and must not be overwritten by the row.
    if not data.championsRequired then
        local champions = tracker.ObjectiveBlock and tracker.ObjectiveBlock.Champions
        if champions then
            data.championsDead     = tonumber(champions.progress)
            data.championsRequired = tonumber(champions.progressMax)
        end
    end

    -- A keystone that reports no time at all is not running, whatever
    -- IsKeystoneActive said - the panel has nothing to draw a clock from.
    if not data.active and data.timeLeft and data.totalTime then data.active = true end

    -- The quest tracker can be set to hide itself for the length of a key, so
    -- the moment a run starts or ends is a moment it has to be told about.
    -- Fired on the transition rather than on every read, because this runs once
    -- per refresh and the refresh runs on a ticker while a key is up.
    local wasActive = lastRead and lastRead.active
    lastRead = data
    if (wasActive and true or false) ~= data.active then
        if ns.Skin and ns.Skin.RefreshAutoHide then pcall(ns.Skin.RefreshAutoHide) end
        -- The quest tracker can also be set to follow this panel rather than
        -- disappear, and that anchor needs the same moment. Redraw announces it
        -- too, off the plate coming up - this is the case Redraw cannot cover,
        -- because with the Mythic+ skin switched off there is no plate to draw
        -- and the tracker hangs off Ascension's own frame instead.
        if ns.Skin and ns.Skin.RefreshQuestAnchor then
            pcall(ns.Skin.RefreshQuestAnchor, "keystone run started or ended")
        end
    end

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
--
-- 60% for +3 was tried here and reverted. The case for it was a wiki page
-- reading "within 60% ... three caches", which lines up with the one native
-- field that happens to land on 0.60 - but that field only gets there through
-- the (1 - PERCENT[n]) error above, off the +2 constant, and taking it at face
-- value means believing four other consumers are wrong instead of one. The
-- completion banner, MythicPlusUtil.GetCompletionInfo, the bar's colour tiers
-- and PlusThreeNotch all read the constant straight, as this does.
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
--
-- The one exception is the enemy-forces row, whose art is hidden as well -
-- alpha alone cannot hold against the animation Ascension plays on it. The
-- reasoning is written out above ClearSubtree.
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

-- A status bar's fill is a texture the frame owns rather than one of its
-- regions, so GetRegions never returns it and a subtree walk goes straight past
-- it. Anything that answers GetStatusBarTexture gets asked for it by name.
local function FadeFill(bar, fade)
    if not bar or type(bar.GetStatusBarTexture) ~= "function" then return end
    local ok, fill = pcall(bar.GetStatusBarTexture, bar)
    if ok and fill then (fade or FadeRegion)(fill) end
end

-- A button's four state textures, which are its own rather than its regions and
-- so are missed by exactly the same walk the status-bar fill is.
local BUTTON_TEXTURES = { "GetNormalTexture", "GetPushedTexture",
                          "GetHighlightTexture", "GetDisabledTexture" }

local function FadeButtonTextures(button, fade)
    for i = 1, #BUTTON_TEXTURES do
        local getter = button[BUTTON_TEXTURES[i]]
        if type(getter) == "function" then
            local ok, texture = pcall(getter, button)
            if ok and texture then (fade or FadeRegion)(texture) end
        end
    end
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
    FadeButtonTextures(frame)

    ns.WalkFrameTree(frame, function(object, info)
        if info.kind == "region" then
            FadeRegion(object)
        elseif info.objectType == "Button" then
            FadeButtonTextures(object)
        end
    end, { maxDepth = 4, includeRegions = true })
end
local FadeButton = FadeSubtree

-- The enemy-forces row, which needs more than alpha
--
-- Ascension animates that bar as trash dies: the fill runs up to its new value
-- and a glow runs across it. An animation owns the alpha of what it animates -
-- it writes the value every frame for as long as it plays - so the zero
-- FadeRegion set is simply gone for the length of the animation, and Ascension's
-- glow drew across the bottom of heroPanel's panel on every pull. Re-fading does
-- not help either: the next frame of the animation writes over that too.
--
-- So this one row is hidden as well as faded. Hiding is what the rest of this
-- file avoids, for the reason in the header - the tracker's layout reads back
-- what it laid out - but that objection is about frames, and this hides regions
-- only. A texture that is not shown does not draw whatever an animation does to
-- its alpha, and the row's own height, anchors and children are untouched, so
-- the tracker still measures it exactly as it did before.
--
-- Show is hooked to keep it that way: the animation's own scripts show the glow
-- again on the next kill, and there is no event heroPanel could hang a re-hide
-- off that lands before the frame it would be visible on. The hook is gated on
-- mplus.enabled, so Disable() hands the row straight back.
local function HideArt(region)
    if not region or type(region.Hide) ~= "function" then return end
    FadeRegion(region)

    if hiddenArt[region] == nil then
        local ok, shown = pcall(region.IsShown, region)
        hiddenArt[region] = (ok and shown) or false
        pcall(hooksecurefunc, region, "Show", function(self)
            if mplus.enabled then pcall(self.Hide, self) end
        end)
    end
    pcall(region.Hide, region)
end

-- Everything drawn anywhere beneath a frame, taken off the screen rather than
-- turned transparent. Frames are walked into but never hidden themselves.
local function ClearSubtree(frame)
    if not frame then return end

    FadeFill(frame, HideArt)
    FadeButtonTextures(frame, HideArt)

    -- The walk covers the row's own regions at depth zero, so there is no
    -- separate pass over them here.
    ns.WalkFrameTree(frame, function(object, info)
        if info.kind == "region" then
            HideArt(object)
        else
            FadeFill(object, HideArt)
            if info.objectType == "Button" then FadeButtonTextures(object, HideArt) end
        end
    end, { maxDepth = 4, includeRegions = true })
end

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
        FadeFill(main.Timer)
    end

    -- The enemy-forces row is redrawn too, so its art goes - cleared rather
    -- than faded, because that row animates and an animation writes alpha of
    -- its own. See ClearSubtree. The boss rows keep their text and lose only
    -- the icon heroPanel replaces.
    local block = tracker.ObjectiveBlock
    if block then
        if block.EnemyForces then ClearSubtree(block.EnemyForces) end

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

        local shadow = saved.shadow
        pcall(fontString.SetShadowColor, fontString,
            shadow and shadow[1] or 0, shadow and shadow[2] or 0,
            shadow and shadow[3] or 0, shadow and shadow[4] or 0)
        local offset = saved.shadowOffset
        pcall(fontString.SetShadowOffset, fontString,
            offset and offset[1] or 0, offset and offset[2] or 0)
    end
    wipe(original)
end

-- Remembered once. A pooled row that is reused keeps the font heroPanel gave
-- it, so re-reading after styling would record our own values as Ascension's.
--
-- The shadow is recorded with the rest, because heroPanel sets one on the boss
-- rows now. Handing the tracker back with heroPanel's outline still on it is
-- exactly the sort of leftover "/hp skin off restores everything" has to mean
-- the absence of.
local function Remember(fontString)
    if not fontString or original[fontString] then return end
    local path, size, flags = fontString:GetFont()
    local r, g, b, a = fontString:GetTextColor()
    local record = { path = path, size = size, flags = flags,
                     r = r, g = g, b = b, a = a,
                     alpha = fontString:GetAlpha() }

    if type(fontString.GetShadowColor) == "function" then
        local ok, sr, sg, sb, sa = pcall(fontString.GetShadowColor, fontString)
        if ok then record.shadow = { sr, sg, sb, sa } end
    end
    if type(fontString.GetShadowOffset) == "function" then
        local ok, ox, oy = pcall(fontString.GetShadowOffset, fontString)
        if ok then record.shadowOffset = { ox, oy } end
    end

    original[fontString] = record
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
    plate = CreateFrame("Frame", "HeroPanelMplusPlate", tracker:GetParent() or UIParent)
    plate:Hide()
    plate:SetWidth(PANEL_MIN_WIDTH)
    plate:SetHeight(HEADER_HEIGHT)

    -- Draggable, but not mouse-enabled. The plate only ever takes the mouse
    -- while the placement preview is up - see SyncPreviewMouse - because the
    -- panel sits one strata below the tracker precisely so it can never take a
    -- click the tracker wanted, and a permanently mouse-enabled plate would
    -- throw that away. The movable flag and the drag registration are harmless
    -- without the mouse and are set once here rather than toggled.
    plate:SetMovable(true)
    plate:SetClampedToScreen(true)
    plate:RegisterForDrag("LeftButton")

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
    -- The glyph is two points over what it was and the button grows with it.
    -- A padlock is read at a glance rather than looked at, and at 13 it was
    -- being read as a smudge in the corner of the header.
    ui.lock:SetWidth(LOCK_GLYPH_SIZE + 4)
    ui.lock:SetHeight(LOCK_GLYPH_SIZE + 4)
    -- Outlined, like the quest tracker's. This panel's background is the
    -- player's to turn down too, and a grey padlock over a lit floor is not a
    -- padlock.
    ui.lockIcon = ns.NewGlyph(ui.lock, LOCK_GLYPH_SIZE, true)
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

    -- The corner handle that scales this panel, hidden while the trackers are
    -- locked. Same widget as the quest tracker's, from Move.lua, so the two
    -- cannot end up behaving differently.
    plate.grip = ns.NewResizeGrip(plate, {
        label    = "Mythic+ tracker",
        deferred = true,
        visible  = function() return not ns.IsLocked() end,
        get      = function() return ns.db.frame.mplus.scale or 1 end,
        set      = function(scale) ns.SetScale("mplus", scale) end,
    })

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

-- Taken out of service: cleared, untooltipped and hidden.
--
-- The tooltip matters. A hidden frame gets no OnLeave, so a button that is
-- hidden while the cursor is on it leaves its tooltip on screen with nothing
-- under it to dismiss it.
local function HideAffix(button)
    if not button then return end
    button.affixID = nil

    if _G.GameTooltip and type(GameTooltip.IsOwned) == "function" then
        local ok, owned = pcall(GameTooltip.IsOwned, GameTooltip, button)
        if ok and owned then pcall(GameTooltip.Hide, GameTooltip) end
    end

    button:Hide()
end

-- Left to right along the affix row, under the dungeon name.
--
-- A button is only shown once its icon has actually loaded, which is the fix
-- for the invisible affixes. GetSpellInfo returning a texture path is not the
-- same as that path resolving to art: this client's custom affixes hand back
-- paths the client will not draw, and SetTexture does not complain. What was
-- left was a shown, mouse-enabled button with nothing in it - an invisible icon
-- that still answered the cursor with a tooltip.
--
-- ns.SetTextureFile is the addon's existing answer to "did that actually load",
-- and it substitutes ns.SOLID when nothing in the chain did. A button that ends
-- up on the substitute is not drawn at all, so it takes no space and no mouse.
local function LayoutAffixes(list)
    local shown = 0
    local count = math.min(#(list or {}), AFFIX_MAX)

    for i = 1, count do
        local affixID = tonumber(list[i])

        local path
        if affixID and type(_G.GetSpellInfo) == "function" then
            local ok, _, _, texture = pcall(_G.GetSpellInfo, affixID)
            if ok and type(texture) == "string" and texture ~= "" then path = texture end
        end

        if affixID and path then
            local button = GetAffixButton(shown + 1)
            button:SetWidth(AFFIX_SIZE)
            button:SetHeight(AFFIX_SIZE)

            if ns.SetTextureFile(button.icon, path) == path then
                shown = shown + 1
                button.affixID = affixID

                button:ClearAllPoints()
                button:SetPoint("TOPLEFT", plate, "TOPLEFT",
                    HEADER_PAD_X + (shown - 1) * (AFFIX_SIZE + AFFIX_GAP),
                    -(HEADER_HEIGHT + gap.affixRow))
                button:Show()
            else
                -- Left out rather than drawn blank. The affix is still on the
                -- key and still in /hp mplus; it just has no art to say so
                -- with, and a hoverable hole is worse than a gap.
                HideAffix(button)
                ns.Debug("mplus: affix %s icon %s did not load, not drawn.",
                    tostring(affixID), tostring(path))
            end
        end
    end

    for i = shown + 1, #affixes do HideAffix(affixes[i]) end

    affixRowHeight = (shown > 0) and (gap.affixRow + AFFIX_SIZE) or 0
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

    ns.StylePlateChrome(plate, ns.PanelStyle("mplus"))

    -- The threshold pair is sized by the row that draws it rather than here.
    -- Dropping the cache is how a face or shadow change reaches it, since
    -- neither of those moves the size the cache is keyed on.
    tierSize = nil

    local font = ns.GetFontFile()

    local ir, ig, ib = ns.HexToRGB(ns.PALETTE.icon)
    ui.lockIcon:SetColor(ir, ig, ib, 1)

    local br, bg, bb = ns.HexToRGB(ns.PALETTE.bright)
    ui.dungeon:SetFont(font, ns.GetFontSize(0, "mplusHeader"))
    ui.dungeon:SetTextColor(br, bg, bb, 1)

    local kr, kg, kb = ns.HexToRGB(ns.PALETTE.accentLight)
    ui.keystone:SetFont(font, ns.GetFontSize(-1, "mplusHeader"))
    ui.keystone:SetTextColor(kr, kg, kb, 1)

    local mr, mg, mb = ns.HexToRGB(ns.PALETTE.muted)
    ui.timerGlyph:SetColor(mr, mg, mb, 1)
    ui.forcesGlyph:SetColor(mr, mg, mb, 1)

    ui.time:SetFont(font, ns.GetFontSize(0, "mplusTimer"))
    ui.time:SetTextColor(br, bg, bb, 1)

    local dr, dg, db = ns.HexToRGB(ns.PALETTE.icon)
    ui.total:SetFont(font, ns.GetFontSize(TOTAL_DELTA, "mplusBody"))
    ui.total:SetTextColor(dr, dg, db, 1)

    local cr, cg, cb = ns.HexToRGB(ns.PALETTE.chest)
    ui.tier:SetTextColor(cr, cg, cb, 1)

    local tr, tg, tb = ns.HexToRGB(ns.PALETTE.chestTime)
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
    ui.forcesLabel:SetFont(font, ns.GetFontSize(-1, "mplusBody"))
    ui.forcesLabel:SetTextColor(fr, fg, fb, 1)

    ui.forcesPercent:SetFont(font, ns.GetFontSize(-1, "mplusBody"))
    ui.forcesPercent:SetTextColor(br, bg, bb, 1)

    -- The footer rule is an edge, so it follows the border's colour, alpha and
    -- style rather than a hairline token of its own - a border turned off must
    -- not leave a line ruled across the panel.
    local rr, rg, rb, ra = ns.BorderPaint(0.5, "mplus")
    ui.rule:SetVertexColor(rr, rg, rb, ra)

    local ar, ag, ab = ns.HexToRGB(ns.PALETTE.accentDeep)
    ui.mark:SetFont(font, ns.GetFontSize(-3.5, "mplusBody"))
    ui.mark:SetTextColor(ar, ag, ab, 1)

    -- Every string this panel owns, in one pass at the end rather than a line
    -- beside each SetFont above. The setting is one flag for the whole panel,
    -- so applying it per string would be nine chances to forget one - and a
    -- shadow that reaches eight of nine strings reads as a rendering fault
    -- rather than as a missed call. The boss rows are done where they are
    -- styled, because they are pooled and restyled per refresh.
    for _, fontString in ipairs({
        ui.dungeon, ui.keystone, ui.time, ui.total, ui.tier, ui.tierTime,
        ui.forcesLabel, ui.forcesPercent, ui.mark,
    }) do
        ns.ApplyTextShadow(fontString, "mplus")
    end
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

    if plate.grip then plate.grip:Raise(strata, level) end
    for i = 1, #affixes do
        affixes[i]:SetFrameStrata(strata)
        affixes[i]:SetFrameLevel(level + 1)
    end

    local width = tracker:GetWidth() or 0
    width = width > 60 and (width + PAD_LEFT + PAD_RIGHT) or PANEL_MIN_WIDTH

    local top    = tracker:GetTop()
    -- affixRowHeight is whatever the last LayoutAffixes resolved, and is zero
    -- when there are none. Redraw lays the affixes out between its two calls
    -- here, so the second one is the one that sizes the panel correctly.
    local headerBlock = HEADER_HEIGHT + affixRowHeight
    local height = headerBlock + gap.timerRow + TIMER_ROW_H + gap.bar + BAR_HEIGHT
                 + gap.forces + FORCES_LABEL_H + FORCES_BAR_TOP + FORCES_BAR_H

    if contentBottom and top then
        height = (top - contentBottom) + FOOTER_TOP + FOOTER_HEIGHT + PAD_BOTTOM
    end

    plate:ClearAllPoints()
    plate:SetPoint("TOPLEFT", tracker, "TOPLEFT", -PAD_LEFT, 0)
    plate:SetWidth(width)
    plate:SetHeight(math.max(headerBlock, height))

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

-- Where the timer bar's bottom edge lands, in plate coordinates.
--
-- Its own function because two callers need it and they have to agree:
-- LayoutTimer draws from it, and ForcesShortfall has to know it before
-- LayoutTimer has run in order to decide how far the gaps must give.
local function TimerBarBottom()
    return -(HEADER_HEIGHT + affixRowHeight + gap.timerRow
             + TIMER_ROW_H + gap.bar + BAR_HEIGHT)
end

-- The threshold pair's size, applied where the row is drawn rather than in
-- StyleStatic with the rest of the panel's fonts.
--
-- Everything else on the panel is styled once per restyle and laid out once per
-- refresh, and for those two the split is right. This row is the exception: it
-- is redrawn four times a second off the clock ticker, and it is the one part of
-- the panel that can be on screen through a whole run without a restyle ever
-- reaching it. Sizing it here means the configured size cannot be left behind by
-- a Restyle that ran while the plate did not yet exist, which is the ordinary
-- state of things when the options window is opened outside a dungeon.
--
-- The cache is what makes that affordable: SetFont is only called when the
-- answer has actually changed, so the ticker's cost is one comparison. It is
-- dropped by StyleStatic, because a restyle can change the face or the shadow
-- without changing the size.
local function ApplyTierFont()
    local wanted = ns.GetFontSize(TIER_DELTA, "mplusBody")
    if wanted == tierSize then return end
    tierSize = wanted

    local font = ns.GetFontFile()
    ui.tier:SetFont(font, wanted)
    ui.tierTime:SetFont(font, wanted)
    ns.ApplyTextShadow(ui.tier, "mplus")
    ns.ApplyTextShadow(ui.tierTime, "mplus")
end

-- The timer row, the bar and its ticks. Split out because it is the only part
-- of the panel that is redrawn on the clock ticker rather than on a refresh.
local function LayoutTimer(data, width)
    ApplyTierFont()

    -- Below the affix row when there is one, so the timer keeps the design's
    -- distance from whatever the header block ended up being.
    local rowTop = -(HEADER_HEIGHT + affixRowHeight + gap.timerRow)

    ui.timerGlyph:ClearAllPoints()
    ui.timerGlyph:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", HEADER_PAD_X, rowTop - TIMER_ROW_H + 3)

    ui.time:ClearAllPoints()
    ui.time:SetPoint("BOTTOMLEFT", ui.timerGlyph, "BOTTOMRIGHT", 6, -2)

    -- Baselines, not boxes.
    --
    -- A FontString's bottom edge is the bottom of its descender, which is
    -- proportional to its size, so bottom-aligning two strings of different
    -- sizes leaves the smaller one sitting low by about a fifth of the
    -- difference. A flat 3px came first and was right only for the one size pair
    -- it was measured against. Working it out from the sizes themselves keeps the
    -- two clocks reading off one line whatever they are set to.
    local lift = math.max(0, (ns.GetFontSize(0, "mplusTimer")
                              - ns.GetFontSize(TOTAL_DELTA, "mplusBody")) * 0.2)

    ui.total:ClearAllPoints()
    ui.total:SetPoint("BOTTOMLEFT", ui.time, "BOTTOMRIGHT", 6, lift)

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
    local barTop   = rowTop - TIMER_ROW_H - gap.bar

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

    return TimerBarBottom()
end

-- The top of the highest boss row heroPanel styles in place, which is the floor
-- its own block has to stop above. Sub-rows are excluded: those are redrawn on
-- the panel and sit below the ones that are not.
local function FirstBossTop(bosses)
    local top
    for i = 1, #bosses do
        local boss = bosses[i]
        if not boss.sub and boss.label then
            local rowTop = boss.label:GetTop()
            if rowTop and (not top or rowTop > top) then top = rowTop end
        end
    end
    return top
end

-- The gap the forces bar will actually leave above the first boss row, with the
-- gaps as they currently stand. Negative means it is drawn over the row.
--
-- Two cases, and the smaller wins, which is what LayoutForces resolves to: the
-- block sits against the row and leaves exactly gap.forces, or it does not fit
-- and is stranded under the timer bar, leaving whatever is left over - which on
-- a compact tracker is a negative number, and was "the bar drawn through Lord
-- Vyletongue".
local function ForcesClearance(firstBossTop)
    local plateTop = plate and plate:GetTop()
    if not (firstBossTop and plateTop) then return gap.forces end

    local strandedBottom = TimerBarBottom() - gap.forces
                           - FORCES_LABEL_H - FORCES_BAR_TOP - FORCES_BAR_H
    return math.min(gap.forces, strandedBottom - (firstBossTop - plateTop))
end

local function LayoutForces(data, width, barBottom, firstBossTop)
    local plateTop = plate:GetTop()

    -- Above the first boss row when there is one, so the two always sit the
    -- design's distance apart; otherwise straight under the timer bar.
    --
    -- When both are possible the lower of the two wins, which is what puts the
    -- block against the boss row rather than leaving it stranded under the
    -- timer. When only the fallback is left the block does not fit at all, and
    -- Redraw has already squeezed the gap budget to make it - see
    -- ForcesClearance.
    local labelTop = barBottom - gap.forces
    if firstBossTop and plateTop then
        local wanted = (firstBossTop - plateTop) + gap.forces + FORCES_BAR_H + FORCES_BAR_TOP + FORCES_LABEL_H
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
-- wants it in the sentence.
--
-- Holding it back until the first extra boss died came first, on the grounds
-- that "(0/4)" is a count of nothing - which had it backwards. The denominator
-- decides whether the group detours for these at all, so withholding it until
-- the first kill meant the number arrived after the decision it informs.
--
-- Rewriting a tracker string is the one thing in here that changes what the
-- game drew, so it follows Lines.lua's rule for the same move: the original is
-- kept, and the rewrite is only recognised as ours if the string on screen is
-- still the one we wrote.
local function SetHeadingText(fontString, raw, progress, maximum)
    -- The verb goes with it.
    --
    -- "Defeat Additional Bosses (6/6)" does not fit the row on a six-boss list
    -- and came out cut to "Defeat Additional Bosses (6...". Of everything in
    -- that string the verb is the part carrying nothing - every row in the
    -- block is something to defeat - so it is the part that goes, and the count
    -- it was crowding out fits.
    --
    -- Only what is drawn loses it. `raw` stays the string Ascension set, which
    -- is what Restore hands back, what RawText recovers and what the encounter
    -- states are matched by name against.
    local shown = (string.gsub(raw, "^[Dd]efeat%s+", ""))
    if progress and maximum and maximum > 0 then
        shown = string.format("%s (%d/%d)", shown, progress, maximum)
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
    --
    -- The heading was +0.5 once, one point under the title, which at the sizes
    -- anyone actually runs is not a step - the block read as two titles. It now
    -- sits a point and a half under the title and half a point over the rows it
    -- heads, which is a hierarchy in both directions.
    local size = ns.GetFontSize(-0.5, "mplusBody")
    if boss.primary then
        size = ns.GetFontSize(1.5, "mplusBody")
    elseif boss.group then
        size = ns.GetFontSize(0, "mplusBody")
    end
    pcall(boss.label.SetFont, boss.label, font, size)
    ns.ApplyTextShadow(boss.label, "mplus")

    -- The tracker's own icon is replaced by heroPanel's indicator, and its
    -- right-aligned counter either moves into the heading's text or is said
    -- by the check mark instead.
    if boss.icon then FadeRegion(boss.icon) end
    if boss.counter then FadeRegion(boss.counter) end

    row.check:Hide()
    row.ring:Hide()
    row.ringDot:Hide()
    row.pulsing = false

    -- The count goes into the sentence in both of the heading's states.
    --
    -- It used to go in only while the block was expanded, which put it on the
    -- one state that did not need it: expanded, the children are on screen and
    -- can be counted. Collapsed they are not, the tracker's own right-aligned
    -- "2/6" is faded with the rest of its art, and the row that stands in for
    -- six bosses said nothing about how many of them were down.
    --
    -- What differs between the two states is the treatment below, not the text:
    -- expanded it is a label over a list, collapsed it is an objective row with
    -- an indicator like any other.
    if boss.heading or boss.group then
        SetHeadingText(boss.label, boss.text, boss.progress, boss.maximum)
    end

    if boss.group then
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
    local size  = ns.GetFontSize(-1, "mplusBody")
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
        ns.ApplyTextShadow(row.label, "mplus")
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

local function DoRedraw()
    if not mplus.enabled or not plate then return end

    local tracker = ns.GetTrackerFrame("mplus")
    if not tracker then return end

    if preview then
        -- A real run wins, always. Standing the preview down here rather than
        -- off an event means it cannot be missed: whatever put a key on screen,
        -- the next draw is the one that notices, and the panel goes straight to
        -- showing the run rather than a made-up one.
        if tracker:IsVisible() and CallApi("IsKeystoneActive") then
            preview = false
            SyncPreviewMouse()
            ns.Print("Mythic+ placement preview off - a keystone is running.")
        else
            DrawPreview(tracker)
            return
        end
    end

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

    -- Shortened at the point of drawing, not in Read: data.dungeon stays the
    -- string the game gave so /hp mplus can still report it, which is how a
    -- row in SHORT_NAMES that never matches gets noticed.
    ui.dungeon:SetText(mplus.ShortName(data.dungeon) or "Mythic+")
    if data.level then
        ui.keystone:SetText("(" .. data.level .. ")")
        ui.keystone:Show()
    else
        ui.keystone:Hide()
    end

    ------------------------------------------------------------------
    -- The gap budget, before anything is placed against it
    --
    -- The affixes are laid out first because their row is part of the header
    -- block the clearance is measured from, and again afterwards because the
    -- squeeze can take pixels out of the gap above them. Nothing else needs a
    -- second pass: the gaps are settled by the time the timer row is drawn.
    ------------------------------------------------------------------

    SqueezeGaps(0)              -- design values, so the measurement is honest
    LayoutAffixes(data.affixes)

    local firstBossTop = FirstBossTop(data.bosses)
    local overrun = SqueezeGaps(FORCES_MIN_CLEAR - ForcesClearance(firstBossTop))
    if overrun > 0 then
        ns.Debug("mplus: %.0fpx short of clearing the first boss row with every "
            .. "gap at its floor; the panel's block does not fit this tracker.", overrun)
    end

    LayoutAffixes(data.affixes)
    LayoutPlate(tracker, nil)   -- affix buttons need the tracker's strata

    local barBottom = LayoutTimer(data, width)


    -- Two lists with two different treatments. The required boss and the
    -- extra-bosses heading are few and fixed, so they are restyled where the
    -- tracker drew them. The extra bosses themselves are a variable-length
    -- list that has to be windowed, so heroPanel fades them and draws its own.
    local contentBottom
    local headingBottom
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
        elseif boss.champions then
            ----------------------------------------------------------
            -- Champions, which the panel does not draw.
            --
            -- A champion is a special kind of trash mob: worth a large slice of
            -- enemy forces, optional, and a great deal harder than the pack it
            -- stands in for. So what a party wants to know about one is a
            -- percentage on the forces meter - what detouring for it is worth -
            -- and not an objective row with a count on it.
            --
            -- Where that percentage goes, and whether it belongs on the meter
            -- at all, is not settled. Drawing the row in the meantime is the
            -- worst of the three options: as a boss row it got a pending ring
            -- for a requirement that is usually zero on this client, and as a
            -- heading it said a count whose meaning nobody had decided. So it
            -- is faded whole, like Ascension's own enemy-forces row and the
            -- extra-boss children, and nothing on the panel refers to it.
            --
            -- The API's counts are still read - see the champions note in
            -- mplus.Read - and /hp dump reports them, so settling this later
            -- starts from numbers rather than from nothing.
            ----------------------------------------------------------
            FadeRegion(boss.label)
            if boss.icon then FadeRegion(boss.icon) end
            if boss.counter then FadeRegion(boss.counter) end
        else
            styled = styled + 1
            StyleBossRow(styled, boss)

            local bottom = boss.label:GetBottom()
            if bottom and (not contentBottom or bottom < contentBottom) then contentBottom = bottom end

            -- The expandable heading's own bottom, kept apart from the lowest
            -- row on the panel - see the anchor note below.
            if boss.group and bottom then headingBottom = bottom end
        end
    end
    HideRowsFrom(styled + 1)

    -- Anchored under the heading the list belongs to, not under the lowest row
    -- on the panel.
    --
    -- Those were the same point right up until a row appeared *below* the
    -- expanded children. Ascension anchors its champions row under the space it
    -- reserves for them, so contentBottom jumped to the bottom of that whole
    -- block and the list was pushed below it. What that looked like on screen
    -- was a tall gap between the heading and that row - the reserved space,
    -- with Ascension's faded rows still standing in it - and heroPanel's own
    -- list stranded underneath.
    --
    -- The panel no longer draws a champions row, so contentBottom no longer
    -- jumps for one. The distinction stays because the reserved space does:
    -- anything Ascension anchors under that block would move the list again.
    --
    -- Drawn against its heading, the list lands in the space that was reserved
    -- for it and the gap closes.
    local anchor = headingBottom or contentBottom

    if #subList > 0 and anchor then
        local plateTop = plate:GetTop()
        local listTop  = plateTop and (anchor - plateTop - 4) or -120
        local listBottom = LayoutSubList(subList, listTop)

        -- Whichever ends up lower wins. The list is normally the bottom of the
        -- panel but is not guaranteed to be: a row drawn under it would be, and
        -- sizing the plate to the list alone would cut that row off.
        if plateTop then
            local listScreen = plateTop + listBottom
            if not contentBottom or listScreen < contentBottom then
                contentBottom = listScreen
            end
        end
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

-- Announcing a change of preview state, once the panel is actually in it.
--
-- The boon bar anchors under this panel and what it draws depends on which of
-- the two states the panel is in, so it has to be told. Told from here rather
-- than from SetPreview because by this point the plate has been drawn or
-- hidden: a listener that measures the panel gets the state it is in now, not
-- the one it was in before this frame's draw. Announcing it from SetPreview
-- instead meant the bar asked whether the panel was up a frame before it was,
-- got "no", and laid itself out as an unanchored bar.
--
-- It also covers the one transition SetPreview never sees: DoRedraw stands the
-- preview down by itself when a real key starts.
local previewNotified = false

-- Whether the panel was on screen at the end of the last draw. The quest
-- tracker can be set to hang off the bottom of it, and coming up or going away
-- is the whole of what that anchor needs told about: it is a SetPoint against
-- this plate, so a panel that has merely grown a boss row taller carries the
-- tracker down with it and needs no second call. Which matters, because this
-- runs on a ticker for the length of a key.
local plateNotified = false

local function Redraw()
    DoRedraw()

    if preview ~= previewNotified then
        previewNotified = preview
        ns:Fire("HEROPANEL_MPLUS_PREVIEW", preview)
    end

    local up = (plate and plate:IsShown()) and true or false
    if up ~= plateNotified then
        plateNotified = up
        if ns.Skin and ns.Skin.RefreshQuestAnchor then
            pcall(ns.Skin.RefreshQuestAnchor, "mplus panel shown or hidden")
        end
    end
end

--------------------------------------------------------------------------------
-- The preview draw
--
-- Sample numbers chosen to exercise the parts of the panel that are hardest to
-- judge empty: a dungeon name long enough that the short-name table has
-- something to do, a clock inside a chest tier so the threshold pair and the
-- tier colour are both drawn, a forces percentage part-way along its bar, and
-- enough boss rows to show the list and its scroll wheel.
--------------------------------------------------------------------------------

local PREVIEW_LIST_GAP = 8   -- forces bar to the first sample boss row

local function PreviewData()
    -- Written out on every call rather than kept as a constant, because
    -- LayoutTimer and LayoutForces are free to read whatever they like off this
    -- and a shared table would carry a previous draw's leftovers into the next.
    return {
        dungeon   = "Dire Maul - North",
        level     = 20,

        -- 28:53 of 40:00 is 72% remaining, which is inside the +3 threshold on
        -- the default percentages - so the tier readout and its gold have
        -- something to draw rather than sitting blank.
        timeLeft  = 1733,
        totalTime = 2400,

        trashDead     = 49,
        trashRequired = 100,

        -- No affixes. They are real icons off the client's own affix table and
        -- inventing IDs would draw either the wrong art or the question mark
        -- fallback, neither of which helps anybody judge a layout. The affix
        -- row is the one part of the panel that has to be seen in a key.
        affixes = nil,

        bosses = {
            { text = "Guard Mol'dar (02:58)", done = true  },
            { text = "Stomper Kreeg",         done = false },
            { text = "Guard Fengus",          done = false },
            { text = "Guard Slip'kik",        done = false },
            { text = "Captain Kromcrush",     done = false },
            { text = "Cho'Rush the Observer", done = false },
        },
    }
end

function DrawPreview(tracker)
    local data = PreviewData()

    -- Nothing of Ascension's is touched, read, faded or restored in here. Only
    -- heroPanel's own boss-row decorations and chevron are cleared, because the
    -- preview draws neither and they would otherwise be left over the rows of
    -- whatever the last real draw saw.
    --
    -- Calling RestoreChrome here was the first version and it was wrong. The
    -- enemy-forces row is hidden rather than faded - see HideArt - and its Show
    -- is hooked to re-hide it for as long as the skin is on. So restoring it
    -- put the row back for one frame, the hook took it away again, and the
    -- record of "this was shown" was wiped in between. The next real draw then
    -- recorded the row as having been hidden all along, and Disable could never
    -- give it back. Leaving Ascension's chrome exactly as the last real draw
    -- left it costs nothing: the panel is still drawn over it either way.
    HideRowsFrom(1)
    ui.expandCaret:Hide()

    local width = LayoutPlate(tracker, nil)
    plate:Show()
    LayoutHeader()

    ui.dungeon:SetText(mplus.ShortName(data.dungeon) or "Mythic+")
    ui.keystone:SetText("(" .. data.level .. ")")
    ui.keystone:Show()

    -- Design values throughout. The squeeze exists to clear Ascension's first
    -- boss row, and in preview there is no such row - so squeezing here would
    -- show a tighter panel than a real key ever draws.
    SqueezeGaps(0)
    LayoutAffixes(data.affixes)
    LayoutPlate(tracker, nil)

    local width2 = width
    local barBottom = LayoutTimer(data, width2)

    -- The list goes under the forces block, which is the one thing between it
    -- and the threshold bar. Measured off TimerBarBottom and the same constants
    -- LayoutPlate sizes an empty panel from, so preview and the real thing
    -- agree about where that block ends.
    local listTop = TimerBarBottom()
        - gap.forces - FORCES_LABEL_H - FORCES_BAR_TOP - FORCES_BAR_H
        - PREVIEW_LIST_GAP

    local listBottom = LayoutSubList(data.bosses, listTop)

    local plateTop = plate:GetTop()
    local contentBottom = plateTop and (plateTop + listBottom) or nil

    LayoutForces(data, width2, barBottom, nil)
    LayoutPlate(tracker, contentBottom)

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
-- Moving the preview
--
-- The panel is normally moved by dragging the tracker: Ascension's frame is the
-- mover, it is unprotected, and Move.lua owns the whole business of saving
-- where it ended up. None of that works here, because the tracker is hidden -
-- a frame nobody can see is a frame nobody can grab.
--
-- So in preview the plate takes the mouse instead, and hands the result back to
-- Move.lua rather than working out a position itself. On drop it anchors the
-- *tracker* to the plate and calls ns.SavePosition("mplus"), which reads the
-- tracker's offsets and re-anchors it to UIParent exactly as an ordinary drag
-- would. Nothing here computes a coordinate, which matters: the plate carries
-- the tracker's scale, and hand-rolled arithmetic between two scaled frames is
-- how a panel ends up half a screen away at 0.8 scale.
--
-- The plate takes the mouse *only* while previewing and unlocked. It must not
-- the rest of the time: the whole panel is built one strata below the tracker
-- precisely so it can never take a click the tracker wanted, and a plate left
-- mouse-enabled would undo that.
--------------------------------------------------------------------------------

function SyncPreviewMouse()
    if not plate then return end

    local wanted = preview and not ns.IsLocked()
    plate:EnableMouse(wanted and true or false)

    -- Dropped mid-drag by a lock, so the plate does not carry on following the
    -- cursor with nothing left to stop it.
    if not wanted and plate.previewMoving then
        plate.previewMoving = nil
        pcall(plate.StopMovingOrSizing, plate)
    end
end

local function PreviewOnDragStart(self)
    if not preview then return end

    if ns.IsLocked() then
        ns.Warn("the Mythic+ panel is locked. Click the padlock in its header, "
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

    local tracker = ns.GetTrackerFrame("mplus")
    if not tracker then return end

    -- Pin the plate to UIParent first. StopMovingOrSizing normally leaves it
    -- there anyway, but it has to be certain: the next line anchors the tracker
    -- to the plate, and a plate still anchored to the tracker would make that
    -- pair circular and the client would refuse the point.
    local x, y = ns.GetUIOffsets(self)
    if x then ns.ApplyUIOffsets(self, x, y) end

    -- The tracker is hung off the plate for exactly two statements, and then
    -- put straight back onto UIParent.
    --
    -- The anchor is how the PAD_LEFT offset gets resolved without any
    -- arithmetic: the plate is drawn that much wider than the tracker on the
    -- left - see LayoutPlate - and letting the client apply it as an anchor
    -- offset means it lands in the tracker's own scale, which hand-rolled maths
    -- between two scaled frames reliably gets wrong.
    --
    -- Putting it back immediately is not tidiness. Move.lua decides who owns a
    -- tracker partly by what it is anchored to, and a tracker anchored to a
    -- frame that is not UIParent reads as another addon having taken it - so a
    -- tracker left hanging off heroPanel's own plate makes heroPanel conclude
    -- it has lost the argument with itself and switch to holder mode. Nothing
    -- can observe the intermediate state, because nothing yields between here
    -- and the re-anchor.
    tracker:ClearAllPoints()
    tracker:SetPoint("TOPLEFT", self, "TOPLEFT", PAD_LEFT, 0)

    local tx, ty = ns.GetUIOffsets(tracker)
    if tx then ns.ApplyUIOffsets(tracker, tx, ty) end

    ns.SavePosition("mplus")
    Refresh("preview moved")
end

--------------------------------------------------------------------------------
-- The switch
--------------------------------------------------------------------------------

function mplus.SetPreview(on)
    on = on and true or false
    if on == preview then return preview end

    if on and not mplus.enabled then
        ns.Warn("the Mythic+ skin is off, so there is no panel to place. "
            .. "Turn it on first.")
        return false
    end

    preview = on
    SyncPreviewMouse()

    if not preview and plate then plate:Hide() end
    Refresh(on and "preview on" or "preview off")
    -- Nothing is announced here on purpose; Redraw does it once the panel is
    -- actually drawn. See the note on previewNotified.

    ns.Print("Mythic+ placement preview %s.%s",
        on and "|cFF79C68Don|r" or "|cFF8B8FA3off|r",
        on and (ns.IsLocked()
                    and " Unlock the trackers to drag it."
                    or  " Drag the panel to place it.")
            or "")
    return preview
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

    -- The placement preview's drag. Inert until SyncPreviewMouse turns the
    -- plate's mouse on, which only happens while previewing and unlocked.
    plate:SetScript("OnDragStart", PreviewOnDragStart)
    plate:SetScript("OnDragStop", PreviewOnDragStop)

    -- The preview follows the same padlock as everything else, so locking mid-
    -- placement takes the drag away rather than leaving a panel that moves
    -- while the lock says it should not.
    ns:On("HEROPANEL_LOCK_CHANGED", function()
        SyncPreviewMouse()
        if preview then Refresh("lock changed") end
    end)

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

    -- The preview goes with it. It is a view of this panel, and a panel that
    -- has been switched off has no view to leave on screen.
    preview = false
    SyncPreviewMouse()

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

    -- Read and not drawn. Reported here rather than on the panel because where
    -- a champion's slice of enemy forces belongs is an open question, and this
    -- is what there is to answer it with.
    ns.Print("  champions: %s/%s |cFF8B8FA3(read, not drawn)|r",
        tostring(data.championsDead), tostring(data.championsRequired))

    for i = 1, #data.bosses do
        local boss = data.bosses[i]
        ns.Print("    boss %d |cFFC2C6D8%s|r: %s%s", i, boss.text,
            boss.done and "|cFF79C68Dslain|r" or "|cFF8B8FA3up|r",
            -- Collected so it can be faded, and listed so the row is accounted
            -- for rather than looking like one the panel lost.
            boss.champions and " |cFF8B8FA3(not drawn)|r" or "")
    end
    if #data.bosses == 0 then
        ns.Print("    |cFFFFAA00no boss rows|r - the objective block is empty or hidden")
    end

    ------------------------------------------------------------------
    -- The gap budget
    --
    -- Everything above the first boss row is heroPanel's and that row is
    -- Ascension's, so the space between them is fixed and the panel's block
    -- has to fit inside it. When it does not the gaps give, and when they have
    -- given everything the bar is drawn over the row. This says which of those
    -- happened, in the only terms that matter: how much clear space is left.
    ------------------------------------------------------------------

    local clearance = ForcesClearance(FirstBossTop(data.bosses))
    local squeezed  = {}
    for i = 1, #GAP_BUDGET do
        local entry = GAP_BUDGET[i]
        if gap[entry.key] ~= entry.default then
            table.insert(squeezed, string.format("%s %d/%d", entry.key, gap[entry.key], entry.default))
        end
    end

    ns.Print("  forces bar clears the first boss row by %s",
        clearance >= 0
            and string.format("|cFF79C68D%.0fpx|r", clearance)
            or  string.format("|cFFFFAA00-%.0fpx - it is drawn over the row|r", -clearance))
    if #squeezed > 0 then
        ns.Print("    gaps squeezed to fit: |cFFC2C6D8%s|r", table.concat(squeezed, ", "))
    else
        ns.Print("    |cFF8B8FA3every gap at its design value|r")
    end

    ------------------------------------------------------------------
    -- Ascension art still drawing where the panel is not
    --
    -- The enemy-forces glow is the reason this is here: it animates, an
    -- animation writes alpha, and it drew across the bottom of the panel until
    -- that row was hidden rather than faded. Guessing at which widget a strip
    -- of Ascension's art under the panel actually is, from a screenshot, does
    -- not work. So the tracker is walked for every region still drawing below
    -- the panel's own bottom edge, which is where a stray shows up.
    --
    -- It reports what is on screen when it runs, so a region that is only
    -- visible for the length of an animation has to be caught by running this
    -- while it plays. What it is good for is the standing case: art that is
    -- drawing there all the time because nothing faded or hid it.
    ------------------------------------------------------------------

    local floor = plate and plate:IsVisible() and plate:GetBottom()
    if not floor then return end

    local strays = 0
    ns.WalkFrameTree(tracker, function(object, info)
        if info.kind ~= "region" then return end
        if not (object.IsVisible and object:IsVisible()) then return end
        if (object.GetAlpha and object:GetAlpha() or 0) <= 0 then return end

        local top = object.GetTop and object:GetTop()
        if not top or top > floor then return end

        strays = strays + 1
        if strays > 12 then return end

        local parent = info.parent
        ns.Print("    |cFFFFAA00stray|r %s on %s, alpha %.2f, top %.0f",
            tostring(info.objectType),
            tostring((parent and parent.GetName and parent:GetName()) or "unnamed"),
            object:GetAlpha() or 0, top)
    end, { maxDepth = 6, includeRegions = true })

    if strays == 0 then
        ns.Print("  nothing of Ascension's is drawing below the panel")
    else
        ns.Print("  |cFFFFAA00%d|r region(s) drawing below the panel's bottom edge (%.0f)%s",
            strays, floor, strays > 12 and ", first 12 listed" or "")
    end
end

--------------------------------------------------------------------------------
-- Wiring
--
-- The tracker frequently does not exist at ADDON_LOADED, so the panel is built
-- off the HEROPANEL_TRACKER_FOUND that Trackers.lua already polls for, rather
-- than from a second timer of its own.
--------------------------------------------------------------------------------

ns:On("HEROPANEL_TRACKER_FOUND", function(key)
    if key ~= "mplus" then return end
    if not ns.db then ns.InitDB() end
    if ns.SkinEnabled("mplus") then mplus.Enable() end
end)

ns:On("HEROPANEL_LOCK_CHANGED", function()
    if mplus.enabled and plate then
        ui.lockIcon:SetShape(ns.IsLocked() and "locked" or "unlocked")
    end
end)

ns:On("PLAYER_ENTERING_WORLD", function()
    if mplus.enabled then Refresh("entering world") end
end)
