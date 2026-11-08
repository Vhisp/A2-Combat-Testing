--!strict
-- Server-authoritative action combat (BDO-inspired prototype).
--
-- The client PREDICTS (plays the attack immediately); this service decides whether the
-- action is legal and what it hits. It owns:
--   * timing/combo/dodge legality (shared ActionRules, with LatencyTolerance)
--   * who gets hit: a cone/range check around the attacker's SERVER-side root at HitTime
--   * damage, applied through CombatService.ResolveHit (never directly)
--   * training-dummy refill so the sandbox can be played continuously
--
-- From the client it reads only: input ("Light"/"Heavy"/"Dodge"), a sequence number, and an
-- aim direction (flattened and normalised). The aim is the one trusted-ish field: it orients
-- the hit cone, but range, targets, timing and damage are all server-derived.
--
-- Reaches other services only through injected deps (never by requiring them).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local TargetingConfig = require(ReplicatedStorage.Shared.Config.Targeting)
local CombatFeel = require(ReplicatedStorage.Shared.Config.CombatFeel)
local ActionRules = require(ReplicatedStorage.Shared.Formulas.ActionRules)

local IS_STUDIO = RunService:IsStudio()

local ActionCombatService = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

-- Per character generation, like SkillService cooldowns: a respawn starts from a clean state.
type PlayerCombat = {
	generation: number,
	rules: ActionRules.State,
	serial: number, -- bumped on every accepted action; a pending hit only lands if it still matches
	iframeToken: number,
	iframesUntil: number,
}
local combatByPlayer: { [Player]: PlayerCombat } = {}
local dummies: { [Model]: boolean } = {}

local VALID_INPUTS: { [string]: boolean } = { Light = true, Heavy = true, Dodge = true }

local function log(...: any): ()
	if IS_STUDIO then
		print("[ActionCombatService]", ...)
	end
end

local function warnStudio(...: any): ()
	if IS_STUDIO then
		warn("[ActionCombatService]", ...)
	end
end

local function requireMember(container: any, dependency: string, member: string): ()
	assert(
		type(container) == "table" and type(container[member]) == "function",
		`ActionCombatService missing dependency {dependency}.{member}`
	)
end

local function sendResult(player: Player, payload: { [string]: any }): ()
	deps.Net.FireClient(Constants.REMOTES.CombatActionResult, player, payload)
end

-- Same liveness rule as SkillService/CombatService: ready player, CURRENT character, finite health > 0.
local function getLiveCasterState(player: Player): any
	if not deps.PlayerService.IsReady(player) then
		return nil
	end
	local state = deps.CharacterService.GetState(player)
	if not state then
		return nil
	end
	if player.Character ~= state.character or not state.humanoid:IsDescendantOf(state.character) then
		return nil
	end
	local health = state.humanoid.Health
	if not (health > 0 and health < math.huge) then
		return nil
	end
	return state
end

local function getCombat(player: Player, generation: number): PlayerCombat
	local combat = combatByPlayer[player]
	if combat == nil or combat.generation ~= generation then
		combat = {
			generation = generation,
			rules = ActionRules.NewState(),
			serial = 0,
			iframeToken = 0,
			iframesUntil = 0,
		}
		combatByPlayer[player] = combat
	end
	return combat :: PlayerCombat
end

-- Returns (input, flatAimUnit, seq) or nil for anything malformed.
local function parseRequest(payload: any): (string?, Vector3?, number?)
	if type(payload) ~= "table" then
		return nil, nil, nil
	end
	if payload.protocol ~= Constants.PROTOCOL_VERSION then
		return nil, nil, nil
	end
	local input = payload.input
	if type(input) ~= "string" or VALID_INPUTS[input] ~= true then
		return nil, nil, nil
	end
	local seq = payload.seq
	if type(seq) ~= "number" or seq ~= seq or seq == math.huge or seq == -math.huge then
		return nil, nil, nil
	end
	local aim = payload.aim
	if typeof(aim) ~= "Vector3" then
		return nil, nil, nil
	end
	local flat = Vector3.new(aim.X, 0, aim.Z)
	local magnitude = flat.Magnitude
	if magnitude ~= magnitude or magnitude < 0.01 or magnitude == math.huge then
		return nil, nil, nil
	end
	return input, flat / magnitude, seq
