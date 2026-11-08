--!strict
-- Server-authoritative combat resolution: applies validated damage to a validated target.
-- Does NOT choose targets, handle remotes, track cooldowns, derive skill damage, or send
-- feedback. SkillService (a later step) owns those and calls ResolveSkill with a
-- server-built request. This service never trusts that request: it revalidates it.
--
-- Reaches other services only through injected deps (never by requiring them).
-- Rejection reasons are INTERNAL (see CombatService.Reasons). They are never sent to
-- clients from here; the caller decides what, if anything, a client is told.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatTypes = require(ReplicatedStorage.Shared.Types.Combat)
local SkillsConfig = require(ReplicatedStorage.Shared.Config.Skills)
local Damage = require(ReplicatedStorage.Shared.Formulas.Damage)

local IS_STUDIO = RunService:IsStudio()

local CombatService = {}

local deps: { [string]: any } = {}

-- Internal rejection reasons. invalid_target / out_of_range intentionally match the
-- names in Types.Skills.SkillRejectionReason; the rest are internal only.
local Reasons = table.freeze({
	InvalidRequest = "invalid_request", -- request, attacker, skillId, targetId, or params malformed
	InvalidAttacker = "invalid_attacker", -- attacker not ready, dead, or has no valid character
	UnknownSkill = "unknown_skill", -- skillId has no definition
	InvalidDamage = "invalid_damage", -- params.damage is missing, invalid, or floors to 0
	InvalidTarget = "invalid_target", -- unknown, stale, self, ineligible, or dead target
	OutOfRange = "out_of_range", -- attacker is beyond the skill's configured range
	DamageBlocked = "damage_blocked", -- TakeDamage ran but no health was lost (e.g. ForceField)
	DamageFailed = "damage_failed", -- TakeDamage errored and no health was lost
})
CombatService.Reasons = Reasons

local function log(...: any): ()
	if IS_STUDIO then
		print("[CombatService]", ...)
	end
end

local function reject(targetId: string, reason: string): CombatTypes.CombatResult
	return {
		ok = false,
		reason = reason,
		targetId = targetId,
		damage = 0,
		targetDied = false,
	}
end

-- Health must be finite and strictly above zero. This is the liveness check combat
-- trusts: the shared targeting eligibility test only rejects Health <= 0, so NaN and
-- +infinity pass it, and TakeDamage on non-finite health can leave Health as NaN.
-- NaN is rejected explicitly (it is the only value that does not equal itself) rather
-- than relying on how it happens to compare against 0 or infinity.
local function isAlive(humanoid: Humanoid): boolean
	local health = humanoid.Health
	if health ~= health then
		return false -- NaN
	end
	return health > 0 and health < math.huge
end

-- Same convention as TargetingService: a player's position is their HumanoidRootPart.
local function getRootPosition(character: Model): Vector3?
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function requireMember(container: any, dependency: string, member: string): ()
	assert(
		type(container) == "table" and type(container[member]) == "function",
		`CombatService missing dependency {dependency}.{member}`
	)
end

