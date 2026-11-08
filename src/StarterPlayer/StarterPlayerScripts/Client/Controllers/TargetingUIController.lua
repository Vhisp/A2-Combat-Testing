--!strict
-- Client targeting UI prototype. Presentation ONLY.
-- Reads the existing TargetStateChanged flow and replicated Humanoid state.
-- It never sends requests and never modifies targeting state or eligibility.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local TargetingConfig = require(ReplicatedStorage.Shared.Config.Targeting)
local UIConfig = require(ReplicatedStorage.Shared.Config.TargetingUI)

local IS_STUDIO = RunService:IsStudio()
local player = Players.LocalPlayer

local TargetingUIController = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

local gui: ScreenGui? = nil
local frame: Frame? = nil
local nameLabel: TextLabel? = nil
local healthFill: Frame? = nil
local healthLabel: TextLabel? = nil

-- One Highlight instance each, reassigned between targets so we never duplicate.
local combatHighlight: Highlight? = nil
local interactHighlight: Highlight? = nil

local combatModel: Model? = nil
local combatHealthConn: RBXScriptConnection? = nil

local function log(...: any): ()
	if IS_STUDIO then
		print("[TargetingUIController]", ...)
	end
end

local function buildHighlight(cfg: any): Highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = cfg.NAME
	highlight.FillColor = cfg.FILL_COLOR
	highlight.FillTransparency = cfg.FILL_TRANSPARENCY
	highlight.OutlineColor = cfg.OUTLINE_COLOR
	highlight.OutlineTransparency = cfg.OUTLINE_TRANSPARENCY
	highlight.DepthMode = cfg.DEPTH_MODE
	highlight.Enabled = false
	return highlight
end

-- Assign a Highlight to a model, or detach it (model == nil) without destroying it.
local function assignHighlight(highlight: Highlight?, cfg: any, model: Model?): ()
	if not highlight then
		return
	end
	if not cfg.ENABLED or not model then
		highlight.Enabled = false
		highlight.Adornee = nil
		highlight.Parent = nil
		return
	end
	highlight.Adornee = model
	highlight.Parent = model
	highlight.Enabled = true
end

-- Resolve a live model from its replicated TargetId within the given tag.
local function resolveModel(targetId: string, tag: string): Model?
	if type(targetId) ~= "string" or targetId == "" then
		return nil
	end
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsA("Model") and instance:GetAttribute(TargetingConfig.ATTRIBUTE_ID) == targetId then
			return instance
		end
	end
	return nil
end

local function setHealthDisplay(current: number?, maximum: number?): ()
	if not healthFill or not healthLabel then
		return
	end
	if current == nil or maximum == nil or maximum <= 0 then
		healthFill.Size = UDim2.new(0, 0, 1, 0)
		healthLabel.Text = "N/A"
		return
	end
	local ratio = math.clamp(current / maximum, 0, 1)
	healthFill.Size = UDim2.new(ratio, 0, 1, 0)
	healthLabel.Text = `{math.floor(current)} / {math.floor(maximum)}`
end

local function readHealth(model: Model?): ()
	if combatHealthConn then
		combatHealthConn:Disconnect()
		combatHealthConn = nil
	end
	if not model then
		setHealthDisplay(nil, nil)
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		setHealthDisplay(nil, nil)
		return
	end
	setHealthDisplay(humanoid.Health, humanoid.MaxHealth)
	combatHealthConn = humanoid.HealthChanged:Connect(function(health: number)
		-- Re-read MaxHealth each change; it can be set after spawn.
		if combatModel then
			local currentHumanoid = combatModel:FindFirstChildOfClass("Humanoid")
			if currentHumanoid then
				setHealthDisplay(health, currentHumanoid.MaxHealth)
			end
		end
	end)
end

local function applyCombat(info: any): ()
	combatModel = nil
	if type(info) == "table" then
		combatModel = resolveModel(info.id, TargetingConfig.TAG_COMBAT)
	end

	if not combatModel then
		if frame then
			frame.Visible = false
		end
		if nameLabel then
			nameLabel.Text = ""
		end
		setHealthDisplay(nil, nil)
		assignHighlight(combatHighlight, UIConfig.COMBAT_HIGHLIGHT, nil)
		readHealth(nil)
		return
	end

	if frame then
		frame.Visible = true
	end
	if nameLabel then
		nameLabel.Text = combatModel.Name
	end
	assignHighlight(combatHighlight, UIConfig.COMBAT_HIGHLIGHT, combatModel)
	readHealth(combatModel)
end

