--!nonstrict
-- BuffService.lua — the in-run LEVEL-UP BUFF DRAFT (server-authoritative). Per-run XP from kills fills a
-- level bar; each level rolls a draft of 3 options that are ALWAYS the same rarity. The rarity is decided by
-- climbing the ladder (Common..Divine), each climb a set chance that only rises with the player's Luck.
-- Picking a buff ADDS its amount to that stat (stacks, never multiplies). Everything is per-run (MatchService
-- resets it). The game never pauses — zombies keep spawning while the draft is on screen.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local BuffConfig = require(Config.BuffConfig)
local GameConfig = require(Config.GameConfig)
local PotionConfig = require(Config.PotionConfig)
local Remotes = require(Modules.Remotes)

local MatchService = require(script.Parent.MatchService)
local CombatService = require(script.Parent.CombatService)

local BuffService = {}

-- Invalidates stale auto-pick timers (a fresh draft bumps the token).
local draftToken: { [number]: number } = {}

local sendNextDraft -- forward decl (mutual reference with the auto-pick timer)

-- ===== PUSH =====
local function pushBuffs(player: Player, ps)
	Remotes.Get("BuffsChanged"):FireClient(player, ps.buffs)
end

local function pushXP(player: Player, ps)
	Remotes.Get("RunXPChanged"):FireClient(player, ps.runXP, BuffConfig.XPForLevel(ps.runLevel), ps.runLevel)
end

