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
-- Taking the tracker back
--
-- Everything above is advisory: it says what it found and leaves the fixing to
-- the player. That was not enough. Two addons on one tracker does not degrade
-- gracefully - it produces a tracker that is blank, or unmovable, or both, with
-- nothing on screen to say why, and a chat line three seconds into login is not
-- where anybody is looking when that happens.
--
-- So the cases heroPanel can actually resolve are resolved, with the player's
-- say-so. Each handler below knows three things: how to tell that the other
-- addon has the tracker, how to hand it back, and what to say when it cannot.
--
-- Both of these drive the other addon's own published controls. Nothing here
-- reaches into a local, re-implements another addon's teardown, or edits a
-- saved variable behind its back - it is the same call their own checkbox makes,
-- so their cleanup runs exactly as it would have if the player had clicked it.
-- That is the difference between cooperating and meddling, and it is the line
-- this file does not cross.
--------------------------------------------------------------------------------

local HANDLERS = {}

--------------------------------------------------------------------------------
-- DeModal
--
-- DeModal skins and anchors a great many frames, and the objective tracker is
-- only one of them - so "disable DeModal" is the wrong advice. It has its own
-- switch for exactly this overlap, and its tooltip names the case: "Resolves
-- conflicts with DragonUI or other layout/tracker addons."
--
-- The switch is a checkbox in Blizzard's own options panel. Ticking it for the
-- player runs DeModal's OnClick, which drops the tracker out of its movable
-- set, un-movables it and hides its lock button. Writing DEMODAL_DB directly
-- would set the flag and skip all of that, which is how you get a half-released
-- frame - so the checkbox is driven and the flag is only a fallback for a build
-- whose script is missing.
--
-- Older DeModal builds have no such option. That is worth telling apart,
-- because the advice is completely different, and it is detectable: the
-- checkbox is a named global, so its absence is the old build.
--------------------------------------------------------------------------------

HANDLERS.demodal = {
    label = "DeModal",

    Present = function()
        -- The flag first, and the order matters. DeModal only ever sets
        -- deModalHooked - nothing clears it - so the marker is still on the
        -- frame for the rest of the session after its objectives features are
        -- switched off, and reading the marker first would go on reporting a
        -- conflict that has just been resolved. From the next load the guards
        -- inside DeModal stop it hooking at all and the marker never appears.
        if _G.DEMODAL_DB and _G.DEMODAL_DB.disableObjectives then return false end

        -- Then the marker, which is what says DeModal has actually taken this
        -- tracker rather than merely being installed alongside it.
        local watch = ns.GetTrackerFrame and ns.GetTrackerFrame("watch")
        if watch and watch.deModalHooked then return true end
        return _G.DEMODAL_DB ~= nil
    end,

    Resolved = function()
        return _G.DEMODAL_DB ~= nil and _G.DEMODAL_DB.disableObjectives and true or false
    end,

    -- The option exists to be ticked. Its absence means an old build.
    CanFix = function() return _G.DeModalDisableObjectives ~= nil end,

    Fix = function()
        local box = _G.DeModalDisableObjectives
        if box then
            -- SetChecked and then the handler, rather than Click. Click toggles,
            -- and a box that somehow reads as already ticked while the flag is
            -- off would be turned the wrong way by it.
            pcall(box.SetChecked, box, true)
            local onClick = box.GetScript and box:GetScript("OnClick")
            if onClick then
                local ok = pcall(onClick, box)
                if ok then return true end
            end
        end

        -- No control to drive. The flag is the guard DeModal itself tests at
        -- the top of its objectives code, so setting it still calls the whole
        -- feature off from the next load - which is why this path reloads too.
        if _G.DEMODAL_DB then
            _G.DEMODAL_DB.disableObjectives = true
            return true
        end
        return false
    end,

    fixText =
        "|cFF9184D9DeModal|r is also skinning and anchoring the objective tracker.\n\n"
        .. "Two addons on one tracker is what leaves it blank, or stuck where it is.\n\n"
        .. "heroPanel can switch off DeModal's |cFFC2C6D8Disable Objectives Features|r "
        .. "option for you. That is DeModal's own setting for this exact conflict, and "
        .. "every other frame DeModal skins is left alone.\n\n"
        .. "Your UI will reload.",

    staleText =
        "|cFF9184D9DeModal|r is also skinning and anchoring the objective tracker, and "
        .. "this build of DeModal has no option to turn that off.\n\n"
        .. "|cFFC2C6D8Update DeModal.|r The newer builds are in the zips at the bottom "
        .. "of the DeModal thread.\n\n"
        .. "Then tick |cFFC2C6D8Escape > Interface > AddOns > DeModal > Disable "
        .. "Objectives Features|r and reload.\n\n"
        .. "Until then only one of the two can own the tracker.",

    -- Said in chat as well, because a popup that is dismissed takes its
    -- instructions with it and this one is a sequence of clicks to remember.
    chatHint =
        "DeModal is skinning the objective tracker. Tick |cFFC2C6D8Escape > Interface "
        .. "> AddOns > DeModal > Disable Objectives Features|r and |cFFC2C6D8/reload|r. "
        .. "No such option means an out-of-date DeModal - the newer zips are at the "
        .. "bottom of the DeModal thread.",
}

