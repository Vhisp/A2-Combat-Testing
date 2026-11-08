--!strict
-- Client targeting input and presentation. Sends REQUESTS only; the server decides
-- everything authoritative. No eligibility, distance, or identity logic is trusted here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local TargetingConfig = require(ReplicatedStorage.Shared.Config.Targeting)

local IS_STUDIO = RunService:IsStudio()
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local TargetingController = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

local function log(...: any): ()
	if IS_STUDIO then
		print("[TargetingController]", ...)
	end
end

-- Disable the default player list so Tab is free for targeting.
-- Bounded retries: SetCoreGuiEnabled can fail while CoreGui is still starting.
local function disablePlayerList(): ()
	for attempt = 1, TargetingConfig.COREGUI_RETRY_ATTEMPTS do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		end)
		if ok then
			log(`player list disabled (attempt {attempt})`)
			return
		end
		task.wait(TargetingConfig.COREGUI_RETRY_DELAY)
	end
	warn("[TargetingController] could not disable the player list after retries")
end

-- Walk up from the raycast hit to the nearest tagged Model.
local function findTaggedModel(instance: Instance): Model?
	local current: Instance? = instance
	while current do
		if current:IsA("Model") then
			local hasCombat = CollectionService:HasTag(current, TargetingConfig.TAG_COMBAT)
			local hasInteract = CollectionService:HasTag(current, TargetingConfig.TAG_INTERACTABLE)
			if hasCombat or hasInteract then
				return current
			end
		end
		current = current.Parent
	end
	return nil
end

local function onCycle(): ()
	deps.Net.FireServer(Constants.REMOTES.RequestCycleTarget, { protocol = Constants.PROTOCOL_VERSION })
end

local function onInteract(): ()
	deps.Net.FireServer(Constants.REMOTES.RequestInteract, { protocol = Constants.PROTOCOL_VERSION })
end

-- Left click: raycast through the cursor and resolve the tagged model under it.
local function onMouseClick(): ()
	if not TargetingConfig.CLICK_SELECT_ENABLED then
		return
	end
	if not camera then
		return
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	if not result then
		return
	end

	local model = findTaggedModel(result.Instance)
	if not model then
		return
	end

	local targetId = model:GetAttribute(TargetingConfig.ATTRIBUTE_ID)
	if type(targetId) ~= "string" then
		return
	end

	deps.Net.FireServer(Constants.REMOTES.RequestSelectTarget, {
		protocol = Constants.PROTOCOL_VERSION,
		targetId = targetId,
	})
end

function TargetingController.Init(injected: { [string]: any }): ()
	deps = injected
end

function TargetingController.Start(): ()
	local net = deps.Net

	disablePlayerList()

	table.insert(connections, net.OnClientEvent(Constants.REMOTES.TargetStateChanged, function(payload: any)
		if type(payload) ~= "table" then
			return
		end
		local combat = payload.combat
		local interaction = payload.interaction
		log(`combat={combat and combat.name or "<none>"} interaction={interaction and interaction.name or "<none>"}`)
	end))

	table.insert(connections, net.OnClientEvent(Constants.REMOTES.InteractionFeedback, function(payload: any)
		if type(payload) ~= "table" then
			return
		end
		log(`interaction: {payload.message or "?"}`)
	end))

	table.insert(connections, UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		-- Ignore anything the engine or a GUI already consumed (chat, menus, etc).
		if gameProcessed then
			return
		end

		if input.KeyCode == TargetingConfig.KEYBINDS.CycleTarget then
			onCycle()
		elseif input.KeyCode == TargetingConfig.KEYBINDS.Interact then
			onInteract()
		end
	end))

	table.insert(connections, UserInputService.InputEnded:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			onMouseClick()
		end
	end))
end

function TargetingController.Destroy(): ()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return TargetingController