-- (Move Speed is applied by PlayerStateService.computeMoveSpeed each frame from ps.buffs.walkspeed; the other
-- stats are read where they're used: CombatService for damage/crit/range/attack-speed, client for prediction.)

-- ===== ROLLS =====
-- Climb the rarity ladder: each step's chance rises by the player's Luck, capped. Returns a tier index 1..N.
local function rollRarity(luck: number): number
	local tier = 1
	for _, chance in BuffConfig.UpgradeChance do
		local c = math.min(BuffConfig.MaxUpgradeChance, chance + luck)
		if math.random() < c then
			tier += 1
		else
			break
		end
	end
	return tier
end

-- Pick OptionsPerDraft DISTINCT buffs, all at `tier`.
local function rollOptions(tier: number)
	local pool = {}
	for _, b in BuffConfig.Buffs do
		table.insert(pool, b)
	end
	local opts = {}
	local n = math.min(BuffConfig.OptionsPerDraft, #pool)
	for _ = 1, n do
		local b = table.remove(pool, math.random(#pool))
		table.insert(opts, { stat = b.stat, name = b.name, amount = BuffConfig.Magnitude(b.base, tier) })
	end
	return opts
end

-- ===== APPLY =====
local function applyPick(player: Player, ps, option)
	if not option then
		return
	end
	ps.buffs[option.stat] = (ps.buffs[option.stat] or 0) + option.amount
	pushBuffs(player, ps)
end

sendNextDraft = function(player: Player)
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.inMatch then
		return
	end
	if ps.pendingDraft then
		return -- one draft on screen at a time
	end
	if (ps.draftsOwed or 0) <= 0 then
		return
	end
	ps.draftsOwed -= 1

	local tier = rollRarity(ps.buffs.luck or 0)
	local rarity = BuffConfig.Rarities[tier]
	local options = rollOptions(tier)
	ps.pendingDraft = options

	Remotes.Get("BuffDraft"):FireClient(player, {
		rarityIndex = tier,
		rarityName = rarity.name,
		color = rarity.color,
		options = options,
	})

	-- Auto-pick guard: the game never pauses, so if the draft is ignored too long, take option 1 and move on.
	draftToken[player.UserId] = (draftToken[player.UserId] or 0) + 1
	local myToken = draftToken[player.UserId]
	task.delay(BuffConfig.AutoPickSeconds, function()
		local ps2 = MatchService.GetPlayerState(player)
		if ps2 and ps2.pendingDraft and draftToken[player.UserId] == myToken then
			local opts = ps2.pendingDraft
			ps2.pendingDraft = nil
			applyPick(player, ps2, opts[1])
			sendNextDraft(player)
		end
	end)
end

-- ===== XP =====
local function addXP(player: Player, amount: number)
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.inMatch then
		return
	end
	ps.runXP += amount
	local leveled = false
	while ps.runXP >= BuffConfig.XPForLevel(ps.runLevel) do
		ps.runXP -= BuffConfig.XPForLevel(ps.runLevel)
		ps.runLevel += 1
		ps.draftsOwed = (ps.draftsOwed or 0) + 1
		leveled = true
	end
	pushXP(player, ps)
	if leveled then
		sendNextDraft(player)
	end
end

local function onKill(player: Player, humanoid: Humanoid, _isHead: boolean, _weaponId: string)
	local model = humanoid.Parent
	local special = model and model:GetAttribute("IsSpecial") == true
	addXP(player, special and BuffConfig.XPPerSpecialKill or BuffConfig.XPPerKill)
end

-- ===== POTIONS (tiered, TIMED buffs — PotionConfig) =====
-- One ACTIVE buff per TYPE (damage / regen); when it expires you can drink another of any tier.
-- CombatService/PlayerStateService read ps.potionBuffs directly; this pushes the HUD's active list.

-- Sync the client's "active potion buffs" strip (above the HP bar): { {id, type, rarity, pct, remaining} }.
local function pushPotionBuffs(player: Player, ps)
	local now = os.clock()
	local list = {}
	for ptype, b in ps.potionBuffs or {} do
		if b.expiresAt > now then
			table.insert(list, {
				id = b.id, type = ptype, rarity = b.rarity, pct = b.pct,
				remaining = b.expiresAt - now,
			})
		end
	end
	Remotes.Get("PotionBuffsChanged"):FireClient(player, list)
end
BuffService.PushPotionBuffs = pushPotionBuffs

function BuffService.ApplyPotion(player: Player, potionId: string): boolean
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.inMatch then
		return false
	end
	local stats = PotionConfig.Stats(potionId)
	if not stats then
		return false
	end
	ps.potionBuffs = ps.potionBuffs or {}
	local active = ps.potionBuffs[stats.type]
	if active and active.expiresAt > os.clock() then
		return false -- that TYPE is already running; wait it out
	end
	ps.potionBuffs[stats.type] = {
		id = potionId,
		rarity = stats.rarity,
		pct = stats.pct,
		expiresAt = os.clock() + stats.duration,
	}
	pushPotionBuffs(player, ps)
	return true
end

-- Is this potion TYPE currently active for the player? (Used by the consume gate.)
function BuffService.IsPotionTypeActive(player: Player, ptype: string): boolean
	local ps = MatchService.GetPlayerState(player)
	local b = ps and ps.potionBuffs and ps.potionBuffs[ptype]
	return (b and b.expiresAt > os.clock()) == true
end

local function onPick(player: Player, index)
	if typeof(index) ~= "number" then
		return
	end
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.pendingDraft then
		return
	end
	local option = ps.pendingDraft[index]
	if not option then
		return
	end
	ps.pendingDraft = nil
	applyPick(player, ps, option)
	sendNextDraft(player) -- if more levels were banked while choosing, show the next immediately
end

-- ===== LIFECYCLE =====
function BuffService.Start()
	CombatService.Kill:Connect(onKill)
	Remotes.Get("BuffPick").OnServerEvent:Connect(onPick)

	-- A fresh run = fresh (zeroed) buffs (MatchService reset them). Reapply move speed + resync the HUD when
	-- the run's character spawns.
	local function hook(player: Player)
		player.CharacterAdded:Connect(function()
			task.defer(function()
				local ps = MatchService.GetPlayerState(player)
				if ps then
					pushBuffs(player, ps)
					pushXP(player, ps)
				end
			end)
		end)
	end
	for _, p in Players:GetPlayers() do
		hook(p)
	end
	Players.PlayerAdded:Connect(hook)
	Players.PlayerRemoving:Connect(function(p)
		draftToken[p.UserId] = nil
	end)

	-- Potion buff expiry sweep: once a second, drop finished buffs and resync that player's HUD strip.
	task.spawn(function()
		while true do
			task.wait(1)
			local now = os.clock()
			for _, p in Players:GetPlayers() do
				local ps = MatchService.GetPlayerState(p)
				if ps and ps.potionBuffs then
					local changed = false
					for ptype, b in ps.potionBuffs do
						if b.expiresAt <= now then
							ps.potionBuffs[ptype] = nil
							changed = true
						end
					end
					if changed then
						pushPotionBuffs(p, ps)
					end
				end
			end
		end
	end)

	print("[BuffService] started")
end

return BuffService
