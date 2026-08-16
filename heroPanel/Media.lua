--[[--------------------------------------------------------------------------
    heroPanel - Media.lua

    Fonts, by way of LibSharedMedia-3.0.

    Everything that draws text in heroPanel asks ns.GetFontFile() for a path.
    Until this file existed that answer was fixed - the client's own normal face,
    read off GameFontNormal - and HEROPANEL_DB.font.face was written down but
    never read. Now the configured face is looked up in LibSharedMedia, so any
    font pack the player has installed (SharedMediaAdditionalFonts,
    SharedMedia_Causese, ElvUI's own, anything else that registers with LSM) is
    selectable from the options panel without heroPanel knowing it exists.

    Two things this file is careful about:

      * Friz Quadrata TT is the fallback, and it does not come from LSM.
        It is the face 3.3.5a always has, so "the default works" must not depend
        on the library being present, on it having that key registered, or on
        the player's locale. GameFontNormal's own path is used, which is that
        face on a western client and the right substitute on the others.

      * A font path is validated before it is handed out. SetFont on a file the
        client will not read leaves the FontString blank, and blank text on a
        dark panel looks exactly like a skin that did not run. The probe follows
        the same shape as ns.SetTextureFile's: ask the client once whether it
        reports failures at all, because believing a client that always answers
        nil would reject every path including the good one.
----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

-- Not configurable and not looked up. This is the contract: whatever else goes
-- wrong, heroPanel draws text.
local DEFAULT_FACE = "Friz Quadrata TT"
local DEFAULT_FILE = "Fonts\\FRIZQT__.TTF"

ns.DEFAULT_FONT_FACE = DEFAULT_FACE

local media = {}
ns.Media = media

--------------------------------------------------------------------------------
-- The library
--------------------------------------------------------------------------------

local lsm, lsmResolved

-- Resolved once and kept. LibStub hands out one table per major version and
-- upgrades it in place, so a newer LibSharedMedia loading after heroPanel
-- upgrades the very table already cached here - the reference stays good and
-- the fonts that addon registers turn up in the list without a second lookup.
function media.GetLSM()
    if lsmResolved then return lsm end
    lsmResolved = true

    if type(_G.LibStub) ~= "table" then
        ns.Debug("LibStub is missing; fonts fall back to the client's own face.")
        return nil
    end

    local ok, lib = pcall(_G.LibStub.GetLibrary, _G.LibStub, "LibSharedMedia-3.0", true)
    if not ok or type(lib) ~= "table" or type(lib.Fetch) ~= "function" then
        ns.Debug("LibSharedMedia-3.0 not available; fonts fall back to the client's own face.")
        return nil
    end

    lsm = lib
    ns.Debug("LibSharedMedia-3.0 resolved.")
    return lsm
end

--------------------------------------------------------------------------------
-- The client's own face
--------------------------------------------------------------------------------

-- Read off GameFontNormal rather than written down, so no asset path is
-- hardcoded on a client whose fonts are not where a stock 3.3.5a keeps them.
-- The literal below is the last resort for a client with no GameFontNormal,
-- which would be a broken client, but a broken client should still get text.
function media.ClientFontFile()
    if GameFontNormal and GameFontNormal.GetFont then
        local ok, path = pcall(GameFontNormal.GetFont, GameFontNormal)
        if ok and path and path ~= "" then return path end
    end
    return DEFAULT_FILE
end

--------------------------------------------------------------------------------
-- Validation
--
-- Same problem, and the same answer, as ns.SetTextureFile: SetFont returns a
-- usable result on most clients of this vintage and nil on some. Probe once
-- against a face that is certainly there. If the client answers meaningfully,
-- trust it; if it always answers nil, trusting it would reject everything, so
-- take the path on faith and let the fallback catch a genuinely bad one only
-- when the client bothers to say so.
--------------------------------------------------------------------------------

local probe, reportsFontResult
local usable = {}

local function Scratch()
    if not probe then
        local frame = CreateFrame("Frame")
        frame:Hide()
        probe = frame:CreateFontString(nil, "BACKGROUND")
    end
    return probe
end

local function ClientReportsFontResult()
    if reportsFontResult == nil then
        local ok, result = pcall(Scratch().SetFont, Scratch(), media.ClientFontFile(), 12)
        reportsFontResult = (ok and result and true) or false
        ns.Debug("client %s font load results.", reportsFontResult and "reports" or "does not report")
    end
    return reportsFontResult
end

function media.IsUsableFont(file)
    if type(file) ~= "string" or file == "" then return false end
    if usable[file] ~= nil then return usable[file] end

    if not ClientReportsFontResult() then
        usable[file] = true
        return true
    end

    local ok, result = pcall(Scratch().SetFont, Scratch(), file, 12)
    usable[file] = (ok and result and true) or false
    return usable[file]
end

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

local cachedFile

-- Clears the resolved path. Called when the configured face changes and when
-- LibSharedMedia tells us something new was registered.
function media.Invalidate()
    cachedFile = nil
end

-- ns.GetFontFile() -> path
--
-- The configured face if LibSharedMedia knows it and the client will draw it,
-- and the client's own normal face otherwise. Never returns nil.
function media.GetFontFile()
    if cachedFile then return cachedFile end

    local face = ns.db and ns.db.font and ns.db.font.face
    local file

    -- The default face is answered without asking the library, on purpose. LSM
    -- registers "Friz Quadrata TT" per locale and a non-western client gets a
    -- different key entirely, so going through Fetch for the one face that is
    -- guaranteed would make the guarantee depend on the player's locale.
    if face and face ~= DEFAULT_FACE then
        local lib = media.GetLSM()
        if lib then
            local ok, fetched = pcall(lib.Fetch, lib, "font", face)
            if ok and type(fetched) == "string" and fetched ~= "" then
                if media.IsUsableFont(fetched) then
                    file = fetched
                else
                    ns.Debug("font '%s' resolved to %s, which the client will not draw.",
                        tostring(face), tostring(fetched))
                end
            end
        end
    end

    cachedFile = file or media.ClientFontFile()
    return cachedFile
end

-- Kept as ns.GetFontFile because that is what every drawing file already calls.
ns.GetFontFile = media.GetFontFile

--------------------------------------------------------------------------------
-- The font list
--------------------------------------------------------------------------------

-- Sorted face names for the options panel's dropdown. Always contains the
-- default, whether or not LibSharedMedia is there to list it, so the control can
-- never come up empty.
function media.ListFonts()
    local names, seen = {}, {}

    local lib = media.GetLSM()
    if lib then
        local ok, list = pcall(lib.List, lib, "font")
        if ok and type(list) == "table" then
            for i = 1, #list do
                local name = list[i]
                if type(name) == "string" and not seen[name] then
                    seen[name] = true
                    table.insert(names, name)
                end
            end
        end
    end

    if not seen[DEFAULT_FACE] then table.insert(names, DEFAULT_FACE) end
    table.sort(names)
    return names
end

-- The path a face resolves to, for previewing a dropdown row in its own font.
-- Falls back the same way GetFontFile does, so a row can always be drawn.
function media.FontFileFor(face)
    if not face or face == DEFAULT_FACE then return media.ClientFontFile() end

    local lib = media.GetLSM()
    if lib then
        local ok, fetched = pcall(lib.Fetch, lib, "font", face)
        if ok and type(fetched) == "string" and fetched ~= "" and media.IsUsableFont(fetched) then
            return fetched
        end
    end
    return media.ClientFontFile()
end

--------------------------------------------------------------------------------
-- Restyling on new media
--
-- Font packs register their faces at their own load time, which can be after
-- heroPanel has already resolved and drawn. A pack registering a hundred faces
-- fires a hundred callbacks, so the restyle is coalesced onto the next frame
-- rather than run per registration.
--------------------------------------------------------------------------------

local restyleQueued = false

local function QueueRestyle()
    if restyleQueued then return end
    restyleQueued = true
    ns.After(0, function()
        restyleQueued = false
        if ns.Skin then
            pcall(ns.Skin.Restyle)
            pcall(ns.Skin.Refresh, "shared media changed")
        end
        if ns.Mplus then
            pcall(ns.Mplus.Restyle)
            pcall(ns.Mplus.Refresh, "shared media changed")
        end
        if ns.Dungeon then
            pcall(ns.Dungeon.Restyle)
            pcall(ns.Dungeon.Refresh, "shared media changed")
        end
        if ns.Boons   then pcall(ns.Boons.Restyle)   end
        if ns.Options then pcall(ns.Options.Restyle) end
    end)
end

-- Called by the options panel and by /hp font once the store has changed.
function media.Apply(reason)
    media.Invalidate()
    if ns.Skin then
        pcall(ns.Skin.Restyle)
        pcall(ns.Skin.Refresh, reason or "font changed")
    end
    if ns.Mplus then
        pcall(ns.Mplus.Restyle)
        pcall(ns.Mplus.Refresh, reason or "font changed")
    end
    if ns.Dungeon then
        pcall(ns.Dungeon.Restyle)
        pcall(ns.Dungeon.Refresh, reason or "font changed")
    end
    if ns.Boons   then pcall(ns.Boons.Restyle)   end
    if ns.Options then pcall(ns.Options.Restyle) end
end

ns:On("HEROPANEL_READY", function()
    local lib = media.GetLSM()
    if not lib or type(lib.RegisterCallback) ~= "function" then return end

    -- A face that was not registered when heroPanel drew is a face the player
    -- picked and did not get. Invalidate and redraw rather than making them
    -- reload to see their own setting take effect.
    --
    -- CallbackHandler's RegisterCallback is a dot call whose first argument is
    -- the *registering* object, not the library - lib:RegisterCallback(...) is
    -- an error, because the library would then be reading itself as the event
    -- name. An addon-name string is a supported self and avoids the question.
    local ok, err = pcall(lib.RegisterCallback, ADDON_NAME, "LibSharedMedia_Registered", function()
        media.Invalidate()
        QueueRestyle()
    end)
    if not ok then
        ns.Debug("could not subscribe to LibSharedMedia registrations: %s", tostring(err))
    end
end)
