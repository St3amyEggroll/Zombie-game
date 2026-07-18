--!nonstrict
-- AutoShootController.lua — the auto-fire STATE. When ON (default OFF), your gun automatically shoots
-- any zombie the auto-aim is locked onto; when OFF you fire manually. Press T to toggle.
-- CHANGED (HUD renovation): this controller no longer draws its own bottom-right sticker buttons — the
-- HUD's lobby-style DOCK owns the visible AUTOFIRE button and drives it through the API below.
--   AutoShootController.IsOn()      -> boolean (read by InputController's fire loop)
--   AutoShootController.Toggle()    -> flips the state
--   AutoShootController.Changed     -> RBXScriptSignal(on: boolean) — fire-state UI listens here

local UserInputService = game:GetService("UserInputService")

local AutoShootController = {}

-- ===== TUNABLES =====
local TOGGLE_KEY = Enum.KeyCode.T

local on = false -- default OFF (press T or the dock button to enable)
local changedEvent = Instance.new("BindableEvent")
AutoShootController.Changed = changedEvent.Event

function AutoShootController.IsOn(): boolean
	return on
end

local function setOn(v: boolean)
	if on == v then
		return
	end
	on = v
	changedEvent:Fire(on)
end

function AutoShootController.Toggle()
	setOn(not on)
end

function AutoShootController.Start()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == TOGGLE_KEY then
			setOn(not on)
		end
	end)
	print("[AutoShootController] started (state + T key; the HUD dock draws the button)")
end

return AutoShootController
