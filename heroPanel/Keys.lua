--[[--------------------------------------------------------------------------
    heroPanel - Keys.lua

    Party key checks. Watches group chat for one of the eight short commands
    everybody already types when a group is forming - !keys, ?key and the rest -
    and answers by linking the player's own keystone into chat.

    Every group member running heroPanel answers the same line with their own
    key, which is the point: one person types two characters and the whole
    party's keystones are on screen, without anybody having to open a bag.

    Why the bags rather than an addon message
    -----------------------------------------
    This started as a request to Ascension_MythicPlus, on the theory that the
    addon which owns the keystone data should be the one to publish it:

        SendAddonMessage("ASC_MYTHIC_PLUS", "RequestKeystones", "PARTY")

    That does nothing on this client. Not "nothing useful" - nothing at all,
    typed by hand at the chat bar as a /run, with a key in the bag and a party
    to send it to. No reply, no error, no chat output. Whatever Ascension's
    addon listens for, it is not that prefix and message, and since
    Ascension_MythicPlus is server-delivered rather than shipped in
    Interface/AddOns, there is no source on disk to read the real protocol out
    of. Guessing at a second one is not better than guessing at the first.

    So the request was abandoned in favour of what the WeakAura this replaces
    actually did, which works because it asks nobody's permission: each client
    reads its own bags, finds the keystone item, and links it. The item link is
    the message. No protocol, no other addon in the path, and the answer is
    readable by everyone in the group whether or not they run anything at all.

    The API-message version is left commented in Announce below rather than
    deleted, so the next person to have the same good idea can see that it was
    had, tried and did not work.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local keys = {}
ns.Keys = keys

--------------------------------------------------------------------------------
-- What is listened for
--
-- Four sigils over two spellings. Which sigil a server's players settle on is
-- a matter of local habit rather than anything the addon can know, and a
-- request that only works when typed one particular way is a request most of
-- the party will conclude is broken.
--------------------------------------------------------------------------------

local COMMANDS = {
    ["!keys"] = true, ["?keys"] = true, ["#keys"] = true, ["$keys"] = true,
    ["!key"]  = true, ["?key"]  = true, ["#key"]  = true, ["$key"]  = true,
}

-- Published so the options window and the slash reply can list them without
-- keeping a second copy that goes stale.
keys.COMMANDS = { "!keys", "?keys", "#keys", "$keys", "!key", "?key", "#key", "$key" }

-- Every channel a group talks in, which is more than the party.
--
-- The WeakAura this replaces listened on all six and it was right to: a key
-- check happens while a group is forming, and a group forming for a dungeon is
-- as likely to be in instance chat as in party chat. Raid is here because a
-- five-man is sometimes assembled out of a raid that is breaking up.
--
-- The three _LEADER variants are separate events on this client rather than a
-- flag on the base one, and the leader is the person most likely to be asking.
--
-- CHAT_MSG_INSTANCE_CHAT does not exist on a stock 3.3.5a client, so these are
-- registered defensively - see Subscribe.
local CHAT_EVENTS = {
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER",
}

-- What marks an item link as a keystone. Matched against the item's name, and
-- plain rather than as a pattern.
--
-- A name match rather than an item ID because there is no single keystone item
-- to key off: every dungeon and every level is its own item. The datamine lists
-- 6700 of them spread from 60008 to 2712518, which is not a range anything can
-- usefully test against - the Mythical Keystone Cache below sits right in the
-- middle of it. The name is the one part that has to stay stable, because
-- players read it.
local KEYSTONE_MARK = "Keystone"

-- A real keystone is named "Keystone: <Dungeon> (<level>)", so its name begins
-- with this. Preferred over a loose match rather than required, because the
-- naming is Ascension's to change and a check that misses a renamed keystone
-- entirely is worse than one that occasionally links the wrong thing.
local KEYSTONE_PREFIX = "Keystone:"

-- Items that carry "Keystone" in their name and are not one.
--
-- The Mythical Keystone Cache is the box the keystone comes out of, and it can
-- sit in the bags beside the keystone itself - so a plain "does the name
-- contain Keystone" test would answer a key check by linking the box. The ID is
-- the authoritative half; the word is the half that still works when the next
-- container is added under a different ID.
local NOT_A_KEYSTONE_ID = {
    [97243] = true,   -- Mythical Keystone Cache
}

local NOT_A_KEYSTONE_WORD = { "Cache" }

local NO_KEYSTONE = "No keystone in bags."

--------------------------------------------------------------------------------
-- Matching
--
-- Word by word rather than a substring search. "!keys" inside a longer line is
-- still a request - "anyone !keys?" is how it actually gets typed - but a
-- substring test would also fire on "monkeys", and a party that cannot say the
-- word is a party that turns the feature off.
--
-- Only *trailing* punctuation is trimmed, because the leading character is the
-- command. "!keys?" and "?key," are requests; "!" on its own is not.
--
-- This is deliberately looser than the WeakAura's anchored msg:find("^!keys"),
-- which only matched a line that *began* with the command. A key check typed
-- as "hey !keys" was ignored, which reads as the addon being broken rather
-- than as the line being malformed.
--------------------------------------------------------------------------------

local function IsRequest(message)
    if type(message) ~= "string" then return false end
    for word in string.gmatch(string.lower(message), "%S+") do
        word = string.gsub(word, "%p+$", "")
        if COMMANDS[word] then return true end
    end
    return false
end
keys.IsRequest = IsRequest

--------------------------------------------------------------------------------
-- Throttle
--
-- Five seconds, which is what the WeakAura used and long enough for the case
-- it exists for: two people asking at once, or one person typing it twice
-- because the first answer had not appeared yet. This reply is visible chat
-- rather than a silent addon message, so a duplicate is not merely redundant -
-- it is the addon spamming the group on the player's behalf.
--
-- The manual /hp keys ignores it deliberately: somebody typing the command
-- themselves has decided the last answer was not good enough.
--------------------------------------------------------------------------------

local THROTTLE = 5

local lastSent = 0

local function Now()
    if type(GetTime) == "function" then
        local ok, value = pcall(GetTime)
        if ok and type(value) == "number" then return value end
    end
    return 0
end

--------------------------------------------------------------------------------
-- Reading the bags
--------------------------------------------------------------------------------

-- The displayed name inside an item link, or the whole link if it has none.
--
-- An item link is |cXXXXXXXX|Hitem:id:...|h[Name]|h|r, so the name is what sits
-- between the brackets. Reading it out matters: the link text also carries the
-- item ID, and testing the whole link for a word means digits can match one.
local function LinkName(link)
    return string.match(link, "%[(.-)%]") or link
end

local function LinkItemID(link)
    return tonumber(string.match(link, "|Hitem:(%d+)"))
end

-- Something with "Keystone" in its name that is not a keystone.
local function IsImpostor(link, name)
    if NOT_A_KEYSTONE_ID[LinkItemID(link) or 0] then return true end
    for i = 1, #NOT_A_KEYSTONE_WORD do
        if string.find(name, NOT_A_KEYSTONE_WORD[i], 1, true) then return true end
    end
    return false
end

-- The player's keystone, as an item link, or nil.
--
-- Bags 0 to 4: the backpack and the four bag slots. The bank is deliberately
-- not searched - it cannot be read while away from it, and a keystone in the
-- bank is not one that can be run tonight anyway.
--
-- Two passes' worth of judgement in one loop. An item whose name *begins*
-- "Keystone:" is the real thing and wins outright; anything else that merely
-- contains "Keystone" is held as a fallback and only used if the bags turn out
-- to have nothing better. That ordering is what makes the exclusions above a
-- second line of defence rather than the only one: with a cache and a keystone
-- in the bags at once - which is the normal state, since the keystone comes out
-- of the cache - the keystone is linked even if a future container slips the
-- list entirely.
function keys.FindKeystone()
    if type(GetContainerNumSlots) ~= "function" then return nil end
    if type(GetContainerItemLink) ~= "function" then return nil end

    local fallback

    for bag = 0, 4 do
        local slots = 0
        local ok, count = pcall(GetContainerNumSlots, bag)
        if ok then slots = tonumber(count) or 0 end

        for slot = 1, slots do
            local gotLink, link = pcall(GetContainerItemLink, bag, slot)
            if gotLink and type(link) == "string" then
                local name = LinkName(link)

                if string.find(name, KEYSTONE_MARK, 1, true) and not IsImpostor(link, name) then
                    if string.sub(name, 1, #KEYSTONE_PREFIX) == KEYSTONE_PREFIX then
                        return link
                    end
                    fallback = fallback or link
                end
            end
        end
    end

    if fallback then
        ns.Debug("no item named '%s...' in the bags; falling back to %s.",
            KEYSTONE_PREFIX, tostring(LinkName(fallback)))
    end
    return fallback
end

--------------------------------------------------------------------------------
-- Answering
--------------------------------------------------------------------------------

function keys.IsEnabled()
    local block = ns.db and ns.db.keys
    if type(block) ~= "table" then return false end
    return block.respond and true or false
end

function keys.SetEnabled(value)
    if not ns.db then return false end
    if type(ns.db.keys) ~= "table" then ns.db.keys = {} end
    ns.db.keys.respond = value and true or false
    return ns.db.keys.respond
end

local function GroupSize(fn)
    if type(fn) ~= "function" then return 0 end
    local ok, count = pcall(fn)
    if not ok then return 0 end
    return tonumber(count) or 0
end

-- Where the answer goes. A raid takes precedence, because a player in a raid
-- is in a party as well and PARTY would reach four of the forty.
--
-- INSTANCE_CHAT is deliberately not a reply channel even though it is a
-- listening one. A group that has an instance chat has a party too, the party
-- reaches the same people, and PARTY is the channel that works whether or not
-- this client has the instance one at all.
local function ReplyChannel()
    if GroupSize(_G.GetNumRaidMembers) > 0 then return "RAID" end
    return "PARTY"
end

local function InGroup()
    return GroupSize(_G.GetNumPartyMembers) > 0
        or GroupSize(_G.GetNumRaidMembers) > 0
end

-- Returns sent, detail. When sent is false, detail names why not - for the
-- debug line and the slash reply. When true, detail is the link that went out,
-- or nil if the "no keystone" line did.
function keys.Announce(force)
    if type(SendChatMessage) ~= "function" then
        return false, "this client has no SendChatMessage"
    end
    if not InGroup() then
        return false, "you are not in a group"
    end

    if not force then
        local elapsed = Now() - lastSent
        if lastSent > 0 and elapsed < THROTTLE then
            return false, string.format("throttled, %.1fs of %ds", elapsed, THROTTLE)
        end
    end

    local channel = ReplyChannel()
    local link    = keys.FindKeystone()

    ----------------------------------------------------------------------
    -- The shelved version.
    --
    -- This is what heroPanel did first, and it is left here rather than in
    -- the git history because the idea is a good enough one to be had
    -- twice. It produces nothing on this client - no reply, no error, not
    -- even when run by hand as a /run with a key in the bag and a party to
    -- answer. See the note at the top of this file.
    --
    --     SendAddonMessage("ASC_MYTHIC_PLUS", "RequestKeystones", channel)
    --
    -- If a future build of Ascension_MythicPlus turns up in
    -- Interface/AddOns, its real prefix and message are worth reading out
    -- of it: an addon message would answer for the whole group at once
    -- rather than one line per heroPanel user, and would not put anything
    -- in chat that the player did not type.
    ----------------------------------------------------------------------

    local ok = pcall(SendChatMessage, link or NO_KEYSTONE, channel)
    if not ok then
        return false, "SendChatMessage refused"
    end

    lastSent = Now()
    return true, link
end

--------------------------------------------------------------------------------
-- The listener
--
-- The player's own line is answered like anyone else's. The answer is this
-- client's own keystone rather than a reply to the asker, so a client that
-- skipped its own would be one that never announces the player's key when the
-- player is the one organising the group.
--------------------------------------------------------------------------------

local function OnGroupMessage(message, sender)
    if not keys.IsEnabled() then return end
    if not IsRequest(message) then return end

    local sent, detail = keys.Announce(false)
    if sent then
        ns.Debug("key check from %s - answered with %s.",
            tostring(sender or "?"), detail and tostring(detail) or "no keystone")
    else
        ns.Debug("key check from %s - not answered (%s).",
            tostring(sender or "?"), tostring(detail))
    end
end

-- Registered defensively. ns:On hands the event straight to RegisterEvent,
-- which throws on a name the client does not know, and a throw at file scope
-- takes the whole file with it - so one missing event would cost the other
-- five. CHAT_MSG_INSTANCE_CHAT is the one that is genuinely not on a stock
-- 3.3.5a client.
local function Subscribe(event, fn)
    local ok, err = pcall(function() ns:On(event, fn) end)
    if not ok then ns.Debug("could not register %s: %s", event, tostring(err)) end
    return ok
end

keys.listening = {}
for i = 1, #CHAT_EVENTS do
    local event = CHAT_EVENTS[i]
    if Subscribe(event, OnGroupMessage) then
        table.insert(keys.listening, event)
    end
end

--------------------------------------------------------------------------------
-- Status
--------------------------------------------------------------------------------

function keys.PrintStatus()
    if not keys.IsEnabled() then
        ns.Print("  |cFF8B8FA3party key checks off|r")
        return
    end

    ns.Print("  |cFF79C68Dparty key checks on|r - answering %s",
        table.concat(keys.COMMANDS, " "))
    ns.Print("    on %d chat event(s); replies by linking your keystone",
        #keys.listening)

    local link = keys.FindKeystone()
    ns.Print("    your keystone: %s", link or "|cFF8B8FA3none in bags|r")
end
