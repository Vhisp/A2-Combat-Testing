--!strict
-- Pure damage formula. Number in, number out.
-- No Instances, services, remotes, player data, or mutable state: the same input
-- always produces the same output, so this can be tested in isolation.
--
-- Currently uses base skill power only. Attack power, critical hits, and
-- mitigation are added when those systems exist.

local Damage = {}

-- Returns a nonnegative integer.
-- Fractional power is floored. Anything that is not a usable positive finite
-- number (negative, zero, NaN, +/-infinity, or a non-number) yields 0.
function Damage.Calculate(power: number): number
	if type(power) ~= "number" then
		return 0
	end

	-- NaN is the only value that does not equal itself.
	if power ~= power then
		return 0
	end

	-- Rejects negatives, zero (including -0), and -infinity.
	if power <= 0 then
		return 0
	end

	-- Rejects +infinity.
	if power == math.huge then
		return 0
	end

	return math.floor(power)
end

return Damage
