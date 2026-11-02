--!strict
--[[
	RateLimiter (token bucket)
	--------------------------
	Each key (usually a Player) gets a bucket of `capacity` tokens that refills
	at `refillPerSecond`. A call is allowed if a token is available.

	Token bucket > fixed cooldown: it tolerates short legitimate bursts
	(double-click, lag spike) while capping sustained spam from exploit scripts.

	The clock is injectable so the module can be unit-tested outside Roblox.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type Bucket = { tokens: number, updated: number }

type RateLimiterData = {
	_capacity: number,
	_refillPerSecond: number,
	_clock: () -> number,
	_buckets: { [any]: Bucket },
}

export type RateLimiter = typeof(setmetatable({} :: RateLimiterData, RateLimiter))

function RateLimiter.new(capacity: number, refillPerSecond: number, clock: (() -> number)?): RateLimiter
	assert(capacity > 0, "capacity must be > 0")
	assert(refillPerSecond >= 0, "refillPerSecond must be >= 0")
	local self: RateLimiterData = {
		_capacity = capacity,
		_refillPerSecond = refillPerSecond,
		_clock = clock or os.clock,
		_buckets = {},
	}
	return setmetatable(self, RateLimiter)
end

--- Returns true if the call is allowed (and consumes `cost` tokens).
function RateLimiter.consume(self: RateLimiter, key: any, cost: number?): boolean
	local amount = cost or 1
	local now = self._clock()
	local bucket = self._buckets[key]
	if bucket == nil then
		bucket = { tokens = self._capacity, updated = now }
		self._buckets[key] = bucket
	else
		local elapsed = math.max(0, now - bucket.updated)
		bucket.tokens = math.min(self._capacity, bucket.tokens + elapsed * self._refillPerSecond)
		bucket.updated = now
	end
	if bucket.tokens >= amount then
		bucket.tokens -= amount
		return true
	end
	return false
end

--- Forget a key (call on PlayerRemoving to avoid leaking memory).
function RateLimiter.reset(self: RateLimiter, key: any)
	self._buckets[key] = nil
end

return RateLimiter
