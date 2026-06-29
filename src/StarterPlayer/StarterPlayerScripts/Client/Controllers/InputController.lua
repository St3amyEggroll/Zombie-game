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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Modules = Shared:WaitForChild("Modules")

local WeaponConfig = require(Config.WeaponConfig)
local Remotes = require(Modules.Remotes)

local CameraController = require(script.Parent.CameraController)

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

local localPlayer = Players.LocalPlayer

-- ===== STATE =====
local equipped = "pistol"
local ownedWeapons: { string } = { "pistol" }
local ammoMirror: { [string]: { mag: number, reserve: number } } = {}
local firing = false

-- ===== SIGNALS =====
local firedEvent = Instance.new("BindableEvent")
local ammoEvent = Instance.new("BindableEvent")
InputController.Fired = firedEvent.Event
InputController.AmmoUpdated = ammoEvent.Event

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
	local origin, direction = CameraController.GetAim()
	if not origin or not direction then
		return
	end
	local mirror = getMirror(equipped)
	if mirror.mag <= 0 then
		return
	end

	Remotes.Get("FireWeapon"):FireServer(equipped, origin, direction)

	-- Local prediction so the gun feels instant; the server's AmmoChanged is the real count.
	mirror.mag -= 1
	ammoEvent:Fire(equipped, mirror.mag, mirror.reserve)
	firedEvent:Fire(equipped)
end

local function fireLoop()
	while firing do
		local weapon = WeaponConfig[equipped]
		if not weapon then
			break
		end
		local mirror = getMirror(equipped)
		if mirror.mag > 0 then
			fireOnce()
			task.wait(1 / weapon.fireRate)
			if not weapon.auto then
				break -- semi-auto: one shot per press
			end
		else
			-- Empty: idle quietly (don't spam the server). Resume if reloaded while still held.
			task.wait(0.1)
			if not weapon.auto then
				break
			end
		end
	end
	firing = false
end

local function startFiring()
	if firing then
		return
	end
	firing = true
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
			Remotes.Get("Reload"):FireServer(equipped)
		elseif input.KeyCode == KEY_SPRINT then
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

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	-- Stop firing if the character dies or we lose focus.
	localPlayer.CharacterAdded:Connect(stopFiring)
	UserInputService.WindowFocusReleased:Connect(stopFiring)

	print("[InputController] started")
end

return InputController
