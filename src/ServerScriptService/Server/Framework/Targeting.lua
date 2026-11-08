--!strict
-- Pure targeting helpers. No networking, no state, no side effects.
-- Directly testable, mirroring Framework.Validate and Framework.RateLimiter.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local TargetingConfig = require(ReplicatedStorage.Shared.Config.Targeting)

local Targeting = {}

export type Candidate = {
	instance: Model,
	position: Vector3,
	distance: number,
}

-- Best-effort authoritative position of a target, or nil when it has none.
function Targeting.getPosition(instance: Instance): Vector3?
	if instance:IsA("Model") then
		local root = instance:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root.Position
		end
		local primary = instance.PrimaryPart
		if primary then
			return primary.Position
		end
		local ok, pivot = pcall(function()
			return instance:GetPivot().Position
		end)
		if ok then
			return pivot
		end
		return nil
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	return nil
end

-- True when the instance carries BOTH tags. Ambiguous targets are rejected
-- so combat vs interaction is never a coin toss.
function Targeting.isDualTagged(instance: Instance): boolean
	local hasCombat = CollectionService:HasTag(instance, TargetingConfig.TAG_COMBAT)
	local hasInteract = CollectionService:HasTag(instance, TargetingConfig.TAG_INTERACTABLE)
	return hasCombat and hasInteract
end

-- Structural eligibility that does NOT depend on distance or the requesting player.
-- Ranges are checked by the service, which knows the player's position.
function Targeting.isCombatEligible(instance: Instance): boolean
	if not instance:IsA("Model") then
		return false
	end
	if not CollectionService:HasTag(instance, TargetingConfig.TAG_COMBAT) then
		return false
	end
	if Targeting.isDualTagged(instance) then
		return false
	end
	if instance.Parent == nil then
		return false
	end
	local humanoid = instance:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end
	if humanoid.Health <= 0 then
		return false
	end
	return Targeting.getPosition(instance) ~= nil
end

-- Interactables do NOT require a Humanoid or health; they must be a Model,
-- tagged, parented, unambiguous, and have a resolvable position.
function Targeting.isInteractEligible(instance: Instance): boolean
	if not instance:IsA("Model") then
		return false
	end
	if not CollectionService:HasTag(instance, TargetingConfig.TAG_INTERACTABLE) then
		return false
	end
	if Targeting.isDualTagged(instance) then
		return false
	end
	if instance.Parent == nil then
		return false
	end
	return Targeting.getPosition(instance) ~= nil
end

function Targeting.distanceBetween(a: Vector3, b: Vector3): number
	return (a - b).Magnitude
end

-- Build the sorted, distance-ascending candidate list for one player.
-- Ties break on full name ascending so cycling is deterministic and never jitters.
function Targeting.buildCandidates(
	registry: { [Model]: string },
	origin: Vector3,
	maxRange: number
): { Candidate }
	local candidates: { Candidate } = {}
	for instance in registry do
		if Targeting.isCombatEligible(instance) then
			local position = Targeting.getPosition(instance)
			if position then
				local distance = Targeting.distanceBetween(origin, position)
				if distance <= maxRange then
					table.insert(candidates, {
						instance = instance,
						position = position,
						distance = distance,
					})
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		if math.abs(a.distance - b.distance) > 0.01 then
			return a.distance < b.distance
		end
		return a.instance:GetFullName() < b.instance:GetFullName()
	end)

	return candidates
end

return Targeting
