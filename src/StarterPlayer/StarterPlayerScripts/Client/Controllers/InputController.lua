--!nonstrict
-- InputController.lua — turns input into server intent. Owns the client fire loop (auto/semi), a
-- predicted ammo mirror (corrected by the server's authoritative AmmoChanged), reload, sprint, the
-- camera toggle, and interact. It NEVER computes damage — it only asks the server to fire.
--
-- Exposes for other controllers:
--   InputController.Fired      : Signal (weaponId)            -> WeaponViewController recoil/muzzle
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
local KEY_RELOAD        = Enum.KeyCode.R
local KEY_SPRINT        = Enum.KeyCode.LeftShift
local KEY_INTERACT      = Enum.KeyCode.E
local KEY_CAMERA_TOGGLE = Enum.KeyCode.V

local localPlayer = Players.LocalPlayer

-- ===== STATE =====
local equipped = "pistol"
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
		elseif input.KeyCode == KEY_CAMERA_TOGGLE then
			CameraController.Toggle()
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

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	-- Stop firing if the character dies or we lose focus.
	localPlayer.CharacterAdded:Connect(stopFiring)
	UserInputService.WindowFocusReleased:Connect(stopFiring)

	print("[InputController] started")
end

return InputController
