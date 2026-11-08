--!strict
-- Action-combat presentation: placeholder slash VFX (shows the REAL hit cone at hit time),
-- health bars on combat targets, floating damage numbers, hit flash, a crosshair, and a
-- small debug HUD. Purely visual, nothing here affects gameplay or is trusted by the server.
--
-- The slash arc is a stand-in for animations: replace it by setting AnimationId on actions
-- in CombatFeel, or delete PlaySlash's body to hide it. HUD: CombatFeel.Debug.ShowHud.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local TargetingConfig = require(ReplicatedStorage.Shared.Config.Targeting)
local CombatFeel = require(ReplicatedStorage.Shared.Config.CombatFeel)

local player = Players.LocalPlayer

local CombatFeedbackController = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

local hudGui: ScreenGui? = nil
local hudLabel: TextLabel? = nil
local barGuis: { [Model]: BillboardGui } = {}

local function getPlayerGui(): PlayerGui
	return player:WaitForChild("PlayerGui") :: PlayerGui
end

local function findTargetById(targetId: string): Model?
	for _, instance in CollectionService:GetTagged(TargetingConfig.TAG_COMBAT) do
		if instance:IsA("Model") and instance:GetAttribute(TargetingConfig.ATTRIBUTE_ID) == targetId then
			return instance
		end
	end
	return nil
end

local function getAdornee(model: Model): BasePart?
	local part = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

-- Slash VFX ------------------------------------------------------------------------

-- Draws the attack's hit arc (radius = Range, width = Angle) at the moment the hit lands,
-- around the character's position then. Handy for judging range/angle while tuning.
function CombatFeedbackController.PlaySlash(def: CombatFeel.ActionDef, aim: Vector3, speed: number): ()
	local delay = def.HitTime / speed
	task.delay(delay, function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			return
		end

		local half = math.rad(def.Angle * 0.5)
		local segments = math.clamp(math.floor(def.Angle / 15), 4, 18)
		local radius = def.Range * 0.9
		local arcLength = radius * (2 * half / segments) * 1.15
		local baseYaw = math.atan2(-aim.X, -aim.Z)
		local center = root.Position - Vector3.new(0, 0.5, 0)

		for index = 0, segments do
			local segmentYaw = baseYaw + half - (2 * half) * (index / segments)
			local direction = Vector3.new(-math.sin(segmentYaw), 0, -math.cos(segmentYaw))
			local tangent = Vector3.new(-direction.Z, 0, direction.X)
			local position = center + direction * radius

			local part = Instance.new("Part")
			part.Name = "SlashSegment"
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Material = Enum.Material.Neon
			part.Color = def.Color
			part.Size = Vector3.new(0.35, 0.35, arcLength)
			part.Transparency = 0.15
			part.CFrame = CFrame.lookAt(position, position + tangent)
			part.Parent = workspace

			TweenService
				:Create(
					part,
					TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, index * 0.006),
					{ Transparency = 1 }
				)
				:Play()
			Debris:AddItem(part, 0.5)
		end
	end)
end

-- Hit feedback -----------------------------------------------------------------------

