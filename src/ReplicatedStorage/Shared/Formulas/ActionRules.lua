--!strict
-- Pure action-timing rules shared by the client (prediction) and the server (validation).
-- No Instances, no remotes, no clocks: callers pass `now`. The same state + input + time
-- always gives the same answer, so both sides agree on which action an input produces.
--
-- Phases (see GetPhase): "free" -> "committed" (before CancelTime) -> "recovery"
-- (CancelTime..Duration, chain/dodge allowed) -> back to "free". "dodge" while dodging.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFeel = require(ReplicatedStorage.Shared.Config.CombatFeel)

local ActionRules = {}

export type State = {
	current: string?, -- last accepted attack action (nil = none / reset by a dodge)
	startedAt: number,
	endsAt: number, -- startedAt + Duration
	cancelAt: number, -- startedAt + CancelTime
	comboUntil: number, -- endsAt + ComboWindow
	dodgeStartedAt: number,
	dodgeEndsAt: number,
	dodgeReadyAt: number,
}

function ActionRules.NewState(): State
	return {
		current = nil,
		startedAt = 0,
		endsAt = 0,
		cancelAt = 0,
		comboUntil = 0,
		dodgeStartedAt = 0,
		dodgeEndsAt = 0,
		dodgeReadyAt = 0,
	}
end

-- Clears the current action/dodge but keeps the dodge cooldown.
function ActionRules.Reset(state: State): ()
	state.current = nil
	state.startedAt = 0
	state.endsAt = 0
	state.cancelAt = 0
	state.comboUntil = 0
	state.dodgeEndsAt = 0
end

-- Effective speed multiplier of an action (global AttackSpeed x per-action Speed).
function ActionRules.ActionSpeed(def: CombatFeel.ActionDef): number
	local speed = CombatFeel.Combat.AttackSpeed * (def.Speed or 1)
	if speed < 0.05 then
		return 0.05
	end
	return speed
end

-- Decide what `input` ("Light" | "Heavy" | "Dodge") does at time `now`.
-- Returns (actionId, nil) when it may start ("Dodge" for a dodge), or (nil, reason).
-- `tolerance` widens every window (the server passes LatencyTolerance, the client 0).
function ActionRules.Evaluate(state: State, input: string, now: number, tolerance: number): (string?, string?)
	if input == "Dodge" then
		if now + tolerance < state.dodgeReadyAt then
			return nil, "cooldown"
		end
		if now + tolerance < state.dodgeEndsAt then
			return nil, "busy"
		end
		local current = state.current
		if current ~= nil and now < state.endsAt then
			local def = CombatFeel.Actions[current]
			local earliest = state.startedAt + (def.DodgeCancelTime or def.HitTime) / ActionRules.ActionSpeed(def)
			if now + tolerance < earliest then
				return nil, "committed"
			end
		end
		return "Dodge", nil
	end

	local startId = CombatFeel.Start[input]
	if startId == nil then
		return nil, "unknown_input"
	end

	-- Attacking out of a dodge is only allowed once AttackCancelTime has passed.
	if now < state.dodgeEndsAt and now + tolerance < state.dodgeStartedAt + CombatFeel.Dodge.AttackCancelTime then
		return nil, "dodging"
	end

	local current = state.current
	if current ~= nil then
		local def = CombatFeel.Actions[current]
		if now < state.endsAt then
			-- Mid-action: only chainable once the cancel window is open.
			if now + tolerance < state.cancelAt then
				return nil, "committed"
			end
			local chained = def.Next[input]
			if chained == nil then
				return nil, "no_chain" -- wait for the action to finish, then it starts fresh
			end
			return chained, nil
		end
		if now <= state.comboUntil + tolerance then
			return def.Next[input] or startId, nil -- still inside the combo window
		end
	end
	return startId, nil
end

-- Record that `actionId` (an attack id or "Dodge") started at `now`.
function ActionRules.Begin(state: State, actionId: string, now: number): ()
	if actionId == "Dodge" then
		local dodge = CombatFeel.Dodge
		state.current = nil
		state.startedAt = now
		state.endsAt = 0
		state.cancelAt = 0
		state.comboUntil = 0
		state.dodgeStartedAt = now
		state.dodgeEndsAt = now + dodge.Duration
		state.dodgeReadyAt = now + dodge.Cooldown
		return
	end

	local def = CombatFeel.Actions[actionId]
	local speed = ActionRules.ActionSpeed(def)
	state.current = actionId
	state.startedAt = now
	state.endsAt = now + def.Duration / speed
	state.cancelAt = now + def.CancelTime / speed
	state.comboUntil = state.endsAt + def.ComboWindow / speed
	state.dodgeEndsAt = 0 -- attacking cancels whatever is left of a dodge
end

function ActionRules.GetPhase(state: State, now: number): string
	if now < state.dodgeEndsAt then
		return "dodge"
	end
	if state.current ~= nil and now < state.endsAt then
		if now < state.cancelAt then
			return "committed"
		end
		return "recovery"
	end
	return "free"
end

-- Warn (never error) about config mistakes so a typo doesn't brick the sandbox.
local function validateConfig(): ()
	for id, def in CombatFeel.Actions do
		if id == "Dodge" then
			warn("[CombatFeel] 'Dodge' is a reserved action id")
		end
		for input, nextId in def.Next do
			if CombatFeel.Actions[nextId] == nil then
				warn(`[CombatFeel] {id}.Next.{input} points at unknown action '{nextId}'`)
			end
		end
		if def.HitTime > def.Duration then
			warn(`[CombatFeel] {id}: HitTime is after Duration`)
		end
		if def.CancelTime > def.Duration then
			warn(`[CombatFeel] {id}: CancelTime is after Duration`)
		end
	end
	for input, id in CombatFeel.Start do
		if CombatFeel.Actions[id] == nil then
			warn(`[CombatFeel] Start.{input} points at unknown action '{id}'`)
		end
	end
end

validateConfig()

return ActionRules
