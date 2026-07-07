--!nonstrict
-- SoundController.lua — ALL game-place audio playback lives here. Reads every id from SoundConfig
-- (blank id = silently skipped, zombie voices fall back to the _normal set), applies the player's volume
-- sliders via two SoundGroups (Music / SFX), and subscribes to the EXISTING remotes for events — no other
-- controller needs to know sound exists. Other controllers *may* call SoundController.Play for bespoke
-- moments (e.g. InputController plays the local gunshot with zero latency).
--
-- Music is a tiny state machine: Calm (between waves) / Combat (wave active) / Boss (boss alive),
-- crossfaded over SoundConfig.MusicFadeSeconds.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SoundConfig = require(Shared.Config.SoundConfig)
local Remotes = require(Shared.Modules.Remotes)

local SoundController = {}

-- ===== TUNABLES =====
local HURT_THROTTLE   = 0.25  -- min seconds between PlayerHurt plays
local MARKER_THROTTLE = 0.03  -- min seconds between identical feedback sounds (minigun spam guard)
local MAX_LIVE_3D     = 24    -- hard cap on simultaneously playing positional sounds

local localPlayer = Players.LocalPlayer

-- ===== VOLUME STATE =====
local vol = {
	master = SoundConfig.DefaultVolumes.master,
	music = SoundConfig.DefaultVolumes.music,
	sfx = SoundConfig.DefaultVolumes.sfx,
}

local musicGroup = Instance.new("SoundGroup")
musicGroup.Name = "ZLMusic"
musicGroup.Parent = SoundService
local sfxGroup = Instance.new("SoundGroup")
sfxGroup.Name = "ZLSFX"
sfxGroup.Parent = SoundService

local function applyVolumes()
	musicGroup.Volume = vol.master * vol.music
	sfxGroup.Volume = vol.master * vol.sfx
end

function SoundController.GetVolumes()
	return vol.master, vol.music, vol.sfx
end

function SoundController.SetVolumes(master, music, sfx)
	vol.master = math.clamp(tonumber(master) or vol.master, 0, 1)
	vol.music = math.clamp(tonumber(music) or vol.music, 0, 1)
	vol.sfx = math.clamp(tonumber(sfx) or vol.sfx, 0, 1)
	applyVolumes()
end

-- ===== CORE PLAYBACK =====
local lastPlayed = {} -- name -> os.clock() (per-sound throttle)
local live3D = 0

