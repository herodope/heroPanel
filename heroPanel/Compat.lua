--[[--------------------------------------------------------------------------
    heroPanel - Compat.lua

    Conflict detection. Purely informational: heroPanel installs all of its own
    hooks regardless of what else is loaded. If another addon is known to take
    an interest in the same frames, the user is told once per session so they
    can decide what to do about it. Nothing is disabled and no hook is skipped.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

-- Addons that also drive WatchFrame, MythicPlusObjectiveTracker or
-- LFGObjectiveTracker. DeModal moves and skins all three.
-- name         the addon folder name passed to the addon API
-- globals      globals that prove the addon is live even if the API disagrees.
--              Only consulted for entries without an Active test.
-- Active       optional, and when present it is the whole test: installed is
--              not enough, the entry only counts while this says the
--              overlapping feature is switched on. DeModal and ElvUI take the
--              tracker by being loaded at all, so they have none. Leatrix Plus
--              is a hundred-odd unrelated tweaks with one checkbox that touches
--              the tracker, off by default - warning its whole user base about
--              a feature they have not enabled is noise, and noise is what gets
--              a warning ignored.
local CONFLICTS = {
    { name = "DeModal", label = "DeModal", globals = { "DeModal" } },
    { name = "ElvUI",   label = "ElvUI",   globals = { "ElvUI" } },
    {
        name   = "Leatrix_Plus",
        label  = "Leatrix Plus",
        Active = function() return ns.LeatrixHasTracker() end,
    },
}

ns.conflictsWarned = false

local function IsLoadedOrEnabled(entry)
    if entry.Active then
        local ok, active = pcall(entry.Active)
        if ok and active then return true, "active" end
        return false
    end

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
-- Leatrix Plus
--
-- The third shape of this problem, and the most destructive of the three.
-- Leatrix Plus is a large quality-of-life addon - a hundred-odd unrelated
-- tweaks - and exactly one of them, "Manage Quest Tracker" on its Frames page,
-- touches WatchFrame. It is off by default. When it is on, its Player() handler
-- does this at PLAYER_LOGIN:
--
--     trackerContainer.SetPoint = function(self, _, relativeTo)
--         if not InCombatLockdown() and not isWatchFrameMoving
--            and relativeTo ~= trackerHolder then
--             WatchFrameSetPoint(self, 'TOPRIGHT', trackerHolder)
--             self:SetParent(trackerHolder)
--         end
--     end
--
-- Read that carefully, because two separate things go wrong and only one of
-- them is the obvious one.
--
--   * It is a *replacement*, not a hook. It rawsets over WatchFrame.SetPoint -
--     and heroPanel installs its anchor watch with hooksecurefunc, which is
--     itself a rawset on the same key. Leatrix runs at PLAYER_LOGIN and
--     heroPanel hooks at ADDON_LOADED, so Leatrix wins and heroPanel's SetPoint
--     hook is simply gone for the session. The one thing that notices the
--     tracker being re-anchored no longer fires.
--   * It discards its own arguments. Every heroPanel SetPoint on the tracker -
--     the mover, the restore-on-show, the geometry re-apply - is swallowed and
--     answered with Leatrix's own anchor instead.
--
-- So the mover moves nothing, and the contention detector that exists to notice
-- precisely that has been unhooked. Nothing degrades, nothing warns, and the
-- player is left dragging a tracker that will not move for no stated reason.
-- (The SetParent hook does survive, and Leatrix calls SetParent from inside its
-- replacement, so heroPanel eventually observes the holder and steps down to
-- holder mode after a visible tug-of-war. That is a floor, not a fix.)
--
-- Detection is off Leatrix's own configuration panel rather than off its addon
-- name or its saved variables. LeaPlusGlobalPanel_TrackerPanel is created by
-- CreatePanel inside the feature's `if` block and nowhere else, so its
-- existence means the feature ran - which is the question, since the option is
-- off by default and is locked out entirely when ElvUI is handling frames.
--
-- Releasing it is where Leatrix differs from the other two, and the difference
-- is worth spelling out because the obvious approach is wrong. Leatrix keeps
-- its live settings in LeaPlusLC, which is a file-local - there is no global
-- handle on it at all. Only LeaPlusDB, the saved variable, is reachable, and
-- writing that is worse than useless: Leatrix rewrites LeaPlusDB from LeaPlusLC
-- at PLAYER_LOGOUT, so a value poked into it is overwritten by the reload that
-- was supposed to apply it. LeaPlusDB is therefore read here and never written.
--
-- What is reachable is the checkbox, because the panel it lives on is a named
-- global. Driving it runs Leatrix's own OnClick, which sets LeaPlusLC inside
-- their closure, and their logout handler then saves it - the same sequence as
-- the player ticking it themselves. The checkbox is anonymous, so it is found
-- by walking the panel and matching its label; a build that renames the caption
-- falls into the instructions path rather than doing something approximate.
--------------------------------------------------------------------------------

-- Leatrix's own caption, minus the "*" MakeCB appends to mark a reload-required
-- option. It is not in Leatrix_Plus_Locale.lua under any locale, so the L[]
-- lookup falls through to the key and this is the on-screen text everywhere.
-- The second entry is the older, shorter wording.
local LEATRIX_CAPTIONS = {
    ["manage quest tracker"] = true,
    ["manage tracker"]       = true,
}

local function LeatrixLabelMatches(box)
    local label = box.f
    if type(label) ~= "table" or type(label.GetText) ~= "function" then return false end

    local ok, text = pcall(label.GetText, label)
    if not ok or type(text) ~= "string" then return false end

    text = string.lower(text)
    text = string.gsub(text, "%*", "")
    text = string.gsub(text, "^%s*(.-)%s*$", "%1")
    return LEATRIX_CAPTIONS[text] and true or false
end

-- The Frames page is a child of the main panel and the checkbox is a child of
-- the page, so two levels down. Regions are skipped - the label is read off the
-- checkbox's own .f rather than found by walking - and the depth is capped just
-- past where the answer is, because this runs on a panel with several hundred
-- widgets on it.
local function FindLeatrixTrackerCheckbox()
    local panel = _G.LeaPlusGlobalPanel
    if type(panel) ~= "table" or type(ns.WalkFrameTree) ~= "function" then return nil end

    local found
    ns.WalkFrameTree(panel, function(object, info)
        if found then return false end
        if info.objectType ~= "CheckButton" then return end
        if LeatrixLabelMatches(object) then found = object end
    end, { includeRegions = false, maxDepth = 3 })

    return found
end

-- The gear button beside the checkbox, which is its only child frame. Leatrix
-- dims it to alpha 0.3 whenever the option is off, from SetDim() at the end of
-- the same OnClick - so it is the one piece of LeaPlusLC's state that is
-- visible from outside, and the only way to confirm the flip actually landed.
local function LeatrixConfigButton(box)
    local ok, children = pcall(function() return { box:GetChildren() } end)
    if not ok then return nil end
    for i = 1, #children do
        local child = children[i]
        if child and child.GetAlpha and child.GetObjectType
           and child:GetObjectType() == "Button" then
            return child
        end
    end
    return nil
end

-- Leatrix's holder is created with no name, so this asks the shape of the
-- question rather than the name: is the tracker hanging off some unnamed frame
-- that is not UIParent? A named holder - ElvUI's WatchFrameHolder is the one in
-- the wild - is not this, and is handled by Move.lua's holder mode instead.
local function DockedIntoUnnamedFrame()
    local watch = ns.GetTrackerFrame and ns.GetTrackerFrame("watch")
    if not watch then return false end

    local function Unnamed(object)
        if type(object) ~= "table" or object == UIParent then return false end
        if type(object.GetName) ~= "function" then return false end
        local ok, objectName = pcall(object.GetName, object)
        return ok and (objectName == nil or objectName == "")
    end

    local gotParent, parent = pcall(watch.GetParent, watch)
    if gotParent and Unnamed(parent) then return true end

    local gotCount, count = pcall(watch.GetNumPoints, watch)
    if not gotCount or type(count) ~= "number" then return false end
    for i = 1, count do
        local gotPoint, _, relativeTo = pcall(watch.GetPoint, watch, i)
        if gotPoint and Unnamed(relativeTo) then return true end
    end
    return false
end

-- Also read by the CONFLICTS table at the top of the file, so the login line
-- stays quiet for the many Leatrix users who never turned this on.
function ns.LeatrixHasTracker()
    -- The flag first, for the reason spelled out on DeModal.Present: after the
    -- fix and its reload this reads "Off" and nothing else needs consulting.
    local db = _G.LeaPlusDB
    if type(db) == "table" and db.ManageTracker == "Off" then return false end

    -- The panel is the marker. It exists only because the feature ran.
    if _G.LeaPlusGlobalPanel_TrackerPanel ~= nil then return true end

    -- A build that stops creating that panel still has to dock the tracker
    -- somewhere, so fall back to the frame itself. Gated on the option being on
    -- so this cannot pin another addon's unnamed holder on Leatrix.
    if type(db) == "table" and db.ManageTracker == "On" then
        return DockedIntoUnnamedFrame()
    end
    return false
end

HANDLERS.leatrix = {
    label = "Leatrix Plus",

    Present = function() return ns.LeatrixHasTracker() end,

    Resolved = function()
        local db = _G.LeaPlusDB
        return type(db) == "table" and db.ManageTracker == "Off" and true or false
    end,

    CanFix = function() return FindLeatrixTrackerCheckbox() ~= nil end,

    Fix = function()
        local box = FindLeatrixTrackerCheckbox()
        if not box then return false end

        local onClick = box.GetScript and box:GetScript("OnClick")
        if type(onClick) ~= "function" then return false end

        -- SetChecked and then the handler, rather than Click, for the same
        -- reason as DeModal: Click toggles, and a box that somehow reads as
        -- already unticked would be turned back on by it.
        pcall(box.SetChecked, box, false)

        -- The return value is deliberately ignored. Leatrix's OnClick sets its
        -- option and then calls Live(), which runs a great deal of unrelated
        -- code; a throw in there leaves the option correctly set and would
        -- still fail a pcall. What actually happened is read off the frames
        -- below instead of inferred from whether the call came back clean.
        pcall(onClick, box)

        local stillChecked = box.GetChecked and box:GetChecked()
        if stillChecked then return false end

        local gear = LeatrixConfigButton(box)
        if gear then
            local ok, alpha = pcall(gear.GetAlpha, gear)
            -- Dimmed means Leatrix's own SetDim ran and read the option as off,
            -- which is the confirmation that LeaPlusLC really changed and not
            -- just the checkbox art.
            if ok and type(alpha) == "number" then return alpha < 0.9 end
        end

        -- No gear button to read. The tick is the only evidence there is.
        return true
    end,

    fixText =
        "|cFF9184D9Leatrix Plus|r is positioning the objective tracker.\n\n"
        .. "It replaces the tracker's anchor outright, so heroPanel's mover cannot "
        .. "move it and gets no say in where it goes.\n\n"
        .. "heroPanel can untick Leatrix Plus's |cFFC2C6D8Manage Quest Tracker|r "
        .. "option for you. That is the one option of its hundred-odd that touches "
        .. "the tracker; everything else Leatrix Plus does is left alone.\n\n"
        .. "Your UI will reload.",

    staleText =
        "|cFF9184D9Leatrix Plus|r is positioning the objective tracker, and heroPanel "
        .. "could not reach its option to untick it.\n\n"
        .. "Open Leatrix Plus with |cFFC2C6D8/ltp|r, go to |cFFC2C6D8Frames|r and untick "
        .. "|cFFC2C6D8Manage Quest Tracker|r, then reload.\n\n"
        .. "Or run |cFFC2C6D8/hp mode yield|r to let Leatrix Plus place the tracker "
        .. "while heroPanel only skins it.",

    chatHint =
        "Leatrix Plus is positioning the objective tracker, so heroPanel's mover "
        .. "cannot. Open |cFFC2C6D8/ltp|r, go to |cFFC2C6D8Frames|r and untick "
        .. "|cFFC2C6D8Manage Quest Tracker|r, then |cFFC2C6D8/reload|r.",
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

-- Leatrix goes second because its overlap is the one that leaves no trace: it
-- unhooks heroPanel's anchor watch on the way past, so unlike the other two
-- there is nothing left to notice the frame being taken and degrade for it.
local ORDER = { "demodal", "leatrix", "moveanything" }

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

    ns.Debug("%s v%s ready. Objective skin %s, Mythic+ skin %s, dungeon skin %s, frames %s.",
        ADDON_NAME, ns.version,
        ns.SkinEnabled("watch")   and "enabled" or "disabled",
        ns.SkinEnabled("mplus")   and "enabled" or "disabled",
        ns.SkinEnabled("dungeon") and "enabled" or "disabled",
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