--------------------------------------------------------------------------------
-- MoveAnything
--
-- A different overlap, and a worse-behaved one. MoveAnything does not skin
-- anything - it owns position and scale - so on paper it and heroPanel do not
-- compete at all. In practice it locks both:
--
--   * MALockPointHook hooks SetPoint and puts its own anchor back, so a frame
--     dragged with heroPanel's mover snaps home the moment the drag is saved.
--   * MAScaled hooks SetScale on the widget metatable and calls Rescale back to
--     its own number, so heroPanel's resize grip appears to do nothing at all.
--
-- Neither of those announces itself, which is the real problem: the player gets
-- a mover that does not move and a grip that does not grip, and no reason.
--
-- MoveAnything's per-frame controls are in its own window rather than in the
-- Blizzard options panel, which is why players look for a switch and do not
-- find one. DisableFrame is what its window calls, and it takes a frame name.
--------------------------------------------------------------------------------

HANDLERS.moveanything = {
    label = "MoveAnything",

    Present = function()
        local watch = ns.GetTrackerFrame and ns.GetTrackerFrame("watch")
        if not watch then return false end
        return (watch.MAScaled ~= nil) or (watch.MALockPointHook ~= nil)
    end,

    Resolved = function()
        local watch = ns.GetTrackerFrame and ns.GetTrackerFrame("watch")
        if not watch then return false end
        return watch.MAScaled == nil and watch.MALockPointHook == nil
    end,

    CanFix = function()
        return type(_G.MovAny) == "table" and type(_G.MovAny.DisableFrame) == "function"
    end,

    Fix = function()
        local watch = ns.GetTrackerFrame and ns.GetTrackerFrame("watch")
        local name  = watch and watch.GetName and watch:GetName()
        if not name then return false end
        -- Its own call, so its own reset and its own saved options are what
        -- record the change. Only this frame is named; the rest of the player's
        -- MoveAnything layout is untouched.
        return pcall(_G.MovAny.DisableFrame, _G.MovAny, name) and true or false
    end,

    fixText =
        "|cFF9184D9MoveAnything|r is controlling the objective tracker's position and size.\n\n"
        .. "While it does, heroPanel's mover and resize grip cannot move or scale the "
        .. "tracker - MoveAnything puts it straight back.\n\n"
        .. "heroPanel can release |cFFC2C6D8just the objective tracker|r from "
        .. "MoveAnything. Every other frame you have moved with it is left alone.\n\n"
        .. "Your UI will reload.",

    staleText =
        "|cFF9184D9MoveAnything|r is controlling the objective tracker's position and "
        .. "size, and heroPanel could not reach its controls to release it.\n\n"
        .. "Open MoveAnything with |cFFC2C6D8/ma|r, find |cFFC2C6D8WatchFrame|r in the "
        .. "list and reset it. Its per-frame controls are in that window, not in the "
        .. "Blizzard options panel.\n\n"
        .. "Or run |cFFC2C6D8/hp mode yield|r to let MoveAnything place the tracker "
        .. "while heroPanel only skins it.",

    chatHint =
        "MoveAnything is positioning and scaling the objective tracker, so heroPanel's "
        .. "mover and resize grip cannot. Open |cFFC2C6D8/ma|r, find "
        .. "|cFFC2C6D8WatchFrame|r and reset it - the per-frame controls are in that "
        .. "window, not the Blizzard options panel.",
}

