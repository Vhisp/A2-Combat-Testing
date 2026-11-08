--!strict
-- Server-only, per-player token-bucket rate limiter.
-- The SINGLE enforcement point. Net never rate limits.
-- Buckets are declared in Constants.RATE_LIMITS; nothing else defines limits.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Config.Constants)

local RateLimiter = {}

type Bucket = {
	tokens: number,
	lastRefill: number,
}

local bucketsByPlayer: { [Player]: { [string]: Bucket } } = {}

local function getBucket(player: Player, bucketName: string): Bucket?
	local perPlayer = bucketsByPlayer[player]
	if not perPlayer then
		return nil
	end
	return perPlayer[bucketName]
end

local function createBucket(bucketName: string): Bucket?
	local config = Constants.RATE_LIMITS[bucketName]
	if not config then
		return nil
	end
	return {
		tokens = config.MaxRequests,
		lastRefill = os.clock(),
	}
end

-- Returns true when the request is allowed. Consumes one token on success.
function RateLimiter.Check(player: Player, bucketName: string, cost: number?): boolean
	local config = Constants.RATE_LIMITS[bucketName]
	if not config then
		-- Unknown bucket: fail closed rather than silently allowing.
		warn(`RateLimiter: unknown bucket '{bucketName}'`)
		return false
	end

	local spend = cost or 1
	local now = os.clock()

	local perPlayer = bucketsByPlayer[player]
	if not perPlayer then
		perPlayer = {}
		bucketsByPlayer[player] = perPlayer
	end

	local bucket = perPlayer[bucketName]
	if not bucket then
		bucket = createBucket(bucketName) :: Bucket
		perPlayer[bucketName] = bucket
	end

	-- Refill proportionally to elapsed time, capped at the bucket maximum.
	local elapsed = now - bucket.lastRefill
	if elapsed > 0 then
		local refillRate = config.MaxRequests / config.WindowSeconds
		bucket.tokens = math.min(config.MaxRequests, bucket.tokens + elapsed * refillRate)
		bucket.lastRefill = now
	end

	if bucket.tokens < spend then
		return false
	end

	bucket.tokens -= spend
	return true
end

-- Called by PlayerService on join so the first request is never penalised.
function RateLimiter.Reset(player: Player): ()
	bucketsByPlayer[player] = {}
end

-- Called by PlayerService on leave. Mandatory, or player keys leak forever.
function RateLimiter.Clear(player: Player): ()
	bucketsByPlayer[player] = nil
end

return RateLimiter
