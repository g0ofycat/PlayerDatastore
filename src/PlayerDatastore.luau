--!strict

local PlayerDatastore = {}

PlayerDatastore.PlayerData = {} :: { [number]: { [any]: any } }
PlayerDatastore.ShardData = {} :: { [string]: { [any]: any } }
PlayerDatastore.GlobalData = {} :: { [string]: any }

PlayerDatastore.SessionLockHeartbeats = {} :: { [number]: boolean }
PlayerDatastore.SessionLockLost = {} :: { [number]: boolean }
PlayerDatastore.PendingShardRemovals = {} :: { [number | string]: { [string]: boolean? } }

PlayerDatastore.WriteQueues = {} :: { [number]: { thread } }
PlayerDatastore.LoadingQueues = {} :: { [number]: { thread } }

PlayerDatastore.LoadingPlayers = {} :: { [number]: boolean }

PlayerDatastore.DirtyData = {} :: { [number | string]: boolean }

PlayerDatastore.CurrentVersion = "v.1.0.0" -- // Used to track metadata version and migrations

PlayerDatastore._initialized = false

PlayerDatastore._globalDataWaiters = {} :: { thread }

--=========================
-- // SERVICES
--=========================

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")

--=========================
-- // MODULES
--=========================

local Config = require("./Utility/Config")

--=========================
-- // TYPES
--=========================

local Types = require("./Utility/Types")

PlayerDatastore.MetaData = {} :: { [number | string]: Types.MetaData }
PlayerDatastore.Migrations = {} :: { [string]: { To: string, Fn: Types.MigrationFunction } }
PlayerDatastore.StoredGlobalVersions = {} :: { [string]: number }

PlayerDatastore.Presets = nil :: Types.PresetOptions?

--=========================
-- // DATASTORE
--=========================

local PlayerDataStore = DataStoreService:GetDataStore(Config.DATASTORE.DATASTORE_NAME)
local ShardedDataStore = DataStoreService:GetDataStore(Config.DATASTORE.SHARDED_DATASTORE_NAME)
local GlobalDataStore = DataStoreService:GetDataStore(Config.DATASTORE.GLOBAL_DATASTORE_NAME)
local PlayerMetaDataStore = DataStoreService:GetDataStore(Config.DATASTORE.PLAYER_METADATA_STORE_NAME)
local SnapshotDataStore = DataStoreService:GetDataStore(Config.DATASTORE.SNAPSHOT_DATASTORE_NAME)
local SessionLockStore = DataStoreService:GetDataStore(Config.DATASTORE.LOCK_DATASTORE_NAME)

local GlobalMemoryStore = MemoryStoreService:GetHashMap(Config.DATASTORE.GLOBAL_HASHMAP_NAME)

--=========================
-- // PRIVATE API
--=========================

-- deepClone(): Deep clones a table
-- @param tbl: The table to clone
-- @return: { [any]: any }
local function deepClone(tbl: { any }): any
	if type(tbl) ~= "table" then
		return tbl
	end

	local result = {}

	for k, v in tbl do
		result[k] = deepClone(v)
	end

	return result
end

-- isSharded(): Checks to see if a table is sharded
-- @param tbl: { [any]: any }
-- @return: boolean
local function isSharded(tbl: { [any]: any }): boolean
	return type(tbl) == "table" and tbl.__sharded
end

-- reconcileData(): Reconciles the loaded data with the schema
-- @param loaded: { [any]: any }
-- @param schema: { [any]: any }
-- @return: { [any]: any }
local function reconcileData(loaded: { [any]: any }, schema: { [any]: any }): { [any]: any }
	if typeof(schema) ~= "table" then
		if typeof(loaded) == "table" then
			warn("reconcileData(): Type mismatch - Loaded value is a table but schema expects", typeof(schema), "; using schema default")
			return schema
		end

		return if loaded ~= nil then loaded else schema
	end

	if typeof(loaded) ~= "table" then
		return deepClone(schema)
	end

	if loaded.__sharded then
		return deepClone(loaded)
	end

	if next(schema) == nil then
		return deepClone(loaded)
	end

	local result = {}
	for key, schemaValue in schema do
		result[key] = reconcileData(loaded[key], schemaValue)
	end

	return result
end

-- parseSegment(): Parses a path segment into a key / index
-- @param segment: string
-- @param isBracketed: boolean
-- @return: any
local function parseSegment(segment: string, isBracketed: boolean): any
	if isBracketed then
		local quoted = segment:match("^['\"](.+)['\"]$")
		if quoted then return quoted end

		return tonumber(segment) or segment
	end

	return tonumber(segment) or segment
end

-- getSegments(): Gets all segments from a path
-- @param path: string
-- @return: { any }
local function getSegments(path: string): { any }
	local segments = {}

	for isBracket, content in path:gmatch("([%[%.]?)([^%[%]%.]+)%]?") do
		local bracketed = (isBracket == "[")
		table.insert(segments, parseSegment(content :: string, bracketed))
	end

	return segments
end

-- resolvePath(): Resolves a path in a table
-- @param tbl: The table to resolve the path in
-- @param path: The path to resolve
-- @return: any
local function resolvePath(tbl: any, path: string): any
	local current = tbl

	for _, key in getSegments(path) do
		if type(current) ~= "table" then return nil end

		current = current[key]
		if current == nil then return nil end
	end

	return current
end

-- setPath(): Sets a value at a path in a table
-- @param tbl: The table to set the value in
-- @param path: The path to set
-- @param value: The value to set
local function setPath(tbl: any, path: string, value: any): ()
	local segments = getSegments(path)
	local current = tbl

	for i = 1, #segments do
		local key = segments[i]

		if i == #segments then
			current[key] = value
		else
			if type(current[key]) ~= "table" then
				current[key] = {}
			end

			current = current[key]
		end
	end
end

-- readGlobalField(): Reads a configured global path
-- @param data: Global data table
-- @param path: Configured global path
-- @return: any: The value at the path, or nil when absent
local function readGlobalField(data: { [string]: any }, path: string): any
	local value = resolvePath(data, path)
	return if value ~= nil then value else data[path]
end

-- setGlobalField(): Writes a nested global path
-- @param data: Global data table
-- @param path: Configured global path
-- @param value: Value to write, or nil to remove
local function setGlobalField(data: { [string]: any }, path: string, value: any): ()
	if path:find(".", 1, true) then
		data[path] = nil
	end
	setPath(data, path, value)
end

-- getPresetFields(): Gets sharded and global fields from PlayerDatastore.Presets
-- @return: ({ string }, { string }): ShardedFields, GlobalFields
local function getPresetFields(): ({ string }, { string })
	return PlayerDatastore.Presets and PlayerDatastore.Presets.ShardedFields or {}, PlayerDatastore.Presets and PlayerDatastore.Presets.GlobalFields or {}
end

