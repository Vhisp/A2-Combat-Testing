--!strict
-- Runtime combat stats. Phase 4: Mana only. Server-authoritative; no remotes.
-- Owns one Mana pool per player per character generation. Does NOT own health:
-- Humanoid.Health stays authoritative, and this service never reads, mirrors, or writes
-- health, MaxHealth, or any Humanoid.
--
-- LIFECYCLE (lazy, validated against CharacterService.GetState(player).generation):
--   * State is created lazily, on first access within a character generation, and ONLY
--     while that generation is ready. A generation that dies before its first access is
--     never initialized. It is NOT created at the CharacterAdded event.
--   * An existing state for the CURRENT generation may be read while the character is
--     dead or not ready, but every mutation is rejected unless the character is ready.
--   * Revisit explicit spawn-time initialization (a CharacterService hook) when class
--     modifiers or other spawn-dependent behaviour must react to spawn.
--   * A state from an earlier generation is discarded, never reused. Callers that hold a
--     generation may pass it as expectedGeneration so a delayed operation from an earlier
--     character is rejected (stale_generation) instead of touching the new one.
--
-- Reaches other services only through injected deps (never by requiring them).
-- Rejection reasons are INTERNAL (see RuntimeStatsService.Reasons). They are never sent to
-- clients from here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local StatsConfig = require(ReplicatedStorage.Shared.Config.Stats)
local StatsTypes = require(ReplicatedStorage.Shared.Types.Stats)
local ManaMath = require(ReplicatedStorage.Shared.Formulas.Mana)

local IS_STUDIO = RunService:IsStudio()

local RuntimeStatsService = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

-- Mana for ONE character generation. When the generation changes (respawn), the old
-- state is discarded on next access, so a new character never inherits a previous pool.
type ManaState = {
	generation: number,
	current: number,
	max: number,
}
local manaStates: { [Player]: ManaState } = {}

-- Internal rejection reasons. Never sent to clients from here.
local Reasons = table.freeze({
	InvalidPlayer = "invalid_player", -- argument is not a Player
	NoCharacter = "no_character", -- CharacterService has no state for the player
	NotReady = "not_ready", -- character is dead or not ready; mutations are rejected
	StaleGeneration = "stale_generation", -- expectedGeneration is not the current generation
	InvalidAmount = "invalid_amount", -- not a finite number above zero
	InvalidMax = "invalid_max", -- not a finite number above zero and within the ceiling
	InsufficientMana = "insufficient_mana", -- consume would take Mana below zero
})
RuntimeStatsService.Reasons = Reasons

local function log(...: any): ()
	if IS_STUDIO then
		print("[RuntimeStatsService]", ...)
	end
end

local function requireMember(container: any, dependency: string, member: string): ()
	assert(
		type(container) == "table" and type(container[member]) == "function",
		`RuntimeStatsService missing dependency {dependency}.{member}`
	)
end

local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Player")
end

-- Copies only: callers never receive the live internal state.
local function snapshot(state: ManaState): StatsTypes.ManaSnapshot
	return {
		generation = state.generation,
		current = state.current,
		max = state.max,
	}
end

local function reject(reason: string, state: ManaState?): StatsTypes.ManaResult
	return {
		ok = false,
		reason = reason,
		generation = if state then state.generation else nil,
		current = if state then state.current else nil,
		max = if state then state.max else nil,
		applied = 0,
	}
end

local function succeed(state: ManaState, applied: number): StatsTypes.ManaResult
	return {
		ok = true,
		reason = nil,
		generation = state.generation,
		current = state.current,
		max = state.max,
		applied = applied,
	}
end

-- CharacterService state for the player's CURRENT character, or nil. Also normalizes our
-- own storage: no character means no Mana state, and a state from an earlier generation
-- is discarded. Never creates state.
local function currentCharacterState(player: Player): any
	local characterState = deps.CharacterService.GetState(player)
	if characterState == nil then
		manaStates[player] = nil
		return nil
	end

	local state = manaStates[player]
	if state ~= nil and state.generation ~= characterState.generation then
		manaStates[player] = nil
	end

	return characterState
end

-- The ONLY place Mana state is created. Returns the current generation's state, creating
-- it (full Mana, once) only if none exists AND the character is ready. Returns nil when
-- there is no state and the character is not ready: nothing is created.
local function ensureState(player: Player, generation: number): ManaState?
	local existing = manaStates[player]
	if existing ~= nil then
		return existing
	end

	if not deps.PlayerService.IsReady(player) then
		return nil
	end

	local state: ManaState = {
		generation = generation,
		current = StatsConfig.BASE_MAX_MANA,
		max = StatsConfig.BASE_MAX_MANA,
	}
	manaStates[player] = state
	log(`initialized mana for {player.Name} (generation {generation}): {state.current}/{state.max}`)
	return state
