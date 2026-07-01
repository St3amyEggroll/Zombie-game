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

-- Apply a consumed potion's effect to the player's CURRENT RUN. Returns true if it applied.
--   "damage" → +GameConfig.PotionEffects.damageBonus damage for the rest of the run
--   "regen"  → +GameConfig.PotionEffects.regenBonus health-regen speed for the rest of the run
-- Each potion TYPE works ONCE per run (ps.usedPotions); effects last until the run ends.
function BuffService.ApplyPotion(player: Player, potionId: string): boolean
	local ps = MatchService.GetPlayerState(player)
	if not ps or not ps.inMatch then
		return false
	end
	ps.usedPotions = ps.usedPotions or {}
	if ps.usedPotions[potionId] then
		return false -- already drank this type this run
	end
	local fx = GameConfig.PotionEffects
	if potionId == "damage" then
		ps.buffs.damage = (ps.buffs.damage or 0) + fx.damageBonus
		pushBuffs(player, ps) -- refresh the client's buff totals (HUD + prediction)
	elseif potionId == "regen" then
		ps.regenMult = (ps.regenMult or 1) + fx.regenBonus
	else
		return false
	end
	ps.usedPotions[potionId] = true
	return true
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

	print("[BuffService] started")
end

return BuffService
