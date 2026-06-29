--!nonstrict
-- WeaponModelService.lua — shows the equipped weapon in the character's hand (third-person), welded
-- server-side so every player sees it. Re-attaches whenever the player's equipped weapon changes.
--
-- MODEL CONTRACT (how to hook up your gun): make a Model, NAME it the weaponId (e.g. "pistol"), give it
-- a part named "Handle" (or set a PrimaryPart), and tag the Model "WeaponModel". That's it — the server
-- pulls it out of the world and welds a clone into the holder's right hand on equip.
-- Optional: set a CFrame Attribute "Grip" on the Model to fine-tune how it sits in the hand.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

local MatchService = require(script.Parent.MatchService)
local CombatService = require(script.Parent.CombatService)

local WeaponModelService = {}

-- ===== TUNABLES =====
-- Default grip offset (Handle relative to the hand). Tune per-model via a "Grip" CFrame attribute instead.
local DEFAULT_GRIP = CFrame.new(0, -0.1, -0.6) * CFrame.Angles(math.rad(-90), 0, 0)
local HELD_NAME = "HeldWeapon"

local templates: { [string]: Model } = {}
local templatesFolder: Folder

-- ===== HELPERS =====
local function getHand(character: Model): BasePart?
	return (character:FindFirstChild("RightHand") :: BasePart?) -- R15
		or (character:FindFirstChild("Right Arm") :: BasePart?) -- R6
end

local function clearHeld(character: Model)
	local existing = character:FindFirstChild(HELD_NAME)
	if existing then
		existing:Destroy()
	end
end

-- Attach the player's currently-equipped weapon model to their hand (or clear it if there's no model).
local function attach(player: Player)
	local character = player.Character
	if not character then
		return
	end
	clearHeld(character)

	local ps = MatchService.GetPlayerState(player)
	if not ps then
		return
	end
	local template = templates[ps.equippedWeapon]
	if not template then
		return -- no model supplied for this weapon (the FP viewmodel still works in first person)
	end
	local hand = getHand(character)
	if not hand then
		return
	end

	local model = template:Clone()
	model.Name = HELD_NAME

	local handle = model:FindFirstChild("Handle")
		or model.PrimaryPart
		or model:FindFirstChildWhichIsA("BasePart")
	if not handle or not handle:IsA("BasePart") then
		model:Destroy()
		return
	end
	model.PrimaryPart = handle

	-- Make every part render-only and lock the model into a rigid assembly around the handle.
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.Massless = true
			d.Anchored = false
			if d ~= handle then
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = handle
				wc.Part1 = d
				wc.Parent = handle
			end
		end
	end

	-- Weld the handle to the hand with the grip offset.
	local grip = template:GetAttribute("Grip")
	local c0 = (typeof(grip) == "CFrame") and grip or DEFAULT_GRIP
	local weld = Instance.new("Weld")
	weld.Part0 = hand
	weld.Part1 = handle
	weld.C0 = c0
	weld.Parent = handle

	model.Parent = character
end

-- ===== TEMPLATE REGISTRATION (tag-driven) =====
local function registerTemplate(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	if templatesFolder and inst:IsDescendantOf(templatesFolder) then
		return
	end
	inst.Parent = templatesFolder
	templates[inst.Name] = inst
	print(("[WeaponModelService] registered weapon model '%s'"):format(inst.Name))
	-- Re-attach for anyone already holding this weapon.
	for _, player in Players:GetPlayers() do
		local ps = MatchService.GetPlayerState(player)
		if ps and ps.equippedWeapon == inst.Name then
			task.spawn(attach, player)
		end
	end
end

local function loadTaggedTemplates()
	for _, inst in CollectionService:GetTagged("WeaponModel") do
		registerTemplate(inst)
	end
end

-- ===== LIFECYCLE =====
function WeaponModelService.Start()
	templatesFolder = Instance.new("Folder")
	templatesFolder.Name = "WeaponModels"
	templatesFolder.Parent = ServerStorage

	loadTaggedTemplates()
	CollectionService:GetInstanceAddedSignal("WeaponModel"):Connect(registerTemplate)

	-- Re-attach on equip changes and on (re)spawn.
	CombatService.Equipped:Connect(attach)
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			task.defer(attach, player)
		end)
	end)
	for _, player in Players:GetPlayers() do
		if player.Character then
			task.defer(attach, player)
		end
	end

	print("[WeaponModelService] started")
end

return WeaponModelService
