--!strict
-- Pure Mana arithmetic helpers. Values in, values out.
-- No Instances, services, remotes, player data, or mutable state, so this can be tested
-- in isolation. RuntimeStatsService owns the state; this module only validates and clamps.

local Mana = {}

local function isFiniteNumber(value: any): boolean
	if type(value) ~= "number" then
		return false
	end

	-- NaN is the only value that does not equal itself.
	if value ~= value then
		return false
	end

	return value ~= math.huge and value ~= -math.huge
end

-- True for a finite number strictly above zero. Rejects zero (including -0), negatives,
-- NaN, +/-infinity, and non-numbers.
function Mana.IsValidAmount(value: any): boolean
	return isFiniteNumber(value) and value > 0
end

-- True for a valid amount that is also at most `limit`. The limit is passed in (it lives
-- in Config/Stats) so this module needs no requires.
function Mana.IsValidMax(value: any, limit: number): boolean
	if not Mana.IsValidAmount(value) then
		return false
	end

	if type(limit) ~= "number" or limit ~= limit then
		return false
	end

	return value <= limit
end

-- Clamps `current` into [0, max]. Total over numbers: a NaN `current`, or a NaN or
-- non-positive `max`, yields 0, so a bad input can never produce a bad result.
function Mana.Clamp(current: number, max: number): number
	if max ~= max or max <= 0 then
		return 0
	end

	if current ~= current or current <= 0 then
		return 0
	end

	if current >= max then
		return max
	end

	return current
end

return Mana