-- request is expected to match Types.Combat.ResolveSkillRequest, but is typed `any`
-- because every field is revalidated here before use. Never throws for bad input.
function CombatService.ResolveSkill(request: any): CombatTypes.CombatResult
	if type(request) ~= "table" then
		return reject("", Reasons.InvalidRequest)
	end

	-- CombatResult.targetId is a non-optional string, so an unusable id reports as "".
	local rawTargetId = request.targetId
	local targetId = if type(rawTargetId) == "string" then rawTargetId else ""

	-- 1. Request shape (pure checks first; no game state is read yet).
	local rawAttacker = request.attacker
	if typeof(rawAttacker) ~= "Instance" or not rawAttacker:IsA("Player") then
		return reject(targetId, Reasons.InvalidRequest)
	end
	local player = rawAttacker :: Player

	local skillId = request.skillId
	if type(skillId) ~= "string" or type(rawTargetId) ~= "string" then
		return reject(targetId, Reasons.InvalidRequest)
	end

	local params = request.params
	if type(params) ~= "table" then
		return reject(targetId, Reasons.InvalidRequest)
	end

	-- 2. Skill definition (used for the range revalidation only).
	local definition = SkillsConfig.DEFINITIONS[skillId]
	if not definition then
		return reject(targetId, Reasons.UnknownSkill)
	end

	-- 3. Damage: server-supplied power through the shared formula. Anything that
	-- floors to zero (missing, non-numeric, negative, NaN, infinite, < 1) is rejected.
	local damage = Damage.Calculate(params.damage)
	if damage <= 0 then
		return reject(targetId, Reasons.InvalidDamage)
	end

	-- 4. Attacker state, read fresh. Nothing below yields, so state cannot change
	-- between these checks and the TakeDamage call.
	if not deps.PlayerService.IsReady(player) then
		return reject(targetId, Reasons.InvalidAttacker)
	end
	local state = deps.CharacterService.GetState(player)
	if not state then
		return reject(targetId, Reasons.InvalidAttacker)
	end
	local character: Model = state.character
	local attackerHumanoid: Humanoid = state.humanoid
	if
		player.Character ~= character
		or character.Parent == nil
		or not attackerHumanoid:IsDescendantOf(character)
		or not isAlive(attackerHumanoid)
	then
		return reject(targetId, Reasons.InvalidAttacker)
	end
	local origin = getRootPosition(character)
	if not origin then
		return reject(targetId, Reasons.InvalidAttacker)
	end

	-- 5. Target: resolved only through the server-owned registry, then fully revalidated.
	local targetModel: Model? = deps.TargetingService.ResolveTargetId(targetId)
	if not targetModel then
		return reject(targetId, Reasons.InvalidTarget)
	end
	if targetModel == character then
		return reject(targetId, Reasons.InvalidTarget) -- self-targeting
	end
	if targetModel.Parent == nil or not deps.Targeting.isCombatEligible(targetModel) then
		return reject(targetId, Reasons.InvalidTarget)
	end
	local targetHumanoid = targetModel:FindFirstChildOfClass("Humanoid")
	-- Non-finite or non-positive target health is rejected here, before any damage is applied.
	if not targetHumanoid or not isAlive(targetHumanoid) then
		return reject(targetId, Reasons.InvalidTarget)
	end

	-- 6. Range, from current positions. NaN distance fails closed.
	local targetPosition = deps.Targeting.getPosition(targetModel)
	if not targetPosition then
		return reject(targetId, Reasons.InvalidTarget)
	end
	local distance = deps.Targeting.distanceBetween(origin, targetPosition)
	if not (distance <= definition.range) then
		return reject(targetId, Reasons.OutOfRange)
	end

	-- 7. Apply. Report OBSERVED health loss, never the requested amount.
	-- Humanoid:TakeDamage does not clamp at zero (testing showed negative and -inf Health
	-- after overkill), so never request more than the target has left. That keeps target
	-- Health >= 0 and keeps "damage applied" meaning health actually removed.
	-- healthBefore is finite and > 0 here: isAlive validated it above and nothing yields since.
	local healthBefore = targetHumanoid.Health
	local requested = math.min(damage, healthBefore)
	local callOk = pcall(function()
		targetHumanoid:TakeDamage(requested)
	end)
	local healthAfter = targetHumanoid.Health
	local applied = healthBefore - healthAfter

	if not (applied > 0) then
		local reason = if callOk then Reasons.DamageBlocked else Reasons.DamageFailed
		log(`{player.Name} -> {targetModel.Name} ({targetId}): no health lost ({reason})`)
		return reject(targetId, reason)
	end

	local targetDied = healthAfter <= 0
	log(`{player.Name} hit {targetModel.Name} ({targetId}) with {skillId}: {applied} damage, died={targetDied}`)

	return {
		ok = true,
		targetId = targetId,
		damage = applied,
		targetDied = targetDied,
	}
end

