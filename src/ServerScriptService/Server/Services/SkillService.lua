--!strict
-- Skill use: request handling, server-side cooldowns, and feedback. Server-authoritative.
-- Decides WHETHER a skill may be attempted (ready and living caster, cooldown, a current
-- combat target) and derives the skill's parameters from Config.Skills. Does NOT apply
-- damage (CombatService), choose or store targets (TargetingService), or read anything
-- from the client request except the skill id.
--
-- Reaches other services only through injected deps (never by requiring them).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local SkillsConfig = require(ReplicatedStorage.Shared.Config.Skills)
local SkillTypes = require(ReplicatedStorage.Shared.Types.Skills)
local CombatTypes = require(ReplicatedStorage.Shared.Types.Combat)
local Damage = require(ReplicatedStorage.Shared.Formulas.Damage)

local IS_STUDIO = RunService:IsStudio()

local SkillService = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

-- Cooldown state for ONE character generation. When the generation changes (respawn),
-- the old state is replaced on next use, so a new character never inherits a cooldown.
-- Cooldowns are timestamps compared on demand: no Heartbeat, no per-frame loop.
type CooldownState = {
	generation: number,
	readyAt: { [string]: number }, -- skillId -> os.clock() time the skill is usable again
}
local cooldowns: { [Player]: CooldownState } = {}

-- CombatService rejection reason -> the public reason a client may be told. Built in Init
-- from CombatService.Reasons so the strings are not duplicated here. A reason that is
-- NOT in this map is an internal fault (bad request, bad attacker, bad params): the client
-- gets no feedback for it, and it never produces success feedback or a cooldown.
local publicReasons: { [string]: SkillTypes.SkillRejectionReason } = {}

local function log(...: any): ()
	if IS_STUDIO then
		print("[SkillService]", ...)
	end
end

local function warnStudio(...: any): ()
	if IS_STUDIO then
		warn("[SkillService]", ...)
	end
end

local function requireMember(container: any, dependency: string, member: string): ()
	assert(
		type(container) == "table" and type(container[member]) == "function",
		`SkillService missing dependency {dependency}.{member}`
	)
end

-- Feedback to the requesting player only. Success carries no reason.
local function sendFeedback(player: Player, skillId: string, ok: boolean, reason: SkillTypes.SkillRejectionReason?): ()
	local feedback: SkillTypes.SkillFeedback = {
		skillId = skillId,
		ok = ok,
		reason = reason,
	}
	deps.Net.FireClient(Constants.REMOTES.SkillFeedback, player, feedback)
end

-- The caster's CharacterState, or nil unless the player is ready and their CURRENT
-- character has a living Humanoid. Health must be finite and above zero, matching the
-- liveness rule CombatService applies to the attacker.
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
	-- NaN fails `health > 0`, so it is rejected here too.
	if not (health > 0 and health < math.huge) then
		return nil
	end
	return state
end

-- Cooldown state for this player's CURRENT generation; replaces a previous character's.
local function getCooldownState(player: Player, generation: number): CooldownState
	local state = cooldowns[player]
	if state == nil or state.generation ~= generation then
		state = { generation = generation, readyAt = {} }
		cooldowns[player] = state
	end
	return state :: CooldownState
end