local function showDamageNumber(model: Model, amount: number, died: boolean): ()
	local adornee = getAdornee(model)
	if not adornee then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "DamageNumber"
	gui.ResetOnSpawn = false
	gui.Adornee = adornee
	gui.Size = UDim2.fromOffset(100, 32)
	gui.StudsOffsetWorldSpace = Vector3.new((math.random() - 0.5) * 1.5, 3, 0)
	gui.AlwaysOnTop = true
	gui.Parent = getPlayerGui()

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = if died then 28 else 22
	label.Text = tostring(math.floor(amount + 0.5))
	label.TextColor3 = if died then Color3.fromRGB(255, 150, 60) else Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.3
	label.Parent = gui

	local info = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gui, info, { StudsOffsetWorldSpace = gui.StudsOffsetWorldSpace + Vector3.new(0, 3, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(gui, 0.8)
end

local function flashModel(model: Model): ()
	local highlight = Instance.new("Highlight")
	highlight.Name = "HitFlash"
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.2
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = model
	highlight.Parent = model
	TweenService:Create(highlight, TweenInfo.new(0.15), { FillTransparency = 1 }):Play()
	Debris:AddItem(highlight, 0.2)
end

local function onResult(payload: any): ()
	if type(payload) ~= "table" or payload.type ~= "hit" then
		return
	end
	if type(payload.targetId) ~= "string" or type(payload.damage) ~= "number" then
		return
	end
	local model = findTargetById(payload.targetId)
	if not model then
		return
	end
	flashModel(model)
	showDamageNumber(model, payload.damage, payload.died == true)
end

-- Health bars -------------------------------------------------------------------------

local function removeBar(model: Model): ()
	local gui = barGuis[model]
	if gui then
		gui:Destroy()
		barGuis[model] = nil
	end
end

local function attachHealthBar(instance: Instance): ()
	if not instance:IsA("Model") or barGuis[instance] then
		return
	end
	local model = instance
	-- Targets may stream in piecemeal, so wait briefly for the parts we need.
	task.spawn(function()
		local humanoid = model:WaitForChild("Humanoid", 10)
		local adornee = model:WaitForChild("Head", 10) or model:WaitForChild("HumanoidRootPart", 10)
		if not humanoid or not humanoid:IsA("Humanoid") or not adornee or barGuis[model] or not model:IsDescendantOf(workspace) then
			return
		end

		local gui = Instance.new("BillboardGui")
		gui.Name = "CombatHealthBar"
		gui.ResetOnSpawn = false -- created before the character spawns; must survive the spawn reset
		gui.Adornee = adornee :: Instance
		gui.Size = UDim2.fromOffset(90, 12)
		gui.StudsOffset = Vector3.new(0, 2, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 90
		gui.Parent = getPlayerGui()

		local back = Instance.new("Frame")
		back.Size = UDim2.fromScale(1, 1)
		back.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
		back.BackgroundTransparency = 0.2
		back.BorderSizePixel = 0
		back.Parent = gui

		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(1, 1)
		fill.BackgroundColor3 = Color3.fromRGB(220, 60, 60)
		fill.BorderSizePixel = 0
		fill.Parent = back

		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Font = Enum.Font.GothamBold
		text.TextSize = 10
		text.TextColor3 = Color3.new(1, 1, 1)
		text.TextStrokeTransparency = 0.5
		text.Parent = back

		local function refresh(): ()
			local maxHealth = math.max(humanoid.MaxHealth, 1)
			local health = math.max(humanoid.Health, 0)
			fill.Size = UDim2.fromScale(math.clamp(health / maxHealth, 0, 1), 1)
			text.Text = if health <= 0 then "DOWN" else `{math.ceil(health)}/{math.ceil(maxHealth)}`
		end
		refresh()

		barGuis[model] = gui
		table.insert(connections, humanoid.HealthChanged:Connect(refresh))
		table.insert(connections, humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(refresh))
		table.insert(connections, model.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				removeBar(model)
			end
		end))
	end)
end

-- Crosshair + debug HUD -----------------------------------------------------------------

local function buildHud(): ()
	local gui = Instance.new("ScreenGui")
	gui.Name = "A2CombatHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	gui.Parent = getPlayerGui()
	hudGui = gui

	local dot = Instance.new("Frame")
	dot.Name = "Crosshair"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(5, 5)
	dot.BackgroundColor3 = Color3.new(1, 1, 1)
	dot.BackgroundTransparency = 0.25
	dot.BorderSizePixel = 0
	dot.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	if CombatFeel.Debug.ShowHud then
		local label = Instance.new("TextLabel")
		label.Name = "DebugHud"
		label.Position = UDim2.fromOffset(12, 12)
		label.Size = UDim2.fromOffset(470, 92)
		label.BackgroundColor3 = Color3.new(0, 0, 0)
		label.BackgroundTransparency = 0.55
		label.BorderSizePixel = 0
		label.Font = Enum.Font.Code
		label.TextSize = 14
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.Text = ""
		label.Parent = gui
		hudLabel = label
	end
end

local function updateHud(): ()
	local label = hudLabel
	local actionController = deps.ActionCombatController
	if not label or not actionController then
		return
	end
	local info = actionController.GetDebugInfo()
	local buffered = if info.buffered then `{info.buffered} ({string.format("%.2f", info.bufferLeft)}s)` else "-"
	label.Text = table.concat({
		` Action: {info.action}   Phase: {info.phase}   Combo window: {if info.comboOpen then "open" else "closed"}`,
		` Buffer: {buffered}   Dodge CD: {string.format("%.2f", info.dodgeCooldown)}s`,
		` Last server refusal: {info.lastReject}`,
		` LMB light | RMB heavy | Shift dodge | Tab target | Alt cursor | Wheel zoom`,
	}, "\n")
end

-- API -------------------------------------------------------------------------------------

function CombatFeedbackController.Init(injected: { [string]: any }): ()
	deps = injected
end

function CombatFeedbackController.Start(): ()
	table.insert(connections, deps.Net.OnClientEvent(Constants.REMOTES.CombatActionResult, onResult))

	for _, instance in CollectionService:GetTagged(TargetingConfig.TAG_COMBAT) do
		attachHealthBar(instance)
	end
	table.insert(
		connections,
		CollectionService:GetInstanceAddedSignal(TargetingConfig.TAG_COMBAT):Connect(attachHealthBar)
	)

	task.spawn(function()
		buildHud()
		table.insert(connections, RunService.RenderStepped:Connect(updateHud))
	end)
end

function CombatFeedbackController.Destroy(): ()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	for model in barGuis do
		removeBar(model)
	end
	if hudGui then
		hudGui:Destroy()
		hudGui = nil
	end
	hudLabel = nil
	deps = {}
end

return CombatFeedbackController
