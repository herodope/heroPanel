--[[--------------------------------------------------------------------------
    heroPanel - BoonData.lua

    The Mythical Boon table, and nothing else. Boons.lua draws the bar; this
    file only says what the boons are.

    Where this came from
    --------------------
    The client ships its own boon UI at
    Interface\FrameXML\Ascension_MythicalBoons, and it is disabled - both files
    are commented out of FrameXML.toc, and its show function is gated behind
    C_Realm.IsDevelopment(). So there is nothing to hook and nothing to read at
    runtime, but its BOON_ITEMS table is a free reference design. This table is
    that one, corrected against the live client:

      * itemID == spellID for every boon. The client says so in a comment and
        relies on it - GetSpellInfo(itemID) is where the icon and the real name
        come from, which is why no icon paths are written down here.

      * The reference has a fifth column, effectSpellID, used to pick which
        spell a tooltip describes. It is dropped. It maps Inquisition (2104923)
        to 2104924, and 2104924 is the internal holy-bolt damage component -
        its text reads "Affecting up to 0 targets" and says nothing about the
        barrier the boon actually puts on the party. The other two non-zero
        values are self-references, so the column's entire effect is to get one
        of fifteen tooltips wrong. A boon is always described by its own ID.

      * Skulking (2104934) and Bloodlust (2104935) are newer than the client's
        table, which has thirteen rows.

    What is deliberately not here
    -----------------------------
    Four IDs sit in the same block and are not usable boons:

      2104919  Mythical Blessing - a different system, just outside the block
      2104924  the damage component of Inquisition, not an item
      2104936  five rows all named "Mythical Boon: Ascension", all on the
        ..2104940  spell_paladin_clarityofpurpose placeholder icon. Unimplemented
                   reserved slots. Nothing resolves past 2104940.

    Those five reserved slots are why this file exists separately and why
    Boons.lua also detects boons by name prefix: the set is expected to grow,
    and adding one here should be a one-line edit rather than a code change.

    Note that a placeholder icon is not a reliable tell. Adaptation (2104930)
    legitimately draws on spell_paladin_clarityofpurpose too.

    Skulking's description is byte-for-byte Phasewalk's and it shares
    Phasewalk's icon. They stay two entries. Whether they behave identically on
    the server is not something the client can answer, and merging two things
    that only look the same is not a decision this file gets to make.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local data = {}
ns.BoonData = data

--------------------------------------------------------------------------------
-- Categories
--
-- The client's own three, in the client's own order. The bar draws one group
-- per category with a gap between, so this order is what the bar reads
-- left-to-right.
--------------------------------------------------------------------------------

data.CATEGORY = {
    SPELLS  = 1,
    BUFFS   = 2,
    DEFENSE = 3,
}

data.CATEGORY_NAMES = {
    "Spells and Abilities",
    "Buffs",
    "Defense",
}

--------------------------------------------------------------------------------
-- The boons
--
-- One line each, on purpose. Adding a boon should be adding a line.
--
--   id       itemID, which is also the spellID
--   name     the short name, without the "Mythical Boon: " the item carries.
--            GetSpellInfo gives the full one; this is what fits under an icon
--            and what a player calls it out loud.
--   cat      one of data.CATEGORY
--   melee    true for the two boons that only do anything for a melee build.
--            The client flags these and heroPanel offers to dim them.
--   summary  a hand-written one-liner for the in-combat tooltip.
--
-- The summaries are written out rather than parsed from
-- C_Spell:GetSpellDescription, which is what the reference does. That parse
-- pulls the |cXXXXXXXX|r coloured runs out of the live string, and the live
-- strings are not consistent enough to build a tooltip on:
--
--   * Sanctified reads "Restoring 1% health every 0.20 milliseconds", which is
--     not a rate anything could have. The wiki says 3% per second.
--   * Piercing's text mentions armour penetration only; the expertise the wiki
--     documents is not in the string, though the client's own melee-only flag
--     on this boon suggests it is real.
--   * Skulking's text is Phasewalk's, word for word.
--
-- So the live description is a fallback rather than the source, and it is
-- still reachable: boons.rawTooltip puts the full client text back for anyone
-- who would rather read that. A boon that turns up in a future build and is
-- not in this table gets the live text, because that is better than nothing.
--------------------------------------------------------------------------------

local SPELLS, BUFFS, DEFENSE = data.CATEGORY.SPELLS, data.CATEGORY.BUFFS, data.CATEGORY.DEFENSE

data.BOONS = {
    { id = 2104920, name = "Ascension",    cat = SPELLS,  melee = false, summary = "+20% damage and healing, 30s" },
    { id = 2104921, name = "Infinity",     cat = SPELLS,  melee = false, summary = "-20% cooldowns and costs, 30s" },
    { id = 2104922, name = "Momentum",     cat = BUFFS,   melee = false, summary = "+20% haste and movement speed, 30s" },
    { id = 2104923, name = "Inquisition",  cat = DEFENSE, melee = false, summary = "Barrier damages nearby enemies, 20s" },
    { id = 2104925, name = "Sanctuary",    cat = DEFENSE, melee = false, summary = "-15% damage taken, 30s" },
    { id = 2104926, name = "Bountiful",    cat = BUFFS,   melee = false, summary = "+20% Str, Agi, Sta, Spi and Int, 30s" },
    { id = 2104927, name = "Piercing",     cat = BUFFS,   melee = true,  summary = "+15% armor penetration, 30s" },
    { id = 2104928, name = "Critical",     cat = SPELLS,  melee = false, summary = "+20% critical strike chance, 30s" },
    { id = 2104929, name = "Sanctified",   cat = DEFENSE, melee = false, summary = "Restores about 3% health a second, 20s" },
    { id = 2104930, name = "Adaptation",   cat = SPELLS,  melee = true,  summary = "Spell power from 20% of attack power, 30s" },
    { id = 2104931, name = "Ruthlessness", cat = BUFFS,   melee = false, summary = "+20% critical damage and healing, 30s" },
    { id = 2104932, name = "Wrathful",     cat = BUFFS,   melee = false, summary = "+170 spell damage, +220 attack power, 30s" },
    { id = 2104933, name = "Phasewalk",    cat = DEFENSE, melee = false, summary = "Party phases out, walk past enemies, 10s" },
    { id = 2104934, name = "Skulking",     cat = DEFENSE, melee = false, summary = "Party phases out, walk past enemies, 10s" },
    { id = 2104935, name = "Bloodlust",    cat = BUFFS,   melee = false, summary = "Grants the party Bloodlust" },
}

--------------------------------------------------------------------------------
-- Detecting a boon that is not in the table
--
-- Five reserved item slots say the set is meant to grow, and a bar that cannot
-- show a boon the player is holding because the addon has not been updated is
-- a bar that is wrong at exactly the moment it matters.
--
-- So anything in the bags whose name starts with PREFIX counts as a boon.
-- "Mythical Blessing" is a different system and does not start with it, which
-- is most of the guard; EXCLUDE names it anyway, because the cost of being
-- explicit is one table and the cost of being wrong is the bar offering a
-- player an item that does nothing for them.
--
-- Boons.lua keeps a few spare buttons for these. It does not create buttons on
-- the fly - a SecureActionButtonTemplate button cannot be created in combat,
-- and a boon is looted in combat as often as not.
--------------------------------------------------------------------------------

data.PREFIX  = "Mythical Boon"
data.EXCLUDE = {
    ["Mythical Blessing"] = true,
}

-- Drawn for a boon that is not in the table. There is no art to pick from for
-- something nobody has seen yet, and the client's question mark is the one
-- icon a player already reads as "this is a thing the game knows about and I
-- do not".
data.FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

--------------------------------------------------------------------------------
-- Derived lookups
--
-- Built once at load from the table above, so the table above stays the only
-- thing anybody has to edit.
--
--   BY_ID[itemID]  -> the entry
--   GROUPED[cat]   -> the entries in that category, in table order
--   ORDER          -> every entry, category by category, which is bar order
--------------------------------------------------------------------------------

data.BY_ID   = {}
data.GROUPED = {}
data.ORDER   = {}

do
    for i = 1, #data.BOONS do
        local entry = data.BOONS[i]
        data.BY_ID[entry.id] = entry
        data.GROUPED[entry.cat] = data.GROUPED[entry.cat] or {}
        table.insert(data.GROUPED[entry.cat], entry)
    end

    for cat = 1, #data.CATEGORY_NAMES do
        local group = data.GROUPED[cat]
        if group then
            for i = 1, #group do
                table.insert(data.ORDER, group[i])
            end
        end
    end
end

-- data.IsBoonName(name) -> true when a bag item's name says it is a boon.
--
-- Used only for items this table does not already know. Matched with a plain
-- string.sub rather than a pattern, so a name with a magic character in it
-- cannot match something it was not meant to.
function data.IsBoonName(name)
    if type(name) ~= "string" then return false end
    if data.EXCLUDE[name] then return false end
    return string.sub(name, 1, #data.PREFIX) == data.PREFIX
end

-- data.Count() -> how many boons this build knows about.
function data.Count()
    return #data.BOONS
end
