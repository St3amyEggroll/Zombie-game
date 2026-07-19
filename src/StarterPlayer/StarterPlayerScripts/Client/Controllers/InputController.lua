--!nonstrict
-- InputController.lua — turns input into server intent. Owns THE single fire driver (manual hold, semi-auto
-- clicks, and auto-shoot all flow through one paced loop, so the cadence is perfectly even and the minigun
-- spin-up applies in every mode). No ammo, no reload — guns fire forever, capped only by fire rate.
--
-- Exposes for other controllers:
--   InputController.Fired : Signal (weaponId)  -> combat juice (muzzle flash, shake)
--   InputController.GetEquipped()

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local WeaponConfig = require(Config.WeaponConfig)
local GunLevelConfig = require(Config.GunLevelConfig)
local Remotes = require(Modules.Remotes)

local CameraController = require(script.Parent.CameraController)
local AimController = require(script.Parent.AimController)
local AutoShootController = require(script.Parent.AutoShootController)
local SoundController = require(script.Parent.SoundController)

local InputController = {}

-- ===== TUNABLES (keybinds) =====
local KEY_SPRINT   = Enum.KeyCode.LeftShift
local KEY_INTERACT = Enum.KeyCode.E

-- Number keys 1..9 select owned weapon slots.
local NUMBER_KEYS = {
	[Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5, [Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8, [Enum.KeyCode.Nine] = 9,
}

-- Spin-up weapons (minigun) start at this fraction of full fire rate and ramp up over weapon.spinUp seconds.
local SPIN_START_FRAC = 0.3

local localPlayer = Players.LocalPlayer

-- ===== STATE =====
local equipped = "pistol"
local ownedWeapons: { string } = { "pistol" }
local gunLevels: { [string]: number } = {} -- persistent gun levels (from DataReady); mirrors server stats
local wantManual = false   -- mouse/touch held (continuous fire for auto weapons)
local pendingShot = false  -- a semi-auto click waiting for the fire gate to open (clicks are never eaten)
local wasFiring = false    -- was the driver firing last frame (edge-detects a new burst for spin-up)
local fireStart = 0        -- os.clock() the current burst began (drives minigun spin-up)
local nextShotAt = 0       -- os.clock() the next shot is allowed — THE one cadence gate

-- ===== SIGNALS =====
local firedEvent = Instance.new("BindableEvent")
InputController.Fired = firedEvent.Event

function InputController.GetEquipped(): string
	return equipped
end

-- ===== THE FIRE DRIVER =====
-- The equipped weapon's fire rate at its PERSISTENT level (mirrors the server's math; levels only
-- change damage today, but reading through GunLevelConfig keeps the cadence correct if that changes).
local function effFireRate(weapon): number
	-- NEW: TRIGGER DISCIPLINE (Power Draft) — the server mirrors this exact multiplier into its
	-- fire-rate gate, so paced-up shots stay inside the anti-cheat bucket.
	local powerMult = 1 + (localPlayer:GetAttribute("PowerFireRate") or 0)
	return GunLevelConfig.EffectiveStats(weapon, gunLevels[weapon.id] or 1).fireRate * powerMult
end

-- Seconds between shots. Constant 1/fireRate; spin-up weapons ramp from SPIN_START_FRAC over
-- weapon.spinUp seconds of continuous firing (releasing resets the ramp).
local function shotInterval(weapon): number
	local rate = effFireRate(weapon)
	if weapon.spinUp and weapon.spinUp > 0 then
		local held = os.clock() - fireStart
		local t = math.clamp(held / weapon.spinUp, 0, 1)
		rate = rate * (SPIN_START_FRAC + (1 - SPIN_START_FRAC) * t)
	end
	return 1 / rate
end

local function fireShot(weapon)
	local origin, direction = CameraController.GetAim()
	if not origin or not direction then
		return false
	end
	Remotes.Get("FireWeapon"):FireServer(equipped, origin, direction)
	SoundController.Play("Fire_" .. equipped) -- instant local gunshot (others hear it via ShotFired)
	firedEvent:Fire(equipped)
	-- Even spacing with no drift: extend from the previous slot unless we've fallen behind a full interval.
	local interval = shotInterval(weapon)
	local now = os.clock()
	nextShotAt = (now - nextShotAt < interval) and (nextShotAt + interval) or (now + interval)
	return true
end

-- One Heartbeat drives everything: manual hold, queued semi-auto clicks, and auto-shoot. A single gate
-- (nextShotAt) means the cadence can't stutter from two drivers racing, and spin-up applies in every mode.
local function onHeartbeat()
	local weapon = WeaponConfig[equipped]
	if not weapon then
		return
	end
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or character:GetAttribute("Downed") then
		pendingShot = false
		wasFiring = false
		return -- dead or downed: no shooting
	end

	local autoFiring = AutoShootController.IsOn() and AimController.GetTarget() ~= nil
	local holdFiring = wantManual and weapon.auto
	local continuous = autoFiring or holdFiring

	-- Edge-detect a fresh burst so the spin-up ramp restarts.
	if continuous and not wasFiring then
		fireStart = os.clock()
	end
	wasFiring = continuous

	if os.clock() < nextShotAt then
		return -- gate closed; a pendingShot stays queued (semi-auto clicks are never dropped)
	end
	if continuous then
		fireShot(weapon)
		pendingShot = false -- the click's shot just happened
	elseif pendingShot then
		if fireShot(weapon) then
			pendingShot = false
		end
	end
end

-- ===== WEAPON SWITCHING =====
local function equip(weaponId: string)
	if weaponId == equipped or not WeaponConfig[weaponId] then
		return
	end
	equipped = weaponId
	pendingShot = false
	AimController.SetWeapon(weaponId) -- auto-aim reach follows the equipped weapon's range
	Remotes.Get("EquipWeapon"):FireServer(weaponId) -- server validates ownership
end

local function equipSlot(i: number)
	local id = ownedWeapons[i]
	if id then
		equip(id)
	end
end

-- ===== INPUT =====
local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		wantManual = true
		local weapon = WeaponConfig[equipped]
		if weapon and not weapon.auto then
			pendingShot = true -- semi-auto: exactly one shot per click, fired the moment the gate opens
		end
	elseif input.UserInputType == Enum.UserInputType.Keyboard then
		if input.KeyCode == KEY_SPRINT then
			Remotes.Get("Sprint"):FireServer(true)
		elseif input.KeyCode == KEY_INTERACT then
			Remotes.Get("Interact"):FireServer()
		elseif NUMBER_KEYS[input.KeyCode] then
			equipSlot(NUMBER_KEYS[input.KeyCode])
		end
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		wantManual = false
	elseif input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == KEY_SPRINT then
		Remotes.Get("Sprint"):FireServer(false)
	end
end

-- ===== LIFECYCLE =====
function InputController.Start()
	-- Server tells us our owned weapons + which one is equipped (spawn, equip).
	Remotes.Get("LoadoutChanged").OnClientEvent:Connect(function(owned, eq)
		if type(owned) == "table" then
			ownedWeapons = owned
		end
		if type(eq) == "string" then
			equipped = eq
			AimController.SetWeapon(eq)
		end
	end)

	-- Persistent gun levels arrive with the profile snapshot (leveled up in the lobby, fixed for the run).
	Remotes.Get("DataReady").OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.gunLevels) == "table" then
			gunLevels = data.gunLevels
		end
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	-- Stop firing if the character dies/respawns or we lose focus.
	localPlayer.CharacterAdded:Connect(function()
		wantManual = false
		pendingShot = false
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		wantManual = false
		pendingShot = false
	end)

	print("[InputController] started (unified fire driver)")
end

return InputController