local function onRequest(player: Player, payload: any): ()
	local rateLimiter = deps.RateLimiter
	local validate = deps.Validate

	-- 1. Global throttle FIRST, before the payload is inspected at all.
	if not rateLimiter.Check(player, "Global") then
		warnStudio(`rejected {player.Name}: global throttle`)
		return
	end

	-- 2. Structural validation. The result is a table, so .ok must be read explicitly.
	local shape = validate.SkillRequest(payload)
	if not shape.ok then
		warnStudio(`rejected {player.Name}: {shape.reason or "malformed request"}`)
		return
	end

	-- 3. Skill throttle, after the payload is known well-formed.
	if not rateLimiter.Check(player, "Skill") then
		warnStudio(`rejected {player.Name}: skill throttle`)
		return
	end

	-- 4. Cast only after .ok. The skill id is the ONLY client field used from here on.
	local request = validate.AsSkillRequest(payload)
	local skillId = request.skillId

	-- Unknown skills are silently rejected. Everything below reads the skill's definition
	-- from Config.Skills, never from the request.
	local definition = SkillsConfig.DEFINITIONS[skillId]
	if not definition then
		warnStudio(`rejected {player.Name}: unknown skill id`)
		return
	end

	-- 5. Caster must be ready with a living current character. Not a gameplay rejection
	-- the client is told about (a dead player pressing a key is normal), so no feedback.
	local caster = getLiveCasterState(player)
	if not caster then
		log(`{player.Name} cannot use {skillId}: caster not ready or not alive`)
		return
	end

	-- 6. Cooldown, keyed to the character generation.
	local now = os.clock()
	local cooldown = getCooldownState(player, caster.generation)
	local readyAt = cooldown.readyAt[skillId]
	if readyAt ~= nil and now < readyAt then
		sendFeedback(player, skillId, false, "cooldown")
		return
	end

	-- 7. The target is whatever the SERVER says the player has selected.
	local targetId: string? = deps.TargetingService.GetCombatTargetId(player)
	if targetId == nil then
		sendFeedback(player, skillId, false, "no_target")
		return
	end

	-- 8. Damage. Every parameter is server-derived. CombatService revalidates all of it.
	local combatRequest: CombatTypes.ResolveSkillRequest = {
		attacker = player,
		skillId = skillId,
		targetId = targetId,
		params = { damage = Damage.Calculate(definition.damage.power) },
	}
	local called, result = pcall(deps.CombatService.ResolveSkill, combatRequest)
	if not called then
		-- An error is never treated as success: no feedback, no cooldown.
		warnStudio(`CombatService.ResolveSkill errored for {player.Name} ({skillId}): {tostring(result)}`)
		return
	end
	if type(result) ~= "table" then
		warnStudio(`CombatService.ResolveSkill returned a non-table for {player.Name} ({skillId})`)
		return
	end
	local combatResult = result :: CombatTypes.CombatResult

	-- 9. Success requires an explicit ok == true. Only then does the cooldown start.
	if combatResult.ok == true then
		cooldown.readyAt[skillId] = now + definition.cooldown
		sendFeedback(player, skillId, true, nil)
		return
	end

	-- 10. Rejected by CombatService: no damage was applied, so no cooldown is consumed.
	local reason = publicReasons[combatResult.reason or ""]
	if reason == nil then
		warnStudio(`{player.Name} {skillId} failed internally: {tostring(combatResult.reason)}`)
		return
	end
	sendFeedback(player, skillId, false, reason)
end

function SkillService.Init(injected: { [string]: any }): ()
	-- Fail fast at startup on a miswired dependency instead of silently rejecting
	-- every request later.
	requireMember(injected.Net, "Net", "OnServerRequest")
	requireMember(injected.Net, "Net", "FireClient")
	requireMember(injected.Validate, "Validate", "SkillRequest")
	requireMember(injected.Validate, "Validate", "AsSkillRequest")
	requireMember(injected.RateLimiter, "RateLimiter", "Check")
	requireMember(injected.PlayerService, "PlayerService", "IsReady")
	requireMember(injected.CharacterService, "CharacterService", "GetState")
	requireMember(injected.TargetingService, "TargetingService", "GetCombatTargetId")
	requireMember(injected.CombatService, "CombatService", "ResolveSkill")

	local reasons = injected.CombatService.Reasons
	assert(type(reasons) == "table", "SkillService missing dependency CombatService.Reasons")

	table.clear(publicReasons)
	publicReasons[reasons.InvalidTarget] = "invalid_target"
	publicReasons[reasons.OutOfRange] = "out_of_range"
	-- A target that took no damage (ForceField) or whose TakeDamage errored cannot be
	-- hit, which the player is told as an unusable target.
	publicReasons[reasons.DamageBlocked] = "invalid_target"
	publicReasons[reasons.DamageFailed] = "invalid_target"

	deps = injected
end

function SkillService.Start(): ()
	table.insert(connections, deps.Net.OnServerRequest(Constants.REMOTES.RequestUseSkill, onRequest))

	-- Cooldown state is per player; drop it when the player leaves.
	table.insert(connections, Players.PlayerRemoving:Connect(function(player: Player)
		cooldowns[player] = nil
	end))
end

function SkillService.Destroy(): ()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(cooldowns)
	table.clear(publicReasons)
	deps = {}
end

return SkillService
