--!nonstrict
-- GameInventoryController.lua — the IN-GAME CASES screen (the old multi-tab inventory is gone:
-- GUNS is its own screen via GunShopController, potions were removed). Same 3-region skeleton as
-- every other panel: case GRID (left) | FEATURED case (middle, spinning render) | action note (right).
-- Cases open in the LOBBY only — this is the "what am I carrying" view + the case-drop toasts.
-- Opened by the hotbar's CASES button (GameInventoryController.Toggle) — keeps the same API name.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = Shared:WaitForChild("Modules")
local Remotes = require(Modules.Remotes)
local UITheme = require(Modules.UITheme)
local GunViewport = require(Modules.GunViewport)
local UIFocus = require(Modules.UIFocus)

local GameInventoryController = {}

-- ===== LAYOUT TUNABLES =====
local PANEL_W, PANEL_H = 940, 560

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local data = nil
local selectedId = nil

local gui, panel, grid, detail, acts

function GameInventoryController.IsOpen(): boolean
	return panel ~= nil and panel.Visible
end

local function rarityColor(rarityId)
	local r = data and data.catalog.rarities[rarityId]
	return (r and r.color) or Color3.fromRGB(176, 190, 197)
end

local function clearChildren(container)
	for _, c in container:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local render -- forward decl

local function caseCell(i, rarity, count)
	local disp = data.catalog.cases[rarity]
	local col = rarityColor(rarity)
	local isSel = selectedId == rarity

	local cell = Instance.new("TextButton")
	cell.BackgroundColor3 = col:Lerp(UITheme.BG, 0.62)
	cell.AutoButtonColor = true
	cell.Text = ""
	cell.BorderSizePixel = 0
	cell.LayoutOrder = i
	cell.Parent = grid
	UITheme.Corner(cell, 7)
	UITheme.Edge(cell, isSel and UITheme.TOXIC or UITheme.BLACK, isSel and 3 or 2.5)
	UITheme.CardShade(cell)

	local vp = GunViewport.Create(rarity, false, "CrateDisplay")
	if vp then
		vp.Size = UDim2.new(1, 0, 1, -26)
		vp.Parent = cell
	end

	local nm = UITheme.Label(cell, nil, 14, UITheme.TEXT, true)
	nm.AnchorPoint = Vector2.new(0, 1)
	nm.Position = UDim2.new(0, 0, 1, -4)
	nm.Size = UDim2.new(1, 0, 0, 22)
	nm.Text = disp and disp.name or rarity
	local nmStroke = Instance.new("UIStroke")
	nmStroke.Color = UITheme.BLACK
	nmStroke.Thickness = 1.4
	nmStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	nmStroke.Parent = nm

	local chip = UITheme.Label(cell, nil, 13, col, true)
	chip.Position = UDim2.fromOffset(6, 6)
	chip.Size = UDim2.fromOffset(60, 18)
	chip.TextXAlignment = Enum.TextXAlignment.Left
	chip.ZIndex = 3
	chip.Text = "x" .. count
	local cStroke = Instance.new("UIStroke")
	cStroke.Color = UITheme.BLACK
	cStroke.Thickness = 1.3
	cStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	cStroke.Parent = chip

	cell.Activated:Connect(function()
		selectedId = rarity
		render()
	end)
end

render = function()
	if not panel or not panel.Visible or not data then
		return
	end
	-- Owned cases, best rarity first.
	local ids = {}
	for _, rarity in data.catalog.rarityOrder do
		if (data.cases[rarity] or 0) > 0 then
			table.insert(ids, rarity)
		end
	end
	if not selectedId or not table.find(ids, selectedId) then
		selectedId = ids[1]
	end
	clearChildren(grid)
	for i, rarity in ids do
		caseCell(i, rarity, data.cases[rarity] or 0)
	end
	if #ids == 0 then
		local msg = UITheme.Label(grid, nil, 14, UITheme.DIM, true)
		msg.Size = UDim2.fromOffset(320, 60)
		msg.TextWrapped = true
		msg.Text = "No crates yet — clear every 10th wave and kill BOSSES to earn them!"
	end

	clearChildren(detail)
	clearChildren(acts)
	if not selectedId then
		return
	end
	local disp = data.catalog.cases[selectedId]
	local col = rarityColor(selectedId)

	local well = Instance.new("Frame")
	well.Position = UDim2.fromOffset(14, 14)
	well.Size = UDim2.new(1, -28, 0, 190)
	well.BackgroundColor3 = col:Lerp(UITheme.BG, 0.7)
	well.BorderSizePixel = 0
	well.Parent = detail
	UITheme.Corner(well, 6)
	UITheme.Edge(well, UITheme.BLACK, 2)
	local wellVp = GunViewport.Create(selectedId, true, "CrateDisplay")
	if wellVp then
		wellVp.Size = UDim2.fromScale(1, 1)
		wellVp.Parent = well
	end

	local nm = UITheme.Title(detail, nil, 21, col)
	nm.Position = UDim2.fromOffset(14, 214)
	nm.Size = UDim2.new(1, -28, 0, 30)
	nm.Text = string.upper(disp and disp.name or selectedId)

	local have = UITheme.Label(detail, nil, 15, UITheme.TEXT, true)
	have.Position = UDim2.fromOffset(14, 248)
	have.Size = UDim2.new(1, -28, 0, 20)
	have.Text = ("You have: x%d"):format(data.cases[selectedId] or 0)

	local note = UITheme.Label(detail, nil, 13, UITheme.DIM)
	note.Position = UDim2.fromOffset(14, 280)
	note.Size = UDim2.new(1, -28, 0, 60)
	note.TextWrapped = true
	note.Text = "Crates hold gun SKINS. Open them at the lobby — the reel is waiting."

	local openBtn = UITheme.Button(acts, "OPEN IN LOBBY", "ghost")
	openBtn.Position = UDim2.new(0, 0, 0, 0)
	openBtn.Size = UDim2.new(1, 0, 0, 60)
	UITheme.SetButtonEnabled(openBtn, false, "OPEN IN LOBBY")
