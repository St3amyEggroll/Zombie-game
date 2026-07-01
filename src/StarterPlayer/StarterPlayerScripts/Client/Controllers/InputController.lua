--!nonstrict
-- InputController.lua — turns input into server intent. Owns the client fire loop (auto/semi), a
-- predicted ammo mirror (corrected by the server's authoritative AmmoChanged), reload, sprint, the
-- camera toggle, and interact. It NEVER computes damage — it only asks the server to fire.
--
-- Exposes for other controllers:
--   InputController.Fired      : Signal (weaponId)            -> (for combat-juice FX later)
--   InputController.AmmoUpdated: Signal (weaponId, mag, reserve) -> HUDController
--   InputController.GetEquipped() / GetAmmo(weaponId)

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local WeaponConfig = require(Config.WeaponConfig)
local GameConfig = require(Config.GameConfig)
local Remotes = require(Modules.Remotes)

local CameraController = require(script.Parent.CameraController)
local AimController = require(script.Parent.AimController)
local AutoShootController = require(script.Parent.AutoShootController)
-- Buff stats (fire rate). GUARDED: a missing/broken BuffController must never brick firing.
local okBuff, BuffController = pcall(require, script.Parent.BuffController)
if not okBuff or type(BuffController) ~= "table" then
	BuffController = { GetStat = function() return 0 end }
end

local InputController = {}

-- ===== TUNABLES (keybinds) =====
local KEY_RELOAD   = Enum.KeyCode.R
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
local ammoMirror: { [string]: { mag: number, reserve: number } } = {}
local firing = false
local fireStart = 0       -- os.clock() when the current trigger-hold began (drives minigun spin-up)
local lastFireClock = 0   -- os.clock() of the last predicted shot (client-side fire-rate gate)
local reloadingUntil = 0  -- os.clock() the current reload ends; can't fire before then

-- ===== SIGNALS =====
local firedEvent = Instance.new("BindableEvent")
local ammoEvent = Instance.new("BindableEvent")
local reloadEvent = Instance.new("BindableEvent")
InputController.Fired = firedEvent.Event
InputController.AmmoUpdated = ammoEvent.Event
InputController.ReloadStarted = reloadEvent.Event -- (weaponId, duration) -> drives the reload ring

-- ===== HELPERS =====
local function getMirror(weaponId: string)
	local m = ammoMirror[weaponId]
	if not m then
		local w = WeaponConfig[weaponId]
		m = { mag = w and w.magSize or 0, reserve = w and w.reserveAmmo or 0 }
		ammoMirror[weaponId] = m
	end
	return m
end

function InputController.GetEquipped(): string
	return equipped
end

function InputController.GetAmmo(weaponId: string?)
	return getMirror(weaponId or equipped)
end

-- ===== FIRING =====
local function fireOnce()
	local weapon = WeaponConfig[equipped]
	if not weapon then
		return
	end
	local now = os.clock()
	-- Can't fire while reloading, and can't fire faster than the weapon's fire rate (stops rapid-clicking a
	-- semi-auto like the shotgun from predicting extra shots the server then rejects). 0.9 keeps the client
	-- a touch stricter than the server's fire-rate slack, so a predicted shot is never bounced.
	if now < reloadingUntil then
		return
	end
	-- CONSTANT fire rate: the cadence is exactly weapon.fireRate, nothing changes it. The 0.95 keeps the
	-- client a hair under the server's slack so a predicted shot is never bounced (even cadence, no drops).
	if now - lastFireClock < (1 / weapon.fireRate) * 0.95 then
		return
	end
	local origin, direction = CameraController.GetAim()
	if not origin or not direction then
		return
	end
	local mirror = getMirror(equipped)
	if not GameConfig.InfiniteAmmo and mirror.mag <= 0 then
		return
	end

	lastFireClock = now
	Remotes.Get("FireWeapon"):FireServer(equipped, origin, direction)

	-- Local prediction so the gun feels instant; the server's AmmoChanged is the real count.
	if not GameConfig.InfiniteAmmo then
		mirror.mag -= 1
		ammoEvent:Fire(equipped, mirror.mag, mirror.reserve)
	end
	firedEvent:Fire(equipped)
end

-- Start a reload IF there's something to reload. Mirrors the server's conditions so the client ring/block
-- only show when the server will actually reload. Blocks firing for weapon.reloadSeconds.
local function tryReload()
	local weapon = WeaponConfig[equipped]
	if not weapon then
		return
	end
	if os.clock() < reloadingUntil then
		return -- already reloading
	end
	local mirror = getMirror(equipped)
	if mirror.mag >= weapon.magSize or mirror.reserve <= 0 then
		return -- mag full or no reserve: nothing to do
	end
	reloadingUntil = os.clock() + weapon.reloadSeconds
	Remotes.Get("Reload"):FireServer(equipped)
	reloadEvent:Fire(equipped, weapon.reloadSeconds)
