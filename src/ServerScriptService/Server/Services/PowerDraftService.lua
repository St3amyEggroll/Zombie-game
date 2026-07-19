--!nonstrict
-- PowerDraftService.lua — THE roguelite loop (replaced extraction, owner call): on a run-long clock,
-- every player gets 3 POWER cards and picks 1; powers STACK for the whole run. The horde never pauses —
-- picking mid-swarm is the drama. No pick in PickSeconds = the first card auto-picks.
--
-- Powers land on the DORMANT buff plumbing that already exists: ps.buffs (CombatService reads damage/
-- range/critchance/critdamage; PlayerStateService reads walkspeed/maxhp) plus two client-read player
-- attributes (PowerFireRate for shot pacing, PowerMagnet for instant loot-coin magnet). Server applies
-- everything; the client only renders cards and sends its pick (validated against the actual offer).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Remotes = require(Shared.Modules.Remotes)

local MatchService = require(script.Parent.MatchService)
local PlayerStateService = require(script.Parent.PlayerStateService)

local PowerDraftService = {}

-- ===== TUNABLES ===== (timing lives in GameConfig.Draft)
-- Each power: what one stack does. `buff` adds to ps.buffs[key]; `attr` mirrors the TOTAL onto a player
-- attribute for client-side effects; `max` = stack cap (excluded from offers once reached).
local POWERS = {
	{ id = "damage",  name = "SHARPENED ROUNDS", desc = "+10% damage",            icon = "💥", buff = "damage",      amount = 0.10, max = 8 },
	{ id = "firerate", name = "TRIGGER DISCIPLINE", desc = "+8% fire rate",       icon = "🔥", buff = "attackspeed", amount = 0.08, max = 8, attr = "PowerFireRate" },
	{ id = "splash",  name = "BIGGER BOOMS",     desc = "+15% blast radius",      icon = "🧨", buff = "splash",      amount = 0.15, max = 5 },
	{ id = "speed",   name = "ADRENALINE",       desc = "+6% move speed",         icon = "👟", buff = "walkspeed",   amount = 0.06, max = 6 },
	{ id = "maxhp",   name = "THICK SKIN",       desc = "+15 max HP (and heal)",  icon = "❤️", buff = "maxhp",       amount = 15,   max = 6 },
	{ id = "crit",    name = "WEAK SPOTS",       desc = "+5% crit chance",        icon = "🎯", buff = "critchance",  amount = 0.05, max = 8 },
	{ id = "magnet",  name = "COIN MAGNET",      desc = "Loot coins fly straight to you", icon = "🧲", buff = "magnet", amount = 1, max = 1, attr = "PowerMagnet" },
	{ id = "frost",   name = "FROST ROUNDS",     desc = "10% chance to chill on hit", icon = "❄️", buff = "frost",   amount = 0.10, max = 3 },
}
local POWER_BY_ID = {}
for _, p in POWERS do
	POWER_BY_ID[p.id] = p
end

local offers: { [number]: { [string]: boolean } } = {} -- userId -> set of offered ids (this window)
local picked: { [number]: boolean } = {}               -- userId -> picked already this window

local function stacksOf(ps, id: string): number
	ps.powerStacks = ps.powerStacks or {}
	return ps.powerStacks[id] or 0
end

local function applyPower(player: Player, ps, def)
	ps.powerStacks = ps.powerStacks or {}
	ps.powerStacks[def.id] = (ps.powerStacks[def.id] or 0) + 1
	ps.buffs = ps.buffs or {}
	ps.buffs[def.buff] = (ps.buffs[def.buff] or 0) + def.amount
	if def.attr then
		player:SetAttribute(def.attr, ps.buffs[def.buff])
	end
	if def.id == "maxhp" then
		-- RefreshMaxHealth re-reads ps.buffs.maxhp and grants the new headroom as HP (the heal half).
		PlayerStateService.RefreshMaxHealth(player)
	end
	print(("[PowerDraft] %s picked %s (x%d)"):format(player.Name, def.id, ps.powerStacks[def.id]))
end

-- Roll 3 distinct, un-maxed powers for this player.
local function rollThree(ps)
	local pool = {}
	for _, p in POWERS do
		if stacksOf(ps, p.id) < p.max then
			table.insert(pool, p)
		end
	end
	for i = #pool, 2, -1 do -- shuffle
		local j = math.random(i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local out = {}
	for i = 1, math.min(3, #pool) do
		table.insert(out, pool[i])
	end
	return out
end

local function runDraftWindow()
	local cfg = GameConfig.Draft
	offers = {}
	picked = {}
	MatchService.ForEachPlayer(function(player, ps)
		if ps.isDead then
			return -- spectators draft nothing; they're out
		end
		local three = rollThree(ps)
		if #three == 0 then
			return -- everything maxed (deep run) — nothing to offer
		end
		local set = {}
		local payload = {}
		for _, def in three do
			set[def.id] = true
			table.insert(payload, {
				id = def.id, name = def.name, desc = def.desc, icon = def.icon,
				stacks = stacksOf(ps, def.id),
			})
		end
		offers[player.UserId] = set
		Remotes.Get("DraftOffer"):FireClient(player, { powers = payload, seconds = cfg.PickSeconds })
	end)
	task.delay(cfg.PickSeconds + 0.5, function()
		-- Auto-pick for anyone who didn't choose (first offered card), then close the window.
		for userId, set in offers do
			if not picked[userId] then
				local player = Players:GetPlayerByUserId(userId)
				local ps = player and MatchService.GetPlayerState(player)
				if player and ps then
					for id in set do
						applyPower(player, ps, POWER_BY_ID[id])
						break
					end
				end
			end
		end
		offers = {}
		picked = {}
	end)
end

local function onPick(player: Player, powerId: any)
	local set = offers[player.UserId]
	if typeof(powerId) ~= "string" or not set or not set[powerId] or picked[player.UserId] then
		return -- not offered / already picked / window closed — server stays authoritative
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps or ps.isDead then
		return
	end
	picked[player.UserId] = true
	offers[player.UserId] = nil
	applyPower(player, ps, POWER_BY_ID[powerId])
end

function PowerDraftService.Start()
	Remotes.Get("DraftPick").OnServerEvent:Connect(onPick)

	-- The run clock: first draft FirstAfter seconds into a run, then every Every seconds — for as long
	-- as the shared run is in its (permanent, in continuous mode) Playing phase. DraftClock keeps every
	-- client's countdown honest (re-sent each schedule, cheap).
	task.spawn(function()
		local wasPlaying = false
		local nextDraft = 0
		while true do
			local playing = MatchService.State.phase == "Playing"
			if playing and not wasPlaying then
				nextDraft = os.clock() + GameConfig.Draft.FirstAfter -- a run just started
				Remotes.Get("DraftClock"):FireAllClients(GameConfig.Draft.FirstAfter)
			end
			if playing and os.clock() >= nextDraft then
				runDraftWindow()
				nextDraft = os.clock() + GameConfig.Draft.Every
				Remotes.Get("DraftClock"):FireAllClients(GameConfig.Draft.Every)
			end
			wasPlaying = playing
			task.wait(0.25)
		end
	end)
	print("[PowerDraftService] started (1-of-3 stacking powers on a run clock)")
end

return PowerDraftService