-- matchGlobalField(): Finds the configured global field a path starts with
-- @param path: Global path
-- @return: string?: The matched global field
local function matchGlobalField(path: string): string?
	local _, globalFields = getPresetFields()
	for _, globalPath in globalFields do
		local suffix = path:sub(#globalPath + 1)
		if path:sub(1, #globalPath) == globalPath and (suffix == "" or suffix:sub(1, 1) == "." or suffix:sub(1, 1) == "[") then
			return globalPath
		end
	end
	return nil
end

-- findShardedPath(): Finds the sharded path for a value
-- @param data: { [any]: any }
-- @param valueName: string
-- @return: string?
local function findShardedPath(data: { [any]: any }, valueName: string): string?
	local pathParts = string.split(valueName, ".")
	local deepestPath: string? = nil

	for i = 1, #pathParts do
		local testPath = table.concat(pathParts, ".", 1, i)
		local testTable = resolvePath(data, testPath)

		if isSharded(testTable) then
			deepestPath = testPath
		end
	end

	return deepestPath
end

--=========================
-- // PRIVATE YIELD API
--=========================

-- yieldPlayerData(): Yields until a players data is loaded
-- @param user_id: number
-- @return: boolean: Whether the data was loaded
local function yieldPlayerData(user_id: number): boolean
	if PlayerDatastore.PlayerData[user_id] then return true end
	if not PlayerDatastore.LoadingPlayers[user_id] then return false end

	if not PlayerDatastore.LoadingQueues[user_id] then
		PlayerDatastore.LoadingQueues[user_id] = {}
	end

	table.insert(PlayerDatastore.LoadingQueues[user_id], coroutine.running())
	coroutine.yield()

	return PlayerDatastore.PlayerData[user_id] ~= nil
end

-- yieldGlobalData(): Yields until .Init() has completed (Config.DATASTORE.INIT_YIELD_TIME)
-- @return: boolean: Whether Init completed in time
local function yieldGlobalData(): boolean
	if PlayerDatastore._initialized then return true end

	table.insert(PlayerDatastore._globalDataWaiters, coroutine.running())
	coroutine.yield()

	return PlayerDatastore._initialized
end

--=========================
-- // PRIVATE MEMORY STORE API
--=========================

-- readMemoryField(): Reads one global field's entry from MemoryStore
-- @param field: Configured global field
-- @return: (Types.MemoryEntry?, boolean): The entry; Whether the read succeeded
local function readMemoryField(field: string): (Types.MemoryEntry?, boolean)
	local success, entry = pcall(function()
		return GlobalMemoryStore:GetAsync(`{Config.DATASTORE.MEMORY_STORE_KEY}:{field}`)
	end)

	if not success then
		warn("readMemoryField(): Failed to read", field, "from MemoryStore")
		return nil, false
	end

	return entry, true
end

-- readMemoryGlobal(): Reads every configured global field's entry from MemoryStore
-- @return: ({ [string]: any }, { [string]: number }, boolean): Values and versions of fields with an entry; Whether every read succeeded
local function readMemoryGlobal(): ({ [string]: any }, { [string]: number }, boolean)
	local values: { [string]: any }, versions: { [string]: number } = {}, {}
	local _, globalFields = getPresetFields()

	for _, field in globalFields do
		local entry, success = readMemoryField(field)
		if not success then return values, versions, false end
		if entry then
			values[field] = entry.d
			versions[field] = entry.v
		end
	end

	return values, versions, true
end

-- writeMemoryField(): Atomically transforms one global field's entry in MemoryStore
-- @param field: Configured global field
-- @param transform: (current: Types.MemoryEntry?) -> Types.MemoryEntry?: Returns the new entry, or nil to cancel
-- @return: (boolean, boolean, Types.MemoryEntry?): Whether the write succeeded; Whether the write committed; The committed entry
local function writeMemoryField(field: string, transform: (current: Types.MemoryEntry?) -> Types.MemoryEntry?): (boolean, boolean, Types.MemoryEntry?)
	local committed: Types.MemoryEntry? = nil

	local success = pcall(function()
		GlobalMemoryStore:UpdateAsync(`{Config.DATASTORE.MEMORY_STORE_KEY}:{field}`, function(current)
			committed = transform(current)
			if committed then
				local encoded = HttpService:JSONEncode(committed)
				if #encoded > Config.DATASTORE.MEMORY_STORE_VALUE_LIMIT then
					warn("writeMemoryField(): Global entry exceeds 32KB MemoryStore limit; write cancelled")
					committed = nil
				end
			end
			return committed
		end, Config.DATASTORE.MEMORY_STORE_TTL)
	end)

	if not success then
		warn("writeMemoryField(): Failed to write", field, "to MemoryStore")
		return false, false, nil
	end

	return true, committed ~= nil, committed
end

--=========================
-- // PRIVATE WRITE LOCK API
--=========================

-- acquireWriteLock(): Acquires a write lock for a user, yielding if necessary until the lock is acquired
-- @param user_id: number
-- @return: boolean: Whether the lock was acquired
local function acquireWriteLock(user_id: number): boolean
	if not PlayerDatastore.WriteQueues[user_id] then
		PlayerDatastore.WriteQueues[user_id] = {}
		return true
	end

	local queue = PlayerDatastore.WriteQueues[user_id]
	table.insert(queue, coroutine.running())
	coroutine.yield()

	return PlayerDatastore.PlayerData[user_id] ~= nil
end

-- releaseWriteLock(): Releases a write lock for a user, resuming the next thread in the queue if there is one
-- @param user_id: number
local function releaseWriteLock(user_id: number): ()
	local queue = PlayerDatastore.WriteQueues[user_id]
	if not queue or #queue == 0 then
		PlayerDatastore.WriteQueues[user_id] = nil
		return
	end

	task.spawn(table.remove(queue, 1) :: thread)
end

--=========================
-- // PRIVATE METADATA API
--=========================

-- getMetaKey(): Returns the metadata key for a given user_id
-- @param user_id: number
-- @return: string
local function getMetaKey(user_id: number): string
	return `meta:{user_id}`
end

-- loadMetaData(): Loads metadata for a player
-- @param player: Player
-- @return: MetaData?
local function loadMetaData(player: Player): (Types.MetaData?, boolean)
	local data: Types.MetaData? = nil

	local success = pcall(function()
		local encoded = PlayerMetaDataStore:GetAsync(getMetaKey(player.UserId))
		data = encoded and HttpService:JSONDecode(encoded) or nil
	end)

	if not success then
		warn("loadMetaData(): Failed to load metadata for", player.Name)
		return nil, false
	end

	return data, true
end

-- saveMetaData(): Saves metadata for a player
-- @param player: Player
-- @note: Only writes SaveCount increment in-memory if persist succeeds
local function saveMetaData(user_id: number, player_name: string): boolean
	if PlayerDatastore.SessionLockLost[user_id] then return false end
	local existing = PlayerDatastore.MetaData[user_id]
	if not existing then return false end

    local updated: Types.MetaData = {
        LastSaved = os.time(),
        ServerId = game.JobId,
        SaveCount = existing.SaveCount + 1,
        FirstJoined = existing.FirstJoined,
        TotalPlaytime = existing.TotalPlaytime + (os.time() - (existing._SessionStart or os.time())),
		DataVersion = existing.DataVersion,
        _SessionStart = existing._SessionStart
    }

    local toPersist = {
        LastSaved = updated.LastSaved,
        ServerId = updated.ServerId,
        SaveCount = updated.SaveCount,
        FirstJoined = updated.FirstJoined,
        TotalPlaytime = updated.TotalPlaytime,
        DataVersion = updated.DataVersion
    }

	local encoded = HttpService:JSONEncode(toPersist)
	if #encoded > 4 * 1024 * 1024 then
		error("saveMetaData(): Metadata size exceeds Roblox 4 MB DataStore limit")
	end

    local success = pcall(function()
		PlayerMetaDataStore:SetAsync(getMetaKey(user_id), encoded)
    end)

    if success then
		PlayerDatastore.MetaData[user_id] = updated
    else
		warn("saveMetaData(): Failed to persist metadata for", player_name)
    end

	return success
end

-- saveGlobalMetaData(): Saves global metadata
local function saveGlobalMetaData(): boolean
	local existing = PlayerDatastore.MetaData[Config.DATASTORE.GLOBAL_DATASTORE_KEY]

	local meta: Types.MetaData = {
		LastSaved = os.time(),
		ServerId = game.JobId,
		SaveCount = (existing and existing.SaveCount or 0) + 1,
		FirstJoined = existing and existing.FirstJoined or os.time(),
		TotalPlaytime = 0,
		DataVersion = PlayerDatastore.CurrentVersion,
		_SessionStart = 0
	}

	local success = pcall(function()
		GlobalDataStore:SetAsync(
			`{Config.DATASTORE.GLOBAL_DATASTORE_KEY}:meta`,
			HttpService:JSONEncode(meta)
		)
	end)

	if success then
		PlayerDatastore.MetaData[Config.DATASTORE.GLOBAL_DATASTORE_KEY] = meta
	else
		warn("saveGlobalMetaData(): Failed to persist; SaveCount not incremented")
	end

	return success
end

--=========================
-- // PRIVATE SNAPSHOT API
--=========================

-- getSnapshotKey(): Returns the snapshot key for a given user_id
-- @param user_id: number | string
-- @return: string
local function getSnapshotKey(user_id: number | string): string
	if type(user_id) == "string" then
		return `snapshot:global`
	end

	return `snapshot:{user_id}`
end

-- loadSnapshots(): Read-only load of all snapshots for a user. Use updateSnapshots for writes.
-- @param user_id: number | string
-- @return: { [string]: Types.SnapshotEntry }
local function loadSnapshots(user_id: number | string): { [string]: Types.SnapshotEntry }
	local success, snapshots = pcall(function()
		local data = SnapshotDataStore:GetAsync(getSnapshotKey(user_id))
		return data and HttpService:JSONDecode(data) or {}
	end)

	if not success then
		warn("loadSnapshots(): Failed to load snapshots for", user_id)
		return {}
	end

	return snapshots
end

-- updateSnapshots(): Atomically updates the snapshots for a user
-- @param user_id: number | string
-- @param updater: (snapshots: { [string]: Types.SnapshotEntry }) -> { [string]: Types.SnapshotEntry }: Transform function
-- @return: boolean: Whether the update succeeded
local function updateSnapshots(user_id: number | string, updater: (snapshots: { [string]: Types.SnapshotEntry }) -> { [string]: Types.SnapshotEntry }): boolean
	local limit = Config.DATASTORE.MAX_SNAPSHOTS_PER_KEY
	local key = getSnapshotKey(user_id)
	local evicted: { string } = {}

	local success = pcall(function()
		SnapshotDataStore:UpdateAsync(key, function(existing: string?): string?
			evicted = {}
			local snapshots: { [string]: Types.SnapshotEntry } = existing and HttpService:JSONDecode(existing) or {}
			local dataKeys: { [string]: string } = {}
			for name, entry in snapshots do
				if entry.Key then dataKeys[name] = entry.Key end
			end
			snapshots = updater(snapshots)

			local entries: { Types.MetadataSnapshotEntry } = {}
			for name, entry in snapshots do
				table.insert(entries, { Key = name, Timestamp = entry.Timestamp })
			end

			if #entries > limit then
				table.sort(entries, function(a: Types.MetadataSnapshotEntry, b: Types.MetadataSnapshotEntry) return a.Timestamp < b.Timestamp end)

				for i = 1, #entries - limit do
					snapshots[entries[i].Key] = nil
				end
			end

			for name, dataKey in dataKeys do
				if not snapshots[name] or snapshots[name].Key ~= dataKey then
					table.insert(evicted, dataKey)
				end
			end

			return HttpService:JSONEncode(snapshots)
		end)
	end)

	if not success then
		warn("updateSnapshots(): Failed for", user_id)
		return false
	end

	for _, dataKey in evicted do
		pcall(function()
			SnapshotDataStore:RemoveAsync(dataKey)
		end)
	end

	return true
end

-- saveSnapshot(): Saves a snapshot under its own key, then adds it to the snapshot index
-- @param user_id: number | string
-- @param name: string
-- @param entry: Types.SnapshotEntry
-- @return: boolean: Whether the snapshot was saved and indexed
local function saveSnapshot(user_id: number | string, name: string, entry: Types.SnapshotEntry): boolean
	local dataKey = `snapshot:{HttpService:GenerateGUID(false)}`
	local success = pcall(function()
		SnapshotDataStore:SetAsync(dataKey, HttpService:JSONEncode(entry))
	end)

	if not success then
		warn("saveSnapshot(): Failed to save snapshot data for", user_id, name)
		return false
	end

	return updateSnapshots(user_id, function(snapshots)
		snapshots[name] = { Path = entry.Path, Timestamp = entry.Timestamp, Version = entry.Version, Key = dataKey }
		return snapshots
	end)
end

-- runMigrations(): Runs all applicable migrations on a players data
-- @param player: Player
-- @param data: { [any]: any }
-- @param loadedVersion: string
-- @return: { [any]: any }
local function runMigrations(player: Player, data: { [any]: any }, loadedVersion: string): ({ [any]: any }, boolean)
	if loadedVersion == PlayerDatastore.CurrentVersion then
		return data, true
	end

	local migrated = deepClone(data)
	local currentVersion = loadedVersion
	local didMigrate = false

	while currentVersion ~= PlayerDatastore.CurrentVersion do
		local entry = PlayerDatastore.Migrations[currentVersion]

		if not entry then
			warn("runMigrations(): No migration found from", currentVersion, "to", PlayerDatastore.CurrentVersion)
			return data, false
		end

		local snapshotKey = `pre-migration:{currentVersion}:{HttpService:GenerateGUID(false)}`

		local saved = saveSnapshot(player.UserId, snapshotKey, {
			Path = "",
			Data = deepClone(migrated),
			Timestamp = os.time(),
			Version = currentVersion
		})

		if not saved then
			warn("runMigrations(): Aborting migration for", player.Name, "; could not save pre-migration snapshot")
			return data, false
		end

		local migrateSuccess, result = pcall(entry.Fn, migrated)
		if not migrateSuccess then
			warn("runMigrations(): Migration function threw for", player.Name, ":", result)
			return data, false
		end

		migrated = result
		currentVersion = entry.To :: string
		didMigrate = true
	end

	if didMigrate then
		warn("runMigrations(): Migrated", player.Name, "from", loadedVersion, "to", currentVersion)
	end

	return migrated, currentVersion == PlayerDatastore.CurrentVersion
end

--=========================
-- // COMPLEX PRIVATE API
--=========================

-- getShardKey(): Returns the shard key for a given path and index
-- @param user_id: number
-- @param path: string
-- @param index: number
-- @return: string
local function getShardKey(user_id: number, path: string, index: number): string
	return `{user_id}:{path}:shard:{index}`
end

-- getShardGlobalKey(): Returns the global shard key for a given path and index
-- @param path: string
-- @param index: number
-- @return: string
local function getShardGlobalKey(path: string, index: number): string
	return `global:{path}:shard:{index}`
end

-- stripGlobalFields(): Removes from PlayerData if their name is in GlobalFields
-- @param data_table: { [any]: any }
-- @param globalFields: { string }
-- @return: { [any]: any }
local function stripGlobalFields(data_table: { [any]: any }, globalFields: { string }): { [any]: any }
	local clone = deepClone(data_table)

	for _, key in globalFields do
		setPath(clone, key, nil)
	end

	return clone
end

-- queueShardRemovals(): Defers obsolete shard deletion until its master record saves
-- @param owner: Player user ID or global datastore key
-- @param oldCount: Previous shard count
-- @param newCount: Replacement shard count
-- @param keyFn: Builds a persistent shard key from its index
local function queueShardRemovals(owner: number | string, oldCount: number, newCount: number, keyFn: (number) -> string): ()
	local pending = PlayerDatastore.PendingShardRemovals[owner] or {}
	for index = 1, newCount do
		pending[keyFn(index)] = nil
	end
	for index = newCount + 1, oldCount do
		pending[keyFn(index)] = true
	end
	if next(pending) then
		PlayerDatastore.PendingShardRemovals[owner] = pending
	else
		PlayerDatastore.PendingShardRemovals[owner] = nil
	end
end

-- cleanupPendingShardRemovals(): Removes queued obsolete shard keys after master save
-- @param owner: Player user ID or global datastore key
-- @return: boolean: Whether every queued shard was removed
local function cleanupPendingShardRemovals(owner: number | string): boolean
	local pending = PlayerDatastore.PendingShardRemovals[owner]
	if not pending then return true end

	local allSucceeded = true
	for shardKey in pending do
		local success = pcall(function()
			ShardedDataStore:RemoveAsync(shardKey)
		end)
		if success then
			pending[shardKey] = nil
			PlayerDatastore.ShardData[shardKey] = nil
		else
			allSucceeded = false
			warn("cleanupPendingShardRemovals(): Failed to remove", shardKey)
		end
	end

	if next(pending) == nil then
		PlayerDatastore.PendingShardRemovals[owner] = nil
	end
	return allSucceeded
end

-- persistShardFields(): Persists all cached shards in the selected fields
-- @param fields: Configured sharded paths
-- @param shouldSkip: Returns true for paths owned by another data set
-- @param getTable: Resolves the in-memory value at a path
-- @param getKey: Builds a persistent shard key from a path and index
-- @return: boolean: Whether every referenced shard was persisted
local function persistShardFields(
	fields: { string },
	shouldSkip: (path: string) -> boolean,
	getTable: (path: string) -> any,
	getKey: (path: string, index: number) -> string
): boolean
	for _, path in fields do
		if shouldSkip(path) then continue end
		local field = getTable(path)
		if not isSharded(field) then continue end

		for index = 1, field.count do
			local shardKey = getKey(path, index)
			local shardData = PlayerDatastore.ShardData[shardKey]
			if not shardData then
				warn("persistShardFields(): Missing cached shard", shardKey)
				return false
			end

			local encodedShard = HttpService:JSONEncode(shardData)
			if #encodedShard > 4 * 1024 * 1024 then
				error("persistShardFields(): Shard exceeds Roblox 4 MB DataStore limit")
			end

			local success = pcall(function()
				ShardedDataStore:SetAsync(shardKey, encodedShard)
			end)
			if not success then
				warn("persistShardFields(): Failed to persist shard", shardKey)
				return false
			end
		end
	end

	return true
end

--=========================
-- // PRIVATE SESSION LOCK API
--=========================

-- getSessionLockKey(): Returns the session lock key for a given user_id
-- @param user_id: number
-- @return: string
local function getSessionLockKey(user_id: number): string
	return `session:{user_id}:lock`
end

-- acquireSessionLock(): Atomically acquires a session lock for a player
-- @param user_id: number
-- @return: (boolean, Types.SessionLockReturnType): Whether the lock was acquired; reason ("OK" | "CONTESTED" | "ERROR")
local function acquireSessionLock(user_id: number): (boolean, Types.SessionLockReturnType)
	local lockKey = getSessionLockKey(user_id)

	for _ = 1, Config.DATASTORE.LOCK_MAX_RETRIES do
		local acquired = false
		local contested = false
		local lock: Types.SessionEntry? = nil
		local success = pcall(function()
			lock = SessionLockStore:UpdateAsync(lockKey, function(existing: Types.SessionEntry?): Types.SessionEntry?
				if existing then
					local isOurs = existing.JobID == game.JobId
					local isStale = (os.time() - (existing.Timestamp or 0)) > Config.DATASTORE.LOCK_STALE_THRESHOLD

					if not isOurs and not isStale then
						contested = true
						return nil
					end
				end

				acquired = true
				return { JobID = game.JobId, Timestamp = os.time() }
			end)
		end)

		if success and acquired and lock and lock.JobID == game.JobId then
			PlayerDatastore.SessionLockLost[user_id] = nil
			PlayerDatastore.SessionLockHeartbeats[user_id] = true
			task.spawn(function()
				while PlayerDatastore.SessionLockHeartbeats[user_id] do
					task.wait(math.max(1, Config.DATASTORE.LOCK_STALE_THRESHOLD / 3))
					if not PlayerDatastore.SessionLockHeartbeats[user_id] then break end

					local renewed = false
					local lost = false
					for attempt = 1, Config.DATASTORE.LOCK_MAX_RETRIES do
						local renewedLock: Types.SessionEntry? = nil
						local belongsElsewhere = false
						local renewalSuccess = pcall(function()
							renewedLock = SessionLockStore:UpdateAsync(lockKey, function(existing: Types.SessionEntry?): Types.SessionEntry?
								if existing and existing.JobID ~= game.JobId then
									belongsElsewhere = true
									return nil
								end
								return { JobID = game.JobId, Timestamp = os.time() }
							end)
						end)

						if renewalSuccess and renewedLock and renewedLock.JobID == game.JobId then
							renewed = true
							break
						end
						if belongsElsewhere or (renewedLock and renewedLock.JobID ~= game.JobId) then
							lost = true
							break
						end
						if attempt < Config.DATASTORE.LOCK_MAX_RETRIES then
							task.wait(Config.DATASTORE.LOCK_RETRY_INTERVAL)
						end
					end

					if lost or not renewed then
						PlayerDatastore.SessionLockHeartbeats[user_id] = nil
						PlayerDatastore.SessionLockLost[user_id] = true
						local player = Players:GetPlayerByUserId(user_id)
						if player then
							warn("acquireSessionLock(): Could not renew session lock for", player.Name)
							player:Kick("[PlayerDatastore]: Your data session could not be secured. Please rejoin.")
						end
						break
					end
				end
			end)

			return true, "OK"
		end
		if success and contested then return false, "CONTESTED" end

		task.wait(Config.DATASTORE.LOCK_RETRY_INTERVAL)
	end

	return false, "ERROR"
end

-- renewSessionLock(): Renews or verifies the session lock before saving
-- @param user_id: number
-- @return: string: "OK" | "LOST" | "ERROR"
local function renewSessionLock(user_id: number): string
	local lockKey = getSessionLockKey(user_id)
	local status = "ERROR"

	local success = pcall(function()
		SessionLockStore:UpdateAsync(lockKey, function(existing: Types.SessionEntry?): Types.SessionEntry?
			if existing and existing.JobID ~= game.JobId then
				status = "LOST"
				return nil
			end
			status = "OK"
			return { JobID = game.JobId, Timestamp = os.time() }
		end)
	end)

	if not success then
		warn("renewSessionLock(): Failed to renew session lock for", user_id)
		return "ERROR"
	end

	return status
end

-- releaseSessionLock(): Releases the session lock for a player
-- @param user_id: number
function releaseSessionLock(user_id: number): ()
	PlayerDatastore.SessionLockHeartbeats[user_id] = nil
	pcall(function()
		SessionLockStore:UpdateAsync(getSessionLockKey(user_id), function(existing: Types.SessionEntry?): Types.SessionEntry?
			if existing and existing.JobID == game.JobId then return { JobID = existing.JobID, Timestamp = 0 } end
			return nil
		end)
	end)
end

--=========================
-- // PRIVATE SAVE / LOAD API
--=========================

-- saveData(): Saves the players data
-- @param player: The player to save the data for
-- @note: Shards unsharded data marked as __sharded; Write unshards to apply changes. While doing this, the player could leave, having corrupted sharded data that may exceed the 4MB Key Limit. This fixes it
local function saveData(player: Player?, user_id: number?): boolean
	local userId = if player then player.UserId else user_id
	if not userId then return false end
	if PlayerDatastore.SessionLockLost[userId] then
		warn("saveData(): Refusing to save after session-lock ownership was lost for", userId)
		return false
	end
	local data = PlayerDatastore.PlayerData[userId]
	if not data then return false end

	local shardedFields, globalFields = getPresetFields()

	for _, table_path in shardedFields do
		local tbl = resolvePath(data, table_path)

		if type(tbl) ~= "table" or tbl.__sharded then continue end

		if not player then return false end
		warn("saveData(): Force-sharding", table_path, "for", player.Name)
		PlayerDatastore.Shard(player, table_path, true)
	end

	local lockStatus = renewSessionLock(userId)
	if lockStatus == "LOST" then
		PlayerDatastore.SessionLockLost[userId] = true
		warn("saveData(): Session lock is owned by another server; refusing to save", userId)
		return false
	end
	if lockStatus == "ERROR" then return false end

	if not persistShardFields(
		shardedFields,
		function(path) return table.find(globalFields, path) ~= nil end,
		function(path) return resolvePath(data, path) end,
		function(path, index) return getShardKey(userId, path, index) end
	) then
		return false
	end

	local encodedData = HttpService:JSONEncode(data)
	if #encodedData > 4 * 1024 * 1024 then
		error("saveData(): Player data payload exceeds Roblox 4 MB DataStore limit")
	end

	local success = pcall(function()
		PlayerDataStore:UpdateAsync(tostring(userId), function(existing: string?): string?
			return encodedData
		end)
	end)

	if not success then
		warn("saveData(): Failed to persist player data for", player and player.Name or userId)
		return false
	end
	if not cleanupPendingShardRemovals(userId) then return false end

	return saveMetaData(userId, player and player.Name or tostring(userId))
end

-- loadData(): Loads the players data
-- @param player: The player to load the data for
-- @return: ({ [any]: any }?, boolean); Loaded Data, if loading failed
local function loadData(player: Player): ({ [any]: any }?, boolean)
	local data: { [any]: any }? = nil

	local success = pcall(function()
		local encoded = PlayerDataStore:GetAsync(tostring(player.UserId))
		data = encoded and HttpService:JSONDecode(encoded) or nil
	end)

	if not success then
		warn("loadData(): Failed to load data for", player.Name)
		return nil, true
	end

	return data, false
end

-- saveGlobalData(): Saves global data to the GlobalDataStore
-- @note: Automatically JSON encodes the value; reshards if needed
local function saveGlobalData(): boolean
	local shardedFields, globalFields = getPresetFields()

	local liveData, versions, memoryReadSucceeded = readMemoryGlobal()
	if not memoryReadSucceeded then return false end
    local dataToSave = {}

    for _, path in globalFields do
		if versions[path] == nil then continue end
		local value: any = liveData[path]

        if value == nil then continue end

        if table.find(shardedFields, path) and type(value) == "table" then
            if not isSharded(value) then
				setGlobalField(PlayerDatastore.GlobalData, path, value)
                PlayerDatastore.ShardGlobal(path, true)
            end
			dataToSave[path] = resolvePath(PlayerDatastore.GlobalData, path)
        else
            dataToSave[path] = value
        end
    end

	if not persistShardFields(
		shardedFields,
		function(path) return table.find(globalFields, path) == nil end,
		function(path) return resolvePath(PlayerDatastore.GlobalData, path) end,
		function(path, index) return getShardGlobalKey(path, index) end
	) then
		return false
	end

	local success = pcall(function()
		GlobalDataStore:UpdateAsync(Config.DATASTORE.GLOBAL_DATASTORE_KEY, function(encoded: string?): string?
			local stored = encoded and HttpService:JSONDecode(encoded) or {}
			stored.__v = stored.__v or {} -- // { [field]: version }; data saved before versioning counts as 0
			for path, version in versions do
				if (stored.__v[path] or 0) > version then continue end
				stored[path] = dataToSave[path]
				stored.__v[path] = version
			end
			PlayerDatastore.StoredGlobalVersions = stored.__v
			return HttpService:JSONEncode(stored)
		end)
    end)

    if not success then
		warn("saveGlobalData(): Failed to persist global data")
		return false
	end
	if not cleanupPendingShardRemovals(Config.DATASTORE.GLOBAL_DATASTORE_KEY) then return false end

	return saveGlobalMetaData()
end

-- loadGlobalData(): Loads global data from the GlobalDataStore
-- @return: any: Global data
local function loadGlobalData(): (any, boolean)
	local data: any = nil

	local success = pcall(function()
		local encoded = GlobalDataStore:GetAsync(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
		data = encoded and HttpService:JSONDecode(encoded) or {}
	end)

	if not success then
		warn("loadGlobalData(): Failed to load master global key")
		return {}, false
	end

	return data or {}, true
end

--=========================
-- // PRIVATE GLOBAL SYNC HELPER
--=========================

-- reshardGlobalField(): After writing a value into GlobalData, reshard if needed
-- @param table_path: string
-- @param value: any
-- @param shardedFields: { string }
local function reshardGlobalField(table_path: string, value: any, shardedFields: { string }): ()
	if not table.find(shardedFields, table_path) then return end
	if type(value) ~= "table" or value.__sharded then return end

	if next(value) then
		PlayerDatastore.ShardGlobal(table_path, true)
	else
		setPath(PlayerDatastore.GlobalData, table_path, { __sharded = true, count = 0 })
	end
end

-- syncGlobalFromMemory(): Writes liveData fields into GlobalData and reshards as needed
-- @param liveData: { [string]: any }
-- @param globalFields: { string }
-- @param shardedFields: { string }
-- @param skipNil: boolean   if true, skips fields that are nil in liveData (used during init)
local function syncGlobalFromMemory(liveData: { [string]: any }, globalFields: { string }, shardedFields: { string }, skipNil: boolean?): ()
	for _, table_path in globalFields do
		local value = readGlobalField(liveData, table_path)

		if value == nil and skipNil then continue end

		local previous = resolvePath(PlayerDatastore.GlobalData, table_path)
		local oldCount = if isSharded(previous) then previous.count or 0 else 0
		setGlobalField(PlayerDatastore.GlobalData, table_path, value)
		if value ~= nil then
			reshardGlobalField(table_path, value, shardedFields)
		end

		local updated = resolvePath(PlayerDatastore.GlobalData, table_path)
		local newCount = if isSharded(updated) then updated.count or 0 else 0
		queueShardRemovals(Config.DATASTORE.GLOBAL_DATASTORE_KEY, oldCount, newCount, function(index)
			return getShardGlobalKey(table_path, index)
		end)
	end
end

--=========================
-- // PRIVATE SHARD API
--=========================

-- shardTable(): Core shard/unshard logic, shared by Shard() and ShardGlobal()
-- @param getTbl: Reads the current table
-- @param setTbl: Writes back the result
-- @param keyFn: Produces the ShardData key for a given index
-- @param enable: boolean
-- @param label: Used in warnings
local function shardTable(getTbl: () -> { [any]: any }, setTbl: (value: any) -> (), keyFn: (index: number) -> string, enable: boolean, label: string): ()
	local tbl = getTbl()

	if type(tbl) ~= "table" then
		if enable then warn(label, ": Invalid table") end
		return
	end

	if enable then
		local limit = Config.DATASTORE.SHARD_BYTE_LIMIT
		local shards: { [number]: { [any]: any } } = {}
		local current: { [any]: any } = {}
		local shardIndex = 1
		local currentBytes = 0

		for k, v in tbl do
			if k == "__sharded" or k == "count" then continue end

			local addedSize = #HttpService:JSONEncode({ [k] = v })

			if currentBytes + addedSize > limit and next(current) ~= nil then
				shards[shardIndex] = current
				shardIndex += 1
				current = {}
				currentBytes = 0
			end

			current[k] = v
			currentBytes += addedSize
		end

		if next(current) then
			shards[shardIndex] = current
		end

		for index, shard in shards do
			PlayerDatastore.ShardData[keyFn(index)] = shard
		end
		local actualCount = #shards

		setTbl({ __sharded = true, count = actualCount })
	else
		if not tbl.__sharded then return end

		local combined = {}

		for i = 1, tbl.count do
			local shardKey = keyFn(i)
			local shardData = PlayerDatastore.ShardData[shardKey]

			if not shardData then
				warn(label, ": Missing shard", i, "; Aborting unshard")
				return
			end

			for k, v in shardData do combined[k] = v end
		end

		for i = 1, tbl.count do
			PlayerDatastore.ShardData[keyFn(i)] = nil
		end

		setTbl(combined)
	end
end

--=========================
-- // PRIVATE AUTOSAVE API
--=========================

-- markDirty(): Marks a key as having unsaved changes
-- @param key: Player.UserId OR Config.DATASTORE.GLOBAL_DATASTORE_KEY for global data
local function markDirty(key: number | string): ()
	PlayerDatastore.DirtyData[key] = true
end

-- flushDirty(): Saves all dirty keys and clears them from DirtyData
-- @param max_keys: Optional capacity on how many keys to save this cycle (default: all)
-- @return: number: Amount of keys flushed
local function flushDirty(max_keys: number?): number
	local Limit = max_keys or math.huge
	local ToProcess: { number | string } = {}

	for Key in PlayerDatastore.DirtyData do
		if #ToProcess >= Limit then break end
		table.insert(ToProcess, Key)
	end

	local SaveHandlers: { [string]: (Key: number | string) -> boolean } = {
		["number"] = function(Key: number | string): boolean
			local userId = Key :: number
			if not PlayerDatastore.PlayerData[userId] then return true end
			local player = Players:GetPlayerByUserId(userId)
			if not player and PlayerDatastore.SessionLockLost[userId] then
				PlayerDatastore.PlayerData[userId] = nil
				PlayerDatastore.MetaData[userId] = nil
				return true
			end
			if not saveData(player, userId) then return false end
			if not Players:GetPlayerByUserId(userId) then
				releaseSessionLock(userId)
				PlayerDatastore.PlayerData[userId] = nil
				PlayerDatastore.MetaData[userId] = nil
			end
			return true
		end,

		["string"] = function(_Key: number | string): boolean
			return saveGlobalData()
		end
	}

	for _, Key in ToProcess do
		if SaveHandlers[type(Key)](Key) then
			PlayerDatastore.DirtyData[Key] = nil
		end
	end

	return #ToProcess
end

-- startAutosave(): Starts the autosave loop
local function startAutosave(): ()
	task.spawn(function()
		while true do
			task.wait(Config.DATASTORE.AUTOSAVE_INTERVAL)
			local flushed = flushDirty(Config.DATASTORE.MAX_KEYS_PER_AUTOSAVE)

			print(`startAutosave(): Flushed {flushed} keys`)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(math.max(1, Config.DATASTORE.MEMORY_STORE_TTL / 3))
			local _, globalFields = getPresetFields()
			for _, field in globalFields do
				writeMemoryField(field, function(current) return current end)
			end
		end
	end)
end

--=========================
-- // PRIVATE UTILITY API
--=========================

-- readGlobalLocalFallback(): Reads global data from local cache, unsharding if needed
-- @param path: string
-- @return: any
local function readGlobalLocalFallback(path: string): any
    local shardedPath = findShardedPath(PlayerDatastore.GlobalData, path)
    if not shardedPath then
        return resolvePath(PlayerDatastore.GlobalData, path)
    end

    local tbl = resolvePath(PlayerDatastore.GlobalData, shardedPath)
    local combined = {}

    for i = 1, tbl.count do
        local shardKey = getShardGlobalKey(shardedPath, i)
        local shardData = PlayerDatastore.ShardData[shardKey]
		if not shardData then return nil end
		for k, v in shardData do combined[k] = v end
    end

    if shardedPath == path then return combined end

    local remainingPath = path:match("^" .. shardedPath:gsub("%.", "%%.") .. "%.(.*)" ) or ""
    return resolvePath(combined, remainingPath)
end

-- cleanupLoadingState(): Cleans up the loading state for a user, resuming any threads waiting on load
-- @param user_id: number
local function cleanupLoadingState(user_id: number): ()
    PlayerDatastore.LoadingPlayers[user_id] = nil

    local loadQueue = PlayerDatastore.LoadingQueues[user_id]
    if loadQueue then
        for _, thread in loadQueue do
            task.spawn(thread)
        end

        PlayerDatastore.LoadingQueues[user_id] = nil
    end
end

-- cleanupWriteQueues(): Resumes any threads waiting on write locks and clears user_id in WriteQueues
-- @param user_id: number
local function cleanupWriteQueues(user_id: number): ()
	local queue = PlayerDatastore.WriteQueues[user_id]
	if not queue then return end

	for _, thread in queue do
		task.spawn(thread)
	end

	PlayerDatastore.WriteQueues[user_id] = nil
end

-- cleanupGlobalDataWaiters(): Resumes any threads waiting on global data load and clears the waiters list
local function cleanupGlobalDataWaiters(): ()
	for _, thread in PlayerDatastore._globalDataWaiters do
		task.spawn(thread)
	end

	table.clear(PlayerDatastore._globalDataWaiters)
end

--=========================
-- // PRIVATE INIT API
--=========================

-- onPlayerAdded(): Handles PlayerAdded and everything player data related
-- @param player: Player
-- @param data_table: { [any]: any }: The template data table for the player
-- @param globalFields: { string }: List of global fields to check for sharding
-- @param shardedFields: { string }: List of sharded fields to set up sharding for
local function onPlayerAdded(player: Player, data_table: { [any]: any }, globalFields: { string }, shardedFields: { string }): ()
	if PlayerDatastore.LoadingPlayers[player.UserId] or PlayerDatastore.PlayerData[player.UserId] then
		return
	end

	PlayerDatastore.LoadingPlayers[player.UserId] = true

	local locked, lockReason = acquireSessionLock(player.UserId)

	if not Players:GetPlayerByUserId(player.UserId) then
		if locked then releaseSessionLock(player.UserId) end
		PlayerDatastore.MetaData[player.UserId] = nil
		cleanupLoadingState(player.UserId)
		return
	end

	if not locked then
		if lockReason == "CONTESTED" then
			player:Kick("[PlayerDatastore]: Your data is still being saved from another server. Please rejoin in a moment.")
		else
			player:Kick("[PlayerDatastore]: Could not verify your session due to a temporary error. Please rejoin.")
		end

		warn("onPlayerAdded(): Failed to acquire lock for", player.Name, "- Reason:", lockReason)

		PlayerDatastore.MetaData[player.UserId] = nil
		cleanupLoadingState(player.UserId)
		return
	end

	if PlayerDatastore.PlayerData[player.UserId] then
		warn("onPlayerAdded(): PlayerData still present for", player.Name, ". Kicking")
		player:Kick("[PlayerDatastore]: Your previous session is still being saved. Please rejoin in a moment.")

		releaseSessionLock(player.UserId)

		PlayerDatastore.MetaData[player.UserId] = nil
		cleanupLoadingState(player.UserId)
		return
	end

	local loadedMeta, metaLoadSucceeded = loadMetaData(player)
	if not metaLoadSucceeded then
		player:Kick("[PlayerDatastore]: Failed to load your metadata. Please rejoin.")
		releaseSessionLock(player.UserId)
		cleanupLoadingState(player.UserId)
		return
	end

	PlayerDatastore.MetaData[player.UserId] = {
		LastSaved = loadedMeta and loadedMeta.LastSaved or os.time(),
		ServerId = game.JobId,
		SaveCount = loadedMeta and loadedMeta.SaveCount or 0,
		FirstJoined = loadedMeta and loadedMeta.FirstJoined or os.time(),
		TotalPlaytime = loadedMeta and loadedMeta.TotalPlaytime or 0,
		DataVersion = loadedMeta and loadedMeta.DataVersion or PlayerDatastore.CurrentVersion,
		_SessionStart = os.time()
	}

	local data, loadFailed = loadData(player)

	if not Players:GetPlayerByUserId(player.UserId) then
		releaseSessionLock(player.UserId)

		PlayerDatastore.MetaData[player.UserId] = nil
		cleanupLoadingState(player.UserId)
		return
	end

	if loadFailed then
		player:Kick("[PlayerDatastore]: Failed to load your data. Please rejoin.")

		releaseSessionLock(player.UserId)

		PlayerDatastore.MetaData[player.UserId] = nil
		cleanupLoadingState(player.UserId)
		return
	end

	local playerTemplate = stripGlobalFields(data_table, globalFields)
	PlayerDatastore.PlayerData[player.UserId] = data and reconcileData(data, playerTemplate) or playerTemplate
	local initializedShardDefaults = false
	local shardLoadFailed = false
	local loadedShardKeys: { string } = {}

	for _, table_path in shardedFields do
		if shardLoadFailed then break end
		if table.find(globalFields, table_path) then continue end

		local tbl = resolvePath(PlayerDatastore.PlayerData[player.UserId], table_path)

		if tbl == nil then
			warn("onPlayerAdded(): Sharded field not found in data template:", table_path)
			continue
		end

		if type(tbl) ~= "table" then
			warn("onPlayerAdded(): Sharded field is not a table:", table_path)
			continue
		end

		if not tbl.__sharded then
			PlayerDatastore.Shard(player, table_path, true)
			initializedShardDefaults = true
			continue
		end

		for i = 1, tbl.count do
			local shardKey = getShardKey(player.UserId, table_path, i)

			local success, shardDataOrError = pcall(function()
				return ShardedDataStore:GetAsync(shardKey)
			end)

			if not success then
				warn(`[PlayerDatastore]: Shard load failed for {player.Name} | key={shardKey} | error={shardDataOrError}`)
				shardLoadFailed = true
				break
			end

			if not shardDataOrError then
				warn(`[PlayerDatastore]: Missing shard {shardKey} for {player.Name}`)
				shardLoadFailed = true
				break
			end

			local decodeSuccess, decoded = pcall(HttpService.JSONDecode, HttpService, shardDataOrError)
			if not decodeSuccess then
				warn(`[PlayerDatastore]: JSON decode failed for shard {shardKey} | player={player.Name}`)
				shardLoadFailed = true
				break
			end

			PlayerDatastore.ShardData[shardKey] = decoded
			table.insert(loadedShardKeys, shardKey)
		end
	end

	if shardLoadFailed then
		for _, shardKey in loadedShardKeys do
			PlayerDatastore.ShardData[shardKey] = nil
		end
		PlayerDatastore.PlayerData[player.UserId] = nil
		PlayerDatastore.MetaData[player.UserId] = nil
		releaseSessionLock(player.UserId)
		player:Kick("[PlayerDatastore]: Failed to load all of your data. Please rejoin.")
		cleanupLoadingState(player.UserId)
		return
	end

	if initializedShardDefaults then
		markDirty(player.UserId)
	end

	if loadedMeta then
		local loadedVersion = loadedMeta.DataVersion or PlayerDatastore.CurrentVersion

		if loadedVersion ~= PlayerDatastore.CurrentVersion then
			for _, table_path in shardedFields do
				if table.find(globalFields, table_path) then continue end
				PlayerDatastore.Shard(player, table_path, false)
			end

			local migratedData, migrationSucceeded = runMigrations(
				player,
				PlayerDatastore.PlayerData[player.UserId],
				loadedVersion
			)
			PlayerDatastore.PlayerData[player.UserId] = migratedData

			if migrationSucceeded then
				PlayerDatastore.MetaData[player.UserId].DataVersion = PlayerDatastore.CurrentVersion
				markDirty(player.UserId)
			end

			for _, table_path in shardedFields do
				if table.find(globalFields, table_path) then continue end
				PlayerDatastore.Shard(player, table_path, true)
			end
		end
	end

	cleanupLoadingState(player.UserId)
end

-- onGlobalSetup(): Loads and sets up everything global related
-- @param data_table: { [any]: any }: The template data table for the player
-- @param globalFields: { string }: List of global fields to check for sharding
-- @param shardedFields: { string }: List of sharded fields to set up sharding for
local function onGlobalSetup(data_table: { [any]: any }, globalFields: { string }, shardedFields: { string }): boolean
	local globalData, globalLoadSucceeded = loadGlobalData()
	if not globalLoadSucceeded then return false end
	local globalMeta: Types.MetaData? = nil

	local metaSuccess = pcall(function()
		local raw = GlobalDataStore:GetAsync(`{Config.DATASTORE.GLOBAL_DATASTORE_KEY}:meta`)
		if not raw then return end

		globalMeta = HttpService:JSONDecode(raw)
	end)

	if metaSuccess and globalMeta then
		PlayerDatastore.MetaData[Config.DATASTORE.GLOBAL_DATASTORE_KEY] = globalMeta
	end

	local globalMemoryState: { [string]: any } = {}
	local shardLoadFailed = false

	for _, table_path in globalFields do
		if shardLoadFailed then break end
		local loadedValue = globalData[table_path]
		local defaultValue = resolvePath(data_table, table_path)

		if defaultValue == nil then
			warn("onGlobalSetup(): Global field not found in data template:", table_path)
			continue
		end

		local reconciled: { [any]: any } = {}

		if type(loadedValue) == "table" and loadedValue.__sharded then
			local combined = {}

			for i = 1, loadedValue.count or 0 do
				local shardKey = getShardGlobalKey(table_path, i)

				local success, shardData = pcall(function()
					return ShardedDataStore:GetAsync(shardKey)
				end)

				if not success then
					warn(`[PlayerDatastore] Global shard load failed for {table_path} | key={shardKey} | error={shardData}`)
					shardLoadFailed = true
					break
				end

				if not shardData then
					warn(`[PlayerDatastore] Global shard missing for {table_path} | key={shardKey}`)
					shardLoadFailed = true
					break
				end

				local decodeSuccess, decoded = pcall(HttpService.JSONDecode, HttpService, shardData)
				if not decodeSuccess then
					warn(`[PlayerDatastore] Global shard JSON decode failed for {shardKey}`)
					shardLoadFailed = true
					break
				end
				for k, v in decoded do
					combined[k] = v
				end
			end

			reconciled = combined
		else
			reconciled = reconcileData(loadedValue, defaultValue)
		end

		setGlobalField(PlayerDatastore.GlobalData, table_path, reconciled)

		if table.find(shardedFields, table_path) and not reconciled.__sharded then
			if next(reconciled) then
				PlayerDatastore.ShardGlobal(table_path, true)
			else
				setPath(PlayerDatastore.GlobalData, table_path, {
					__sharded = true,
					count = 0
				})
			end
		end

		globalMemoryState[table_path] = reconciled
	end

	if shardLoadFailed then
		return false
	end

	local storedVersions = globalData.__v or {}
	PlayerDatastore.StoredGlobalVersions = storedVersions

	for table_path, reconciled in globalMemoryState do
		local syncedFromMemory: Types.MemoryEntry? = nil

		writeMemoryField(table_path, function(current): Types.MemoryEntry?
			syncedFromMemory = current
			if current then return nil end
			return { v = PlayerDatastore.StoredGlobalVersions[table_path] or 0, d = reconciled }
		end)

		if not syncedFromMemory then continue end

		local tbl = resolvePath(PlayerDatastore.GlobalData, table_path)
		local oldCount = if isSharded(tbl) then tbl.count or 0 else 0

		syncGlobalFromMemory({ [table_path] = syncedFromMemory.d }, { table_path }, shardedFields, true)

		local newTbl = resolvePath(PlayerDatastore.GlobalData, table_path)
		local newCount = isSharded(newTbl) and (newTbl.count or 0) or 0

		for i = newCount + 1, oldCount do
			PlayerDatastore.ShardData[getShardGlobalKey(table_path, i)] = nil
		end
	end

	return true
end

--=========================
-- // PUBLIC API
--=========================

-- Init(): Initialize the datastore handler
-- @param data_table: { [any]: any }
-- @param presets: Types.PresetOptions?
function PlayerDatastore.Init(data_table: { [any]: any }, presets: Types.PresetOptions?): ()
	if PlayerDatastore._initialized then
		warn("Init(): PlayerDatastore is already initialized")
		return
	end

	PlayerDatastore.Presets = presets

	local shardedFields: { string } = presets and presets.ShardedFields or {}
	local globalFields: { string } = presets and presets.GlobalFields or {}
	if not onGlobalSetup(data_table, globalFields, shardedFields) then
		error("Init(): Global shard load failed; initialization aborted")
	end

	Players.PlayerAdded:Connect(function(player)
		onPlayerAdded(player, data_table, globalFields, shardedFields)
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player, data_table, globalFields, shardedFields)
	end

	Players.PlayerRemoving:Connect(function(player)
		PlayerDatastore.LoadingPlayers[player.UserId] = nil

		local saved: boolean
		if PlayerDatastore.DirtyData[player.UserId] then
			saved = saveData(player, player.UserId)
		else
			saved = saveMetaData(player.UserId, player.Name)
		end

		if saved then
			PlayerDatastore.DirtyData[player.UserId] = nil
			releaseSessionLock(player.UserId)
			PlayerDatastore.PlayerData[player.UserId] = nil
			PlayerDatastore.MetaData[player.UserId] = nil
		else
			markDirty(player.UserId)
			warn("PlayerRemoving: Retaining unsaved data for retry", player.Name)
		end

		cleanupLoadingState(player.UserId)
		cleanupWriteQueues(player.UserId)
	end)

	game:BindToClose(function()
		local activeThreads = {}
		for _, player in Players:GetPlayers() do
			table.insert(activeThreads, task.spawn(function()
				local userId = player.UserId
				if not PlayerDatastore.PlayerData[userId] then
					releaseSessionLock(userId)
					return
				end

				local saved: boolean
				if PlayerDatastore.DirtyData[userId] then
					saved = saveData(player, userId)
				else
					saved = saveMetaData(userId, player.Name)
				end

				if saved then
					PlayerDatastore.DirtyData[userId] = nil
					releaseSessionLock(userId)
				else
					markDirty(userId)
				end

				cleanupWriteQueues(userId)
			end))
		end

		local startTime = os.clock()
		while true do
			local allDone = true
			for _, thread in activeThreads do
				if coroutine.status(thread) ~= "dead" then
					allDone = false
					break
				end
			end
			if allDone or (os.clock() - startTime > 15) then break end
			task.wait(0.2)
		end

		for attempt = 1, Config.DATASTORE.LOCK_MAX_RETRIES do
			flushDirty()
			if next(PlayerDatastore.DirtyData) == nil then break end
			if attempt < Config.DATASTORE.LOCK_MAX_RETRIES then
				task.wait(Config.DATASTORE.LOCK_RETRY_INTERVAL)
			end
		end

		for _, player in Players:GetPlayers() do
			if not PlayerDatastore.DirtyData[player.UserId] then
				releaseSessionLock(player.UserId)
			end
		end
	end)

	PlayerDatastore._initialized = true

	cleanupGlobalDataWaiters()

	startAutosave()
end

-- Read(): Reads the players data, unshards if sharded
-- @param player: The player to read the data for
-- @param table_path: The path to the table to read
-- @return: { [any]: any }
function PlayerDatastore.Read(player: Player, table_path: string): { [any]: any }?
	yieldPlayerData(player.UserId)

	local data = PlayerDatastore.PlayerData[player.UserId]

	if not data then
		warn("Read(): Couldn't find data for player:", player.Name)
		return nil
	end

	local shardedPath = findShardedPath(data, table_path)

	if shardedPath then
		local shardedTable = resolvePath(data, shardedPath)
		local combined = {}

		for i = 1, shardedTable.count do
			local shardKey = getShardKey(player.UserId, shardedPath, i)
			local shardData = PlayerDatastore.ShardData[shardKey]

			if not shardData then
				warn("Read(): Missing shard", shardKey, "for", player.Name)
				return nil
			end

			for k, v in shardData do
				combined[k] = v
			end
		end

		if shardedPath == table_path then
			return combined
		end

		local remainingPath = table_path:match(
			"^" .. shardedPath:gsub("%.", "%%.") .. "%.(.*)"
		) or ""

		return resolvePath(combined, remainingPath)
	end

	return resolvePath(data, table_path)
end

-- Write(): Applies a transform to a player's data at a path
-- @param player: The player whose data is being updated
-- @param write: Types.WriteType (path, transform)
function PlayerDatastore.Write(player: Player, write: Types.WriteType): ()
	yieldPlayerData(player.UserId)
	if PlayerDatastore.SessionLockLost[player.UserId] then
		warn("Write(): Refusing write after session-lock ownership was lost for", player.Name)
		return
	end

	local ok = acquireWriteLock(player.UserId)
	if not ok then return end

	local data = PlayerDatastore.PlayerData[player.UserId]
	if not data then
		warn("Write(): No data for player:", player.Name, "; write dropped")
		releaseWriteLock(player.UserId)
		return
	end

	local shardedPath = findShardedPath(data, write.path)
	local prevShardCount = 0

	if shardedPath then
		local shardedTable = resolvePath(data, shardedPath)
		prevShardCount = shardedTable.count or 0
		local combined = {}
		local missingShard = false

		for i = 1, prevShardCount do
			local shardKey = getShardKey(player.UserId, shardedPath, i)
			local shardData = PlayerDatastore.ShardData[shardKey]

			if not shardData then
				missingShard = true
				break
			end
			for k, v in shardData do combined[k] = v end
		end

		if missingShard then
			warn("Write(): Missing shard for", player.Name, "; write dropped")
			releaseWriteLock(player.UserId)
			return
		end

		for i = 1, prevShardCount do
			PlayerDatastore.ShardData[getShardKey(player.UserId, shardedPath, i)] = nil
		end

		setPath(data, shardedPath, combined)
	end

	local success, failure = pcall(function()
		local currentValue = resolvePath(data, write.path)
		if currentValue == nil then
			error(`Write(): Couldn't find value: {write.path}`)
		end

		local newValue = write.transform(currentValue)
		setPath(data, write.path, newValue)
	end)

	if not success then
		warn("Write(): Failed to apply transform for", player.Name, ":", failure)

		if shardedPath then
			PlayerDatastore.Shard(player, shardedPath, true)
		end

		releaseWriteLock(player.UserId)
		return
	end

	markDirty(player.UserId)

	if shardedPath then
		PlayerDatastore.Shard(player, shardedPath, true)

		local newTable = resolvePath(data, shardedPath)
		local newCount = newTable and newTable.count or 0
		queueShardRemovals(player.UserId, prevShardCount, newCount, function(index)
			return getShardKey(player.UserId, shardedPath, index)
		end)
	end

	releaseWriteLock(player.UserId)
end

-- DeletePlayerData(): Deletes a players data
-- @param player: The player to delete data for
-- @note: This will kick the player after deleting their data, use with caution
function PlayerDatastore.DeletePlayerData(player: Player): ()
	yieldPlayerData(player.UserId)
	if PlayerDatastore.SessionLockLost[player.UserId] then
		warn("DeletePlayerData(): Refusing deletion after session-lock ownership was lost for", player.Name)
		return
	end

	local user_id = player.UserId

	cleanupWriteQueues(player.UserId)

	local shardedFields, globalFields = getPresetFields()

	for _, table_path in shardedFields do
		if table.find(globalFields, table_path) then continue end

		local data = PlayerDatastore.PlayerData[user_id]
		if data then
			local tbl = resolvePath(data, table_path)
			if not isSharded(tbl) then continue end

			for i = 1, tbl.count do
				local shardKey = getShardKey(user_id, table_path, i)
				PlayerDatastore.ShardData[shardKey] = nil

				pcall(function()
					ShardedDataStore:RemoveAsync(shardKey)
				end)
			end
		end
	end

	PlayerDatastore.DirtyData[user_id] = nil
	PlayerDatastore.PlayerData[user_id] = nil
	PlayerDatastore.MetaData[user_id] = nil

	pcall(function()
		PlayerDataStore:RemoveAsync(tostring(user_id))
	end)

	pcall(function()
		PlayerMetaDataStore:RemoveAsync(getMetaKey(user_id))
	end)

	releaseSessionLock(player.UserId)
	player:Kick("[PlayerDatastore]: Your data has been deleted. Please rejoin.")
end

-- DeleteGlobalData(): Deletes a global data key and its shards
-- @param path: The global key to delete
-- @note: This almost should NEVER be used, proceed with caution
-- @return: boolean: Whether the deletion was committed to MemoryStore
function PlayerDatastore.DeleteGlobalData(path: string): boolean
	yieldGlobalData()

	local _, globalFields = getPresetFields()

	if not table.find(globalFields, path) then
		warn("DeleteGlobalData(): Path is not a valid global field:", path)
		return false
	end

	local memorySuccess, memoryCommitted = writeMemoryField(path, function(current): Types.MemoryEntry?
		return { v = math.max(current and current.v or 0, PlayerDatastore.StoredGlobalVersions[path] or 0) + 1 }
	end)

	if not memorySuccess or not memoryCommitted then
		warn("DeleteGlobalData(): Deletion was not committed to MemoryStore; not applied")
		return false
	end

	local tbl = resolvePath(PlayerDatastore.GlobalData, path)

	if isSharded(tbl) then
		queueShardRemovals(Config.DATASTORE.GLOBAL_DATASTORE_KEY, tbl.count, 0, function(index)
			return getShardGlobalKey(path, index)
		end)
	end

	setGlobalField(PlayerDatastore.GlobalData, path, nil)
	PlayerDatastore.MetaData[path] = nil

	markDirty(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
	if saveGlobalData() then
		PlayerDatastore.DirtyData[Config.DATASTORE.GLOBAL_DATASTORE_KEY] = nil
	end
	return true
end

--=========================
-- // COMPLEX WRITE API
--=========================

-- Shard(): Enables sharding for a table path (Check Config.DATASTORE.SHARD_BYTE_LIMIT)
-- @param player: The player to shard
-- @param table_path: Path to the table
-- @param enable: Whether to enable it
-- @note: Disabling while having a sharded table will result in all of the tables combining, likely leading to errors
-- @note: The first entry will always be put, no matter how large it is, subsequent data will be sharded
function PlayerDatastore.Shard(player: Player, table_path: string, enable: boolean): ()
	local data = PlayerDatastore.PlayerData[player.UserId]

	if not data then
		warn("Shard(): Couldn't find data for player:", player.Name)
		return
	end
	local previous = resolvePath(data, table_path)
	local oldCount = if isSharded(previous) then previous.count or 0 else 0

	shardTable(
		function() return resolvePath(data, table_path) end,
		function(value) setPath(data, table_path, value) end,
		function(index) return getShardKey(player.UserId, table_path, index) end,
		enable,
		`Shard({table_path})`
	)

	if enable then
		local updated = resolvePath(data, table_path)
		local newCount = if isSharded(updated) then updated.count or 0 else 0
		queueShardRemovals(player.UserId, oldCount, newCount, function(index)
			return getShardKey(player.UserId, table_path, index)
		end)
	end
end

-- ShardGlobal(): Enables sharding for a global table path
-- @param path: The global key pointing to the table
-- @param enable: Whether to enable sharding
-- @note: Automatically handles unshard + reshard
function PlayerDatastore.ShardGlobal(path: string, enable: boolean): ()
	local previous = resolvePath(PlayerDatastore.GlobalData, path)
	local oldCount = if isSharded(previous) then previous.count or 0 else 0
	shardTable(
		function() return resolvePath(PlayerDatastore.GlobalData, path) end,
		function(value) setPath(PlayerDatastore.GlobalData, path, value) end,
		function(index) return getShardGlobalKey(path, index) end,
		enable,
		`ShardGlobal({path})`
	)

	if enable then
		local updated = resolvePath(PlayerDatastore.GlobalData, path)
		local newCount = if isSharded(updated) then updated.count or 0 else 0
		queueShardRemovals(Config.DATASTORE.GLOBAL_DATASTORE_KEY, oldCount, newCount, function(index)
			return getShardGlobalKey(path, index)
		end)
	end
end

--=========================
-- // GLOBAL WRITE API
--=========================

-- ReadGlobal(): Reads a global table or value, unshards if needed
-- @param path: The global key or nested path to read
-- @return: any: The value stored globally
function PlayerDatastore.ReadGlobal(path: string): any
    yieldGlobalData()

	local field = matchGlobalField(path)
	local entry = if field then readMemoryField(field) else nil
	if not field or not entry then
		return readGlobalLocalFallback(path)
	end

	local liveData = {}
	setGlobalField(liveData, field, entry.d)
	return readGlobalField(liveData, path)
end

-- WriteGlobal(): Applies a transform to a global value at a path
-- @param write: Types.WriteType (path, transform)
-- @return: boolean: Whether the write was committed to MemoryStore; nothing is applied otherwise
function PlayerDatastore.WriteGlobal(write: Types.WriteType): boolean
	yieldGlobalData()

	local field = matchGlobalField(write.path)
	if not field then
		warn("WriteGlobal(): Path doesn't start with a valid global field:", write.path)
		return false
	end

	local success, committed, entry = writeMemoryField(field, function(current): Types.MemoryEntry?
		local base = {}
		setGlobalField(base, field, current and current.d)

		local currentValue = resolvePath(base, write.path)
		if currentValue == nil then
			warn("WriteGlobal(): Couldn't find value:", write.path)
			return nil
		end

		setPath(base, write.path, write.transform(currentValue))
		return { v = (current and current.v or 0) + 1, d = resolvePath(base, field) }
	end)

	if not success or not committed or not entry then
		warn("WriteGlobal(): Write failed to commit to MemoryStore; write not applied")
		return false
	end

	local shardedFields = getPresetFields()
	syncGlobalFromMemory({ [field] = entry.d }, { field }, shardedFields)

	markDirty(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
	return true
end

--=========================
-- // UTILITY API
--=========================

-- GetPlayerData(): Gets a players data
-- @param player: The player to get data for
-- @return: { [any]: any }?
function PlayerDatastore.GetPlayerData(player: Player): { [any]: any }?
	yieldPlayerData(player.UserId)
	local data = PlayerDatastore.PlayerData[player.UserId]
	return data and deepClone(data) or nil
end

-- GetShardData(): Gets a shards data
-- @param player: The player to check yield for
-- @param key?: Optional Key to get shard data for; else returns the entire table
-- @return: { [string]: any } | any
function PlayerDatastore.GetShardData(player: Player, key: string?): { [string]: any } | any
	yieldPlayerData(player.UserId)
	local shard = key and PlayerDatastore.ShardData[key] or PlayerDatastore.ShardData
	return deepClone(shard)
end

-- GetGlobalData(): Gets the global data
-- @param table_path?: The path to the table to get; else returns the entire table
-- @return: { [string]: any } | any
function PlayerDatastore.GetGlobalData(table_path: string?): { [string]: any } | any
	yieldGlobalData()
	local data = table_path and resolvePath(PlayerDatastore.GlobalData, table_path) or PlayerDatastore.GlobalData
	return deepClone(data)
end

--=========================
-- // METADATA API
--=========================

-- GetMetadata(): Gets metadata for a player or global data
-- @param player?: The player to get metadata for; if nil returns global metadata
-- @return: Types.MetaData?
function PlayerDatastore.GetMetadata(player: Player?): Types.MetaData?
	if player then
		yieldPlayerData(player.UserId)
		return PlayerDatastore.MetaData[player.UserId]
	end

	yieldGlobalData()

	return PlayerDatastore.MetaData[Config.DATASTORE.GLOBAL_DATASTORE_KEY]
end

--=========================
-- // VERSIONING API
--=========================

-- RegisterMigration(): Registers a migration function for a version transition
-- @param from_version: string
-- @param to_version: string
-- @param migration: Types.MigrationFunction
-- @note: Only linear chains are supported, one outgoing migration per source version
-- @note: If ShardedFields changed between versions, manually unshard affected fields inside the migration function before transforming them, as only current ShardedFields are automatically unsharded before migration runs
function PlayerDatastore.RegisterMigration(from_version: string, to_version: string, migration: Types.MigrationFunction): ()
	if PlayerDatastore.Migrations[from_version] then
		error(`RegisterMigration(): A migration from '{from_version}' already exists. Only linear chains are supported.`)
	end

	PlayerDatastore.Migrations[from_version] = { To = to_version, Fn = migration }
end

--=========================
-- // SNAPSHOT API
--=========================

-- CreateSnapshot(): Creates a named snapshot of a path in a players data or global data (NOTE: Sharded data will be unsharded in the snapshot, and restoring will restore it as sharded)
-- @param name: string
-- @param path: string
-- @param player?: Player; if nil snapshots global data at path
function PlayerDatastore.CreateSnapshot(name: string, path: string, player: Player?): ()
	local user_id: (number | string)? = nil
	local value: any = nil

	if player then
		user_id = player.UserId
		value = PlayerDatastore.Read(player, path)
	else
		yieldGlobalData()
		user_id = Config.DATASTORE.GLOBAL_DATASTORE_KEY

		if path == "" then
			local liveData, _, success = readMemoryGlobal()
			value = if success then liveData else nil
		else
			value = PlayerDatastore.ReadGlobal(path)
		end
	end

	if value == nil then
		warn("CreateSnapshot(): Path not found:", path)
		return
	end

	local snapshot: Types.SnapshotEntry = {
		Path = path,
		Data = deepClone(value),
		Timestamp = os.time(),
		Version = PlayerDatastore.CurrentVersion
	}

	saveSnapshot(user_id :: number | string, name, snapshot)
end

-- RestoreSnapshot(): Restores a named snapshot, overwriting current data at that path
-- @param name: string
-- @param player?: Player; if nil restores global data
function PlayerDatastore.RestoreSnapshot(name: string, player: Player?): ()
	local user_id: (number | string)? = nil

	if player then
		user_id = player.UserId
	else
		yieldGlobalData()
		user_id = Config.DATASTORE.GLOBAL_DATASTORE_KEY
	end

	local snapshots = loadSnapshots(user_id :: number | string)
	local snapshot = snapshots[name]

	if not snapshot then
		warn("RestoreSnapshot(): Snapshot not found:", name)
		return
	end

	local snapshotData: any = snapshot.Data
	if snapshotData == nil then
		local success, stored = pcall(function()
			local encoded = snapshot.Key and SnapshotDataStore:GetAsync(snapshot.Key)
			return encoded and HttpService:JSONDecode(encoded)
		end)
		if not success or not stored then
			warn("RestoreSnapshot(): Failed to load snapshot data:", name)
			return
		end
		snapshotData = stored.Data
	end

	if player then
		local data = PlayerDatastore.PlayerData[user_id :: number]
		if not data then
			warn("RestoreSnapshot(): No player data found for", player.Name)
			return
		end

		if snapshot.Path == "" then
			PlayerDatastore.PlayerData[user_id :: number] = deepClone(snapshotData)
		else
			setPath(data, snapshot.Path, deepClone(snapshotData))
		end

		local shardedFields, globalFields = getPresetFields()

		if snapshot.Path ~= "" and table.find(shardedFields, snapshot.Path) and not table.find(globalFields, snapshot.Path) then
			PlayerDatastore.Shard(player, snapshot.Path, true)
		end

		markDirty(user_id :: number | string)
	else
		local shardedFields, globalFields = getPresetFields()
		local matched = if snapshot.Path == "" then nil else matchGlobalField(snapshot.Path)
		if snapshot.Path ~= "" and not matched then
			warn("RestoreSnapshot(): Snapshot path is not a global field:", snapshot.Path)
			return
		end
		local fields: { string } = if matched then { matched } else globalFields

		for _, field in fields do
			if snapshot.Path == "" and readGlobalField(snapshotData, field) == nil then continue end
			local success, committed, entry = writeMemoryField(field, function(current): Types.MemoryEntry?
				local base = if snapshot.Path == "" then deepClone(snapshotData) else {}
				if snapshot.Path ~= "" then
					setGlobalField(base, field, current and current.d)
					setGlobalField(base, snapshot.Path, deepClone(snapshotData))
				end
				return { v = math.max(current and current.v or 0, PlayerDatastore.StoredGlobalVersions[field] or 0) + 1, d = readGlobalField(base, field) }
			end)

			if not success or not committed or not entry then
				warn("RestoreSnapshot(): Global write failed to commit for", field, "; restore not applied")
				return
			end

			syncGlobalFromMemory({ [field] = entry.d }, { field }, shardedFields)
			markDirty(Config.DATASTORE.GLOBAL_DATASTORE_KEY)
		end
	end
end

-- DeleteSnapshot(): Deletes a named snapshot
-- @param name: string
-- @param player?: Player; if nil deletes from global snapshots
function PlayerDatastore.DeleteSnapshot(name: string, player: Player?): ()
	local user_id: (number | string)? = nil

	if player then
		user_id = player.UserId
	else
		yieldGlobalData()
		user_id = Config.DATASTORE.GLOBAL_DATASTORE_KEY
	end

	updateSnapshots(user_id :: number | string, function(snapshots)
		if not snapshots[name] then
			warn("DeleteSnapshot(): Snapshot not found:", name)
			return snapshots
		end

		snapshots[name] = nil
		return snapshots
	end)
end

-- ListSnapshots(): Lists all snapshots for a player or global
-- @param player?: Player; if nil lists global snapshots
-- @return: { [string]: Types.SnapshotEntry }?
function PlayerDatastore.ListSnapshots(player: Player?): { [string]: Types.SnapshotEntry }?
	local user_id: (number | string)? = nil

	if player then
		user_id = player.UserId
	else
		yieldGlobalData()
		user_id = Config.DATASTORE.GLOBAL_DATASTORE_KEY
	end

	return loadSnapshots(user_id :: number | string)
end

--=========================
-- // INIT
--=========================

task.delay(Config.DATASTORE.INIT_YIELD_TIME, function()
	if PlayerDatastore._initialized then return end

	warn("PlayerDatastore: Init() was not called within INIT_YIELD_TIME; Unblocking all waiters")

	cleanupGlobalDataWaiters()
end)

return PlayerDatastore