local function applyInteraction(info: any): ()
	local model: Model? = nil
	if type(info) == "table" then
		model = resolveModel(info.id, TargetingConfig.TAG_INTERACTABLE)
	end
	assignHighlight(interactHighlight, UIConfig.INTERACT_HIGHLIGHT, model)
end

local function buildUI(parentGui: Instance): ()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = UIConfig.SCREEN_GUI.NAME
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = parentGui
	gui = screenGui

	local targetFrame = Instance.new("Frame")
	targetFrame.Name = "TargetFrame"
	targetFrame.Position = UIConfig.FRAME.POSITION
	targetFrame.AnchorPoint = UIConfig.FRAME.ANCHOR_POINT
	targetFrame.Size = UIConfig.FRAME.SIZE
	targetFrame.BackgroundColor3 = UIConfig.FRAME.BACKGROUND_COLOR
	targetFrame.BackgroundTransparency = UIConfig.FRAME.BACKGROUND_TRANSPARENCY
	targetFrame.BorderSizePixel = 0
	targetFrame.Visible = false
	targetFrame.Parent = screenGui
	frame = targetFrame

	local label = Instance.new("TextLabel")
	label.Name = "NameLabel"
	label.Position = UIConfig.NAME.POSITION
	label.Size = UIConfig.NAME.SIZE
	label.BackgroundTransparency = 1
	label.Font = UIConfig.NAME.FONT
	label.TextSize = UIConfig.NAME.TEXT_SIZE
	label.TextColor3 = UIConfig.NAME.TEXT_COLOR
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""
	label.Parent = targetFrame
	nameLabel = label

	local barBg = Instance.new("Frame")
	barBg.Name = "HealthBarBackground"
	barBg.Position = UIConfig.HEALTH_BAR.POSITION
	barBg.Size = UIConfig.HEALTH_BAR.SIZE
	barBg.BackgroundColor3 = UIConfig.HEALTH_BAR.BACKGROUND_COLOR
	barBg.BorderSizePixel = 0
	barBg.Parent = targetFrame

	local fill = Instance.new("Frame")
	fill.Name = "HealthFill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = UIConfig.HEALTH_BAR.FILL_COLOR
	fill.BorderSizePixel = 0
	fill.Parent = barBg
	healthFill = fill

	local hLabel = Instance.new("TextLabel")
	hLabel.Name = "HealthLabel"
	hLabel.Position = UIConfig.HEALTH_TEXT.POSITION
	hLabel.Size = UIConfig.HEALTH_TEXT.SIZE
	hLabel.BackgroundTransparency = 1
	hLabel.Font = UIConfig.HEALTH_TEXT.FONT
	hLabel.TextSize = UIConfig.HEALTH_TEXT.TEXT_SIZE
	hLabel.TextColor3 = UIConfig.HEALTH_TEXT.TEXT_COLOR
	hLabel.TextXAlignment = Enum.TextXAlignment.Left
	hLabel.Text = ""
	hLabel.Parent = targetFrame
	healthLabel = hLabel
end

function TargetingUIController.Init(injected: { [string]: any }): ()
	deps = injected
end

function TargetingUIController.Start(): ()
	local playerGui = player:WaitForChild("PlayerGui", 10)
	if not playerGui then
		log("PlayerGui unavailable; targeting UI not built")
		return
	end

	buildUI(playerGui)

	combatHighlight = buildHighlight(UIConfig.COMBAT_HIGHLIGHT)
	interactHighlight = buildHighlight(UIConfig.INTERACT_HIGHLIGHT)

	table.insert(connections, deps.Net.OnClientEvent(Constants.REMOTES.TargetStateChanged, function(payload: any)
		if type(payload) ~= "table" then
			return
		end
		applyCombat(payload.combat)
		applyInteraction(payload.interaction)
	end))

	-- Safety clear on respawn; the server also pushes a cleared state.
	table.insert(connections, player.CharacterRemoving:Connect(function()
		applyCombat(nil)
		applyInteraction(nil)
	end))
end

function TargetingUIController.Destroy(): ()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	if combatHealthConn then
		combatHealthConn:Disconnect()
		combatHealthConn = nil
	end

	if combatHighlight then
		combatHighlight:Destroy()
		combatHighlight = nil
	end
	if interactHighlight then
		interactHighlight:Destroy()
		interactHighlight = nil
	end
	if gui then
		gui:Destroy()
		gui = nil
	end
	frame = nil
	nameLabel = nil
	healthFill = nil
	healthLabel = nil
	combatModel = nil
end

return TargetingUIController
