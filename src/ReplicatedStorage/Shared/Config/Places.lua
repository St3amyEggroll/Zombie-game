--!strict
-- Places.lua — Place IDs for this experience. The GAME place (the experience's START place) routes fresh
-- joiners to the LOBBY, and teleports players back to the LOBBY on death/victory. The LOBBY is a separate
-- place (lobby-src/, synced with lobby.project.json) whose PLAY teleports back to the game.
-- If you clone/copy the experience, update these IDs (here and in lobby-src/.../LobbyServer.server.lua).

local Places = {}

Places.Lobby = 140566663451993 -- the lobby place
Places.Game  = 109730423425701 -- the gameplay place (also the experience's START place)

return Places
