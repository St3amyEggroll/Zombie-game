--!strict
-- Places.lua — Place IDs for this experience. The GAME place uses Places.Lobby to teleport players back to
-- the lobby (on a fresh join to the start place, and on death). The LOBBY place is a SEPARATE codebase
-- (lobby-src/, synced with lobby.project.json) and keeps its own copy of the game place id.
-- If you clone/copy the experience, update these IDs (here and in lobby-src/.../LobbyServer.server.lua).

local Places = {}

Places.Lobby = 140566663451993 -- the menu lobby place
Places.Game  = 109730423425701 -- the gameplay place (also the experience's start place)

return Places
