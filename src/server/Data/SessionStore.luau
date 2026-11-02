--[[
	SessionStore
	------------
	Session-locked player data on top of DataStoreService.

	Why session locking: when a player hops servers quickly, server A may still
	be saving while server B already loaded the OLD data. B then saves on top,
	and depending on timing you get rolled-back progress or duplicated items.
	This is the #1 source of "dupe" exploits on Roblox.

	How it works:
	  * Every record stores a lock: { jobId, session, time }.
	  * Load = UpdateAsync that only succeeds if there is no lock, the lock is
	    ours, or the lock is stale (owner server crashed).
	  * Every save is an UpdateAsync that first checks we STILL own the lock.
	    If we don't, we stop writing and kick the player instead of
	    overwriting fresher data.
	  * Release (on leave / shutdown) clears the lock in the same write as the
	    final save, so the next server can load immediately.

	Record layout in the DataStore:
		{
			data = { ...player data... },
			version = <schema version>,
			lock = { jobId = string, session = string, time = number } | nil,
			meta = { created = number, updated = number, saves = number },
		}
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

export type Session = {
	Player: Player,
	Key: string,
	SessionId: string,
	Data: any,
	Released: boolean,
	SaveAsync: (self: Session) -> boolean,
	ReleaseAsync: (self: Session) -> boolean,
}

export type StoreOptions = {
	name: string, -- DataStore name. Bump it (e.g. _v2) only for a full wipe.
	template: { [string]: any },
	schemaVersion: number?,
	-- migrations[n] upgrades data from version n-1 to n.
	migrations: { [number]: (data: any) -> any }?,
	autosaveInterval: number?, -- seconds, default 90
	staleLockAfter: number?, -- seconds, default 600 (must be >> autosaveInterval)
	loadAttempts: number?, -- default 6
	onLoaded: ((session: Session) -> ())?,
}

local SessionStore = {}
SessionStore.__index = SessionStore

local SessionMethods = {}
SessionMethods.__index = SessionMethods

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[deepCopy(k)] = deepCopy(v)
	end
	return copy
end

-- Fill keys that exist in the template but not in the data (shallow per level).
local function reconcile(data: { [any]: any }, template: { [any]: any })
	for key, defaultValue in template do
		if data[key] == nil then
			data[key] = deepCopy(defaultValue)
		elseif type(data[key]) == "table" and type(defaultValue) == "table" and next(defaultValue) ~= nil then
			-- Recurse only into dictionary-like defaults (skip empty arrays).
			reconcile(data[key], defaultValue)
		end
	end
end

function SessionStore.new(options: StoreOptions)
	local self = setmetatable({}, SessionStore)
	self._options = options
	self._store = DataStoreService:GetDataStore(options.name)
	self._schemaVersion = options.schemaVersion or 1
	self._migrations = options.migrations or {}
	self._autosaveInterval = options.autosaveInterval or 90
	self._staleLockAfter = options.staleLockAfter or 600
	self._loadAttempts = options.loadAttempts or 6
	self._sessions = {} :: { [Player]: Session }
	self._activeKeys = {} :: { [string]: boolean } -- keys this server currently holds
	self._shuttingDown = false
	assert(self._staleLockAfter > self._autosaveInterval * 3, "staleLockAfter must be well above autosaveInterval")
	return self
end

function SessionStore:Get(player: Player): Session?
	return self._sessions[player]
end

function SessionStore:_keyFor(player: Player): string
	return `Player_{player.UserId}`
end

function SessionStore:_migrate(record: any)
	local version = record.version or 1
	while version < self._schemaVersion do
		local migration = self._migrations[version + 1]
		if migration then
			record.data = migration(record.data)
		end
		version += 1
	end
	record.version = self._schemaVersion
end

-- Returns a Session, or nil if the data could not be safely acquired.
function SessionStore:LoadAsync(player: Player): Session?
	local key = self:_keyFor(player)
	local sessionId = HttpService:GenerateGUID(false)

	for attempt = 1, self._loadAttempts do
		if player.Parent == nil then
			return nil -- player left while we were waiting
		end

		-- Same server still releasing a previous session for this player (fast rejoin).
		if self._activeKeys[key] then
			task.wait(2)
			continue
		end

		local acquired = false
		local loadedRecord = nil
		local ok, err = pcall(function()
			self._store:UpdateAsync(key, function(old)
				-- The transform may run several times: always reset outputs.
				acquired = false
				loadedRecord = nil
				local now = os.time()
				local record = old
				if record == nil then
					record = {
						data = deepCopy(self._options.template),
						version = self._schemaVersion,
						lock = nil,
						meta = { created = now, updated = now, saves = 0 },
					}
				end

				local lock = record.lock
				if lock ~= nil then
					local isStale = (now - (lock.time or 0)) >= self._staleLockAfter
					-- A lock from THIS server with no active session is an orphan
					-- (e.g. a release write that failed): safe to take over.
					local isOrphanFromThisServer = lock.jobId == game.JobId and not self._activeKeys[key]
					if not isStale and not isOrphanFromThisServer then
						return nil -- locked by another live server: cancel the write
					end
				end

				record.lock = { jobId = game.JobId, session = sessionId, time = now }
				record.meta = record.meta or { created = now, updated = now, saves = 0 }
				acquired = true
				loadedRecord = record
				return record
			end)
		end)

		if ok and acquired and loadedRecord ~= nil then
			self:_migrate(loadedRecord)
			reconcile(loadedRecord.data, self._options.template)

			local session = setmetatable({
				Player = player,
				Key = key,
				SessionId = sessionId,
				Data = loadedRecord.data,
				Released = false,
				_store = self,
			}, SessionMethods)

			if player.Parent == nil then
				-- Left during the load: give the lock back immediately.
				self._activeKeys[key] = true
				session:ReleaseAsync()
				return nil
			end

			self._activeKeys[key] = true
			self._sessions[player] = session :: any
			return session :: any
		end

		if not ok then
			warn(`[SessionStore] load error for {key} (attempt {attempt}): {err}`)
		end
		-- Locked elsewhere or DataStore error: back off and retry.
		task.wait(math.min(2 ^ attempt, 15))
	end

	return nil
end

-- Writes the session's data, keeping (or releasing) the lock.
-- Returns false if the write failed OR if the lock was lost.
function SessionMethods:_write(release: boolean): boolean
	if self.Released or (self._releasing and not release) then
		return false
	end
	local store = self._store
	local snapshot = deepCopy(self.Data)
	local stillOwned = true

	local ok, err = pcall(function()
		store._store:UpdateAsync(self.Key, function(old)
			stillOwned = true
			if old == nil or old.lock == nil or old.lock.session ~= self.SessionId then
				stillOwned = false
				return nil -- someone else owns this record now: never overwrite
			end
			local now = os.time()
			old.data = snapshot
			old.version = store._schemaVersion
			old.meta = old.meta or {}
			old.meta.updated = now
			old.meta.saves = (old.meta.saves or 0) + 1
			if release then
				old.lock = nil
			else
				old.lock.time = now -- heartbeat: proves this server is alive
			end
			return old
		end)
	end)

	if not ok then
		warn(`[SessionStore] save error for {self.Key}: {err}`)
		return false
	end

	if not stillOwned then
		-- Another server took the record (we were considered dead). Stop
		-- writing to avoid rolling back fresher data, and remove the player.
		warn(`[SessionStore] lock lost for {self.Key}, ending session`)
		self:_end()
		if self.Player.Parent ~= nil then
			self.Player:Kick("Your data was loaded on another server. Please rejoin.")
		end
		return false
	end

	if release then
		self:_end()
	end
	return true
end

function SessionMethods:_end()
	if self.Released then
		return
	end
	self.Released = true
	local store = self._store
	store._activeKeys[self.Key] = nil
	if store._sessions[self.Player] == self then
		store._sessions[self.Player] = nil
	end
end

function SessionMethods:SaveAsync(): boolean
	return self:_write(false)
end

function SessionMethods:ReleaseAsync(): boolean
	-- PlayerRemoving and BindToClose can both fire for the same player on shutdown.
	if self._releasing or self.Released then
		return false
	end
	self._releasing = true
	for attempt = 1, 3 do
		if self:_write(true) then
			return true
		end
		if self.Released then
			return false -- lock was lost: nothing more to do
		end
		task.wait(attempt)
	end
	-- Final save failed: free the key locally. The DataStore lock will expire
	-- (staleLockAfter) or be taken over by this server as an orphan.
	self:_end()
	return false
end

function SessionStore:_onPlayerAdded(player: Player)
	local session = self:LoadAsync(player)
	if session == nil then
		if player.Parent ~= nil then
			player:Kick("Could not load your data safely. Please rejoin in a minute.")
		end
		return
	end
	if self._options.onLoaded then
		task.spawn(self._options.onLoaded, session)
	end
end

function SessionStore:Start()
	Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(self._onPlayerAdded, self, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local session = self._sessions[player]
		if session then
			session:ReleaseAsync()
		end
	end)

	-- Autosave: staggered so we don't burst the DataStore budget.
	task.spawn(function()
		while not self._shuttingDown do
			task.wait(self._autosaveInterval)
			local list = {}
			for _, session in self._sessions do
				table.insert(list, session)
			end
			local spacing = #list > 0 and math.min(1, self._autosaveInterval / (#list * 2)) or 0
			for _, session in list do
				if self._shuttingDown then
					break
				end
				if not session.Released then
					task.spawn(session.SaveAsync, session)
				end
				task.wait(spacing)
			end
		end
	end)

	-- Shutdown: release everyone in parallel (BindToClose has a ~30 s budget).
	game:BindToClose(function()
		self._shuttingDown = true
		local pending = 0
		for _, session in self._sessions do
			pending += 1
			task.spawn(function()
				session:ReleaseAsync()
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.25)
		end
	end)
end

return SessionStore