end

-- Runs at the action's HitTime. Finds targets in the cone around the attacker's current
-- server position and applies damage through CombatService.ResolveHit.
local function resolveHit(player: Player, combat: PlayerCombat, serial: number, actionId: string, aim: Vector3): ()
	if combat.serial ~= serial then
		return -- cancelled: dodged out, or a newer action replaced this one
	end
	local caster = getLiveCasterState(player)
	if not caster or caster.generation ~= combat.generation then
		return
	end
	local character: Model = caster.character
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local def = CombatFeel.Actions[actionId]
	local tuning = CombatFeel.Combat
	local origin = root.Position
	local halfAngle = math.rad(def.Angle * 0.5)
	local reach = def.Range + tuning.TargetRadius

	type Hit = { model: Model, id: string, distance: number }
	local hits: { Hit } = {}

	for _, instance in CollectionService:GetTagged(TargetingConfig.TAG_COMBAT) do
		if instance:IsA("Model") and instance ~= character and deps.Targeting.isCombatEligible(instance) then
			local position = deps.Targeting.getPosition(instance)
			local id = instance:GetAttribute(TargetingConfig.ATTRIBUTE_ID)
			if position and type(id) == "string" then
				local offset = position - origin
				if math.abs(offset.Y) <= tuning.HitHeight then
					local flat = Vector3.new(offset.X, 0, offset.Z)
					local distance = flat.Magnitude
					if distance <= reach then
						-- Targets have width: widen the cone by the angle their radius covers.
						local slack = math.atan2(tuning.TargetRadius, math.max(distance, 0.01))
						local angle = 0
						if distance > 0.01 then
							angle = math.acos(math.clamp(flat.Unit:Dot(aim), -1, 1))
						end
						if angle <= halfAngle + slack then
							table.insert(hits, { model = instance, id = id, distance = distance })
						end
					end
				end
			end
		end
	end

	table.sort(hits, function(a: Hit, b: Hit)
		return a.distance < b.distance
	end)

	-- ResolveHit re-checks the (3D) distance; give it the flat reach plus the allowed height.
	local resolveRange = math.sqrt(reach * reach + tuning.HitHeight * tuning.HitHeight)

	for index = 1, math.min(#hits, tuning.MaxHitTargets) do
		local hit = hits[index]
		local called, result = pcall(deps.CombatService.ResolveHit, {
			attacker = player,
			actionId = actionId,
			targetId = hit.id,
			damage = def.Damage,
			range = resolveRange,
		})
		if not called then
			warnStudio(`CombatService.ResolveHit errored for {player.Name} ({actionId}): {tostring(result)}`)
		elseif type(result) == "table" and result.ok == true then
			sendResult(player, {
				type = "hit",
				targetId = hit.id,
				damage = result.damage,
				died = result.targetDied,
				action = actionId,
			})
		end
	end
end

local function onRequest(player: Player, payload: any): ()
	-- 1. Dedicated Combat throttle FIRST, before the payload is inspected at all.
	if not deps.RateLimiter.Check(player, "Combat") then
		warnStudio(`rejected {player.Name}: combat throttle`)
		return
	end

	-- 2. Structure.
	local input, aim, seq = parseRequest(payload)
	if input == nil or aim == nil or seq == nil then
		warnStudio(`rejected {player.Name}: malformed combat request`)
		return
	end

	-- 3. Caster must be ready and alive (no feedback: a dead player pressing a key is normal).
	local caster = getLiveCasterState(player)
	if not caster then
		return
	end
	local character: Model = caster.character
	local combat = getCombat(player, caster.generation)

	-- 4. Legality: the same rules the client predicted with, plus latency tolerance.
	local now = os.clock()
	local actionId, reason = ActionRules.Evaluate(combat.rules, input, now, CombatFeel.Combat.LatencyTolerance)
	if actionId == nil then
		sendResult(player, { type = "ack", seq = seq, ok = false, reason = reason })
		return
	end

	-- 5. Accept. Bumping `serial` cancels any hit still pending from the previous action.
	ActionRules.Begin(combat.rules, actionId, now)
	combat.serial += 1
	local serial = combat.serial
	character:SetAttribute("CombatAction", actionId)
	sendResult(player, { type = "ack", seq = seq, ok = true, action = actionId })

	if actionId == "Dodge" then
		local dodge = CombatFeel.Dodge
		combat.iframeToken += 1
		local token = combat.iframeToken
		combat.iframesUntil = now + dodge.IFrameDuration
		character:SetAttribute("IFrames", true)
		task.delay(dodge.IFrameDuration, function()
			if combat.iframeToken == token then
				character:SetAttribute("IFrames", nil)
			end
		end)
		task.delay(dodge.Duration, function()
			if combat.serial == serial then
				character:SetAttribute("CombatAction", nil)
			end
		end)
		log(`{player.Name} dodge`)
		return
	end

	local def = CombatFeel.Actions[actionId]
	local speed = ActionRules.ActionSpeed(def)
	task.delay(def.HitTime / speed, resolveHit, player, combat, serial, actionId, aim)
	task.delay(def.Duration / speed, function()
		if combat.serial == serial then
			character:SetAttribute("CombatAction", nil)
		end
	end)
	log(`{player.Name} {actionId} (seq {seq})`)
end

-- Training dummies cannot die: at 0 HP they are "down" (ineligible for targeting/damage via the
-- existing Health <= 0 rules) and are refilled after RespawnTime.
local function setupDummy(instance: Instance): ()
	if not instance:IsA("Model") or dummies[instance] then
		return
	end
	local humanoid = instance:FindFirstChildOfClass("Humanoid")
	if not humanoid or Players:GetPlayerFromCharacter(instance) then
		return
	end
	dummies[instance] = true
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)

	local reviving = false
	table.insert(connections, humanoid.HealthChanged:Connect(function(health: number)
		if health > 0 or reviving then
			return
		end
		reviving = true
		instance:SetAttribute("Downed", true)
		task.delay(CombatFeel.Dummy.RespawnTime, function()
			reviving = false
			if humanoid.Parent then
				humanoid.Health = humanoid.MaxHealth
				instance:SetAttribute("Downed", nil)
			end
		end)
	end))
