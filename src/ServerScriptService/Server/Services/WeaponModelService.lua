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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local SharedConfig = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")
local WeaponConfig = require(SharedConfig:WaitForChild("WeaponConfig"))
local AnimationConfig = require(SharedConfig:WaitForChild("AnimationConfig"))

local MatchService = require(script.Parent.MatchService)
local CombatService = require(script.Parent.CombatService)

local WeaponModelService = {}

-- ===== TUNABLES =====
-- HOW EACH GUN SITS IN THE HAND. This is the thing to edit if a weapon looks wrong.
--   pos = { x, y, z } in studs — moves the gun: +x right, +y up, -z forward (away from you)
--   rot = { x, y, z } in degrees — spins the gun: x = pitch (tilt up/down), y = yaw (turn left/right),
--                                   z = roll (bank sideways)
-- Each weaponId can have its own entry; anything missing falls back to `default`. (A "Grip" CFrame
-- attribute set on the model in Studio still wins over this, for fine manual tuning.)
local GRIPS = {
	default = { pos = { 0, -0.1, -0.6 }, rot = { -90, 0, 0 } },
	pistol  = { pos = { 0, -0.1, -0.6 }, rot = { -90, 0, 0 } },
	shotgun = { pos = { 0, -0.3, -1.1 }, rot = { -90, 0, 0 } },
	ak47    = { pos = { 0, -0.3, -1.2 }, rot = { -90, 0, 0 } },
	minigun = { pos = { 0, -0.5, -1.6 }, rot = { -90, 0, 0 } },
	raygun  = { pos = { 0, -0.2, -0.9 }, rot = { -90, 0, 0 } },
}

local function gripCFrame(weaponId: string): CFrame
	local g = GRIPS[weaponId] or GRIPS.default
	return CFrame.new(g.pos[1], g.pos[2], g.pos[3])
		* CFrame.Angles(math.rad(g.rot[1]), math.rad(g.rot[2]), math.rad(g.rot[3]))
end

local HELD_NAME = "HeldWeapon"

local templates: { [string]: Model } = {}  -- weaponId -> Model
local templatesFolder: Folder

-- Per-player held-weapon state for recoil.
local held: { [number]: any } = {}              -- userId -> { weld, baseC0 }

-- Resolve a model name to a weaponId by matching either the id ("pistol") OR the display name ("m1911"
-- for the M1911, "ak47"/"ak-47" for the AK-47), case/space/dash-insensitive. So you can name a gun model
-- whatever the gun is actually called.
local function sanitize(s: string): string
	return (s:lower():gsub("[%s%-_]", ""))
end
local nameToId: { [string]: string } = {}
for id, w in WeaponConfig do
	nameToId[sanitize(id)] = id
	if type(w) == "table" and w.name then
		nameToId[sanitize(w.name)] = id
	end
end
local function resolveWeaponId(modelName: string): string?
	return nameToId[sanitize(modelName)]
end

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

-- ===== ANIMATION / RECOIL =====
-- The hold pose is PLAYED BY EACH CLIENT (CharacterAnimController): the server only stamps WHAT to
-- play as an attribute on the character. Local playback has no replication rules to satisfy — it shows
-- for everyone no matter who created the Animator, which server-side playback silently depends on.
local function playHold(player: Player, weaponId: string)
	local character = player.Character
	if not character then
		return
	end
	local cfg = AnimationConfig.Weapons[weaponId]
	local id = cfg and AnimationConfig.Resolve(cfg.Hold)
	character:SetAttribute("HoldAnimId", id) -- nil clears the pose
end

-- Procedural gun recoil: kick the hand→handle weld and tween it back. Server-side so everyone sees it.
local function recoil(player: Player)
	if not AnimationConfig.Recoil.Enabled then
		return
	end
	local h = held[player.UserId]
	if not h or not h.weld or not h.weld.Parent then
		return
	end
	local cfg = AnimationConfig.Recoil
	h.weld.C0 = h.baseC0 * CFrame.new(0, 0, cfg.KickBack) * CFrame.Angles(math.rad(cfg.KickUp), 0, 0)
	TweenService:Create(
		h.weld,
		TweenInfo.new(cfg.RecoverTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ C0 = h.baseC0 }
	):Play()
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

	-- Decide how the gun sits in the hand. Priority:
	--   1) BEST + EASIEST: an Attachment named "Grip" in the model — the gun snaps so that attachment lands
	--      in the hand. Just drag/rotate that attachment in Studio until the gun looks right (its gizmo
	--      shows orientation). No numbers, no guessing.
	--   2) a "Grip" CFrame attribute on the model.
	--   3) the per-weapon GRIPS number table at the top of this file.
	local c0
	local gripAtt
	for _, d in model:GetDescendants() do
		if d:IsA("Attachment") and (d.Name == "Grip" or d.Name == "GripAttachment") then
			gripAtt = d
			break
		end
	end
	if gripAtt then
		-- Place the handle so the Grip attachment coincides with the hand: handle = hand * C0, and we want
		-- the attachment (at handle*rel) to equal the hand, so C0 = rel:Inverse().
		local rel = handle.CFrame:ToObjectSpace(gripAtt.WorldCFrame)
		c0 = rel:Inverse()
	else
		local grip = template:GetAttribute("Grip")
		c0 = (typeof(grip) == "CFrame") and grip or gripCFrame(ps.equippedWeapon)
	end
	local weld = Instance.new("Weld")
	weld.Part0 = hand
	weld.Part1 = handle
	weld.C0 = c0
	weld.Parent = handle

	model.Parent = character

	held[player.UserId] = { weld = weld, baseC0 = c0 }
	playHold(player, ps.equippedWeapon)
