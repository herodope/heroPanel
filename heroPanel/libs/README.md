# Embedded libraries

heroPanel embeds these rather than declaring them as dependencies. A player
installing a skin addon should not have to go and find a library first, and
`## Dependencies` on a 3.3.5a client is a hard failure rather than a warning —
the addon simply does not load.

Embedding is safe because all three go through **LibStub**, which keeps one
instance per major version and the highest minor wins. If another addon already
loaded a newer LibSharedMedia, ours is a no-op and heroPanel uses theirs — which
is what makes fonts registered by SharedMediaAdditionalFonts, SharedMedia_Causese
or ElvUI show up in heroPanel's font dropdown without heroPanel knowing they
exist.

| Library | Version | License |
|---|---|---|
| LibStub | r2 | Public Domain |
| CallbackHandler-1.0 | r3 | [Ace3 license](https://www.wowace.com/projects/ace3) |
| LibSharedMedia-3.0 | r62 (MINOR `3030002`) | LGPL v2.1 |

Nothing here is modified from upstream. Do not edit these files — a local fix
would be silently discarded on any client where another addon ships a higher
minor.

## Why r62 of LibSharedMedia and not the current release

`3030002` is the revision tagged for the 3.3.5 client. Current LibSharedMedia
(`12.x`) is written against the retail API — `C_AddOns`, `WOW_PROJECT_ID`,
`Enum` — none of which exist here. r62 is the last revision that is plain 5.1
Lua and 3.3.5a globals throughout.

## A note about Ascension

Ascension-flavoured Ace3 bundles (LootCollector's, for one) call
`LibStub:NewAscensionLibrary` instead of `LibStub:NewLibrary`. What that does is
not documented anywhere heroPanel can see, so it is possible a library
registered that way is not reachable through `LibStub("LibSharedMedia-3.0")`.
heroPanel does not try to guess: it looks LibSharedMedia up the ordinary way and
falls back to the copy embedded here, which is registered the ordinary way too.
The visible cost of being wrong about this is a shorter font list, never a
missing font — `Media.lua` always resolves to something the client can draw.
