--[[
	RemoteGuard
	-----------
	The single entry point for client -> server events. Every remote created
	through RemoteGuard gets, in this order:

	  1. exact-arity + per-argument validation (Validators)
	  2. per-player token-bucket rate limiting
	  3. a protected handler call (one bad request can't kill the listener)
	  4. violation tracking with decay, and an optional kick threshold

	The handler only ever receives arguments that already passed validation.
	It must STILL re-check game state (ownership, position, cooldowns): a
	well-typed request can still be an illegitimate one.

	Usage:
		RemoteGuard.on({
			name = "RequestPurchase",
			args = { V.keyOf(Catalog.ShopItems) },
			rateLimit = { capacity = 5, refillPerSecond = 1 },
			handler = function(player, itemId) ... end,
		})
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Validators = require(Shared.Validators)
local RateLimiter = require(Shared.RateLimiter)

type Check = Validators.Check

export type GuardOptions = {
	name: string,
	args: { Check },
	handler: (player: Player, ...any) -> (),
	rateLimit: { capacity: number, refillPerSecond: number }?,
	-- Violations above this score (with decay) kick the player. nil = never kick, log only.
	kickThreshold: number?,
}

local RemoteGuard = {}

-- Violation score decays by this much per second, so honest players who hit
-- a rate limit once during a lag spike are never kicked.
local VIOLATION_DECAY_PER_SECOND = 0.5
local DEFAULT_RATE_LIMIT = { capacity = 10, refillPerSecond = 5 }

local violations: { [Player]: { score: number, updated: number } } = {}
local limiters = {}

local function getRemotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

local function addViolation(player: Player, remoteName: string, reason: string, kickThreshold: number?)
	local now = os.clock()
	local entry = violations[player]
	if entry == nil then
		entry = { score = 0, updated = now }
		violations[player] = entry
	end
	entry.score = math.max(0, entry.score - (now - entry.updated) * VIOLATION_DECAY_PER_SECOND) + 1
	entry.updated = now

	-- Plug your logging/analytics here (webhook, AnalyticsService, etc.).
	warn(`[RemoteGuard] {player.Name} ({player.UserId}) -> {remoteName}: {reason} (score {string.format("%.1f", entry.score)})`)

	if kickThreshold ~= nil and entry.score >= kickThreshold then
		player:Kick("Unexpected network activity. Please rejoin.")
	end
end

--- Creates (or reuses) a RemoteEvent and attaches a guarded listener.
function RemoteGuard.on(options: GuardOptions): RemoteEvent
	assert(type(options.name) == "string", "RemoteGuard: name required")
	assert(type(options.handler) == "function", "RemoteGuard: handler required")

	local folder = getRemotesFolder()
	local remote = folder:FindFirstChild(options.name) :: RemoteEvent?
	if remote == nil then
		local created = Instance.new("RemoteEvent")
		created.Name = options.name
		created.Parent = folder
		remote = created
	end
	assert(remote ~= nil and remote:IsA("RemoteEvent"), `RemoteGuard: {options.name} is not a RemoteEvent`)

	local rate = options.rateLimit or DEFAULT_RATE_LIMIT
	local limiter = RateLimiter.new(rate.capacity, rate.refillPerSecond)
	table.insert(limiters, limiter)

	remote.OnServerEvent:Connect(function(player: Player, ...)
		-- Rate limit first: it is the cheapest check and stops flooding early.
		if not limiter:consume(player) then
			addViolation(player, options.name, "rate limited", options.kickThreshold)
			return
		end

		local args = table.pack(...)
		local ok, reason = Validators.arguments(options.args, args)
		if not ok then
			addViolation(player, options.name, `invalid payload: {reason}`, options.kickThreshold)
			return
		end

		local success, err = xpcall(options.handler, debug.traceback, player, table.unpack(args, 1, args.n))
		if not success then
			warn(`[RemoteGuard] handler error in {options.name}: {err}`)
		end
	end)

	return remote
end

--- Creates a server -> client RemoteEvent (no listener; clients only receive).
function RemoteGuard.outbound(name: string): RemoteEvent
	local folder = getRemotesFolder()
	local remote = folder:FindFirstChild(name) :: RemoteEvent?
	if remote == nil then
		local created = Instance.new("RemoteEvent")
		created.Name = name
		created.Parent = folder
		remote = created
	end
	return remote :: RemoteEvent
end

Players.PlayerRemoving:Connect(function(player)
	violations[player] = nil
	for _, limiter in limiters do
		limiter:reset(player)
	end
end)

return RemoteGuard