end

-- ===== TEMPLATE REGISTRATION (tag-driven) =====
local function registerTemplate(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	if templatesFolder and inst:IsDescendantOf(templatesFolder) then
		return
	end
	local id = resolveWeaponId(inst.Name)
	if not id then
		return -- model name doesn't match any weapon
	end
	inst.Parent = templatesFolder
	templates[id] = inst
	print(("[WeaponModelService] registered weapon model '%s' as %s"):format(inst.Name, id))
	-- Re-attach for anyone already holding this weapon.
	for _, player in Players:GetPlayers() do
		local ps = MatchService.GetPlayerState(player)
		if ps and ps.equippedWeapon == id then
			task.spawn(attach, player)
		end
	end
end

local function loadTaggedTemplates()
	for _, inst in CollectionService:GetTagged("WeaponModel") do
		registerTemplate(inst)
	end
end

-- Also accept weapon models placed in ReplicatedStorage > Assets (root), > Assets > Weapons,
-- > Assets > Guns, or > Assets > Viewmodels — any Model named after a weaponId. Cloned per attach.
-- Case-insensitive child lookup (map builders don't match capitalization).
local function ciFind(parent: Instance?, name: string): Instance?
	if not parent then
		return nil
	end
	local exact = parent:FindFirstChild(name)
	if exact then
		return exact
	end
	local lname = name:lower()
	for _, c in parent:GetChildren() do
		if c.Name:lower() == lname then
			return c
		end
	end
	return nil
end

local function scanAssets()
	local function consider(inst: Instance)
		if not inst:IsA("Model") then
			return
		end
		local id = resolveWeaponId(inst.Name)
		if id and not templates[id] then
			templates[id] = inst
			print(("[WeaponModelService] using Assets model '%s' for %s"):format(inst.Name, id))
		end
	end
	-- Look in an "Assets" folder (case-insensitive) in ReplicatedStorage OR ServerStorage.
	for _, container in { ReplicatedStorage, ServerStorage } do
		local assets = ciFind(container, "Assets")
		if assets then
			for _, c in assets:GetChildren() do
				consider(c)
			end
			for _, subName in { "Weapons", "Guns", "Viewmodels" } do
				local sub = ciFind(assets, subName)
				if sub then
					for _, c in sub:GetChildren() do
						consider(c)
					end
				end
			end
		end
	end
end

-- ===== LIFECYCLE =====
function WeaponModelService.Start()
	templatesFolder = Instance.new("Folder")
	templatesFolder.Name = "WeaponModels"
	templatesFolder.Parent = ServerStorage

	loadTaggedTemplates()
	scanAssets()
	CollectionService:GetInstanceAddedSignal("WeaponModel"):Connect(registerTemplate)

	-- ANIMATOR REPLICATION RULE: a track played on the server only replicates to clients if its
	-- Animator was created ON THE SERVER before the client's Animate script spun up its own. Creating
	-- it lazily at equip time (what we did before) silently plays hold poses into the void — so make
	-- one the instant every character spawns.
	local function ensureAnimator(character: Model)
		local hum = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
		if hum and not hum:FindFirstChildOfClass("Animator") then
			local animator = Instance.new("Animator")
			animator.Parent = hum
		end
	end

	-- Re-attach on equip changes and on (re)spawn.
	CombatService.Equipped:Connect(attach)
	CombatService.Fired:Connect(recoil)
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			ensureAnimator(character)
			task.defer(attach, player)
		end)
	end)
	Players.PlayerRemoving:Connect(function(player)
		held[player.UserId] = nil
	end)
	for _, player in Players:GetPlayers() do
		if player.Character then
			ensureAnimator(player.Character)
			task.defer(attach, player)
		end
	end

	print("[WeaponModelService] started")
end

return WeaponModelService
