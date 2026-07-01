--!strict
-- Places.lua — Place IDs for this experience.
-- The LOBBY is the experience's START place, so it loads FIRST when a player joins. In the lobby you pick
-- a map + difficulty; PLAY teleports you to the GAME place. On death/victory the game teleports you back.
-- IMPORTANT (Roblox rule): which place loads first is fixed by which place is the experience's START place.
-- For the lobby to load first, the LOBBY build+code must be PUBLISHED to the start place (109730423425701).
-- Syncing with Rojo does not change this — only Publishing does. See the header of LobbyServer.server.lua.
-- If you clone/copy the experience, update these IDs (here and in lobby-src/.../LobbyServer.server.lua).

local Places = {}

Places.Lobby = 109730423425701 -- the LOBBY = the experience's START place (loads first on join)
Places.Game  = 140566663451993 -- the gameplay place (PLAY in the lobby teleports here)

return Places
