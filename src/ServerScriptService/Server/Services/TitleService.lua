--!nonstrict
-- TitleService.lua — TITLE achievements (the trophies worn on the overhead tag's top line).
-- Grants are GAME-side and land in profile.titlesOwned (a GAME_OWNED_FIELD, so they survive the
-- two-place save merge); the LOBBY renders the picker on the classes showcase and owns
-- profile.titleEquipped. Rendering is PlayerTagService (+ TitleFXController for animated styles).
--
-- EARNING (all grants fire on WAVE CLEAR so "survive it" is literal):
--   wave milestones — clear wave >= 10/20/30/40 → survivor/veteran/nightmare/unkillable
--   event trophies  — clear a wave whose roller event was bloodmoon/apocalypse/godmode
--   vault cracker   — EventService calls in when the BODYGUARDS vault actually cracks
--   (vip + level titles are DERIVED — the pass / account level — never stored)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TitleConfig = require(Shared.Config.TitleConfig)
local Remotes = require(Shared.Modules.Remotes)

local DataService = require(script.Parent.DataService)
local MatchService = require(script.Parent.MatchService)

local TitleService = {}

-- ===== TUNABLES =====
local WAVE_TITLES = { -- clear a wave at/past N → the title
	{ wave = 10, id = "survivor" },
	{ wave = 20, id = "veteran" },
	{ wave = 30, id = "nightmare" },
	{ wave = 40, id = "unkillable" },
}
local EVENT_TITLES = { -- roller outcome of the CLEARED wave → the trophy
	bloodmoon = "bloodmoon",
	apocalypse = "apocalypse",
	godmode = "god",
}

-- Grant a title (idempotent). Announces server-wide — trophies are for showing off.
function TitleService.Grant(player: Player, id: string)
	local def = TitleConfig.Titles[id]
	local data = DataService.Get(player)
	if not def or not data then
		return
	end
	if typeof(data.titlesOwned) ~= "table" then
		data.titlesOwned = {}
	end
	if data.titlesOwned[id] then
		return
	end
	data.titlesOwned[id] = true
	DataService.MarkDirty(player)
	Remotes.Get("RunEvent"):FireAllClients("announce", {
		text = ("%s UNLOCKED THE TITLE: %s"):format((player.DisplayName or player.Name):upper(), def.name),
		color = "gold",
	})
end

-- Grant to everyone currently in the run (EventService's vault crack uses this).
function TitleService.GrantInMatch(id: string)
	MatchService.ForEachPlayer(function(player)
		TitleService.Grant(player, id)
	end)
end

function TitleService.Start()
	-- Everything else keys off the wave that just CLEARED (ForEachPlayer already filters to in-run).
	MatchService.WaveCleared:Connect(function(round)
		local evTitle = EVENT_TITLES[MatchService.State.waveEvent]
		MatchService.ForEachPlayer(function(player, ps)
			if ps.isDead then
				return -- spectators didn't survive the wave — no trophy
			end
			for _, wt in WAVE_TITLES do
				if round >= wt.wave then
					TitleService.Grant(player, wt.id)
				end
			end
			if evTitle then
				TitleService.Grant(player, evTitle)
			end
		end)
	end)
	print("[TitleService] started (trophies armed)")
end

return TitleService
