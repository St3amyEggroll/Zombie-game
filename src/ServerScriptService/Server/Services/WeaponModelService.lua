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
local GameConfig = require(SharedConfig:WaitForChild("GameConfig"))
local SkinConfig = require(SharedConfig:WaitForChild("SkinConfig"))
local AnimationConfig = require(SharedConfig:WaitForChild("AnimationConfig"))

local MatchService = require(script.Parent.MatchService)
local CombatService = require(script.Parent.CombatService)
local DataService = require(script.Parent.DataService)

local WeaponModelService = {}

-- ===== TUNABLES =====
-- HOW THE GUN SITS IN THE HAND: the model's "Handle" part is welded onto the hand — the gun sits exactly
-- where you place the Handle inside the model in Studio (no position offset). The one thing the hand needs
-- is a rotation: the R6 arm part's local axes don't line up with "forward", so without this a normally-built
-- gun comes out backwards / facing the ground. HANDLE_ROT is a SINGLE shared rotation (degrees) applied to
-- every gun to fix that — NOT a per-gun table:
--   pitch = tilt the muzzle up/down     (flip the sign if it's pitched the wrong way)
--   yaw   = spin left/right             (use 180 if the gun points BACKWARDS)
--   roll  = bank sideways               (use 180 if the gun is UPSIDE DOWN)
local HANDLE_ROT = { pitch = 90, yaw = 0, roll = 180 }

-- Per-gun overrides for any gun modeled on a different axis than the rest (so it needs its own rotation).
-- Anything not listed uses HANDLE_ROT above. Only add an entry when one gun sits wrong while others are fine.
local HANDLE_ROT_OVERRIDE = {
	tommygun = { pitch = 180, yaw = 0, roll = 180 }, -- modeled face-down; +90 pitch vs the default lifts it forward
	minigun  = { pitch = 120, yaw = -90, roll = 180 }, -- rotated left 90; muzzle raised 30 off the default
	pistol   = { pitch = 90, yaw = 90, roll = 180 }, -- rotated right 90 off the default
}

local function handleRotCFrame(weaponId: string): CFrame
	local r = HANDLE_ROT_OVERRIDE[weaponId] or HANDLE_ROT
	return CFrame.Angles(math.rad(r.pitch), math.rad(r.yaw), math.rad(r.roll))
end

-- On R6 the hand we weld to is the "Right Arm" part, whose origin is the MIDDLE of the arm — so a plain
-- weld sits the gun mid-forearm. Drop it this many studs down the arm to reach the hand (Roblox's own tool
-- grip uses 1). R15 welds to the actual RightHand, so it gets no drop.
local HAND_DROP = 1.0

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
-- Skin models register under their FULL id ("revolver_gold"); accept "Gold Revolver" style names too.
for fullId, s in SkinConfig.Skins do
	nameToId[sanitize(fullId)] = fullId
	nameToId[sanitize(s.name)] = fullId
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

-- Standard character rig part names. If a weapon model was built ON an animation dummy (gun welded to a
-- rig), we strip these + the Humanoid on equip so ONLY the gun welds to the hand — otherwise the whole rig
-- (and the player) gets dragged around.
local RIG_PARTS: { [string]: boolean } = {}
for _, n in {
	"HumanoidRootPart", "Head", "Torso", "UpperTorso", "LowerTorso",
	"Left Arm", "Right Arm", "Left Leg", "Right Leg",
	"LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot",
} do
	RIG_PARTS[n:lower()] = true
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
	-- Update the hold POSE first, before any model early-returns below — otherwise switching to a gun with
	-- no model (or a missing hand) would leave the PREVIOUS gun's pose playing (the "animation doesn't switch"
	-- bug). The pose is independent of the in-hand model, so stamp it immediately on every equip.
	playHold(player, ps.equippedWeapon)
	-- Equipped SKIN first (profile skins.equipped, lobby-owned), base gun model as the fallback —
	-- tinted when the skin is a TINT skin with no dedicated model (SkinConfig.SkinNames[skin].tint).
	local template = templates[ps.equippedWeapon]
	local tint = nil
	local data = DataService.Get(player)
	local skins = data and data.skins
	local skinId = (type(skins) == "table" and type(skins.equipped) == "table") and skins.equipped[ps.equippedWeapon] or nil
	if skinId then
		if templates[ps.equippedWeapon .. "_" .. skinId] then
			template = templates[ps.equippedWeapon .. "_" .. skinId]
		else
			local sn = SkinConfig.SkinNames[skinId]
			tint = sn and sn.tint or nil
		end
	end
	if not template then
		return -- no model supplied for this weapon (the FP viewmodel still works in first person)
	end
	local hand = getHand(character)
	if not hand then
		return
	end

	local model = template:Clone()
	model.Name = HELD_NAME

	-- Strip ANY animation-rig leftovers so ONLY the gun welds to the hand: a Humanoid/Animator, any Motor6D
	-- (character joints — this is what chains the gun to the rig and drags you to it), and any standard rig
	-- body part. A clean gun model has none of these, so this is safe to always run.
	do
		local strip = {}
		for _, d in model:GetDescendants() do
			if d:IsA("Humanoid") or d:IsA("Animator") or d:IsA("AnimationController") or d:IsA("Motor6D")
				or (d:IsA("BasePart") and RIG_PARTS[d.Name:lower()]) then
				table.insert(strip, d)
			end
		end
		if #strip > 0 then
			for _, d in strip do
				if d.Parent then
					d:Destroy()
				end
			end
			warn(("[WeaponModelService] '%s' had animation-rig leftovers (%d) — stripped so only the gun welds."):format(ps.equippedWeapon, #strip))
		end
	end

	if tint then -- tint skin: mostly flat color, a hint of the original shading
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Color = tint:Lerp(d.Color, 0.15)
			end
		end
	end

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

	-- Decide how the gun sits in the hand. DEFAULT: weld the Handle straight onto the hand (identity C0) —
	-- the gun sits exactly where you placed the Handle inside the model, no offset applied. Optional
	-- overrides if you ever want them: (1) an Attachment named "Grip" in the model, or (2) a "Grip" CFrame
	-- attribute on the model. With neither present it's a plain handle weld.
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
		if typeof(grip) == "CFrame" then
			c0 = grip
		else
			c0 = handleRotCFrame(ps.equippedWeapon)
			-- R6: shift the weld down the Right Arm so the gun sits in the HAND, not mid-arm.
			if hand.Name == "Right Arm" then
				c0 = CFrame.new(0, -HAND_DROP, 0) * c0
			end
		end
	end
	local weld = Instance.new("Weld")
	weld.Part0 = hand
	weld.Part1 = handle
	weld.C0 = c0
	weld.Parent = handle

	model.Parent = character

	held[player.UserId] = { weld = weld, baseC0 = c0 }
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
-- Publish client-visible display clones so the UI can render spinning 3D previews (GunViewport):
--   ReplicatedStorage > GunDisplay   (weapon models, named the weaponId)
--   ReplicatedStorage > CrateDisplay (case models — Assets models named e.g. "CommonCrate" / "RareCase")
-- Sanitized: anchored, no scripts/sounds, no tags.
local function displayFolder(name: string): Folder
	local folder = ReplicatedStorage:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = ReplicatedStorage
	end
	return folder
end

local function publishOne(folder: Folder, id: string, inst: Model)
	if folder:FindFirstChild(id) then
		return
	end
	local c = inst:Clone()
	CollectionService:RemoveTag(c, "WeaponModel")
	for _, d in c:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("BaseScript") or d:IsA("Sound") then
			d:Destroy()
		end
	end
	c.Name = id
	c.Parent = folder
end

local function crateSanitize(s: string): string
	return (s:lower():gsub("[%s%-_]", ""))
end

local function publishDisplayModels()
	local gunFolder = displayFolder("GunDisplay")
	for id, inst in templates do
		publishOne(gunFolder, id, inst)
	end
	-- Crates: any Assets model named "<rarity>Crate" or "<rarity>Case" (case-insensitive).
	local crateFolder = displayFolder("CrateDisplay")
	local wanted = {} -- "commoncrate" -> "common", "commoncase" -> "common", ...
	for _, rarity in GameConfig.CaseRarities do
		wanted[rarity .. "crate"] = rarity
		wanted[rarity .. "case"] = rarity
	end
	for _, container in { ReplicatedStorage, ServerStorage } do
		local assets = ciFind(container, "Assets")
		if assets then
			for _, d in assets:GetDescendants() do
				if d:IsA("Model") then
					local rarity = wanted[crateSanitize(d.Name)]
					if rarity then
						publishOne(crateFolder, rarity, d)
					end
				end
			end
		end
	end
end

function WeaponModelService.Start()
	templatesFolder = Instance.new("Folder")
	templatesFolder.Name = "WeaponModels"
	templatesFolder.Parent = ServerStorage

	loadTaggedTemplates()
	scanAssets()
	publishDisplayModels()
	CollectionService:GetInstanceAddedSignal("WeaponModel"):Connect(function(inst)
		registerTemplate(inst)
		publishDisplayModels()
	end)

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
