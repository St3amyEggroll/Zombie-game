--!strict
-- Places.lua — Place IDs for this experience. The LOBBY is the experience's START place (players land there
-- first). The GAME is a secondary place reached only by teleport from the lobby (into a reserved server);
-- on death/victory the game teleports players back to Places.Lobby.
-- If you clone/copy the experience, update these IDs (here and in lobby-src/.../LobbyServer.server.lua).

local Places = {}

Places.Lobby = 109730423425701 -- the lobby hub — the experience's START place (players join here first)
Places.Game  = 140566663451993 -- the gameplay place (reserved-server, reached via the lobby's PLAY)

return Places
