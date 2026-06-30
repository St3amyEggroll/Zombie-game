--!strict
-- Places.lua — the Place IDs for this experience's two places, plus convenience flags for code that must
-- behave differently in the lobby vs the game place. BOTH places run the SAME synced code; everything keys
-- off game.PlaceId. If you clone/copy the experience, update these two IDs.
--
--   Game  = the gameplay place (maps + waves). It is ALSO the experience's start place (can't be changed),
--           so it doubles as the entry router: fresh joiners are teleported straight to the lobby.
--   Lobby = the menu lobby place. Press PLAY there to teleport into the game and start a run.

local Places = {}

Places.Lobby = 140566663451993
Places.Game  = 109730423425701

Places.IsLobby = game.PlaceId == Places.Lobby
Places.IsGame  = game.PlaceId == Places.Game

return Places
