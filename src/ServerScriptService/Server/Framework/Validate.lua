--!strict
-- Server-only payload validation. Pure functions, no networking, no side effects.
-- Every rejection returns the SAME generic reason; detail goes to the server log only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local NetTypes = require(ReplicatedStorage.Shared.Types.Net)
local SkillTypes = require(ReplicatedStorage.Shared.Types.Skills)

local Validate = {}

export type Result = {
	ok: boolean,
	reason: string?, -- internal detail, never sent to the client
}

local function reject(detail: string): Result
	return { ok = false, reason = detail }
end

local function isFinitePositive(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value > 0
end

-- Structural check only. Runs BEFORE the detailed per-action validation.
function Validate.RequestShape(payload: any): Result
	if type(payload) ~= "table" then
		return reject("payload is not a table")
	end
	if type(payload.protocol) ~= "number" then
		return reject("protocol is not a number")
	end
	if payload.protocol ~= Constants.PROTOCOL_VERSION then
		return reject(`protocol mismatch: got {payload.protocol}, expected {Constants.PROTOCOL_VERSION}`)
	end
	if type(payload.action) ~= "string" then
		return reject("action is not a string")
	end
	return { ok = true }
end

-- Action-specific checks. Only valid for the "echo" and "time" diagnostics actions.
function Validate.DiagnosticsRequest(payload: any): Result
	local action = payload.action :: string
	if action ~= "echo" and action ~= "time" then
		return reject(`unknown action '{action}'`)
	end

	if payload.text ~= nil then
		if type(payload.text) ~= "string" then
			return reject("text is not a string")
		end
		if #payload.text > Constants.MAX_DIAGNOSTIC_TEXT_LENGTH then
			return reject(`text exceeds {Constants.MAX_DIAGNOSTIC_TEXT_LENGTH} characters`)
		end
		if string.find(payload.text, "%c") then
			return reject("text contains control characters")
		end
	end

	if not isFinitePositive(payload.clientTime) then
		return reject("clientTime is not a finite positive number")
	end

	return { ok = true }
end

-- Cast a fully validated payload to its typed form.
function Validate.AsDiagnosticsRequest(payload: any): NetTypes.DiagnosticsRequest
	return payload :: NetTypes.DiagnosticsRequest
end

-- Complete structural validation of a skill-use request: { protocol, skillId }.
-- Self-contained on purpose. Skill payloads carry no `action` field, so
-- Validate.RequestShape does not apply, and the table and protocol checks happen
-- here before any field is read. Never throws on malformed input.
-- Extra fields are ignored, matching the existing validators; the server never
-- reads them. Whether the skill exists is SkillService's decision, not this
-- validator's. Callers must check `.ok` on the returned table.
function Validate.SkillRequest(payload: any): Result
	if type(payload) ~= "table" then
		return reject("payload is not a table")
	end
	if type(payload.protocol) ~= "number" then
		return reject("protocol is not a number")
	end
	if payload.protocol ~= Constants.PROTOCOL_VERSION then
		return reject(`protocol mismatch: got {payload.protocol}, expected {Constants.PROTOCOL_VERSION}`)
	end

	local skillId = payload.skillId
	if type(skillId) ~= "string" then
		return reject("skillId is not a string")
	end
	if skillId == "" then
		return reject("skillId is empty")
	end
	if #skillId > Constants.MAX_SKILL_ID_LENGTH then
		return reject(`skillId exceeds {Constants.MAX_SKILL_ID_LENGTH} bytes`)
	end

	return { ok = true }
end

-- Cast a fully validated payload to its typed form.
-- Call ONLY after Validate.SkillRequest returned ok = true. Like
-- AsDiagnosticsRequest this is a bare cast: it does not re-validate.
function Validate.AsSkillRequest(payload: any): SkillTypes.RequestUseSkill
	return payload :: SkillTypes.RequestUseSkill
end

return Validate