end

-- ===== CASE-DROP TOAST =====
local function showToast(textStr, color)
	local toast = Instance.new("Frame")
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.new(0.5, 0, 0, -60)
	toast.Size = UDim2.fromOffset(340, 44)
	toast.BackgroundColor3 = UITheme.PANEL
	toast.BorderSizePixel = 0
	toast.Parent = gui
	UITheme.Corner(toast, 7)
	UITheme.Edge(toast, color or UITheme.GOLD, 2)
	local lbl = UITheme.Label(toast, nil, 15, color or UITheme.GOLD, true)
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Text = textStr
	TweenService:Create(toast, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, 96),
	}):Play()
	task.delay(3.2, function()
		local out = TweenService:Create(toast, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 0, -60),
		})
		out.Completed:Once(function()
			toast:Destroy()
		end)
		out:Play()
	end)
end

function GameInventoryController.Toggle()
	if not panel then
		return
	end
	panel.Visible = not panel.Visible
	if panel.Visible then
		UIFocus.Open()
		Remotes.Get("InvSnapshot"):FireServer() -- ask for a fresh snapshot
		render()
	else
		UIFocus.Close()
	end
end

function GameInventoryController.Start()
	gui = Instance.new("ScreenGui")
	gui.Name = "GameInventory"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 8
	gui.Parent = playerGui
	UITheme.Attach(gui)

	panel = UITheme.Panel(gui, "CasesPanel", { accent = UITheme.TOXIC })
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.Visible = false
	UITheme.Header(panel, "CASES", 44, UITheme.TOXIC, UITheme.HeaderColors.cases)

	local closeBtn = Instance.new("TextButton")
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -8, 0, 6)
	closeBtn.Size = UDim2.fromOffset(46, 46)
	closeBtn.BackgroundColor3 = Color3.fromRGB(224, 34, 34)
	closeBtn.BorderSizePixel = 0
	closeBtn.FontFace = UITheme.TitleFace
	closeBtn.TextSize = 26
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.Text = "✕"
	closeBtn.Parent = panel
	UITheme.Corner(closeBtn, 7)
	UITheme.Edge(closeBtn, UITheme.BLACK, 2.5)
	local xg = Instance.new("UIGradient")
	xg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(224, 34, 34)),
		ColorSequenceKeypoint.new(0.78, Color3.fromRGB(224, 34, 34)),
		ColorSequenceKeypoint.new(0.8, Color3.fromRGB(150, 16, 16)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 16, 16)),
	})
	xg.Rotation = 90
	xg.Parent = closeBtn
	closeBtn.Activated:Connect(function()
		if panel.Visible then UIFocus.Close() end
		panel.Visible = false
	end)

	grid = Instance.new("ScrollingFrame")
	grid.Position = UDim2.fromOffset(16, 60)
	grid.Size = UDim2.fromOffset(346, PANEL_H - 76)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 6
	grid.CanvasSize = UDim2.new()
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.Parent = panel
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.fromOffset(160, 148)
	gl.CellPadding = UDim2.fromOffset(12, 12)
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = grid

	detail = Instance.new("Frame")
	detail.Position = UDim2.fromOffset(378, 60)
	detail.Size = UDim2.fromOffset(280, PANEL_H - 76)
	detail.BackgroundColor3 = UITheme.PANEL2
	detail.BorderSizePixel = 0
	detail.Parent = panel
	UITheme.Corner(detail, 6)
	UITheme.Edge(detail, UITheme.BLACK, 2)
	UITheme.Edge(detail, UITheme.LINE, 1, 0.5)

	acts = Instance.new("Frame")
	acts.AnchorPoint = Vector2.new(1, 0)
	acts.Position = UDim2.new(1, -16, 0, 60)
	acts.Size = UDim2.fromOffset(250, PANEL_H - 76)
	acts.BackgroundTransparency = 1
	acts.Parent = panel

	Remotes.Get("InvSnapshot").OnClientEvent:Connect(function(snap)
		if typeof(snap) ~= "table" then
			return
		end
		data = snap
		if panel.Visible then
			render()
		end
	end)

	Remotes.Get("CaseDropped").OnClientEvent:Connect(function(rarity)
		local disp = data and data.catalog.cases[tostring(rarity)]
		showToast(("CASE DROP — %s!"):format(disp and disp.name or "Case"), rarityColor(tostring(rarity)))
	end)

	print("[GameInventoryController] started (CASES screen)")
end

return GameInventoryController
