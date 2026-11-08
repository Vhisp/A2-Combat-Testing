--!strict
-- Combat and interaction targeting. Server-authoritative.
-- Owns the targetable registry, both target states, and all validation.
-- Does NOT implement attacks, damage, health, or dialogue - targeting only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local TargetingConfig = require(ReplicatedStorage.Shared.Config.Targeting)

local IS_STUDIO = RunService:IsStudio()

local TargetingService = {}

local deps: { [string]: any } = {}

-- Registry: server-generated ids, unique for the session, never reused.
local idToInstance: { [string]: Model } = {}
local instanceToId: { [Model]: string } = {}
local idCounter = 0

-- Per-player target state. Combat and interaction are fully independent.
local combatTarget: { [Player]: Model } = {}
local interactionTarget: { [Player]: Model } = {}

local globalConnections: { RBXScriptConnection } = {}
local instanceConnections: { [Model]: { RBXScriptConnection } } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}
local validationThread: thread? = nil
-- Instances already warned about, so a dual-tagged model warns once, not once per tag.
local dualWarned: { [Instance]: boolean } = {}

local function log(...: any): ()
	if IS_STUDIO then
		print("[TargetingService]", ...)
	end
end

local function warnStudio(...: any): ()
	if IS_STUDIO then
		warn("[TargetingService]", ...)
	end
end

local function getPlayerPosition(player: Player): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function pushState(player: Player): ()
	local combat = combatTarget[player]
	local interaction = interactionTarget[player]

	local payload = {
		combat = combat and { id = instanceToId[combat] or "", name = combat.Name } or nil,
		interaction = interaction and { id = instanceToId[interaction] or "", name = interaction.Name } or nil,
	}

	deps.Net.FireClient(Constants.REMOTES.TargetStateChanged, player, payload)
end

local function clearCombat(player: Player): ()
	if combatTarget[player] ~= nil then
		combatTarget[player] = nil
		pushState(player)
	end
end

local function clearInteraction(player: Player): ()
	if interactionTarget[player] ~= nil then
		interactionTarget[player] = nil
		pushState(player)
	end
end

local function clearBoth(player: Player): ()
	local changed = false
	if combatTarget[player] ~= nil then
		combatTarget[player] = nil
		changed = true
	end
	if interactionTarget[player] ~= nil then
		interactionTarget[player] = nil
		changed = true
	end
	if changed then
		pushState(player)
	end
end

local function clearPlayersTargeting(instance: Model): ()
	for player, target in combatTarget do
		if target == instance then
			combatTarget[player] = nil
			pushState(player)
		end
	end
	for player, target in interactionTarget do
		if target == instance then
			interactionTarget[player] = nil
			pushState(player)
		end
	end
end

local function unregister(instance: Model): ()
	local id = instanceToId[instance]
	if not id then
		return
	end

	local connections = instanceConnections[instance]
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
		instanceConnections[instance] = nil
	end

	clearPlayersTargeting(instance)

	instanceToId[instance] = nil
	idToInstance[id] = nil

	if instance.Parent ~= nil then
		instance:SetAttribute(TargetingConfig.ATTRIBUTE_ID, nil)
	end
end

local function register(instance: Instance): ()
	if not instance:IsA("Model") then
		return
	end

	if deps.Targeting.isDualTagged(instance) then
		if not dualWarned[instance] then
			dualWarned[instance] = true
			warnStudio(`rejected dual-tagged model '{instance:GetFullName()}' - it carries both CombatTarget and Interactable`)
		end
		return
	end
	-- A model that stops being dual-tagged may be warned about again if it regresses.
	dualWarned[instance] = nil

	if instanceToId[instance] then
		return
	end

	idCounter += 1
	local id = `t_{idCounter}`

	idToInstance[id] = instance
	instanceToId[instance] = id
	instance:SetAttribute(TargetingConfig.ATTRIBUTE_ID, id)

	local connections: { RBXScriptConnection } = {}

	table.insert(connections, instance.Destroying:Connect(function()
		unregister(instance)
	end))

	local humanoid = instance:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(connections, humanoid.Died:Connect(function()
			clearPlayersTargeting(instance)
		end))
	end

	table.insert(connections, CollectionService:GetInstanceRemovedSignal(TargetingConfig.TAG_COMBAT):Connect(function(removed)
		if removed == instance then
			unregister(instance)
		end
	end))
	table.insert(connections, CollectionService:GetInstanceRemovedSignal(TargetingConfig.TAG_INTERACTABLE):Connect(function(removed)
		if removed == instance then
			unregister(instance)
		end
	end))

	instanceConnections[instance] = connections
	log(`registered {instance.Name} as {id}`)
