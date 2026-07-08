--!nonstrict
-- TrapController.lua — client side of buyable traps: a floating "Name  $cost  [E]" prompt over each trap
-- (with a live cooldown countdown), plus simple activation VFX (a coloured glow + light). The server
-- (TrapService) owns the cash + damage. Tag the trap's zone as a Part for the prompt to appear over it.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("UITheme"))

local Modules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules")
local Remotes = require(Modules.Remotes)

local TrapController = {}

-- ===== TUNABLES =====
local PROMPT_DIST = 18
local TYPE_COLORS = {
	Electric = Color3.fromRGB(90, 180, 255),
	Fire     = Color3.fromRGB(255, 120, 40),
	Blades   = Color3.fromRGB(220, 220, 230),
}
local DEFAULT_COLOR = Color3.fromRGB(255, 230, 120)

local localPlayer = Players.LocalPlayer
local prompts: { [BasePart]: any } = {}

local function colorFor(t: string?): Color3
	return TYPE_COLORS[t] or DEFAULT_COLOR
end

local function ensurePrompt(part: BasePart)
	if prompts[part] then
		return prompts[part]
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "TrapPrompt"
	bb.Size = UDim2.fromOffset(190, 46)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	bb.AlwaysOnTop = true
	bb.Adornee = part
	bb.Parent = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.FontFace = UITheme.BodyBoldFace
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	local cap = Instance.new("UITextSizeConstraint") -- stop the prompt re-sizing per string length
	cap.MaxTextSize = 26
	cap.Parent = label
	label.TextStrokeTransparency = 0.3
	label.Text = ""
	label.Parent = bb
	prompts[part] = { gui = bb, label = label }
	return prompts[part]
end

local function update()
	local char = localPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local now = Workspace:GetServerTimeNow()
	for _, inst in CollectionService:GetTagged("Trap") do
		if inst:IsA("BasePart") then
			local p = ensurePrompt(inst)
			local dist = root and (inst.Position - root.Position).Magnitude or math.huge
			if dist <= PROMPT_DIST then
				p.gui.Enabled = true
				local cd = inst:GetAttribute("CooldownUntil") or 0
				local activeUntil = inst:GetAttribute("ActiveUntil") or 0
				local name = inst:GetAttribute("TrapType") or "Trap"
				local cost = inst:GetAttribute("Cost") or 500
				if now < activeUntil then
					p.label.Text = name .. "  ACTIVE"
					p.label.TextColor3 = colorFor(name)
				elseif now < cd then
					p.label.Text = string.format("%s  %ds", name, math.ceil(cd - now))
					p.label.TextColor3 = Color3.fromRGB(170, 170, 170)
				else
					p.label.Text = string.format("%s  $%d  [E]", name, cost)
					p.label.TextColor3 = Color3.fromRGB(255, 255, 255)
				end
			else
				p.gui.Enabled = false
			end
		end
	end
end

local function onActivated(part: BasePart?, trapType: string?, duration: number?)
	if not part or not part:IsA("BasePart") then
		return
	end
	local col = colorFor(trapType)
	local hl = Instance.new("Highlight")
	hl.Name = "TrapGlow"
	hl.FillColor = col
	hl.FillTransparency = 0.5
	hl.OutlineColor = col
	hl.Adornee = part
	hl.Parent = part
	local light = Instance.new("PointLight")
	light.Name = "TrapLight"
	light.Color = col
	light.Range = 18
	light.Brightness = 3
	light.Parent = part
	task.delay(duration or 5, function()
		hl:Destroy()
		light:Destroy()
	end)
end

local function onDeactivated(part: BasePart?)
	if not part then
		return
	end
	local hl = part:FindFirstChild("TrapGlow")
	if hl then
		hl:Destroy()
	end
	local l = part:FindFirstChild("TrapLight")
	if l then
		l:Destroy()
	end
end

function TrapController.Start()
	Remotes.Get("TrapActivated").OnClientEvent:Connect(onActivated)
	Remotes.Get("TrapDeactivated").OnClientEvent:Connect(onDeactivated)
	RunService.RenderStepped:Connect(update)
	print("[TrapController] started")
end

return TrapController