local function def(name)
	local d = SoundConfig.Sounds[name]
	if d and (typeof(d.id) == "table" and #d.id > 0 or (typeof(d.id) == "string" and d.id ~= "")) then
		return d
	end
	return nil
end

-- A slot's id may be a list — pick a random variant per play.
local function pickId(d)
	if typeof(d.id) == "table" then
		return d.id[math.random(1, #d.id)]
	end
	return d.id
end

local function buildSound(name, d, pitchMult)
	local s = Instance.new("Sound")
	s.SoundId = SoundConfig.AssetId(pickId(d))
	s.Volume = d.vol
	s.Looped = d.loop
	s.SoundGroup = (string.sub(name, 1, 5) == "Music") and musicGroup or sfxGroup
	if d.pitchLo ~= 1 or d.pitchHi ~= 1 or (pitchMult and pitchMult ~= 1) then
		local jitter = d.pitchLo + math.random() * (d.pitchHi - d.pitchLo)
		s.PlaybackSpeed = jitter * (pitchMult or 1)
	end
	return s
end

-- 2D one-shot (UI, stingers, local-player feedback).
function SoundController.Play(name, pitchMult)
	local d = def(name)
	if not d or d.loop then
		return
	end
	local now = os.clock()
	if now - (lastPlayed[name] or 0) < MARKER_THROTTLE then
		return
	end
	lastPlayed[name] = now
	local s = buildSound(name, d, pitchMult)
	s.Parent = SoundService
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(15, function()
		if s.Parent then
			s:Destroy()
		end
	end)
	s:Play()
end

local liveFuses = {} -- { {sound, pos} } — BombFuse plays 5s of beeps but detonation cuts it off

local function stopFusesNear(position)
	for i = #liveFuses, 1, -1 do
		local f = liveFuses[i]
		if not f.sound.Parent or (f.pos - position).Magnitude <= 20 then
			if f.sound.Parent then
				f.sound:Stop()
				f.sound:Destroy()
			end
			table.remove(liveFuses, i)
		end
	end
end

-- 3D one-shot at a world position (gunshots, zombies, explosions).
function SoundController.PlayAt(name, position, pitchMult)
	local d = def(name)
	if not d or d.loop or typeof(position) ~= "Vector3" then
		return
	end
	if live3D >= MAX_LIVE_3D then
		return
	end
	live3D += 1
	local att = Instance.new("Attachment")
	att.WorldPosition = position
	att.Parent = workspace.Terrain
	local s = buildSound(name, d, pitchMult)
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 8
	s.RollOffMaxDistance = math.max(d.dist, 20)
	s.Parent = att
	local done = false
	local function cleanup()
		if done then
			return
		end
		done = true
		live3D -= 1
		att:Destroy()
	end
	s.Ended:Once(cleanup)
	task.delay(15, cleanup)
	if name == "BombFuse" then
		table.insert(liveFuses, { sound = s, pos = position })
	elseif name == "Explosion" then
		stopFusesNear(position)
	end
	s:Play()
end

-- Named LOOPS (heartbeat, downed alarm) — one live instance per key.
local loops = {} -- key -> Sound
local function startLoop(key, name)
	if loops[key] then
		return
	end
	local d = def(name)
	if not d then
		return
	end
	local s = buildSound(name, d)
	s.Looped = true
	s.Parent = SoundService
	loops[key] = s
	s:Play()
end
local function stopLoop(key)
	local s = loops[key]
	if s then
		loops[key] = nil
		s:Stop()
		s:Destroy()
	end
end

-- ===== ZOMBIE VOICE RESOLUTION ===== "ZAttack:speedytank" -> Attack_tank, falling back to Attack_normal.
local function zombieSlot(kind, typeId)
	local voice = SoundConfig.Voice[typeId] or "normal"
	local candidates = { kind .. "_" .. voice }
	if kind == "Roar" then
		table.insert(candidates, "Growl_" .. voice) -- no entrance roar recorded: reuse the growl, deeper
	end
	table.insert(candidates, kind .. "_normal")
	if kind == "Roar" then
		table.insert(candidates, "Growl_normal")
	end
	for _, slot in candidates do
		if def(slot) then
			return slot
		end
	end
	return nil
end

-- ===== MUSIC STATE MACHINE =====
local musicState = { phase = "Lobby", bossAlive = false }
local currentTrack = nil -- name of the playing music slot
local musicSounds = {}   -- name -> persistent looping Sound

local function musicSound(name)
	if musicSounds[name] then
		return musicSounds[name]
	end
	local d = def(name)
	if not d then
		return nil
	end
	local s = Instance.new("Sound")
	s.SoundId = SoundConfig.AssetId(pickId(d))
	s.Looped = true
	s.Volume = 0
	s.SoundGroup = musicGroup
	s.Parent = SoundService
	musicSounds[name] = s
	return s
end

local function setMusic(name)
	if name == currentTrack then
		return
	end
	local fade = SoundConfig.MusicFadeSeconds
	local info = TweenInfo.new(fade, Enum.EasingStyle.Linear)
	if currentTrack then
		local old = musicSounds[currentTrack]
		if old then
			TweenService:Create(old, info, { Volume = 0 }):Play()
			task.delay(fade, function()
				if old.Volume <= 0.01 then
					old:Stop()
				end
			end)
		end
	end
	currentTrack = name
	if name then
		local s = musicSound(name)
		if s then
			local d = SoundConfig.Sounds[name]
			if not s.IsPlaying then
				s:Play()
			end
			TweenService:Create(s, info, { Volume = d.vol }):Play()
		end
	end
end

local function updateMusic()
	-- Combat music runs for the WHOLE run — wave breaks included. Calm is only pre-run (waiting/countdown).
	local inRun = musicState.phase == "Playing" or musicState.phase == "RoundBreak"
	if inRun then
		setMusic(musicState.bossAlive and "MusicBoss" or "MusicCombat")
	else
		setMusic("MusicCalm")
	end
	-- Fall back down the chain when a track has no id yet (e.g. no boss track pasted -> keep combat).
	if currentTrack and not def(currentTrack) then
		if currentTrack == "MusicBoss" and def("MusicCombat") then
			setMusic("MusicCombat")
		elseif def("MusicCalm") then
			setMusic("MusicCalm")
		else
			setMusic(nil)
		end
	end
end

-- ===== UI CLICK AUTO-HOOK ===== every GuiButton in PlayerGui clicks, no per-controller wiring.
local function hookButton(inst)
	if not inst:IsA("GuiButton") or inst:GetAttribute("NoClickSound") then
		return
	end
	inst.Activated:Connect(function()
		SoundController.Play("UiClick")
	end)
end

-- ===== SUBSCRIPTIONS =====
local lastHurt = 0
local activePotionIds = {}
local countdownToken = 0
local wasDowned = false

function SoundController.Start()
	applyVolumes()

	-- Initial volume settings from the profile (settings.vol saved by SoundFXService).
	task.spawn(function()
		local ok, data = pcall(function()
			return Remotes.Get("GetData"):InvokeServer()
		end)
		if ok and typeof(data) == "table" and typeof(data.settings) == "table"
			and typeof(data.settings.vol) == "table" then
			local v = data.settings.vol
			SoundController.SetVolumes(v.master, v.music, v.sfx)
		end
	end)

	-- Preload every non-blank id in the background so first plays aren't late.
	task.spawn(function()
		local assets = {}
		for _, d in SoundConfig.Sounds do
			local ids = (typeof(d.id) == "table") and d.id or { d.id }
			for _, id in ids do
				if id ~= "" then
					local s = Instance.new("Sound")
					s.SoundId = SoundConfig.AssetId(id)
					table.insert(assets, s)
				end
			end
		end
		if #assets > 0 then
			pcall(function()
				ContentProvider:PreloadAsync(assets)
			end)
			for _, s in assets do
				s:Destroy()
			end
		end
	end)

	-- UI clicks (existing + future buttons).
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	for _, inst in playerGui:GetDescendants() do
		hookButton(inst)
	end
	playerGui.DescendantAdded:Connect(hookButton)

	-- Server-emitted world sounds ("ZAttack:<typeId>" style or plain slot names).
	Remotes.Get("SoundEvent").OnClientEvent:Connect(function(name, position)
		if typeof(name) ~= "string" then
			return
		end
		local kind, typeId = string.match(name, "^Z(%a+):(%w+)$")
		local slot = kind and zombieSlot(kind, typeId) or name
		if not slot then
			return
		end
		if typeof(position) == "Vector3" then
			SoundController.PlayAt(slot, position)
		else
			SoundController.Play(slot)
		end
	end)

	-- Gunshots: every shot the server validated, at its true origin. The LOCAL player's shots are played
	-- instantly by InputController instead — skip them here so they don't double up.
	Remotes.Get("ShotFired").OnClientEvent:Connect(function(shooterUserId, origin, _endpoint, weaponId)
		if shooterUserId == localPlayer.UserId then
			return
		end
		if typeof(origin) == "Vector3" and typeof(weaponId) == "string" then
			SoundController.PlayAt("Fire_" .. weaponId, origin)
		end
	end)

	-- Hit feedback (2D — it's YOUR hit).
	Remotes.Get("HitConfirmed").OnClientEvent:Connect(function(_position, _isHeadshot, _hitHumanoid, killed)
		if killed then
			SoundController.Play("KillConfirm")
		else
			SoundController.Play("Hitmarker")
		end
	end)

	-- Waves + music.
	Remotes.Get("MatchStateChanged").OnClientEvent:Connect(function(phase)
		local prev = musicState.phase
		musicState.phase = phase
		if phase ~= "Playing" then
			musicState.bossAlive = false
		end
		if phase == "RoundBreak" and prev == "Playing" then
			SoundController.Play("WaveCleared")
		end
		updateMusic()
	end)
	Remotes.Get("RoundChanged").OnClientEvent:Connect(function(round)
		if tonumber(round) == 1 then
			SoundController.Play("WaveStart") -- the ROUND-start audio: first wave only
		end
		musicState.phase = "Playing"
		updateMusic()
	end)
	Remotes.Get("BossSpawned").OnClientEvent:Connect(function()
		musicState.bossAlive = true
		updateMusic()
	end)
	Remotes.Get("BossDefeated").OnClientEvent:Connect(function()
		musicState.bossAlive = false
		SoundController.Play("BossDefeatedFanfare")
		updateMusic()
	end)
	Remotes.Get("EnemyIncoming").OnClientEvent:Connect(function()
		SoundController.Play("NewEnemySting")
	end)
	Remotes.Get("FlawlessWave").OnClientEvent:Connect(function()
		SoundController.Play("FlawlessJingle")
	end)
	Remotes.Get("KillStreak").OnClientEvent:Connect(function(streak)
		SoundController.Play("StreakStinger", 1 + math.min(tonumber(streak) or 0, 12) * 0.03)
	end)

	-- Pre-run countdown ticks.
	Remotes.Get("StartCountdown").OnClientEvent:Connect(function(seconds)
		countdownToken += 1
		local token = countdownToken
		seconds = tonumber(seconds) or 0
		if seconds <= 0 then
			return
		end
		task.spawn(function()
			for i = 1, seconds do
				if token ~= countdownToken then
					return
				end
				SoundController.Play(i == seconds and "CountdownGo" or "CountdownTick")
				if i < seconds then
					task.wait(1)
				end
			end
		end)
	end)

	-- Player state.
	Remotes.Get("DamageTaken").OnClientEvent:Connect(function()
		local now = os.clock()
		if now - lastHurt >= HURT_THROTTLE then
			lastHurt = now
			SoundController.Play("PlayerHurt")
		end
	end)
	Remotes.Get("HealthChanged").OnClientEvent:Connect(function(health, maxHealth)
		health, maxHealth = tonumber(health) or 0, tonumber(maxHealth) or 100
		if maxHealth > 0 and health > 0 and health / maxHealth <= SoundConfig.LowHealthRatio then
			startLoop("lowhp", "LowHealthLoop")
		else
			stopLoop("lowhp")
		end
	end)
	Remotes.Get("DownedChanged").OnClientEvent:Connect(function(userId, isDowned)
		if userId ~= localPlayer.UserId then
			return
		end
		if isDowned then
			wasDowned = true
			startLoop("downed", "DownedAlarm")
		else
			stopLoop("downed")
			if wasDowned then
				wasDowned = false
				SoundController.Play("ReviveComplete")
			end
		end
	end)

	-- Potions: diff the active-buff list — a NEW id is a drink, a VANISHED id is an expiry.
	Remotes.Get("PotionBuffsChanged").OnClientEvent:Connect(function(list)
		if typeof(list) ~= "table" then
			return
		end
		local nowIds = {}
		for _, buff in list do
			if typeof(buff) == "table" and buff.id then
				nowIds[buff.id] = true
				if not activePotionIds[buff.id] then
					SoundController.Play("PotionDrink")
				end
			end
		end
		for id in activePotionIds do
			if not nowIds[id] then
				SoundController.Play("PotionExpire")
			end
		end
		activePotionIds = nowIds
	end)
	Remotes.Get("PotionDropped").OnClientEvent:Connect(function()
		SoundController.Play("PotionDrop")
	end)
	Remotes.Get("CaseDropped").OnClientEvent:Connect(function()
		SoundController.Play("CaseDrop")
	end)

	-- Traps.
	Remotes.Get("TrapActivated").OnClientEvent:Connect(function(trapPart)
		local pos = (typeof(trapPart) == "Instance" and trapPart:IsA("BasePart")) and trapPart.Position or nil
		if pos then
			SoundController.PlayAt("TrapTrigger", pos)
		else
			SoundController.Play("TrapTrigger")
		end
	end)

	updateMusic()
	print("[SoundController] started")
end

return SoundController