end

local function selectTarget(player: Player, instance: Model): boolean
	local origin = getPlayerPosition(player)
	if not origin then
		return false
	end

	local position = deps.Targeting.getPosition(instance)
	if not position then
		return false
	end

	local distance = deps.Targeting.distanceBetween(origin, position)

	if deps.Targeting.isInteractEligible(instance) then
		if distance > TargetingConfig.MAX_ACQUIRE_RANGE then
			return false
		end
		interactionTarget[player] = instance
		pushState(player)
		log(`{player.Name} interaction target -> {instance.Name} ({math.floor(distance)} studs)`)
		return true
	end

	if deps.Targeting.isCombatEligible(instance) then
		if distance > TargetingConfig.MAX_ACQUIRE_RANGE then
			return false
		end
		if player.Character == instance then
			return false
		end
		combatTarget[player] = instance
		pushState(player)
		log(`{player.Name} combat target -> {instance.Name} ({math.floor(distance)} studs)`)
		return true
	end

	return false
end

local function cycleTarget(player: Player): ()
	local origin = getPlayerPosition(player)
	if not origin then
		clearCombat(player)
		return
	end

	local candidates = deps.Targeting.buildCandidates(instanceToId, origin, TargetingConfig.MAX_ACQUIRE_RANGE)
	if #candidates == 0 then
		clearCombat(player)
		return
	end

	local current = combatTarget[player]
	local nextInstance: Model? = nil

	if current then
		for index, candidate in candidates do
			if candidate.instance == current then
				local nextIndex = (index % #candidates) + 1
				nextInstance = candidates[nextIndex].instance
				break
			end
		end
	end

	if not nextInstance then
		nextInstance = candidates[1].instance
	end

	combatTarget[player] = nextInstance
	pushState(player)
	log(`{player.Name} cycled -> {nextInstance.Name}`)
end

local function requestInteract(player: Player): ()
	local target = interactionTarget[player]
	if not target then
		return
	end

	local origin = getPlayerPosition(player)
	local position = deps.Targeting.getPosition(target)
	if not origin or not position then
		clearInteraction(player)
		return
	end

	if not deps.Targeting.isInteractEligible(target) then
		clearInteraction(player)
		return
	end

	local distance = deps.Targeting.distanceBetween(origin, position)
	if distance > TargetingConfig.MAX_INTERACT_RANGE then
		deps.Net.FireClient(Constants.REMOTES.InteractionFeedback, player, {
			ok = false,
			targetId = instanceToId[target],
			message = "out of range",
		})
		return
	end

	deps.Net.FireClient(Constants.REMOTES.InteractionFeedback, player, {
		ok = true,
		targetId = instanceToId[target],
		message = `interacting with {target.Name}`,
	})
	log(`{player.Name} interacted with {target.Name} ({math.floor(distance)} studs)`)
end

local function reject(player: Player, detail: string): ()
	warnStudio(`rejected {player.Name}: {detail}`)
end

local function startValidationLoop(): ()
	validationThread = task.spawn(function()
		while true do
			task.wait(TargetingConfig.VALIDATION_INTERVAL)

			for player in playerConnections do
				local origin = getPlayerPosition(player)
				if not origin then
					clearBoth(player)
					continue
				end

				local combat = combatTarget[player]
				if combat then
					local position = deps.Targeting.getPosition(combat)
					if not position or not deps.Targeting.isCombatEligible(combat) then
						clearCombat(player)
					elseif deps.Targeting.distanceBetween(origin, position) > TargetingConfig.MAX_RETENTION_RANGE then
						clearCombat(player)
					end
				end

				local interaction = interactionTarget[player]
				if interaction then
					local position = deps.Targeting.getPosition(interaction)
					if not position or not deps.Targeting.isInteractEligible(interaction) then
						clearInteraction(player)
					elseif deps.Targeting.distanceBetween(origin, position) > TargetingConfig.MAX_INTERACT_RETENTION_RANGE then
						clearInteraction(player)
					end
				end
			end
		end
	end)
end

local function onPlayerAdded(player: Player)
	clearBoth(player)

	local connections: { RBXScriptConnection } = {}

	table.insert(connections, player.CharacterAdded:Connect(function()
		clearBoth(player)
	end))

	table.insert(connections, player.CharacterRemoving:Connect(function()
		clearBoth(player)
	end))

	playerConnections[player] = connections
end

function TargetingService.Init(injected: { [string]: any }): ()
	deps = injected
end

function TargetingService.Start(): ()
	local net = deps.Net
	local validate = deps.Validate
	local rateLimiter = deps.RateLimiter

	for _, instance in CollectionService:GetTagged(TargetingConfig.TAG_COMBAT) do
		register(instance)
	end
	for _, instance in CollectionService:GetTagged(TargetingConfig.TAG_INTERACTABLE) do
		register(instance)
	end

	table.insert(globalConnections, CollectionService:GetInstanceAddedSignal(TargetingConfig.TAG_COMBAT):Connect(register))
	table.insert(globalConnections, CollectionService:GetInstanceAddedSignal(TargetingConfig.TAG_INTERACTABLE):Connect(register))

	table.insert(globalConnections, Players.PlayerAdded:Connect(onPlayerAdded))
	table.insert(globalConnections, Players.PlayerRemoving:Connect(function(player)
		combatTarget[player] = nil
		interactionTarget[player] = nil
		local connections = playerConnections[player]
		if connections then
			for _, connection in connections do
				connection:Disconnect()
			end
			playerConnections[player] = nil
		end
	end))

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	table.insert(globalConnections, net.OnServerRequest(Constants.REMOTES.RequestCycleTarget, function(player: Player, payload: any)
		if not rateLimiter.Check(player, "Global") then
			reject(player, "global throttle")
			return
		end
		if not validate.RequestShape(payload) then
			reject(player, "cycle shape")
			return
		end
		if not rateLimiter.Check(player, "Targeting") then
			reject(player, "targeting throttle")
			return
		end
		cycleTarget(player)
	end))

	table.insert(globalConnections, net.OnServerRequest(Constants.REMOTES.RequestSelectTarget, function(player: Player, payload: any)
		if not rateLimiter.Check(player, "Global") then
			reject(player, "global throttle")
			return
		end
		if not validate.RequestShape(payload) then
			reject(player, "select shape")
			return
		end
		if not rateLimiter.Check(player, "Targeting") then
			reject(player, "targeting throttle")
			return
		end

		local targetId = payload.targetId
		if type(targetId) ~= "string" then
			reject(player, "targetId not a string")
			return
		end

		local instance = idToInstance[targetId]
		if not instance then
			reject(player, `unknown targetId '{targetId}'`)
			return
		end

		if not selectTarget(player, instance) then
			reject(player, `target '{targetId}' failed validation`)
		end
	end))

	table.insert(globalConnections, net.OnServerRequest(Constants.REMOTES.RequestInteract, function(player: Player, payload: any)
		if not rateLimiter.Check(player, "Global") then
			reject(player, "global throttle")
			return
		end
		if not validate.RequestShape(payload) then
			reject(player, "interact shape")
			return
		end
		if not rateLimiter.Check(player, "Interact") then
			reject(player, "interact throttle")
			return
		end
		requestInteract(player)
	end))

	startValidationLoop()
end

-- Read-only registry lookup for other services. Returns the registered Model for a
-- server-generated id, or nil for anything else. Performs NO eligibility, health, or
-- range checks: callers must validate the returned Model themselves.
function TargetingService.ResolveTargetId(targetId: string): Model?
	if type(targetId) ~= "string" then
		return nil
	end
	return idToInstance[targetId]
end

-- Read-only accessor for other services: the registered id of the player's CURRENT
-- combat target, or nil when there is none. Returns only the id string, so the registry
-- and the target state stay private. Performs NO eligibility, health, or range checks:
-- callers must validate through the id (CombatService.ResolveSkill does).
function TargetingService.GetCombatTargetId(player: Player): string?
	local target = combatTarget[player]
	if not target then
		return nil
	end
	return instanceToId[target]
end

function TargetingService.Destroy(): ()
	if validationThread then
		task.cancel(validationThread)
		validationThread = nil
	end

	for _, connection in globalConnections do
		connection:Disconnect()
	end
	table.clear(globalConnections)

	local registered: { Model } = {}
	for instance in instanceToId do
		table.insert(registered, instance)
	end
	for _, instance in registered do
		unregister(instance)
	end

	table.clear(idToInstance)
	table.clear(instanceToId)
	table.clear(combatTarget)
	table.clear(interactionTarget)
	table.clear(playerConnections)
	table.clear(instanceConnections)
	table.clear(dualWarned)
end

return TargetingService