end

-- Seconds to wait before the next shot. CONSTANT: exactly 1/fireRate — no buff, no click-cadence jitter.
-- Spin-up weapons (minigun) ramp from SPIN_START_FRAC× the fire rate up to full over weapon.spinUp seconds
-- of continuous holding; releasing resets the ramp (so it spins down).
local function shotInterval(weapon): number
	if weapon.spinUp and weapon.spinUp > 0 then
		local held = os.clock() - fireStart
		local t = math.clamp(held / weapon.spinUp, 0, 1)
		local startRate = weapon.fireRate * SPIN_START_FRAC
		local rate = startRate + (weapon.fireRate - startRate) * t
		return 1 / rate
	end
	return 1 / weapon.fireRate
end

-- While the trigger is held, fire on a STEADY cadence (every 1/fireRate) for every weapon — so holding OR
-- clicking gives perfectly even fire, capped only by the weapon's fire rate. Nothing else stops it.
local function fireLoop()
	while firing do
		local weapon = WeaponConfig[equipped]
		if not weapon then
			break
		end
		local mirror = getMirror(equipped)
		if GameConfig.InfiniteAmmo or mirror.mag > 0 then
			fireOnce()
			task.wait(shotInterval(weapon))
		else
			-- Empty (only when ammo is finite): idle quietly and resume if reloaded while still held.
			task.wait(0.1)
		end
	end
	firing = false
end

local function startFiring()
	if firing then
		return
	end
	firing = true
	fireStart = os.clock() -- begin the spin-up ramp from this moment
	task.spawn(fireLoop)
end

local function stopFiring()
	firing = false
end

-- ===== WEAPON SWITCHING =====
local function equip(weaponId: string)
	if weaponId == equipped or not WeaponConfig[weaponId] then
		return
	end
	equipped = weaponId
	stopFiring()
	reloadingUntil = 0 -- switching weapons cancels the reload gate
	Remotes.Get("EquipWeapon"):FireServer(weaponId) -- server validates ownership + sends authoritative ammo
	local m = getMirror(weaponId)
	ammoEvent:Fire(weaponId, m.mag, m.reserve) -- refresh the HUD to the newly held weapon
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
		startFiring()
	elseif input.UserInputType == Enum.UserInputType.Keyboard then
		if input.KeyCode == KEY_RELOAD then
			tryReload()
		elseif input.KeyCode == KEY_SPRINT then
			Remotes.Get("Sprint"):FireServer(true)
		elseif input.KeyCode == KEY_INTERACT then
			Remotes.Get("Interact"):FireServer()
		end
		-- Weapon switching (1/2/3...) is handled by Roblox's NATIVE hotbar now: the equipped weapons are
		-- real Tools in the Backpack (LoadoutService). Selecting a slot fires the server equip, which sends
		-- LoadoutChanged back and updates `equipped` below.
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		stopFiring()
	elseif input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == KEY_SPRINT then
		Remotes.Get("Sprint"):FireServer(false)
	end
end

-- ===== LIFECYCLE =====
function InputController.Start()
	-- Authoritative ammo updates from the server overwrite the predicted mirror.
	Remotes.Get("AmmoChanged").OnClientEvent:Connect(function(weaponId, mag, reserve)
		ammoMirror[weaponId] = { mag = mag, reserve = reserve }
		ammoEvent:Fire(weaponId, mag, reserve)
	end)

	-- Server tells us our owned weapons + which one is equipped (spawn, buy, equip).
	Remotes.Get("LoadoutChanged").OnClientEvent:Connect(function(owned, eq)
		if type(owned) == "table" then
			ownedWeapons = owned
		end
		if type(eq) == "string" then
			equipped = eq
			local m = getMirror(eq)
			ammoEvent:Fire(eq, m.mag, m.reserve)
		end
	end)

	-- Auto-shoot: when enabled, fire automatically at whatever the auto-aim is locked onto (and reload
	-- hands-free when empty). fireOnce() is gated by fire-rate/ammo/reload, so calling it each frame is safe.
	RunService.Heartbeat:Connect(function()
		if not AutoShootController.IsOn() then
			return
		end
		local weapon = WeaponConfig[equipped]
		if not weapon then
			return
		end
		if getMirror(equipped).mag <= 0 then
			tryReload()
			return
		end
		if AimController.GetTarget() then
			fireOnce()
		end
	end)

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	-- Stop firing if the character dies or we lose focus.
	localPlayer.CharacterAdded:Connect(function()
		stopFiring()
		reloadingUntil = 0 -- a fresh life isn't mid-reload
	end)
	UserInputService.WindowFocusReleased:Connect(stopFiring)

	print("[InputController] started")
end

return InputController