--------------------------------------------------------------------------------
-- Asking, and acting
--------------------------------------------------------------------------------

-- One prompt per session per addon. The check runs again on later logins
-- because the answer can change - the player may have fixed it, or installed
-- something new - but nagging twice in one sitting for a thing that needs a
-- reload to take effect is just noise.
local prompted = {}

local POPUP = "HEROPANEL_TAKEOVER"

local function InstallPopup()
    if type(_G.StaticPopupDialogs) ~= "table" then return false end
    if _G.StaticPopupDialogs[POPUP] then return true end

    _G.StaticPopupDialogs[POPUP] = {
        text         = "%s",
        button1      = ACCEPT or "Okay",
        button2      = CANCEL or "Cancel",
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
        -- Off the low indices, which the client reuses for its own dialogs.
        preferredIndex = 3,
        OnAccept = function(self)
            local handler = self and self.heroPanelHandler
            if not handler then return end
            if not handler.CanFix() then return end

            if handler.Fix() then
                ns.Print("%s released the objective tracker. Reloading.", handler.label)
                if type(_G.ReloadUI) == "function" then _G.ReloadUI() end
            else
                ns.Warn("could not change %s's setting automatically. %s",
                    handler.label, handler.chatHint)
            end
        end,
        OnCancel = function(self)
            local handler = self and self.heroPanelHandler
            if handler then ns.Warn(handler.chatHint) end
        end,
    }
    return true
end

-- Shows the dialog and returns whether it got on screen. A client with no
-- StaticPopup - the harness is one - falls back to chat rather than failing.
local function Ask(handler, fixable)
    if not InstallPopup() then
        ns.Warn(handler.chatHint)
        return false
    end

    local dialog = _G.StaticPopup_Show(POPUP, fixable and handler.fixText or handler.staleText)
    if not dialog then
        ns.Warn(handler.chatHint)
        return false
    end

    -- Carried on the dialog rather than in an upvalue, because two of these can
    -- be queued at once and each button must act on its own one.
    --
    -- Left nil when there is nothing to fix, which is what makes both buttons
    -- dismiss: OnAccept returns early without a handler. The dialog is then
    -- purely instructions, and the wording carries that rather than the buttons.
    dialog.heroPanelHandler = fixable and handler or nil
    return true
end

local ORDER = { "demodal", "moveanything" }

function ns.CheckTakeovers()
    for i = 1, #ORDER do
        local handler = HANDLERS[ORDER[i]]
        if handler and not prompted[ORDER[i]] then
            local ok, present = pcall(handler.Present)
            if ok and present then
                prompted[ORDER[i]] = true

                local canFix = false
                local gotFix, result = pcall(handler.CanFix)
                if gotFix then canFix = result and true or false end

                ns.Debug("%s has the objective tracker; %s.", handler.label,
                    canFix and "offering to release it" or "no control to drive")
                Ask(handler, canFix)

                -- One at a time. Two stacked dialogs about the same frame is a
                -- pile-on, and the second is often moot once the first is done.
                return
            end
        end
    end
end

-- Exposed so /hp can re-run it after the player has changed something, rather
-- than making them reload to find out whether it is sorted.
ns.CompatHandlers = HANDLERS

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

    -- After the conflict line, and later again, for two reasons: the markers
    -- these read are stamped on the frame by the other addon at its own pace,
    -- and a dialog thrown up in the middle of the login rush is a dialog
    -- clicked away without being read.
    ns.After(5, ns.CheckTakeovers)

    if not ns.DEBUG then return end

    ns.Debug("%s v%s ready. Objective skin %s, Mythic+ skin %s, frames %s.",
        ADDON_NAME, ns.version,
        ns.SkinEnabled("watch") and "enabled" or "disabled",
        ns.SkinEnabled("mplus") and "enabled" or "disabled",
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
