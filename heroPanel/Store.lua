--[[--------------------------------------------------------------------------
    heroPanel - Store.lua

    What survives an update.

    heroPanel used to throw the whole store away whenever `dbVersion` did not
    match the build - keeping only the geometry - because the shape was still
    moving and nobody was running an old build. That is not a trade a released
    addon gets to make: a player who has spent an evening on their colours and
    sizes is owed them back after an update.

    The replacement is two mechanisms, and the first does nearly all the work.

      Reconciliation  Every value in the store is checked against ns.defaults
                      and the rules below: right type, right range, a colour
                      that is a colour, an enum the code still knows. Anything
                      that still fits is kept exactly as the player set it,
                      anything that does not goes back to its own default, and
                      keys the defaults tree no longer has are dropped. This
                      runs on every login, so it also repairs a hand-edited
                      SavedVariables file and a store half-written by a crash.

      The chain       MIGRATIONS[n] turns a store shaped n-1 into shape n, for
                      the changes reconciliation cannot infer: a key that was
                      renamed, split in two, or now means something else in the
                      same type. Steps run in order, on a copy.

    The division matters. Reconciliation is the backbone precisely because it
    needs nobody to remember it: bump DB_VERSION with no step written and the
    settings still come through, minus only the values whose shape genuinely
    changed. The old migration chain was dropped because every step had to go on
    working forever; this one carries only the cases that are actually a
    rename, which are rare, and an empty chain is the normal state.

    Nothing here discards a store. There is no case left that needs to: a value
    that cannot be read is one value, and resetting one value is not a reason to
    take the other forty with it.

    Load order: this file sits directly after Core.lua because it is Core's
    defaults seen from the other side. Everything it borrows from later files -
    ns.OWNERSHIP_MODES, ns.GLYPH_MODES, ns.BORDER_STYLES, the font and scale
    bounds - is read through a function rather than at load time, so the rules
    below can name them without depending on file order. They are resolved when
    Prepare runs, which is ADDON_LOADED, by which point every file is in.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

ns.Store = ns.Store or {}
local store = ns.Store

--------------------------------------------------------------------------------
-- The chain
--
-- MIGRATIONS[n](db) is handed a store already shaped n-1 and must leave it
-- shaped n. Write one only when reconciliation cannot work the change out for
-- itself, which means: a key changed name, one key became two, or a value kept
-- its type and changed its meaning (degrees to radians, a fraction to a
-- percentage). Adding, removing and retyping a key all need nothing.
--
-- Steps run on a copy and in ascending order, so each one may assume every
-- earlier step has already run. A step that throws is caught: the copy is
-- dropped, the original store is reconciled instead, and the player is told.
-- That is the safe direction to fail in - a value or two back at its default,
-- rather than a store half-rewritten by a step that stopped in the middle.
--
-- Empty is the normal state, and an empty chain is not an untested one:
-- ns.Store.MIGRATIONS is public so the harness can register a step, run a store
-- through it and take it out again, which tests the mechanism without waiting
-- for a shape change to test it with.
--
--   Example, if font.face had been renamed from font.family in shape 6:
--
--     MIGRATIONS[6] = function(db)
--         if type(db.font) == "table" and db.font.family then
--             db.font.face, db.font.family = db.font.family, nil
--         end
--     end
--------------------------------------------------------------------------------

local MIGRATIONS = {}
store.MIGRATIONS = MIGRATIONS

-- boons.dimMelee became boons.markMelee.
--
-- A rename, which is exactly the case reconciliation cannot work out for
-- itself: without this the old key is pruned as junk and the new one is filled
-- in from its default, so somebody who had turned melee marking on would find
-- it off again. The setting also changed what it does - dimming the two
-- melee-only boons, which is what an unowned boon already looks like, became a
-- border in a colour nothing else on the bar uses - but the answer to "do you
-- want these two called out" is the same either way, so the value carries.
MIGRATIONS[6] = function(db)
    if type(db.boons) == "table" and db.boons.dimMelee ~= nil then
        db.boons.markMelee = db.boons.dimMelee and true or false
        db.boons.dimMelee  = nil
    end
end

--------------------------------------------------------------------------------
-- The rules
--
-- What ns.defaults cannot say about itself. A default gives every key a type
-- and a sensible value, and for most of the store that is the whole rule -
-- `header.show` is a boolean because `true` is, and nothing else has to be
-- written down. These are the keys that need more than their type:
--
--   * a range, so a scale of 40 comes back as 1.5 rather than as a tracker
--     drawn off the edge of the screen
--   * a format, so a colour is six hex digits and not the word "blue"
--   * an enum, so a positioning mode is one the code has a branch for
--   * permission to exist at all, for the keys whose default is nil. `point`
--     is deliberately absent from ns.defaults - nil means "never moved, leave
--     the frame where the game put it" - so without a rule saying it is a real
--     key, pruning would read it as junk and drop every saved position.
--
-- A path may wildcard a segment with `*`. The most specific rule wins, so
-- `panel.watch.bgColor` would beat `panel.*.bgColor` if both existed.
--
-- min, max and values may each be a function, resolved when the rules run
-- rather than when this file loads. That is what lets a bound live in the file
-- that owns it - the font sizes in Util.lua, the scale in Move.lua - instead of
-- being copied here to drift.
--------------------------------------------------------------------------------

-- Where a frame can be anchored. A client constant rather than a heroPanel one,
-- so there is nothing for this copy to drift from.
local ANCHORS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT    = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local COLOUR  = { type = "string", pattern = "^#%x%x%x%x%x%x$" }
local UNIT    = { type = "number", min = 0, max = 1 }
local ANCHOR  = { type = "string", optional = true, values = ANCHORS }
local COORD   = { type = "number" }

local RULES = {
    -- The stamp itself. It lives in the store and not in the defaults, so it
    -- needs saying here or every login would prune the thing that says which
    -- shape the store is in.
    ["dbVersion"] = { type = "number", optional = true },

    ["frame.ownership"] = { type = "string",
                            values = function() return ns.OWNERSHIP_MODES end },
    ["frame.*.point"]   = ANCHOR,
    ["frame.*.x"]       = COORD,
    ["frame.*.y"]       = COORD,
    ["frame.*.scale"]   = { type = "number",
                            min = function() return ns.SCALE_MIN end,
                            max = function() return ns.SCALE_MAX end },

    -- Move.lua's own stamp on a saved position, and the reason the two version
    -- numbers do not have to know about each other: GetSaved drops a position
    -- written in an older geometry shape whatever this file decided about the
    -- rest of the store. Preserved, not validated beyond its type - Move.lua is
    -- the only reader and it compares for equality.
    ["frame.*.v"]       = { type = "number", optional = true },

    ["options.point"]   = ANCHOR,
    ["options.x"]       = COORD,
    ["options.y"]       = COORD,
    ["options.scale"]   = { type = "number",
                            min = function() return ns.SCALE_MIN end,
                            max = function() return ns.SCALE_MAX end },

    -- The boon bar's geometry. It is not one of ns.trackers - heroPanel creates
    -- this frame rather than finding it - so it does not fall under the
    -- frame.* rules above and needs its own. `point` matters for the same
    -- reason it does there: its default is nil, and without a rule saying it is
    -- a real key, pruning would read a saved position as junk and drop it.
    ["boons.point"]       = ANCHOR,
    ["boons.x"]           = COORD,
    ["boons.y"]           = COORD,
    ["boons.scale"]       = { type = "number",
                              min = function() return ns.SCALE_MIN end,
                              max = function() return ns.SCALE_MAX end },
    ["boons.iconSize"]    = { type = "number",
                              min = function() return ns.BOON_ICON_MIN end,
                              max = function() return ns.BOON_ICON_MAX end },
    ["boons.orientation"] = { type = "string",
                              values = function() return ns.BOON_ORIENTATIONS end },

    ["panel.*.bgColor"]        = COLOUR,
    ["panel.*.borderColor"]    = COLOUR,
    ["panel.*.bgOpacity"]      = UNIT,
    ["panel.*.borderAlpha"]    = UNIT,
    ["panel.*.borderStyle"]    = { type = "string",
                                   values = function() return ns.BORDER_STYLES end },
    ["panel.*.radius"]         = { type = "number", min = 0,
                                   max = function() return ns.MAX_NOTCH end },
    ["panel.*.textShadowSize"] = { type = "number", min = 1, max = 3 },

    ["text.*"] = COLOUR,

    ["font.face"]   = { type = "string", nonempty = true },
    ["font.size.*"] = { type = "number",
                        min = function() return ns.FONT_SIZE_MIN end,
                        max = function() return ns.FONT_SIZE_MAX end },

    -- Only "flat" draws, and Plate.lua already falls back for the other three,
    -- so this asks for a name and not for a name off a list. A texture set that
    -- grows should not be a texture set that resets what a player chose from a
    -- build where the entry was live.
    ["bg.texture"] = { type = "string", nonempty = true },

    ["glyph.mode"] = { type = "string",
                       values = function() return ns.GLYPH_MODES end },
}

--------------------------------------------------------------------------------
-- Rule lookup
--
-- Paths are compared segment by segment rather than by pattern, so a key with a
-- dot or a magic character in it cannot match a rule it was never meant to.
-- Ordered once at load: fewest wildcards first, which is what makes "the most
-- specific rule wins" true rather than a matter of table order.
--------------------------------------------------------------------------------

local compiled = {}

do
    for path, rule in pairs(RULES) do
        local segments, wild = {}, 0
        for segment in string.gmatch(path, "[^%.]+") do
            segments[#segments + 1] = segment
            if segment == "*" then wild = wild + 1 end
        end
        compiled[#compiled + 1] = { path = path, rule = rule,
                                    segments = segments, depth = #segments, wild = wild }
    end

    table.sort(compiled, function(a, b)
        if a.wild ~= b.wild then return a.wild < b.wild end
        return a.path < b.path
    end)
end

local function RuleFor(trail)
    local depth = #trail
    for i = 1, #compiled do
        local entry = compiled[i]
        if entry.depth == depth then
            local match = true
            for s = 1, depth do
                local want = entry.segments[s]
                if want ~= "*" and want ~= trail[s] then match = false; break end
            end
            if match then return entry.rule end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

local function Resolve(value)
    if type(value) == "function" then
        local ok, resolved = pcall(value)
        if ok then return resolved end
        return nil
    end
    return value
end

-- A `values` rule may be written as a set or as a list, because the two
-- existing ones are: ns.OWNERSHIP_MODES is keyed, ns.GLYPH_MODES is an array.
-- Asking each of them to be the other shape to suit this file would be the
-- tail wagging the dog.
local function Allowed(values, candidate)
    if type(values) ~= "table" then return true end
    if values[candidate] then return true end
    for i = 1, #values do
        if values[i] == candidate then return true end
    end
    return false
end

-- Returns the value to store, and one of "kept", "repaired" or "reset".
--
-- "repaired" covers everything that arrived meaning the right thing in the
-- wrong form: a number as a string, a scale past the end of its range, a colour
-- missing its hash. Those are worth keeping and worth reporting separately from
-- a value that had to be thrown out, because a clamp is the player's setting
-- honoured as far as it can be and a reset is not.
--
-- Only ever called with a value that is actually in the store. A key that is
-- absent is not a key that failed to validate - it is one the player never set,
-- or one this build has just added - and Reconcile fills those from the
-- defaults without calling this at all.
local function Validate(value, rule, default)
    local wanted = (rule and rule.type) or type(default)
    local repaired = false

    -- A store hand-edited in a text editor, or written by a build that took the
    -- value off a text box, arrives as a string. Only numbers are coerced:
    -- reading "false" as a boolean would be guessing at what somebody typed.
    if wanted == "number" and type(value) == "string" then
        local asNumber = tonumber(value)
        if asNumber then value, repaired = asNumber, true end
    end

    if type(value) ~= wanted then return default, "reset" end

    if wanted == "number" then
        -- NaN is the one value that is not equal to itself, and infinity
        -- survives every arithmetic comparison below it. Both come out of a
        -- corrupt file rather than out of the addon.
        if value ~= value or value == math.huge or value == -math.huge then
            return default, "reset"
        end

        local low, high = Resolve(rule and rule.min), Resolve(rule and rule.max)
        if low and value < low then value, repaired = low, true end
        if high and value > high then value, repaired = high, true end

    elseif wanted == "string" then
        if rule and rule.pattern then
            -- Colours, in practice. A value that is six hex digits and nothing
            -- else is what was meant, so it is repaired rather than reset - the
            -- hash is punctuation, not the setting.
            if not string.find(value, rule.pattern) then
                local candidate = string.upper(string.gsub(value, "^%s*#?%s*", ""))
                candidate = "#" .. candidate
                if string.find(candidate, rule.pattern) then
                    value, repaired = candidate, true
                else
                    return default, "reset"
                end
            end

        elseif rule and rule.values then
            local values = Resolve(rule.values)
            if not Allowed(values, value) then
                -- Case is the one difference worth forgiving. Every enum in the
                -- addon is written one way, and a store carrying the other is a
                -- file somebody typed into rather than a setting they did not
                -- mean.
                local lower, upper = string.lower(value), string.upper(value)
                if Allowed(values, lower) then value, repaired = lower, true
                elseif Allowed(values, upper) then value, repaired = upper, true
                else return default, "reset" end
            end
        end

        if rule and rule.nonempty and string.find(value, "^%s*$") then
            return default, "reset"
        end
    end

    return value, repaired and "repaired" or "kept"
end

--------------------------------------------------------------------------------
-- Reconciliation
--
-- Walks the defaults tree and the store together. Every key the defaults know
-- is validated; every key they do not is dropped, unless a rule above claims it
-- (`point`, `v`, `dbVersion`) - those are real keys whose default is nil, and
-- pruning them would throw away the saved positions this whole file exists to
-- protect.
--
-- It fills missing keys itself rather than leaving that to a pass of
-- ns.ApplyDefaults beforehand, because the two answers have to be told apart. A
-- key that is absent is not a loss - the player never set it, or this build has
-- just added it - and a key that is present in a shape that cannot be read is.
-- ApplyDefaults cannot see the difference: it replaces a `font.size` that used
-- to be one number with the block of seven and says nothing, which is a setting
-- lost silently by the one mechanism that is supposed to report it.
--
-- prune is off for a store written by a newer build. Its unknown keys are that
-- build's settings, not junk, and dropping them would mean an older build
-- opened once quietly cost the player everything the newer one had added.
--------------------------------------------------------------------------------

local function Record(report, verdict, trail)
    if verdict == "kept" then return end
    local list = report[verdict]
    if list then list[#list + 1] = table.concat(trail, ".") end
end

local function Reconcile(target, defaults, trail, report, prune)
    -- Unknown keys first, so nothing below spends time validating a subtree
    -- that is about to go. Clearing a field during pairs is the one mutation
    -- Lua allows mid-traversal.
    for key in pairs(target) do
        if defaults[key] == nil then
            trail[#trail + 1] = key
            local rule = RuleFor(trail)

            if rule then
                -- A real key with no default to be checked against: `point`,
                -- `v`, `dbVersion`. There is nothing to fall back to, so a
                -- value that fails its rule is removed rather than replaced -
                -- which for `point` is exactly right, since absent means
                -- "never moved, leave the frame where the game put it".
                local value, verdict = Validate(target[key], rule, nil)
                Record(report, verdict, trail)
                target[key] = value
            elseif prune then
                Record(report, "pruned", trail)
                target[key] = nil
            end

            trail[#trail] = nil
        end
    end

    for key, default in pairs(defaults) do
        trail[#trail + 1] = key

        if type(default) == "table" then
            if type(target[key]) ~= "table" then
                -- A block that arrived as something other than a block cannot
                -- be read key by key - `font.size` was one number and is now
                -- seven. That is a real loss and is reported as one, but only
                -- when there was something there to lose: an absent block is a
                -- setting nobody had rather than a setting that broke.
                if target[key] ~= nil then Record(report, "reset", trail) end
                target[key] = {}
            end
            Reconcile(target[key], default, trail, report, prune)

        elseif target[key] == nil then
            -- Never set, or new in this build. Either way it is the default's
            -- job and not the report's.
            target[key] = default

        else
            local value, verdict = Validate(target[key], RuleFor(trail), default)
            Record(report, verdict, trail)
            target[key] = value
        end

        trail[#trail] = nil
    end
end

--------------------------------------------------------------------------------
-- Running the chain
--------------------------------------------------------------------------------

-- Cycle-safe because it costs four lines, not because SavedVariables can
-- contain a cycle - the client's own writer could not have written one.
local function DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do copy[key] = DeepCopy(item, seen) end
    return copy
end

local function RunChain(db, from, to, report)
    for version = from + 1, to do
        local step = MIGRATIONS[version]
        if step then
            local ok, err = pcall(step, db)
            if not ok then return false, version, err end
            report.migrated[#report.migrated + 1] = version
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- Prepare
--
-- The whole of what happens to the store between the client handing it over and
-- the addon reading it. Returns the store to use and the report of what it took
-- to get there; Core.lua's InitDB is the only caller.
--------------------------------------------------------------------------------

local function NewReport(to)
    return { to = to, migrated = {}, reset = {}, repaired = {}, pruned = {} }
end

function store.Prepare(db, version, defaults)
    local report = NewReport(version)
    store.lastReport = report

    if type(db) ~= "table" then db = {} end
    report.fresh = (next(db) == nil)
    report.from  = tonumber(db.dbVersion)

    -- A store from a newer build. It is not this build's to rewrite: the player
    -- has downgraded, or is running two installs, and going back up must find
    -- everything where it was left. So the keys this build knows are checked -
    -- it still has to be safe to read - and everything else is left alone,
    -- including the stamp, which is what makes this reversible.
    if report.from and report.from > version then
        report.future = true
        Reconcile(db, defaults, {}, report, false)
        return db, report
    end

    -- The chain runs on a copy, so a step that throws halfway cannot leave a
    -- half-rewritten store behind. An unstamped store skips it: there is no
    -- version to start from, and reconciliation alone is what carries it.
    if report.from and report.from < version then
        local copy = DeepCopy(db)
        local ok, at, err = RunChain(copy, report.from, version, report)
        if ok then
            db = copy
        else
            report.failed, report.error = at, err
            for i = #report.migrated, 1, -1 do report.migrated[i] = nil end
        end
    end

    Reconcile(db, defaults, {}, report, true)
    db.dbVersion = version

    return db, report
end

--------------------------------------------------------------------------------
-- Saying what happened
--
-- Carrying settings forward is silent: it is what the player expects to have
-- happened and there is nothing for them to do about it. Losing one is not, and
-- neither is refusing to write to a store this build does not understand.
--
-- Pruning and repairing stay at debug level. A dropped key the defaults no
-- longer have is invisible to the player by definition, and a clamped scale is
-- their setting honoured as far as it goes - reporting either as a loss would
-- teach them to distrust a message that matters.
--------------------------------------------------------------------------------

function store.Announce(report)
    if not report or report.fresh then return end

    if report.future then
        ns.Warn("your settings were written by a newer build of heroPanel "
            .. "(store %s, this build is %s). They have been left exactly as they "
            .. "are, so nothing is lost when you go back - but anything this build "
            .. "does not know about is not being used.",
            tostring(report.from), tostring(report.to))
        return
    end

    if report.failed then
        ns.Warn("could not carry your settings up to shape %s: %s. Everything that "
            .. "still fits this build has been kept; type |cFFC2C6D8/hp store|r for "
            .. "what did not.", tostring(report.failed), tostring(report.error))
    end

    if #report.reset > 0 then
        ns.Warn("%d setting(s) could not be read and went back to their defaults. "
            .. "Everything else came through. |cFFC2C6D8/hp store|r lists them.",
            #report.reset)
    end

    if #report.migrated > 0 then
        ns.Debug("carried settings forward from shape %s to %s.",
            tostring(report.from), tostring(report.to))
    end
    if #report.repaired > 0 then
        ns.Debug("%d setting(s) repaired: %s", #report.repaired,
            table.concat(report.repaired, ", "))
    end
    if #report.pruned > 0 then
        ns.Debug("%d key(s) this build no longer has, dropped: %s", #report.pruned,
            table.concat(report.pruned, ", "))
    end
end

--------------------------------------------------------------------------------
-- /hp store
--
-- What the last login did to the store. A settings window cannot answer this -
-- it shows what the values are now, and the question here is which of them are
-- not what the player set.
--------------------------------------------------------------------------------

local function PrintList(label, list)
    if #list == 0 then return end
    -- pairs order is not defined, so the paths are sorted before they are
    -- printed. A report that lists the same keys in a different order each
    -- login reads as a different report.
    local sorted = {}
    for i = 1, #list do sorted[i] = list[i] end
    table.sort(sorted)
    ns.Print("  %s: |cFFC2C6D8%s|r", label, table.concat(sorted, ", "))
end

function store.PrintReport()
    local report = store.lastReport
    if not report then
        ns.Print("the store has not been read yet this session.")
        return
    end

    ns.Print("store shape |cFFC2C6D8%s|r, this build wants |cFFC2C6D8%s|r.",
        tostring(report.from or "unstamped"), tostring(report.to))

    if report.fresh then
        ns.Print("  fresh install - everything is at its default.")
        return
    end
    if report.future then
        ns.Print("  |cFFFFAA00written by a newer build|r - left as it is, not rewritten.")
    end
    if report.failed then
        ns.Print("  |cFFFFAA00migration to shape %s failed:|r %s",
            tostring(report.failed), tostring(report.error))
    end
    if #report.migrated > 0 then
        local steps = {}
        for i = 1, #report.migrated do steps[i] = tostring(report.migrated[i]) end
        ns.Print("  migrated through shape(s) |cFFC2C6D8%s|r.", table.concat(steps, ", "))
    end

    PrintList("reset to defaults", report.reset)
    PrintList("repaired", report.repaired)
    PrintList("dropped", report.pruned)

    if #report.reset == 0 and #report.repaired == 0 and #report.pruned == 0 then
        ns.Print("  every setting came through as it was saved.")
    end
end