end

-- Read-only helpers (handy for tests and for future enemy-attack code).
function ActionCombatService.IsInvulnerable(player: Player): boolean
	local combat = combatByPlayer[player]
	return combat ~= nil and os.clock() < combat.iframesUntil
end

function ActionCombatService.GetCurrentAction(player: Player): string?
	local combat = combatByPlayer[player]
	if combat == nil then
		return nil
	end
	return combat.rules.current
end

function ActionCombatService.Init(injected: { [string]: any }): ()
	requireMember(injected.Net, "Net", "OnServerRequest")
	requireMember(injected.Net, "Net", "FireClient")
	requireMember(injected.RateLimiter, "RateLimiter", "Check")
	requireMember(injected.PlayerService, "PlayerService", "IsReady")
	requireMember(injected.CharacterService, "CharacterService", "GetState")
	requireMember(injected.CombatService, "CombatService", "ResolveHit")
	requireMember(injected.Targeting, "Targeting", "isCombatEligible")
	requireMember(injected.Targeting, "Targeting", "getPosition")
	deps = injected
end

function ActionCombatService.Start(): ()
	table.insert(connections, deps.Net.OnServerRequest(Constants.REMOTES.RequestCombatAction, onRequest))

	table.insert(connections, Players.PlayerRemoving:Connect(function(player: Player)
		combatByPlayer[player] = nil
	end))

	if CombatFeel.Dummy.Enabled then
		for _, instance in CollectionService:GetTagged(TargetingConfig.TAG_COMBAT) do
			setupDummy(instance)
		end
		table.insert(
			connections,
			CollectionService:GetInstanceAddedSignal(TargetingConfig.TAG_COMBAT):Connect(setupDummy)
		)
	end
end

function ActionCombatService.Destroy(): ()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(combatByPlayer)
	table.clear(dummies)
	deps = {}
end

return ActionCombatService
