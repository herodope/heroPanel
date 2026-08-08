--[[--------------------------------------------------------------------------
    heroPanel - Compat.lua

    Conflict detection. Purely informational: heroPanel installs all of its own
    hooks regardless of what else is loaded. If another addon is known to take
    an interest in the same frames, the user is told once per session so they
    can decide what to do about it. Nothing is disabled and no hook is skipped.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

-- Addons that also drive WatchFrame / MythicPlusObjectiveTracker.
-- name         the addon folder name passed to the addon API
-- globals      globals that prove the addon is live even if the API disagrees
local CONFLICTS = {
    { name = "DeModal", label = "DeModal", globals = { "DeModal" } },
    { name = "ElvUI",   label = "ElvUI",   globals = { "ElvUI" } },
}

ns.conflictsWarned = false

local function IsLoadedOrEnabled(entry)
    if IsAddOnLoaded and IsAddOnLoaded(entry.name) then return true, "loaded" end

    if GetAddOnInfo then
        -- 3.3.5a signature: name, title, notes, enabled, loadable, reason, security
        local ok, _, _, _, enabled, loadable = pcall(GetAddOnInfo, entry.name)
        if ok and enabled and loadable then return true, "enabled" end
    end

    for i = 1, #entry.globals do
        if _G[entry.globals[i]] ~= nil then return true, "present" end
    end

    return false
end

function ns.CheckConflicts()
    if ns.conflictsWarned then return end

    local detected = {}
    for i = 1, #CONFLICTS do
        local found, how = IsLoadedOrEnabled(CONFLICTS[i])
        if found then
            table.insert(detected, CONFLICTS[i].label)
            ns.Debug("conflict candidate %s (%s).", CONFLICTS[i].label, tostring(how))
        end
    end

    if #detected == 0 then
        ns.Debug("no conflicting tracker addons detected.")
        ns.conflictsWarned = true
        return
    end

    ns.conflictsWarned = true
    local others = table.concat(detected, "/")

    -- Another addon being present is not by itself a problem. What matters is
    -- how the overlap actually resolved, so report that rather than telling the
    -- user to disable something that is working fine alongside heroPanel.
    local cooperating, yielded = {}, {}
    for i = 1, #ns.TRACKER_KEYS do
        local key    = ns.TRACKER_KEYS[i]
        local record = ns.trackers[key]
        local mode   = ns.GetMode and ns.GetMode(key) or "own"
        if mode == "holder" then
            table.insert(cooperating, tostring(record.holderName))
        elseif mode == "yield" then
            table.insert(yielded, string.lower(record.label))
        end
    end

    if #yielded > 0 then
        ns.Warn("%s is positioning the %s and heroPanel could not share it. "
            .. "Disable that addon's objective tracker module, or run /hp mode own, "
            .. "to let heroPanel place it.",
            others, table.concat(yielded, " and "))
        return
    end

    if #cooperating > 0 then
        -- Sharing cleanly. Nothing for the user to do, so keep it out of chat.
        ns.Debug("%s detected; sharing via %s.", others, table.concat(cooperating, ", "))
        return
    end

    ns.Warn("%s also loading - both may try to control WatchFrame/MythicPlusObjectiveTracker. "
        .. "If the trackers misbehave, disable one or run /hp status to see what heroPanel resolved.",
        others)
end

ns.GetDetectedConflicts = function()
    local detected = {}
    for i = 1, #CONFLICTS do
        if IsLoadedOrEnabled(CONFLICTS[i]) then table.insert(detected, CONFLICTS[i].label) end
    end
    return detected
end

--------------------------------------------------------------------------------
-- Login report
--
-- The conflict warning is the only unconditional chat output. The load
-- confirmation and the frame report are debug-gated.
--------------------------------------------------------------------------------

ns:On("PLAYER_LOGIN", function()
    -- Deliberately deferred. Holder adoption and the Mythic+ tracker poll both
    -- resolve after login, and the message depends on how they resolved.
    ns.After(3, ns.CheckConflicts)

    if not ns.DEBUG then return end

    ns.Debug("%s v%s ready. Skin %s, frames %s.",
        ADDON_NAME, ns.version,
        (ns.db and ns.db.enabled) and "enabled" or "disabled",
        ns.IsLocked() and "locked" or "unlocked")

    -- The M+ tracker may still be polling at this point, so report once more
    -- after the polling window has had a chance to resolve.
    ns.After(3, function()
        for i = 1, #ns.TRACKER_KEYS do
            local record = ns.trackers[ns.TRACKER_KEYS[i]]
            if record.found then
                ns.Debug("%s: found as %s, mover %s, %s.",
                    record.label, tostring(record.frameName), tostring(record.moverName),
                    record.hooked and "hooked" or "not hooked")
            else
                ns.Debug("%s: not found.", record.label)
            end
        end
    end)
end)