end

-- Lifecycle gates shared by every mutation, in this order:
--   1. invalid_player   2. no_character   3. stale_generation   4. not_ready
--   5. create the state if this is the first access while ready.
-- Creation depends only on lifecycle, never on the amount or max being applied, so a call
-- rejected later for a bad value on a ready, uninitialized generation still creates it.
-- Returns the state on success. On rejection returns the existing state (or nil) for
-- reporting, plus the reason.
local function prepareMutation(player: any, expectedGeneration: any): (ManaState?, string?)
	if not isPlayer(player) then
		return nil, Reasons.InvalidPlayer
	end

	local characterState = currentCharacterState(player)
	if characterState == nil then
		return nil, Reasons.NoCharacter
	end

	-- Checked before any creation, so a stale call can never initialize a new generation.
	if expectedGeneration ~= nil and expectedGeneration ~= characterState.generation then
		return manaStates[player], Reasons.StaleGeneration
	end

	if not deps.PlayerService.IsReady(player) then
		return manaStates[player], Reasons.NotReady
	end

	local state = ensureState(player, characterState.generation)
	if state == nil then
		return nil, Reasons.NotReady
	end
	return state, nil
end

-- A copy of the player's Mana for the CURRENT generation, or nil.
-- May read an existing state while the character is dead or not ready. If the current
-- generation has no state yet, creates it (full, once) only when the character is ready;
-- otherwise returns nil and creates nothing. Returns nil when there is no character.
function RuntimeStatsService.GetMana(player: any): StatsTypes.ManaSnapshot?
	if not isPlayer(player) then
		return nil
	end

	local characterState = currentCharacterState(player)
	if characterState == nil then
		return nil
	end

	local state = ensureState(player, characterState.generation)
	if state == nil then
		return nil
	end
	return snapshot(state)
end

-- All-or-nothing: never partially spends and never takes Mana below zero.
function RuntimeStatsService.ConsumeMana(player: any, amount: any, expectedGeneration: any): StatsTypes.ManaResult
	local state, reason = prepareMutation(player, expectedGeneration)
	if reason ~= nil or state == nil then
		return reject(reason or Reasons.NotReady, state)
	end

	if not ManaMath.IsValidAmount(amount) then
		return reject(Reasons.InvalidAmount, state)
	end
	local cost = amount :: number

	if cost > state.current then
		return reject(Reasons.InsufficientMana, state)
	end

	state.current = ManaMath.Clamp(state.current - cost, state.max)
	return succeed(state, cost)
end

-- Clamped to maximum Mana. `applied` reports what was actually restored (0 when already full).
function RuntimeStatsService.RestoreMana(player: any, amount: any, expectedGeneration: any): StatsTypes.ManaResult
	local state, reason = prepareMutation(player, expectedGeneration)
	if reason ~= nil or state == nil then
		return reject(reason or Reasons.NotReady, state)
	end

	if not ManaMath.IsValidAmount(amount) then
		return reject(Reasons.InvalidAmount, state)
	end
	local requested = amount :: number

	local missing = state.max - state.current
	if requested >= missing then
		-- Exactly full, with no floating point drift from adding back the difference.
		state.current = state.max
		return succeed(state, missing)
	end

	state.current = state.current + requested
	return succeed(state, requested)
end

-- Changes maximum Mana. Current Mana is clamped DOWN to a lower maximum and never refilled
-- by a higher one.
function RuntimeStatsService.SetMaxMana(player: any, newMax: any, expectedGeneration: any): StatsTypes.ManaResult
	local state, reason = prepareMutation(player, expectedGeneration)
	if reason ~= nil or state == nil then
		return reject(reason or Reasons.NotReady, state)
	end

	if not ManaMath.IsValidMax(newMax, StatsConfig.MAX_MANA_LIMIT) then
		return reject(Reasons.InvalidMax, state)
	end
	local maximum = newMax :: number

	state.max = maximum
	state.current = ManaMath.Clamp(state.current, maximum)
	return succeed(state, 0)
end

function RuntimeStatsService.Init(injected: { [string]: any }): ()
	-- Fail fast at startup on a miswired dependency instead of failing every call later.
	requireMember(injected.PlayerService, "PlayerService", "IsReady")
	requireMember(injected.CharacterService, "CharacterService", "GetState")

	deps = injected
end

function RuntimeStatsService.Start(): ()
	-- Mana state is per player; drop it when the player leaves.
	table.insert(
		connections,
		Players.PlayerRemoving:Connect(function(player: Player)
			manaStates[player] = nil
		end)
	)
end

function RuntimeStatsService.Destroy(): ()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(manaStates)
	deps = {}
end

return RuntimeStatsService