-- Action-combat hit (BDO-style prototype), added alongside ResolveSkill, which is untouched.
-- Same attacker/target revalidation and the same observed-health-loss damage application,
-- but the reach comes from the SERVER-built request instead of a skill definition, and
-- there is no skill id (the caller names the action for logging only).
-- request: { attacker: Player, actionId: string, targetId: string, damage: number, range: number }
function CombatService.ResolveHit(request: any): CombatTypes.CombatResult
	if type(request) ~= "table" then
		return reject("", Reasons.InvalidRequest)
	end

	local rawTargetId = request.targetId
	local targetId = if type(rawTargetId) == "string" then rawTargetId else ""

	local rawAttacker = request.attacker
	if typeof(rawAttacker) ~= "Instance" or not rawAttacker:IsA("Player") then
		return reject(targetId, Reasons.InvalidRequest)
	end
	local player = rawAttacker :: Player

	local actionId = request.actionId
	if type(actionId) ~= "string" or type(rawTargetId) ~= "string" then
		return reject(targetId, Reasons.InvalidRequest)
	end

	local range = request.range
	if type(range) ~= "number" or range ~= range or range <= 0 or range == math.huge then
		return reject(targetId, Reasons.InvalidRequest)
	end

	local damage = Damage.Calculate(request.damage)
	if damage <= 0 then
		return reject(targetId, Reasons.InvalidDamage)
	end

	if not deps.PlayerService.IsReady(player) then
		return reject(targetId, Reasons.InvalidAttacker)
	end
	local state = deps.CharacterService.GetState(player)
	if not state then
		return reject(targetId, Reasons.InvalidAttacker)
	end
	local character: Model = state.character
	local attackerHumanoid: Humanoid = state.humanoid
	if
		player.Character ~= character
		or character.Parent == nil
		or not attackerHumanoid:IsDescendantOf(character)
		or not isAlive(attackerHumanoid)
	then
		return reject(targetId, Reasons.InvalidAttacker)
	end
	local origin = getRootPosition(character)
	if not origin then
		return reject(targetId, Reasons.InvalidAttacker)
	end

	local targetModel: Model? = deps.TargetingService.ResolveTargetId(targetId)
	if not targetModel or targetModel == character then
		return reject(targetId, Reasons.InvalidTarget)
	end
	if targetModel.Parent == nil or not deps.Targeting.isCombatEligible(targetModel) then
		return reject(targetId, Reasons.InvalidTarget)
	end
	local targetHumanoid = targetModel:FindFirstChildOfClass("Humanoid")
	if not targetHumanoid or not isAlive(targetHumanoid) then
		return reject(targetId, Reasons.InvalidTarget)
	end

	local targetPosition = deps.Targeting.getPosition(targetModel)
	if not targetPosition then
		return reject(targetId, Reasons.InvalidTarget)
	end
	local distance = deps.Targeting.distanceBetween(origin, targetPosition)
	if not (distance <= range) then
		return reject(targetId, Reasons.OutOfRange)
	end

	local healthBefore = targetHumanoid.Health
	local requested = math.min(damage, healthBefore)
	local callOk = pcall(function()
		targetHumanoid:TakeDamage(requested)
	end)
	local healthAfter = targetHumanoid.Health
	local applied = healthBefore - healthAfter

	if not (applied > 0) then
		local reason = if callOk then Reasons.DamageBlocked else Reasons.DamageFailed
		log(`{player.Name} -> {targetModel.Name} ({targetId}): no health lost ({reason})`)
		return reject(targetId, reason)
	end

	local targetDied = healthAfter <= 0
	log(`{player.Name} hit {targetModel.Name} ({targetId}) with {actionId}: {applied} damage, died={targetDied}`)

	return {
		ok = true,
		targetId = targetId,
		damage = applied,
		targetDied = targetDied,
	}
end

function CombatService.Init(injected: { [string]: any }): ()
	-- Fail fast at startup on a miswired dependency instead of silently rejecting
	-- every request later.
	requireMember(injected.PlayerService, "PlayerService", "IsReady")
	requireMember(injected.CharacterService, "CharacterService", "GetState")
	requireMember(injected.TargetingService, "TargetingService", "ResolveTargetId")
	requireMember(injected.Targeting, "Targeting", "isCombatEligible")
	requireMember(injected.Targeting, "Targeting", "getPosition")
	requireMember(injected.Targeting, "Targeting", "distanceBetween")
	deps = injected
end

function CombatService.Destroy(): ()
	deps = {}
end

return CombatService
